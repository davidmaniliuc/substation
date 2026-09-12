import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// A fresh defaults key per test, exactly as `InternalResolutionTests` does:
/// these write to the real `UserDefaults`, so a shared key would let one test
/// see another's mode — and would clobber the running user's own setting.
private func uniqueKey() -> String { "test-dither-\(UUID().uuidString)" }

@Test func ditherModeRawValuesMatchTheShaderHeader() {
    // The enum is a MIRROR of PrimInstance.h's PS1_DITHER_*, and the uniform
    // carries the raw value straight to the GPU. A renumbering on one side
    // alone would not fail to compile: it would silently select a different
    // mode, and at 1x — where `.native` and `.scaled` are the same expression
    // — two of the three swap without changing a single pixel.
    #expect(DitherMode.off.uniformValue == UInt32(PS1_DITHER_OFF))
    #expect(DitherMode.native.uniformValue == UInt32(PS1_DITHER_NATIVE))
    #expect(DitherMode.scaled.uniformValue == UInt32(PS1_DITHER_SCALED))
    #expect(DitherMode.trueColor.uniformValue == UInt32(PS1_DITHER_TRUE_COLOR))
}

@Test func anUnusedKeyLoadsAsTheDefaultRatherThanAsOff() {
    // Still `object(forKey:)` and not `integer(forKey:)`: 0 is a VALID mode
    // (`.off`, the worst-looking of the four), so a missing key read as an
    // integer reports every fresh install as having deliberately chosen it.
    #expect(DitherSetting(key: uniqueKey()).mode == .trueColor)
    #expect(DitherSetting.defaultMode == .trueColor)
}

@Test func aFreshRasterizerCarriesTheShippedMode() throws {
    // The seam between the setting and the uniform. `MetalRasterizer.ditherMode`
    // is initialised from `DitherSetting.defaultMode`, so a rasterizer built
    // before any coordinator assigns one — every test harness, and the first
    // frame after a scale change — must already be in the shipped mode.
    //
    // The shipped default must also not opt the player out of an oracle:
    // `.scaled` breaks downsample-invariance above 1x knowingly, and
    // `.trueColor` writes VRAM exactly as `.off` does, so nothing a gate reads
    // moves at any scale. That is why this default could move at all.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    #expect(r.ditherMode == .trueColor)
    #expect(DitherSetting.defaultMode == .trueColor)
}

@Test func theModeRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var written = DitherSetting(key: key)
    written.set(.native)
    #expect(written.mode == .native)
    #expect(DitherSetting(key: key).mode == .native)
}

@Test func offPersistsRatherThanReadingBackAsTheDefault() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    // The other side of the missing-key rule: a STORED 0 is a real choice and
    // must survive a relaunch. A load written as `integer(forKey:)` plus a
    // "0 means unset" fallback passes the test above and fails this one.
    var written = DitherSetting(key: key)
    written.set(.off)
    #expect(DitherSetting(key: key).mode == .off)
}

@Test func anUnrecognisedPersistedValueFallsBackToTheDefault() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    // Hand-edited defaults, or a mode written by a future build and then
    // downgraded. A `UserDefaults` integer is DATA, not a literal, and the
    // shader's `else` treats anything unrecognised as `.off` — so accepting it
    // here would ship the banding this setting exists to remove.
    UserDefaults.standard.set(7, forKey: key)
    #expect(DitherSetting(key: key).mode == .trueColor)
}

@Test func everyModeHasADistinctMenuTitle() {
    // `DitherMode.allCases` is what builds the Video menu picker, so a missing
    // case is a mode the player cannot select and a duplicated title is two
    // menu items that read the same.
    let titles = DitherMode.allCases.map(\.title)
    #expect(titles.count == 4)
    #expect(Set(titles).count == titles.count)
}
