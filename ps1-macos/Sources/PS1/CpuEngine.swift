import Foundation

/// How the PlayStation's CPU is emulated. The raw values are the C ABI's
/// `PS1_ENGINE_*` numbers.
public enum CpuEngine: Int, CaseIterable, Identifiable, Sendable {
    case interpreter = 0
    case cachedInterpreter = 1
    case recompiler = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .interpreter: return "Interpreter"
        case .cachedInterpreter: return "Cached Interpreter"
        case .recompiler: return "Recompiler"
        }
    }

    /// Fastest first, as the Settings picker lists them.
    static let menuOrder: [CpuEngine] = [.recompiler, .cachedInterpreter, .interpreter]

    var isAvailable: Bool { Ps1Core.isCpuEngineAvailable(self) }
}

/// The persisted engine choice, shaped after `DitherSetting`: `init`
/// resolves, `set` persists, and the load rejects a value no case matches.
///
/// `stored` is what the player chose; `engine` is what runs. They differ only
/// where this build lacks the stored engine (the recompiler off Apple
/// silicon), which runs the cached interpreter and leaves the choice in
/// place for a build that has it.
struct CpuEngineSetting {
    static let defaultsKey = "cpuEngine"
    static let defaultEngine = CpuEngine.recompiler

    private var choice: PersistedChoice<CpuEngine>
    private let isAvailable: (CpuEngine) -> Bool

    var stored: CpuEngine { choice.value }
    var engine: CpuEngine { isAvailable(stored) ? stored : .cachedInterpreter }

    init(key: String = CpuEngineSetting.defaultsKey,
         defaults: UserDefaults = .standard,
         isAvailable: @escaping (CpuEngine) -> Bool = Ps1Core.isCpuEngineAvailable) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultEngine)
        self.isAvailable = isAvailable
    }

    mutating func set(_ value: CpuEngine) { choice.set(value) }
}
