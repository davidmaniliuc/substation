import Foundation

/// The emulation-speed setting: the speed a game runs at, the speed it runs at
/// while fast-forward is held, and where both are stored.
///
/// Shaped after `VolumeSetting` — `init` resolves from `UserDefaults`, every
/// setter clamps and persists, and the rule lives in the type so it is
/// reachable from a test without a window or an audio device.
///
/// **The held key is session state and is never persisted**: a fast-forward
/// that outlived its key-up would come back on the next launch with nothing
/// held to explain it.
struct SpeedSetting {
    static let choices = 1...4
    static let baseKey = "emulationSpeed"
    static let turboKey = "fastForwardSpeed"

    private let defaults: UserDefaults
    private let baseName: String
    private let turboName: String

    private(set) var base: Int
    private(set) var turbo: Int
    var isFastForwarding = false

    init(baseKey: String = SpeedSetting.baseKey,
         turboKey: String = SpeedSetting.turboKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseName = baseKey
        self.turboName = turboKey
        // `integer(forKey:)` returns 0 for an absent key, which the clamp
        // lifts to 1x — the right default for the base, but not for the
        // turbo, whose absence has to be read separately.
        self.base = Self.clamp(defaults.integer(forKey: baseKey))
        let storedTurbo = (defaults.object(forKey: turboKey) as? NSNumber)?.intValue
        self.turbo = storedTurbo.map(Self.clamp) ?? 2
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, choices.lowerBound), choices.upperBound)
    }

    /// The one value the audio path and the runner read.
    var effective: Int { isFastForwarding ? turbo : base }

    mutating func setBase(_ value: Int) {
        base = Self.clamp(value)
        defaults.set(base, forKey: baseName)
    }

    mutating func setTurbo(_ value: Int) {
        turbo = Self.clamp(value)
        defaults.set(turbo, forKey: turboName)
    }

    /// The OSD button: 1x, 2x, 3x, 4x, then back to 1x.
    mutating func cycleBase() {
        setBase(base == Self.choices.upperBound ? Self.choices.lowerBound : base + 1)
    }
}
