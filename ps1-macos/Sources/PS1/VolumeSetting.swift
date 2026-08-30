import Foundation

/// The output-volume setting: the level, the mute flag, and where both are
/// stored.
///
/// Shaped after `InternalResolution` — `init` resolves from `UserDefaults`,
/// `set` clamps and persists, and the clamp lives in the type so it is
/// reachable from a test without a window or an audio device.
///
/// Two things here are deliberate and are what the tests pin. **A missing key
/// means full volume, not silence**: `UserDefaults.double(forKey:)` returns 0
/// for an absent key and 0 is a legitimate volume, so unlike the scale, the
/// default cannot fall out of the clamp and the key's absence has to be read
/// separately. And **mute is a flag over an untouched level**, not a level of
/// zero with the old one stashed beside it, so unmuting restores what you had
/// without a second field to keep in step.
struct VolumeSetting {
    static let range = 0.0...1.0
    static let levelKey = "audioVolume"
    static let mutedKey = "audioMuted"

    private let defaults: UserDefaults
    private let levelName: String
    private let mutedName: String

    private(set) var level: Double
    private(set) var isMuted: Bool

    init(levelKey: String = VolumeSetting.levelKey,
         mutedKey: String = VolumeSetting.mutedKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.levelName = levelKey
        self.mutedName = mutedKey
        let stored = (defaults.object(forKey: levelKey) as? NSNumber)?.doubleValue
        self.level = stored.map(Self.clamp) ?? Self.range.upperBound
        self.isMuted = defaults.bool(forKey: mutedKey)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The one value the audio path reads. `Float` because that is what the
    /// render callback multiplies by.
    var gain: Float { Float(isMuted ? 0 : level) }

    /// Clamped on the way in as well as on the way out, so a value that would
    /// clip the mix never reaches the defaults database.
    ///
    /// Moving the slider also unmutes: otherwise it is a dead control — the
    /// fill tracks the drag and nothing comes out, with no visible reason why.
    mutating func set(_ value: Double) {
        level = Self.clamp(value)
        defaults.set(level, forKey: levelName)
        setMuted(false)
    }

    mutating func toggleMute() { setMuted(!isMuted) }

    mutating func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        defaults.set(muted, forKey: mutedName)
    }
}
