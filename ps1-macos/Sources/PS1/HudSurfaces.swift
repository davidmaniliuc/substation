/// A part of the HUD that, while open, keeps the HUD on screen.
enum HudSurface: Hashable { case speedTab, saveStates, pauseMenu }

/// Where the Save States panel was opened from. It decides which button the
/// panel's sheet offers first: a player who chose Save State means to save.
enum SaveStatesOrigin: Equatable { case bar, menuSave, menuLoad }

/// Which HUD surfaces are open, and the pause they own.
///
/// The menu and the panel pause the game while either is open, and on the
/// last one closing hand back the pause from BEFORE the first opened: a game
/// the player had already paused stays paused. The speed tab only holds the
/// HUD up. A value type fed the current pause, so the rule is reachable from
/// a test without a window, as `VolumeControlState` is.
struct HudSurfaces {
    private(set) var open: Set<HudSurface> = []
    private var pausedBefore = false

    var holdsHUD: Bool { !open.isEmpty }
    /// The menu or the panel is open: the game is paused, and the keys and
    /// the controller drive the surface instead of the game.
    var pausesGame: Bool { open.contains(.saveStates) || open.contains(.pauseMenu) }

    /// Opens or closes `surface`. Returns the pause state to apply, or nil to
    /// leave it as it is.
    mutating func set(_ surface: HudSurface, open isOpen: Bool, paused: Bool) -> Bool? {
        let wasPausing = pausesGame
        if isOpen { open.insert(surface) } else { open.remove(surface) }
        switch (wasPausing, pausesGame) {
        case (false, true):
            pausedBefore = paused
            return true
        case (true, false):
            return pausedBefore
        default:
            return nil
        }
    }

    /// Closes everything at once, for an eject, a disc swap or an exit
    /// prompt. Returns the pause to apply, as `set` does.
    mutating func closeAll() -> Bool? {
        let wasPausing = pausesGame
        open = []
        return wasPausing ? pausedBefore : nil
    }
}
