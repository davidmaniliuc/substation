import Foundation

/// Where the machine's VRAM lives. The raw values are `ps1_session.h`'s
/// `PS1_VRAM_*` numbers.
enum VramMode: Int, Sendable {
    /// Software VRAM beside the render texture: every read is local.
    case dual = 0
    /// The render texture is the only VRAM: a read waits on the GPU.
    case gpu = 1
}

/// The player's per-game answer to "does this game need accurate VRAM
/// readbacks". Automatic follows the core's table of games that read VRAM
/// back often; On keeps software VRAM (dual), Off runs GPU-only.
///
/// Unlike the Video menu's other entries this one is PER GAME, so it has
/// nothing to act on, and is disabled, with no game running.
enum VramReadbacks: Int, CaseIterable, Identifiable, Sendable {
    case automatic = 0
    case on = 1
    case off = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// Every game's choice, stored by serial as ONE `[String: Int]` dictionary.
/// A game with no entry is Automatic, so only a deliberate choice is ever
/// written, and choosing Automatic again removes the entry. An entry whose
/// value no case matches reads as Automatic, `PersistedChoice`'s rule.
struct VramReadbacksSetting {
    static let defaultsKey = "vramReadbacks"

    private let defaults: UserDefaults
    private let key: String
    private var choices: [String: Int]

    init(key: String = VramReadbacksSetting.defaultsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        choices = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    func choice(serial: String?) -> VramReadbacks {
        guard let serial, let raw = choices[serial] else { return .automatic }
        return VramReadbacks(rawValue: raw) ?? .automatic
    }

    mutating func set(_ value: VramReadbacks, serial: String) {
        guard value != choice(serial: serial) else { return }
        choices[serial] = value == .automatic ? nil : value.rawValue
        defaults.set(choices, forKey: key)
    }

    static func mode(_ choice: VramReadbacks, tableNeedsDual: Bool) -> VramMode {
        switch choice {
        case .on: return .dual
        case .off: return .gpu
        case .automatic: return tableNeedsDual ? .dual : .gpu
        }
    }
}
