import Foundation

/// Whether a game boots past the BIOS logos (`ps1_set_fast_boot`).
///
/// Defaults to FALSE, as DuckStation ships it, so `bool(forKey:)`'s
/// false-for-absent is exactly the default and needs no probing.
struct FastBootSetting {
    static let defaultsKey = "fastBoot"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = FastBootSetting.defaultsKey,
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
