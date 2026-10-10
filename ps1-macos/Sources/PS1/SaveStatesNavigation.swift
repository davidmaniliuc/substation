/// A button in the sheet a picked tile opens.
enum SlotSheetButton: Hashable { case cancel, overwrite, saveHere, load }

enum SaveStatesAction: Equatable {
    case none, close
    case load(StateSource)
    case save(Int)
}

/// The sheet over a picked tile: its buttons, left to right, and which one
/// Return would press.
struct SlotSheetState: Equatable {
    let tile: Int
    let buttons: [SlotSheetButton]
    var index: Int

    var highlighted: SlotSheetButton { buttons[index] }
}

/// Where the Save States panel's highlight is and what a move does. Tile 0 is
/// Resume, in a column of its own; slot n sits at column `(n - 1) % 3 + 1`,
/// row `(n - 1) / 3`. Nothing is written by one move: a tile only opens its
/// sheet, and the sheet's button is a second, deliberate step.
struct SaveStatesNavigation {
    private(set) var selection: Int
    private(set) var sheet: SlotSheetState?
    /// The tiles holding a state.
    let filled: Set<Int>
    let origin: SaveStatesOrigin

    init(filled: Set<Int>, origin: SaveStatesOrigin) {
        self.filled = filled
        self.origin = origin
        let firstSave = ([0] + Array(StateSource.slots)).first { filled.contains($0) }
        selection = origin == .menuSave ? 1 : firstSave ?? 1
    }

    /// Resume only when there is one: the app writes it, never the player.
    func isSelectable(_ tile: Int) -> Bool {
        tile == 0 ? filled.contains(0) : StateSource.slots.contains(tile)
    }

    static func buttons(tile: Int, filled: Bool) -> [SlotSheetButton] {
        if tile == 0 { return [.cancel, .load] }
        return filled ? [.cancel, .overwrite, .load] : [.cancel, .saveHere]
    }

    mutating func point(at tile: Int) {
        if sheet == nil, isSelectable(tile) { selection = tile }
    }

    /// A click on a tile, or Return on the highlighted one: opens its sheet
    /// on the button the player most likely means.
    mutating func pick(_ tile: Int) {
        guard isSelectable(tile) else { return }
        selection = tile
        let buttons = Self.buttons(tile: tile, filled: filled.contains(tile))
        let wanted: SlotSheetButton = origin == .menuSave && tile != 0
            ? (filled.contains(tile) ? .overwrite : .saveHere)
            : (filled.contains(tile) ? .load : .saveHere)
        sheet = SlotSheetState(tile: tile, buttons: buttons,
                               index: buttons.firstIndex(of: wanted) ?? buttons.count - 1)
    }

    mutating func press(_ button: SlotSheetButton) -> SaveStatesAction {
        guard let tile = sheet?.tile else { return .none }
        sheet = nil
        switch button {
        case .cancel: return .none
        case .load: return .load(tile == 0 ? .resume : .slot(tile))
        case .overwrite, .saveHere: return .save(tile)
        }
    }

    mutating func handle(_ move: MenuMove) -> SaveStatesAction {
        if var open = sheet {
            switch move {
            case .left: open.index = max(0, open.index - 1)
            case .right: open.index = min(open.buttons.count - 1, open.index + 1)
            case .up, .down: break
            case .confirm: return press(open.highlighted)
            case .back: sheet = nil; return .none
            }
            sheet = open
            return .none
        }
        switch move {
        case .back: return .close
        case .confirm: pick(selection)
        case .left: moveTo(selection == 0 ? nil : Self.column(selection) == 1 ? 0 : selection - 1)
        case .right: moveTo(selection == 0 ? 1 : Self.column(selection) == 3 ? nil : selection + 1)
        case .up: moveTo(selection > 3 ? selection - 3 : nil)
        case .down: moveTo(selection != 0 && selection <= 3 ? selection + 3 : nil)
        }
        return .none
    }

    private mutating func moveTo(_ tile: Int?) {
        if let tile, isSelectable(tile) { selection = tile }
    }

    private static func column(_ tile: Int) -> Int { (tile - 1) % 3 + 1 }
}
