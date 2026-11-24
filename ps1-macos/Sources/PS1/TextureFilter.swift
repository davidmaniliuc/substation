import Foundation

/// How a textured primitive samples its texture in the picture the player sees.
///
/// Display-only: the filtered colour reaches the true-colour sidecar and
/// never VRAM, and VRAM's value and its STP bit stay on the nearest texel, so
/// no gate can tell the filters apart. Two settings carry it:
/// `TextureFilterSetting` for 3D primitives and `SpriteFilterSetting` for
/// sprites, the split `Rasterizer.metal`'s `ps1_is_sprite` decides.
/// `PrimInstance.h`'s `PS1_FILTER_*` are the shader's half, pinned by
/// `textureFilterRawValuesMatchTheShaderHeader`.
///
/// The raw values are persisted and are NOT in declaration order: the cases
/// are declared in menu order, and `bilinearNoEdge` keeps the 1 that plain
/// "Bilinear" had before the edge-blending variant existed.
public enum TextureFilter: Int, CaseIterable, Identifiable, Sendable {
    case nearest = 0
    case bilinear = 2
    case bilinearNoEdge = 1
    case jinc2 = 3
    case jinc2NoEdge = 4
    case xbr = 5
    case xbrNoEdge = 6
    case scale2x = 7
    case scale3x = 8
    case mmpx = 9
    case mmpxEnhanced = 10
    case mmpxAdvanced = 11

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .nearest: return "Nearest-Neighbour"
        case .bilinear: return "Bilinear"
        case .bilinearNoEdge: return "Bilinear (No Edge Blending)"
        case .jinc2: return "JINC2 (Slow)"
        case .jinc2NoEdge: return "JINC2 (Slow, No Edge Blending)"
        case .xbr: return "xBR (Very Slow)"
        case .xbrNoEdge: return "xBR (Very Slow, No Edge Blending)"
        case .scale2x: return "Scale2x (EPX)"
        case .scale3x: return "Scale3x (Slow)"
        case .mmpx: return "MMPX (Slow)"
        case .mmpxEnhanced: return "MMPX Enhanced (Slow)"
        case .mmpxAdvanced: return "MMPX Advanced (Very Slow)"
        }
    }

    /// The value `Ps1RasterUniforms.texture_filter` carries.
    public var uniformValue: UInt32 { UInt32(rawValue) }
}

/// The persisted texture filter. Same shape as `DitherSetting`.
struct TextureFilterSetting {
    static let defaultsKey = "textureFilter"
    /// Off, as DuckStation ships it.
    static let defaultFilter = TextureFilter.nearest

    private var choice: PersistedChoice<TextureFilter>
    var filter: TextureFilter { choice.value }

    init(key: String = TextureFilterSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultFilter)
    }

    mutating func set(_ value: TextureFilter) { choice.set(value) }
}

/// The persisted SPRITE texture filter: what textured rectangles and
/// screen-aligned 2D polygons use. Same shape as `TextureFilterSetting`.
struct SpriteFilterSetting {
    static let defaultsKey = "spriteTextureFilter"
    /// Off, as DuckStation ships it.
    static let defaultFilter = TextureFilter.nearest

    private var choice: PersistedChoice<TextureFilter>
    var filter: TextureFilter { choice.value }

    init(key: String = SpriteFilterSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultFilter)
    }

    mutating func set(_ value: TextureFilter) { choice.set(value) }
}
