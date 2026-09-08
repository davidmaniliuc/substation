import Foundation

/// Which discs a cover sweep should actually fetch.
///
/// A value type, so the rule is reachable from a test without a window, a
/// network or a library — the same reason `MemoryCardFlushPolicy` and
/// `FpsCounter` are ones.
struct CoverSweepPolicy {
    /// Serials this session has already asked the collection for and been told
    /// it does not have. Kept for the session only, never persisted: a rescan
    /// must not re-ask for the same few dozen missing covers every time, and a
    /// relaunch must still pick up covers added to the collection since.
    private(set) var attempted: Set<String> = []

    /// An automatic sweep skips what has already been asked for; a manual one
    /// does not, because the player asking again IS the request to retry.
    func discs(from entries: [GameEntry],
               hasCover: (GameEntry) -> Bool,
               automatic: Bool) -> [GameEntry] {
        entries.filter { entry in
            guard let serial = entry.serial else { return false }
            if hasCover(entry) { return false }
            return automatic ? !attempted.contains(serial) : true
        }
    }

    /// Recorded after a sweep, whatever its outcome: a disc whose cover
    /// downloaded is no longer missing one, and a disc whose cover the
    /// collection lacks must not be asked for again this session.
    mutating func record(_ entries: [GameEntry]) {
        for entry in entries { if let serial = entry.serial { attempted.insert(serial) } }
    }
}

/// Whether a library scan fetches missing covers by itself.
///
/// Shaped after `MultiDiscSetting`, including its trap: this defaults to TRUE,
/// so a missing key cannot be read with `bool(forKey:)` — absence has to be
/// probed with `object(forKey:)` or the feature ships off on every first
/// launch.
///
/// On by default because covers appearing without being asked for is the point
/// of the feature. It is switchable because it is the only thing in this app
/// that reaches the network, and that should never be unavoidable.
struct AutoCoverSetting {
    static let defaultsKey = "autoDownloadCovers"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = AutoCoverSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? true
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
