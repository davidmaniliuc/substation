import Foundation

/// Active play since the last timed auto-save, on `PlayClock`'s terms: the
/// caller passes "running, unpaused and the app in front" as `counting`, and
/// times are `systemUptime`, so a game paused, left behind other windows or
/// asleep under a closed lid does not keep rewriting its resume state.
///
/// A value type fed timestamps, like `PlayClock`, so the rule is reachable
/// from a test with synthetic times and no window.
struct AutoSaveClock {
    private var banked: TimeInterval = 0
    /// The uptime the current counting stretch began at, or nil while stopped.
    private var since: TimeInterval?

    mutating func update(counting: Bool, at now: TimeInterval) {
        switch (since, counting) {
        case (nil, true):
            since = now
        case (let start?, false):
            banked += max(0, now - start)
            since = nil
        default:
            break
        }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        banked + (since.map { max(0, now - $0) } ?? 0)
    }

    /// After a save, a load or a new game: count again from zero.
    mutating func restart(at now: TimeInterval) {
        banked = 0
        if since != nil { since = now }
    }
}
