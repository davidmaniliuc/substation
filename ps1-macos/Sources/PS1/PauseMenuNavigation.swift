/// One step of keyboard or controller input to a HUD surface: the arrows or
/// D-pad, Return/✕ and Esc/○.
enum MenuMove: Equatable { case up, down, left, right, confirm, back }

enum PauseMenuPage: Equatable { case root, quickSettings, gameInfo }

/// The root page's rows, top to bottom.
enum PauseMenuRow: CaseIterable, Equatable {
    case resume, saveState, loadState, changeDisc, quickSettings, gameInfo, reset, quitGame
}

/// Quick Settings' rows, top to bottom. Each is a stepper, never a cycle.
enum QuickSetting: CaseIterable, Equatable { case speed, resolution, pgxp, analog, volume }

/// What a move asks the model to do. Everything else (moving the highlight,
/// changing page, the disc flyout) the navigation does on its own.
enum PauseMenuAction: Equatable {
    case none, close
    case saveStates(SaveStatesOrigin)
    case reset, quitGame
    case adjust(QuickSetting, Int)
    case insertDisc(Int)
}

/// Where the pause menu's highlight is and what a move does to it. A value
/// type, so the rules are tested without a window; the view renders it and
/// the mouse goes through `point` and the same `handle` the keys do.
struct PauseMenuNavigation {
    private(set) var page: PauseMenuPage = .root
    /// The highlighted row of the current page.
    private(set) var selection = 0
    /// The highlighted disc while Change Disc's flyout is open.
    private(set) var flyout: Int?
    var discCount = 1
    var insertedDisc = 0

    /// Change Disc for a game with one disc: greyed, never highlighted.
    func isDisabled(_ row: PauseMenuRow) -> Bool {
        row == .changeDisc && discCount < 2
    }

    /// Back to the root on Resume, for each opening of the menu.
    mutating func reset() {
        page = .root
        selection = 0
        flyout = nil
    }

    mutating func handle(_ move: MenuMove) -> PauseMenuAction {
        if flyout != nil { return handleFlyout(move) }
        switch page {
        case .root: return handleRoot(move)
        case .quickSettings: return handleQuickSettings(move)
        case .gameInfo: return handleGameInfo(move)
        }
    }

    /// A hover or click on row `index` of the current page. Moving off
    /// Change Disc closes its flyout.
    mutating func point(at index: Int) {
        switch page {
        case .root:
            guard PauseMenuRow.allCases.indices.contains(index),
                  !isDisabled(PauseMenuRow.allCases[index]) else { return }
            if index != selection { flyout = nil }
            selection = index
        case .quickSettings:
            if QuickSetting.allCases.indices.contains(index) { selection = index }
        case .gameInfo:
            break
        }
    }

    mutating func pointFlyout(at index: Int) {
        if flyout != nil, (0..<discCount).contains(index) { flyout = index }
    }

    private mutating func handleRoot(_ move: MenuMove) -> PauseMenuAction {
        let row = PauseMenuRow.allCases[selection]
        switch move {
        case .up: step(by: -1)
        case .down: step(by: 1)
        case .back: return .close
        case .left: break
        case .right:
            // Right only enters what has a › beside it.
            if [.saveState, .loadState, .changeDisc, .quickSettings, .gameInfo].contains(row) {
                return activate(row)
            }
        case .confirm: return activate(row)
        }
        return .none
    }

    private mutating func activate(_ row: PauseMenuRow) -> PauseMenuAction {
        switch row {
        case .resume: return .close
        case .saveState: return .saveStates(.menuSave)
        case .loadState: return .saveStates(.menuLoad)
        case .changeDisc:
            flyout = insertedDisc == 0 && discCount > 1 ? 1 : 0
        case .quickSettings: enter(.quickSettings)
        case .gameInfo: enter(.gameInfo)
        case .reset: return .reset
        case .quitGame: return .quitGame
        }
        return .none
    }

    private mutating func handleFlyout(_ move: MenuMove) -> PauseMenuAction {
        guard let disc = flyout else { return .none }
        switch move {
        case .up: flyout = max(0, disc - 1)
        case .down: flyout = min(discCount - 1, disc + 1)
        case .left, .back: flyout = nil
        case .right: break
        case .confirm:
            flyout = nil
            if disc != insertedDisc { return .insertDisc(disc) }
        }
        return .none
    }

    private mutating func handleQuickSettings(_ move: MenuMove) -> PauseMenuAction {
        let setting = QuickSetting.allCases[selection]
        switch move {
        case .up: selection = max(0, selection - 1)
        case .down: selection = min(QuickSetting.allCases.count - 1, selection + 1)
        case .left: return .adjust(setting, -1)
        case .right, .confirm: return .adjust(setting, 1)
        case .back: leave(.quickSettings)
        }
        return .none
    }

    private mutating func handleGameInfo(_ move: MenuMove) -> PauseMenuAction {
        if move == .back || move == .left { leave(.gameInfo) }
        return .none
    }

    private mutating func enter(_ next: PauseMenuPage) {
        page = next
        selection = 0
    }

    /// Back to the root with the highlight on the row the page came from.
    private mutating func leave(_ current: PauseMenuPage) {
        let row: PauseMenuRow = current == .quickSettings ? .quickSettings : .gameInfo
        page = .root
        selection = PauseMenuRow.allCases.firstIndex(of: row) ?? 0
    }

    /// Up or down one row, past disabled ones, stopping at the ends.
    private mutating func step(by delta: Int) {
        let rows = PauseMenuRow.allCases
        var next = selection + delta
        while rows.indices.contains(next) && isDisabled(rows[next]) { next += delta }
        if rows.indices.contains(next) { selection = next }
    }
}
