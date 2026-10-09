import Foundation

/// Rewind: whether history is kept, how much memory it may use, and which
/// controller button holds it. The key is a `KeyBindings` control.
///
/// Off by default: history costs memory and a capture every other frame.
/// Every key is probed with `object(forKey:)`, because the memory default is
/// not 0 and a stored value outside `memoryChoices` reads as the default
/// rather than as a neighbour nobody chose.
struct RewindSetting {
    static let enabledKey = "rewindEnabled"
    static let memoryKey = "rewindMemoryMB"
    static let padKey = "rewindPadButton"
    static let memoryChoices = [128, 256, 512]
    static let defaultMemoryMB = 256

    /// The controller button that holds rewind. The PS1 pad has no button to
    /// spare, so a chosen one is WITHHELD from the game while it is set; the
    /// stick clicks are the ones fewest games read.
    enum PadButton: Int, CaseIterable {
        case none = 0
        case l3 = 1
        case r3 = 2

        var title: String {
            switch self {
            case .none: "None"
            case .l3: "L3 (Left Stick Click)"
            case .r3: "R3 (Right Stick Click)"
            }
        }

        /// Module-qualified: inside this enum `PadButton` names the enum.
        private var button: PS1.PadButton? {
            switch self {
            case .none: nil
            case .l3: .l3
            case .r3: .r3
            }
        }

        /// Whether this pad snapshot is holding rewind.
        func claims(_ input: InputMap) -> Bool {
            guard let button else { return false }
            return input.mask & button.rawValue == 0
        }

        /// The snapshot the game sees: the rewind button released.
        func withheld(from input: InputMap) -> InputMap {
            guard let button else { return input }
            var game = input
            game.release(button)
            return game
        }
    }

    private let defaults: UserDefaults
    private(set) var enabled: Bool
    private(set) var memoryMB: Int
    private(set) var padButton: PadButton

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = (defaults.object(forKey: Self.enabledKey) as? NSNumber)?.boolValue ?? false
        let mb = (defaults.object(forKey: Self.memoryKey) as? NSNumber)?.intValue
        memoryMB = mb.flatMap { Self.memoryChoices.contains($0) ? $0 : nil } ?? Self.defaultMemoryMB
        let pad = (defaults.object(forKey: Self.padKey) as? NSNumber)?.intValue
        padButton = pad.flatMap(PadButton.init(rawValue:)) ?? .none
    }

    /// What the core is told: 0 is off.
    var budgetBytes: Int { enabled ? memoryMB << 20 : 0 }

    mutating func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
    }

    mutating func setMemoryMB(_ mb: Int) {
        guard Self.memoryChoices.contains(mb) else { return }
        memoryMB = mb
        defaults.set(mb, forKey: Self.memoryKey)
    }

    mutating func setPadButton(_ b: PadButton) {
        padButton = b
        defaults.set(b.rawValue, forKey: Self.padKey)
    }
}
