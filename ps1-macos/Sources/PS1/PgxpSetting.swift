import Foundation

/// Whether PGXP geometry correction is on.
///
/// Shaped after `InternalResolution` — `init` resolves from `UserDefaults`,
/// `set` persists, and the rule lives in the type so it is reachable from a
/// test without a window.
///
/// Default OFF, and for the same reason internal resolution defaults to 1×:
/// off is the configuration the byte-exact oracle covers. Selecting PGXP opts
/// out of that knowingly; the shipped configuration must not opt out for the
/// player.
///
/// There is no clamp and no `object(forKey:)` probe, unlike its two
/// neighbours. `bool(forKey:)` returns false for a missing key and false is
/// the intended default, so absence is not ambiguous the way it is for
/// `VolumeSetting`'s level.
struct PgxpSetting {
    static let defaultsKey = "pgxpEnabled"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = PgxpSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.bool(forKey: key)
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
