import Foundation

/// The internal-resolution setting: the supported range, where it is stored,
/// and a load that CLAMPS.
///
/// A type of its own rather than two lines inside `EmulatorViewModel` so the
/// clamp is reachable from a test without a window — the same reason
/// `ScopedBookmark` is a type, and the same shape: `init` resolves, `set`
/// persists.
///
/// The clamp is the whole point. `MetalVram.init` traps outside `range`, and
/// its own comment anticipates this: a value read back from `UserDefaults` is
/// DATA, not a literal, so it must be clamped or rejected here rather than
/// aborting the app at launch. The precondition over there stays exactly what
/// it always was — a programming-error trap for a bad literal.
struct InternalResolution {
    /// Everything Phase C proved, shipped.
    static let range = 1...8
    static let defaultsKey = "internalResolution"

    private let defaults: UserDefaults
    private let key: String
    private(set) var scale: Int

    init(key: String = InternalResolution.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        // `integer(forKey:)` returns 0 for a missing key, and the clamp lifts
        // that to 1 — so the shipped default is not a second constant that can
        // drift from the range.
        self.scale = Self.clamp(defaults.integer(forKey: key))
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Clamped on the way in as well as on the way out, so a bad value never
    /// reaches the defaults database at all.
    mutating func set(_ value: Int) {
        scale = Self.clamp(value)
        defaults.set(scale, forKey: key)
    }
}
