import Foundation

/// Active play time: the clock runs only while a game is running, unpaused,
/// AND the app is in front.
///
/// The third condition is its own input because the app does not pause a
/// game when it goes to the background: the emulator keeps running behind
/// other windows, and a game left open overnight is not a game played.
///
/// A value type fed timestamps, like `FpsCounter`, so the rule is reachable
/// from a test with synthetic times and no window.
struct PlayClock {
    /// When the current counting stretch began, or nil while stopped.
    private var since: Date?

    /// Applies the three inputs as of `now`. Returns the seconds banked by
    /// this call: the length of the stretch it ended, or 0 when it ended none.
    mutating func update(running: Bool, paused: Bool, active: Bool,
                         at now: Date) -> TimeInterval {
        let counting = running && !paused && active
        switch (since, counting) {
        case (nil, true):
            since = now
            return 0
        case (let start?, false):
            since = nil
            return max(0, now.timeIntervalSince(start))
        default:
            return 0
        }
    }
}
