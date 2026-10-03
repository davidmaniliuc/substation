import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// A fresh defaults key per test, as `DitherModeTests` does: these write the
/// real `UserDefaults`, and a shared key would clobber the user's own setting.
private func uniqueKey() -> String { "test-texture-filter-\(UUID().uuidString)" }

@Test func textureFilterRawValuesMatchTheShaderHeader() {
    // The enum MIRRORS PrimInstance.h's PS1_FILTER_*, and the uniform carries
    // the raw value straight to the GPU: a renumbering on one side alone
    // compiles and silently selects the other filter.
    #expect(TextureFilter.nearest.uniformValue == UInt32(PS1_FILTER_NEAREST))
    #expect(TextureFilter.bilinear.uniformValue == UInt32(PS1_FILTER_BILINEAR))
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
    // A filter written by a future build (JINC2, xBR) and then downgraded.
    UserDefaults.standard.set(7, forKey: key)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
}

@Test func aFreshRasterizerCarriesNearest() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    #expect(r.textureFilter == .nearest)
}

@Test func theTextureFilterReachesTheRasterizerWithoutARebuild() throws {
    // Review Focus 5. A runtime uniform, like dithering: the coordinator is
    // NOT rebuilt, so `updateNSView`'s assignment must land on the live
    // rasterizer the next frame encodes with.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }
    let live = try LiveRenderer(device: device, queue: queue)
    #expect(live.textureFilter == .nearest)
    live.textureFilter = .bilinear
    // The getter reads the (private) rasterizer's own field, so this is the
    // value the next encoded frame's uniform carries.
    #expect(live.textureFilter == .bilinear)
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
    UserDefaults.standard.set(7, forKey: key)
    #expect(SpriteFilterSetting(key: key).filter == .nearest)
}

@Test func aFreshRasterizerCarriesANearestSpriteFilter() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    #expect(r.spriteFilter == .nearest)
}
