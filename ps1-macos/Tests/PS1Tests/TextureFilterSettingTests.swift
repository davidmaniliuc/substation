import Testing
import Foundation
import CPs1
@testable import PS1

/// A fresh defaults key per test, as `DitherModeTests` does: these write the
/// real `UserDefaults`, and a shared key would clobber the user's own setting.
private func uniqueKey() -> String { "test-texture-filter-\(UUID().uuidString)" }

@Test func textureFilterRawValuesMatchTheShaderHeader() {
    // The enum MIRRORS PrimInstance.h's PS1_FILTER_*, and the uniform carries
    // the raw value straight to the GPU: a renumbering on one side alone
    // compiles and silently selects the other filter.
    let header: [(TextureFilter, UInt32)] = [
        (.nearest, UInt32(PS1_FILTER_NEAREST)), (.bilinear, UInt32(PS1_FILTER_BILINEAR)),
        (.bilinearNoEdge, UInt32(PS1_FILTER_BILINEAR_NO_EDGE)), (.jinc2, UInt32(PS1_FILTER_JINC2)),
        (.jinc2NoEdge, UInt32(PS1_FILTER_JINC2_NO_EDGE)), (.xbr, UInt32(PS1_FILTER_XBR)),
        (.xbrNoEdge, UInt32(PS1_FILTER_XBR_NO_EDGE)), (.scale2x, UInt32(PS1_FILTER_SCALE2X)),
        (.scale3x, UInt32(PS1_FILTER_SCALE3X)), (.mmpx, UInt32(PS1_FILTER_MMPX)),
        (.mmpxEnhanced, UInt32(PS1_FILTER_MMPX_ENHANCED)), (.mmpxAdvanced, UInt32(PS1_FILTER_MMPX_ADVANCED)),
    ]
    #expect(header.count == TextureFilter.allCases.count)
    for (filter, value) in header {
        #expect(filter.uniformValue == value, "\(filter)")
    }
}

@Test func theFiltersAreListedInMenuOrder() {
    #expect(TextureFilter.allCases.map(\.title) == [
        "Nearest-Neighbour", "Bilinear", "Bilinear (No Edge Blending)",
        "JINC2 (Slow)", "JINC2 (Slow, No Edge Blending)",
        "xBR (Very Slow)", "xBR (Very Slow, No Edge Blending)",
        "Scale2x (EPX)", "Scale3x (Slow)",
        "MMPX (Slow)", "MMPX Enhanced (Slow)", "MMPX Advanced (Very Slow)",
    ])
}

@Test func aFilterSavedBeforeEdgeBlendingStillLoadsAsNoEdgeBilinear() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // 1 was the only bilinear there was, and it never blended edges.
    UserDefaults.standard.set(1, forKey: key)
    #expect(TextureFilterSetting(key: key).filter == .bilinearNoEdge)
}

@Test func anUnusedTextureFilterKeyLoadsAsNearest() {
    // Shipped off, as DuckStation ships it.
    #expect(TextureFilterSetting(key: uniqueKey()).filter == .nearest)
    #expect(TextureFilterSetting.defaultFilter == .nearest)
}

@Test func theTextureFilterRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = TextureFilterSetting(key: key)
    written.set(.bilinear)
    #expect(written.filter == .bilinear)
    #expect(TextureFilterSetting(key: key).filter == .bilinear)
}

@Test func aStoredNearestPersistsRatherThanReadingBackAsTheDefault() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // 0 is a real choice. Today it equals the default, so this pins the load
    // rule (object(forKey:)) rather than the value: it fails the day the
    // default moves if the load ever becomes `integer(forKey:)` plus a
    // "0 means unset" fallback.
    UserDefaults.standard.set(0, forKey: key)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
    var written = TextureFilterSetting(key: key)
    written.set(.bilinear)
    written.set(.nearest)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
}

@Test func anUnrecognisedTextureFilterFallsBackToNearest() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // A filter written by a future build and then downgraded.
    UserDefaults.standard.set(12, forKey: key)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
}

// MARK: - Sprite Texture Filtering

private func uniqueSpriteKey() -> String { "test-sprite-filter-\(UUID().uuidString)" }

@Test func anUnusedSpriteFilterKeyLoadsAsNearest() {
    // Shipped off, as DuckStation ships it.
    #expect(SpriteFilterSetting(key: uniqueSpriteKey()).filter == .nearest)
    #expect(SpriteFilterSetting.defaultFilter == .nearest)
    #expect(SpriteFilterSetting.defaultsKey == "spriteTextureFilter")
}

@Test func theSpriteFilterRoundTripsThroughUserDefaults() {
    let key = uniqueSpriteKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = SpriteFilterSetting(key: key)
    written.set(.bilinear)
    #expect(written.filter == .bilinear)
    #expect(SpriteFilterSetting(key: key).filter == .bilinear)
}

@Test func anUnrecognisedSpriteFilterFallsBackToNearest() {
    let key = uniqueSpriteKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set(12, forKey: key)
    #expect(SpriteFilterSetting(key: key).filter == .nearest)
}

