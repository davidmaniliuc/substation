import Testing
import Foundation
import CPs1
@testable import PS1

private func uniqueKey() -> String { "test-deinterlacing-\(UUID().uuidString)" }

@Test func deinterlacingRawValuesMatchTheHeader() {
    // The session reads the number as its mode: a renumbering on one side
    // alone compiles and shows another mode than the menu ticks.
    #expect(Deinterlacing.progressive.rawValue == Int(PS1_DEINTERLACE_PROGRESSIVE))
    #expect(Deinterlacing.adaptive.rawValue == Int(PS1_DEINTERLACE_ADAPTIVE))
    #expect(Deinterlacing.blend.rawValue == Int(PS1_DEINTERLACE_BLEND))
    #expect(Deinterlacing.weave.rawValue == Int(PS1_DEINTERLACE_WEAVE))
    #expect(Deinterlacing.singleField.rawValue == Int(PS1_DEINTERLACE_SINGLE_FIELD))
    #expect(Deinterlacing.allCases.count == 5)
}

@Test func theDeinterlacingModesAreTitledForTheMenu() {
    #expect(Deinterlacing.allCases.map(\.title) == ["Progressive", "Adaptive", "Blend", "Weave", "Single Field"])
}

@Test func anUnusedDeinterlacingKeyLoadsAsProgressive() {
    #expect(DeinterlacingSetting(key: uniqueKey()).mode == .progressive)
    #expect(DeinterlacingSetting.defaultsKey == "deinterlacing")
}

@Test func theDeinterlacingRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = DeinterlacingSetting(key: key)
    written.set(.adaptive)
    #expect(DeinterlacingSetting(key: key).mode == .adaptive)
    UserDefaults.standard.set(9, forKey: key)
    #expect(DeinterlacingSetting(key: key).mode == .progressive)
}

@Test func theDeinterlacingReachesTheSessionStructWhole() {
    for mode in Deinterlacing.allCases {
        let s = SessionSettings(gain: 1, cpuEngine: .interpreter, runaheadFrames: 0, rewindBudget: 0,
                                scale: 1, dither: .off, textureFilter: .nearest, spriteFilter: .nearest,
                                pgxp: PgxpSettings(), pgxpUsePresets: false, vramReadbacks: .on,
                                deinterlacing: mode)
        #expect(s.c.deinterlace == Int32(mode.rawValue))
    }
}
