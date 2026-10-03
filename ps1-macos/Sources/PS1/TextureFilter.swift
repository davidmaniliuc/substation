import Foundation

/// How a textured TRIANGLE samples its texture in the picture the player sees.
///
/// Display-only: the filtered colour reaches the true-colour sidecar and
/// never VRAM, and the hole, the STP bit and VRAM's value all stay on the
/// nearest texel, so no gate can tell the two apart. Textured rectangles
/// (HUDs, text, 2D sprites) are never filtered. `PrimInstance.h`'s
/// `PS1_FILTER_*` are the shader's half, pinned by
/// `textureFilterRawValuesMatchTheShaderHeader`.
public enum TextureFilter: Int, CaseIterable, Identifiable, Sendable {
    case nearest = 0
    /// DuckStation's "Bilinear (No Edge Blending)". Plain "Bilinear", which
    /// also softens cut-out edges, is a separate later case.
    case bilinear = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .nearest: return "Nearest-Neighbour"
        case .bilinear: return "Bilinear (No Edge Blending)"
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
