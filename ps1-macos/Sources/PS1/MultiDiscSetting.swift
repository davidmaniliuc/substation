import Foundation

/// Whether a multi-disc game shows as one library tile.
///
/// Shaped after `PgxpSetting` — `init` resolves from `UserDefaults`, `set`
/// persists, and the rule lives in the type so it is reachable from a test
/// without a window — with one difference that is a trap rather than a style
/// note. `PgxpSetting` can read its key with `bool(forKey:)` precisely because
/// it defaults to false and false is what a missing key returns. This defaults
/// to TRUE, so that reasoning inverts: absence has to be probed with
/// `object(forKey:)`, the way `VolumeSetting` probes its level, or the feature
/// ships off on every first launch.
///
/// On by default because four Final Fantasy IX tiles is the noise this exists
/// to remove. It is not one of the byte-exactness defaults (1x, PGXP off) —
/// it changes no emulated behaviour at all.
struct MultiDiscSetting {
    static let defaultsKey = "mergeMultiDisc"

    private let defaults: UserDefaults
    private let key: String
    private(set) var merging: Bool

    init(key: String = MultiDiscSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.merging = (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? true
    }

    mutating func set(_ value: Bool) {
        merging = value
        defaults.set(value, forKey: key)
    }
}
