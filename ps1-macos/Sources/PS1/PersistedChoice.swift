import Foundation

/// An `Int`-backed enum persisted in `UserDefaults`, with a load that REJECTS.
///
/// It reads `object(forKey:)` rather than `integer(forKey:)` because 0 is a
/// valid case of every enum stored this way, so the 0 that `integer(forKey:)`
/// invents for a missing key would read back as a deliberate choice. A stored
/// value no case matches (hand-edited, or written by a newer build and then
/// downgraded) falls back the same way: a `UserDefaults` integer is DATA.
struct PersistedChoice<Value: RawRepresentable> where Value.RawValue == Int {
    private let defaults: UserDefaults
    private let key: String
    private(set) var value: Value

    init(key: String, defaults: UserDefaults, fallback: Value) {
        self.defaults = defaults
        self.key = key
        if let raw = defaults.object(forKey: key) as? Int, let stored = Value(rawValue: raw) {
            self.value = stored
        } else {
            self.value = fallback
        }
    }

    mutating func set(_ newValue: Value) {
        value = newValue
        defaults.set(newValue.rawValue, forKey: key)
    }
}
