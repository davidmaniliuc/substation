import Foundation

/// Clock Speed Control: the console's processor at a percentage of its real
/// clock, while video, the CD drive and sound keep real time. Off by
/// default, and the percentage is kept while it is off.
///
/// Probed with `object(forKey:)` like `RunaheadSetting`, so a stored value
/// outside `choices` reads as the default rather than a neighbour nobody
/// chose.
struct CpuOverclockSetting {
    static let enabledKey = "cpuOverclockEnabled"
    static let percentKey = "cpuOverclockPercent"
    /// The control's steps. The core takes any whole percent in this range.
    static let choices = Array(stride(from: 10, through: 1000, by: 10))
    static let defaultPercent = 100

    private let defaults: UserDefaults
    private(set) var enabled: Bool
    private(set) var percent: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        let stored = (defaults.object(forKey: Self.percentKey) as? NSNumber)?.intValue
        percent = stored.flatMap { Self.choices.contains($0) ? $0 : nil } ?? Self.defaultPercent
    }

    /// What the session is sent: 100, the real clock, while disabled.
    var effective: Int { enabled ? percent : Self.defaultPercent }

    mutating func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
    }

    mutating func setPercent(_ value: Int) {
        guard Self.choices.contains(value) else { return }
        percent = value
        defaults.set(value, forKey: Self.percentKey)
    }
}
