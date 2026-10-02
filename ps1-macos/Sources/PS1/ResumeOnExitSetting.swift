import Foundation

/// Whether leaving a game saves a resume state. The checkbox on the exit
/// sheet IS this setting: unticking it once keeps it unticked.
///
/// Defaults to TRUE, so — as `MultiDiscSetting` explains — absence is probed
/// with `object(forKey:)`; `bool(forKey:)` would ship it off on first launch.
struct ResumeOnExitSetting {
    static let defaultsKey = "saveStateOnExit"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = ResumeOnExitSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? true
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
