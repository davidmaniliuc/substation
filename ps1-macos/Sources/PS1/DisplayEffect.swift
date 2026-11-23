import Foundation

/// A screen look drawn over the picture in the window. Display-only: the
/// effect is the last pass of the window's draw, and a screenshot is taken
/// without it. The raw values are the C ABI's `PS1_EFFECT_*` numbers, pinned
/// by `displayEffectRawValuesMatchTheHeader`.
public enum DisplayEffect: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case sharpBilinear = 1
    case scanlines = 2
    case crt = 3
    case composite = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: return "None"
        case .sharpBilinear: return "Sharp Bilinear"
        case .scanlines: return "Scanlines"
        case .crt: return "CRT"
        case .composite: return "Composite"
        }
    }
}

/// The persisted display effect. Same shape as `SpriteFilterSetting`.
struct DisplayEffectSetting {
    static let defaultsKey = "displayEffect"
    static let defaultEffect = DisplayEffect.none

    private var choice: PersistedChoice<DisplayEffect>
    var effect: DisplayEffect { choice.value }

    init(key: String = DisplayEffectSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultEffect)
    }

    mutating func set(_ value: DisplayEffect) { choice.set(value) }
}
