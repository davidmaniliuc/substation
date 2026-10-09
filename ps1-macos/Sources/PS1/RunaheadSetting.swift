import Foundation

/// How many frames runahead shows ahead of the game; 0 is Off. Off by
/// default: each frame ahead costs a whole frame of emulation.
///
/// Probed with `object(forKey:)` like `AutoSaveSetting`, so a stored value
/// outside `choices` reads as Off rather than a neighbour nobody chose.
struct RunaheadSetting {
    static let defaultsKey = "runahead"
    static let choices = Array(0...StreamQueue.maxSpeculativeFrames)

    private let defaults: UserDefaults
    private let key: String
    private(set) var frames: Int

    init(key: String = RunaheadSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        let stored = (defaults.object(forKey: key) as? NSNumber)?.intValue
        frames = stored.flatMap { Self.choices.contains($0) ? $0 : nil } ?? 0
    }

    mutating func set(_ value: Int) {
        guard Self.choices.contains(value) else { return }
        frames = value
        defaults.set(value, forKey: key)
    }

    static func title(_ frames: Int) -> String {
        switch frames {
        case 0: "Off"
        case 1: "1 Frame"
        default: "\(frames) Frames"
        }
    }
}
