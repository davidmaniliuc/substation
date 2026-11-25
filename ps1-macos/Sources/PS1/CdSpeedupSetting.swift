import Foundation

/// The CD drive's read and seek speedups, each 1 to 10 times the real
/// drive, 1x being the hardware. Both are opt-in. The core never speeds up
/// XA or CD audio, and the session holds the games known to break to 1x, so
/// this type keeps only what the player chose.
///
/// Probed with `object(forKey:)` like `CpuOverclockSetting`, so a stored
/// value outside `choices` reads as 1x rather than a neighbour nobody chose.
struct CdSpeedupSetting {
    static let readKey = "cdReadSpeedup"
    static let seekKey = "cdSeekSpeedup"
    static let choices = Array(1...10)
    static let defaultFactor = 1

    private let defaults: UserDefaults
    private(set) var read: Int
    private(set) var seek: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        read = Self.stored(Self.readKey, in: defaults)
        seek = Self.stored(Self.seekKey, in: defaults)
    }

    mutating func setRead(_ value: Int) {
        guard Self.choices.contains(value) else { return }
        read = value
        defaults.set(value, forKey: Self.readKey)
    }

    mutating func setSeek(_ value: Int) {
        guard Self.choices.contains(value) else { return }
        seek = value
        defaults.set(value, forKey: Self.seekKey)
    }

    /// A choice's title in the picker: 1× names the real drive.
    static func title(_ factor: Int) -> String {
        factor == defaultFactor ? "\(factor)× (Real)" : "\(factor)×"
    }

    private static func stored(_ key: String, in defaults: UserDefaults) -> Int {
        let value = (defaults.object(forKey: key) as? NSNumber)?.intValue
        return value.flatMap { choices.contains($0) ? $0 : nil } ?? defaultFactor
    }
}
