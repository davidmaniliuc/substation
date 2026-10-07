import Foundation

/// Whether the game's rumble reaches the controller. Defaults to ON, so the
/// key's absence is probed with `object(forKey:)`: `bool(forKey:)` would read
/// it as off.
struct VibrationSetting {
    static let defaultsKey = "vibration"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = VibrationSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
