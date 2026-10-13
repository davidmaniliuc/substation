/// One step of keyboard or controller input to a HUD surface: the arrows or
/// D-pad, Return/✕ and Esc/○.
enum MenuMove: Hashable { case up, down, left, right, confirm, back }

/// The pause menu's rows that take the highlight, top to bottom. About This
/// Game is read-only and takes none.
enum PauseMenuItem: CaseIterable, Hashable {
    case saveStates, disc, speed, resolution, volume, pgxp, analog, reset, quitGame
}

/// A Quick Settings control, as a step or a toggle names it.
enum QuickSetting: Equatable { case speed, resolution, volume, pgxp, analog }

/// What a move asks the model to do. Moving the highlight and picking a disc
/// the navigation does on its own.
enum PauseMenuAction: Equatable {
    case none, close
    case saveStates
    case reset, quitGame
    /// ← or →: one step down or up. A switch takes Off or On; nothing wraps.
    case adjust(QuickSetting, Int)
    /// Return on a switch flips it; on Volume it mutes.
    case toggle(QuickSetting)
    case insertDisc(Int)
}

/// Where the pause menu's highlight is and what a move does to it. One flat
/// list: ↑↓ move the highlight, ←→ change the setting under it, Return
/// toggles or opens it, and with nothing highlighted Return resumes. A value
/// type, so the rules are tested without a window; the view renders it and
/// the pointer goes through `point` and the same `handle` the keys do.
struct PauseMenuNavigation {
    /// The highlighted row, or nil.
    private(set) var focus: PauseMenuItem?
    /// The last highlight came from a key or the controller. Only then does
    /// the list scroll to it: the pointer's highlight never scrolls.
    private(set) var focusFromKeys = false
    /// The disc ←→ picked on the Disc row; Return inserts it.
    private(set) var discChoice = 0
    private(set) var discCount = 1
    private(set) var insertedDisc = 0
    /// PGXP while the game's preset decides it: greyed, never highlighted.
    private(set) var pgxpLocked = false

    /// For each opening of the menu: nothing highlighted, so Return resumes.
    mutating func open(discCount: Int, insertedDisc: Int, pgxpLocked: Bool) {
        self = PauseMenuNavigation()
        self.discCount = discCount
        self.insertedDisc = insertedDisc
        self.pgxpLocked = pgxpLocked
        discChoice = insertedDisc
    }

    /// The Disc row exists only for a game with more than one disc.
    func isShown(_ item: PauseMenuItem) -> Bool { item != .disc || discCount > 1 }

    func isEnabled(_ item: PauseMenuItem) -> Bool { isShown(item) && !(item == .pgxp && pgxpLocked) }

    mutating func handle(_ move: MenuMove) -> PauseMenuAction {
        switch move {
        case .up: step(by: -1)
        case .down: step(by: 1)
        case .left: return adjust(by: -1)
        case .right: return adjust(by: 1)
        case .confirm: return confirm()
        case .back: return .close
        }
        return .none
    }

    /// The pointer entered `item`'s row.
    mutating func point(at item: PauseMenuItem) {
        guard isEnabled(item) else { return }
        focus = item
        focusFromKeys = false
    }

    /// The pointer left `item`'s row. A highlight the keys have since moved
    /// elsewhere stays.
    mutating func leave(_ item: PauseMenuItem) {
        if focus == item { focus = nil }
    }

    private mutating func adjust(by delta: Int) -> PauseMenuAction {
        switch focus {
        case .saveStates:
            // Right enters what has a › beside it.
            return delta > 0 ? .saveStates : .none
        case .disc:
            discChoice = min(max(discChoice + delta, 0), discCount - 1)
        case .speed: return .adjust(.speed, delta)
        case .resolution: return .adjust(.resolution, delta)
        case .volume: return .adjust(.volume, delta)
        case .pgxp: return .adjust(.pgxp, delta)
        case .analog: return .adjust(.analog, delta)
        case .reset, .quitGame, nil: break
        }
        return .none
    }

    private func confirm() -> PauseMenuAction {
        switch focus {
        case nil: .close
        case .saveStates: .saveStates
        case .disc: discChoice == insertedDisc ? .none : .insertDisc(discChoice)
        case .speed, .resolution: .none
        case .volume: .toggle(.volume)
        case .pgxp: .toggle(.pgxp)
        case .analog: .toggle(.analog)
        case .reset: .reset
        case .quitGame: .quitGame
        }
    }

    /// Up or down one row, past disabled ones, stopping at the ends. From no
    /// highlight, down lands on the first row and up on the last.
    private mutating func step(by delta: Int) {
        let rows = PauseMenuItem.allCases.filter(isEnabled)
        focusFromKeys = true
        guard let current = focus.flatMap(rows.firstIndex(of:)) else {
            focus = delta > 0 ? rows.first : rows.last
            return
        }
        focus = rows[min(max(current + delta, 0), rows.count - 1)]
    }
}
