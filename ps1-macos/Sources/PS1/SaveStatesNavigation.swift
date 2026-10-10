/// A button in the sheet a picked tile opens.
enum SlotSheetButton: Hashable { case cancel, overwrite, load, delete }

/// A control in a tile's corner, shown under the pointer.
enum TileCorner { case load, save, delete }

enum SaveStatesAction: Equatable {
    case none, close
    case load(StateSource)
    case save(Int)
    case delete(StateSource)
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
    private(set) var filled: Set<Int>
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

    /// A filled tile's sheet; an empty slot has none.
    static func buttons(tile: Int) -> [SlotSheetButton] {
        tile == 0 ? [.cancel, .load] : [.cancel, .overwrite, .load]
    }

    /// Whether the highlight is drawn: only once a key or the controller
    /// has moved it. Under the pointer a tile shows its hover instead, as
    /// the resume sheet's do.
    private(set) var showsSelection = false

    mutating func point(at tile: Int) {
        guard sheet == nil else { return }
        showsSelection = false
        if isSelectable(tile) { selection = tile }
    }

    /// A click on a tile, or Return on the highlighted one. An empty slot
    /// saves at once, since nothing is lost; a filled tile opens its sheet on
    /// the button the player most likely means.
    mutating func pick(_ tile: Int) -> SaveStatesAction {
        guard isSelectable(tile) else { return .none }
        selection = tile
        guard filled.contains(tile) else { return .save(tile) }
        let buttons = Self.buttons(tile: tile)
        let wanted: SlotSheetButton = origin == .menuSave && tile != 0 ? .overwrite : .load
        sheet = SlotSheetState(tile: tile, buttons: buttons,
                               index: buttons.firstIndex(of: wanted) ?? buttons.count - 1)
        return .none
    }

    /// A filled tile's corner control. Loading loses no save, so it acts at
    /// once; an overwrite and a delete open a sheet first, on Overwrite and
    /// on Cancel respectively.
    mutating func corner(_ corner: TileCorner, on tile: Int) -> SaveStatesAction {
        guard sheet == nil, isSelectable(tile) else { return .none }
        selection = tile
        let isFilled = filled.contains(tile)
        switch corner {
        case .load:
            return isFilled ? .load(Self.source(tile)) : .none
        case .save:
            if tile == 0 || !isFilled { return .none }
            sheet = SlotSheetState(tile: tile, buttons: [.cancel, .overwrite], index: 1)
        case .delete:
            if isFilled { sheet = SlotSheetState(tile: tile, buttons: [.cancel, .delete], index: 0) }
        }
        return .none
    }

    mutating func press(_ button: SlotSheetButton) -> SaveStatesAction {
        guard let tile = sheet?.tile else { return .none }
        sheet = nil
        switch button {
        case .cancel: return .none
        case .load: return .load(Self.source(tile))
        case .overwrite: return .save(tile)
        case .delete: return .delete(Self.source(tile))
        }
    }

    /// After a delete: the tile is empty, and an emptied Resume can no longer
    /// hold the highlight.
    mutating func removed(_ tile: Int) {
        filled.remove(tile)
        if !isSelectable(selection) { selection = 1 }
    }

    static func source(_ tile: Int) -> StateSource { tile == 0 ? .resume : .slot(tile) }
    static func tile(_ source: StateSource) -> Int {
        if case .slot(let n) = source { n } else { 0 }
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
        showsSelection = true
        switch move {
        case .back: return .close
        case .confirm: return pick(selection)
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
