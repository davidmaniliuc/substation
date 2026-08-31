import Foundation

/// When a dirtied memory card should be written to disk.
///
/// A value type with no clock and no I/O of its own, like `FpsCounter` and
/// `InternalResolution`: the rule is then reachable from a test with synthetic
/// timestamps, which is the only way to check a one-second debounce without
/// spending a second per case.
///
/// The window restarts on every new write rather than counting from the first,
/// because what is being waited out is a BURST — a game committing a save
/// writes ten or so 128-byte blocks back to back, and each one raises the
/// dirty flag.
struct MemoryCardFlushPolicy {
    /// Long enough to swallow a save's burst of blocks, short enough that a
    /// force-quit a moment later still finds the save on disk.
    static let settleDelay = 1.0

    private var pendingSince: Double?

    var hasPendingWrite: Bool { pendingSince != nil }

    /// `dirty` is whether the core reported new bytes on this tick.
    mutating func shouldWrite(dirty: Bool, now: Double) -> Bool {
        if dirty { pendingSince = now }
        guard let since = pendingSince, now >= since + Self.settleDelay else { return false }
        pendingSince = nil
        return true
    }
}
