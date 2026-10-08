import Foundation

/// How often a running game writes its resume state on its own, in minutes
/// of active play; 0 is Off. Independent of save-on-exit: either can be off
/// while the other is on.
///
/// Defaults to 5, so absence is probed with `object(forKey:)`:
/// `integer(forKey:)` reads a missing key as 0, which here means Off. A
/// stored value outside `choices` reads as the default rather than being
/// clamped to a neighbour nobody chose.
struct AutoSaveSetting {
    static let defaultsKey = "autoSaveInterval"
    static let choices = [0, 1, 5, 10]
    static let defaultMinutes = 5

    private let defaults: UserDefaults
    private let key: String
    private(set) var minutes: Int

    init(key: String = AutoSaveSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        let stored = (defaults.object(forKey: key) as? NSNumber)?.intValue
        minutes = stored.flatMap { Self.choices.contains($0) ? $0 : nil } ?? Self.defaultMinutes
    }

    /// Seconds of active play between saves, or nil when Off.
    var interval: TimeInterval? {
        minutes == 0 ? nil : TimeInterval(minutes * 60)
    }

    mutating func set(_ value: Int) {
        guard Self.choices.contains(value) else { return }
        minutes = value
        defaults.set(value, forKey: key)
    }

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Off"
        case 1: "Every Minute"
        default: "Every \(minutes) Minutes"
        }
    }
}
