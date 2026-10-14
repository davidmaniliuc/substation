/// A button in the bar under the list, for the selected row.
enum StateButton: Hashable { case delete, overwrite, load, save }

/// A button in the confirmation a destructive bar button asks first.
enum SlotSheetButton: Hashable { case cancel, overwrite, delete }

enum SaveStatesAction: Equatable {
    case none, close
    case load(StateSource)
    case save(Int)
    case delete(StateSource)
}

/// The confirmation over the panel: its buttons, left to right, and which
/// one Return would press.
struct SlotSheetState: Equatable {
    let row: Int
    let buttons: [SlotSheetButton]
    var index: Int

    var highlighted: SlotSheetButton { buttons[index] }
}

/// The Save States panel's list and the bar under it. Row 0 is Resume, rows
/// 1-6 the slots. ↑↓ select a row, ←→ move along the bar, Return presses the
/// bar's highlighted button, which starts on the primary one: Load, or Save
/// Here for an empty slot. Overwrite and Delete ask first; nothing else does,
/// since a save to an empty slot and a load lose nothing.
struct SaveStatesNavigation {
    private(set) var selection: Int
    /// Which of the selected row's bar buttons Return presses.
    private(set) var button: StateButton
    private(set) var sheet: SlotSheetState?
    /// The rows holding a state.
    private(set) var filled: Set<Int>
    /// Whether the bar's highlight is drawn as a focus ring: only once a key
    /// or the controller has moved. The list's selection is always drawn.
    private(set) var showsFocus = false

    static let rows = 0...6

    init(filled: Set<Int>) {
        self.filled = filled
        let first = Self.rows.first { filled.contains($0) } ?? 1
        selection = first
        button = Self.buttons(row: first, filled: filled.contains(first)).last!
    }

    /// Resume only when there is one: the app writes it, never the player.
    func isSelectable(_ row: Int) -> Bool {
        row == 0 ? filled.contains(0) : StateSource.slots.contains(row)
    }

    /// The bar for a row, the primary button last.
    static func buttons(row: Int, filled: Bool) -> [StateButton] {
        if !filled { return [.save] }
        return row == 0 ? [.delete, .load] : [.delete, .overwrite, .load]
    }

    var buttons: [StateButton] { Self.buttons(row: selection, filled: filled.contains(selection)) }

    /// A click on a row.
    mutating func select(_ row: Int) {
        guard sheet == nil, isSelectable(row) else { return }
        showsFocus = false
        moveTo(row)
    }

    /// A double click on a row: its primary button.
    mutating func activate(_ row: Int) -> SaveStatesAction {
        guard sheet == nil, isSelectable(row) else { return .none }
        moveTo(row)
        return press(buttons.last!)
    }

    /// A bar button, clicked or pressed with Return.
    mutating func press(_ pressed: StateButton) -> SaveStatesAction {
        guard sheet == nil, buttons.contains(pressed) else { return .none }
        button = pressed
        let row = selection
        switch pressed {
        case .load: return .load(Self.source(row))
        case .save: return .save(row)
        case .overwrite: sheet = SlotSheetState(row: row, buttons: [.cancel, .overwrite], index: 1)
        case .delete: sheet = SlotSheetState(row: row, buttons: [.cancel, .delete], index: 0)
        }
        return .none
    }

    /// A confirmation button.
    mutating func answer(_ pressed: SlotSheetButton) -> SaveStatesAction {
        guard let row = sheet?.row else { return .none }
        sheet = nil
        switch pressed {
        case .cancel: return .none
        case .overwrite: return .save(row)
        case .delete: return .delete(Self.source(row))
        }
    }

    /// A save finished: the row now holds a state, and its bar changes under
    /// the selection.
    mutating func saved(_ row: Int) {
        filled.insert(row)
        if row == selection { button = buttons.last! }
    }

    /// After a delete: the row is empty, and an emptied Resume can no longer
    /// hold the selection.
    mutating func removed(_ row: Int) {
        filled.remove(row)
        moveTo(isSelectable(selection) ? selection : 1)
    }

    static func source(_ row: Int) -> StateSource { row == 0 ? .resume : .slot(row) }
    static func row(_ source: StateSource) -> Int {
        if case .slot(let n) = source { n } else { 0 }
    }

    mutating func handle(_ move: MenuMove) -> SaveStatesAction {
        showsFocus = true
        if var open = sheet {
            switch move {
            case .left: open.index = max(0, open.index - 1)
            case .right: open.index = min(open.buttons.count - 1, open.index + 1)
            case .up, .down: break
            case .confirm: return answer(open.highlighted)
            case .back: sheet = nil; return .none
            }
            sheet = open
            return .none
        }
        switch move {
        case .back: return .close
        case .confirm: return press(button)
        case .up: if let row = Self.rows.reversed().first(where: { $0 < selection && isSelectable($0) }) { moveTo(row) }
        case .down: if selection < Self.rows.upperBound { moveTo(selection + 1) }
        case .left, .right:
            let bar = buttons
            let i = bar.firstIndex(of: button) ?? bar.count - 1
            button = bar[move == .left ? max(0, i - 1) : min(bar.count - 1, i + 1)]
        }
        return .none
    }

    /// A new row starts its bar on the primary button.
    private mutating func moveTo(_ row: Int) {
        selection = row
        button = buttons.last!
    }
}
