import Foundation

/// How a 480-line interlaced game is shown. The raw values are the C ABI's
/// `PS1_DEINTERLACE_*` numbers, pinned by `deinterlacingRawValuesMatchTheHeader`.
/// Every mode but Progressive has the machine draw one field at a time, as
/// the console does.
public enum Deinterlacing: Int, CaseIterable, Identifiable, Sendable {
    case progressive = 0
    case adaptive = 1
    case blend = 2
    case weave = 3
    case singleField = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .progressive: return "Progressive"
        case .adaptive: return "Adaptive"
        case .blend: return "Blend"
        case .weave: return "Weave"
        case .singleField: return "Single Field"
        }
    }
}

/// The persisted deinterlacing mode. Same shape as `DisplayEffectSetting`.
struct DeinterlacingSetting {
    static let defaultsKey = "deinterlacing"
    static let defaultMode = Deinterlacing.progressive

    private var choice: PersistedChoice<Deinterlacing>
    var mode: Deinterlacing { choice.value }

    init(key: String = DeinterlacingSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultMode)
    }

    mutating func set(_ value: Deinterlacing) { choice.set(value) }
}
