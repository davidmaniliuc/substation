import Foundation

/// Active play time: the clock runs only while a game is running, unpaused,
/// AND the app is in front.
///
/// The third condition is its own input because the app does not pause a
/// game when it goes to the background: the emulator keeps running behind
/// other windows, and a game left open overnight is not a game played.
///
/// Times are `ProcessInfo.systemUptime`, not `Date`: uptime stops while the
/// Mac sleeps, which does not resign app-active, so a lid closed mid-game
/// would otherwise bank the whole night. It also ignores wall-clock jumps.
///
/// A value type fed timestamps, like `FpsCounter`, so the rule is reachable
/// from a test with synthetic times and no window.
struct PlayClock {
    /// The uptime the current counting stretch began at, or nil while stopped.
    private var since: TimeInterval?

    /// Applies the three inputs as of `now`, a `systemUptime` reading.
    /// Returns the seconds banked by this call: the length of the stretch it
    /// ended, or 0 when it ended none.
    /// The stretch in progress as of `now`, or 0 while stopped: what has
    /// been played but not yet banked.
    func elapsed(at now: TimeInterval) -> TimeInterval {
        since.map { max(0, now - $0) } ?? 0
    }

    mutating func update(running: Bool, paused: Bool, active: Bool,
                         at now: TimeInterval) -> TimeInterval {
        let counting = running && !paused && active
        switch (since, counting) {
        case (nil, true):
            since = now
            return 0
        case (let start?, false):
            since = nil
            return max(0, now - start)
        default:
            return 0
        }
    }
}
