import Testing
import Foundation
import CPs1
@testable import PS1

private func uniqueKey() -> String { "test-display-effect-\(UUID().uuidString)" }

@Test func displayEffectRawValuesMatchTheHeader() {
    // The enum mirrors ps1_session.h's PS1_EFFECT_*, which the session reads
    // as the effect to draw: a renumbering on one side alone compiles and
    // selects another look.
    #expect(DisplayEffect.none.rawValue == Int(PS1_EFFECT_NONE))
    #expect(DisplayEffect.sharpBilinear.rawValue == Int(PS1_EFFECT_SHARP_BILINEAR))
    #expect(DisplayEffect.scanlines.rawValue == Int(PS1_EFFECT_SCANLINES))
    #expect(DisplayEffect.crt.rawValue == Int(PS1_EFFECT_CRT))
    #expect(DisplayEffect.composite.rawValue == Int(PS1_EFFECT_COMPOSITE))
    #expect(DisplayEffect.allCases.count == 5)
}

@Test func theEffectsAreTitledForTheMenu() {
    #expect(DisplayEffect.allCases.map(\.title) == ["None", "Sharp Bilinear", "Scanlines", "CRT", "Composite"])
}

@Test func anUnusedDisplayEffectKeyLoadsAsNone() {
    #expect(DisplayEffectSetting(key: uniqueKey()).effect == .none)
    #expect(DisplayEffectSetting.defaultEffect == .none)
    #expect(DisplayEffectSetting.defaultsKey == "displayEffect")
}

@Test func theDisplayEffectRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = DisplayEffectSetting(key: key)
    written.set(.crt)
    #expect(DisplayEffectSetting(key: key).effect == .crt)
    written.set(.none)
    #expect(DisplayEffectSetting(key: key).effect == .none)
}

@Test func anUnrecognisedDisplayEffectFallsBackToNone() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set(9, forKey: key)
    #expect(DisplayEffectSetting(key: key).effect == .none)
}

@Test func theDisplayEffectReachesTheSessionStructWhole() {
    for effect in DisplayEffect.allCases {
        let s = SessionSettings(gain: 1, cpuEngine: .interpreter, runaheadFrames: 0, rewindBudget: 0,
                                scale: 1, dither: .off, textureFilter: .nearest, spriteFilter: .nearest,
                                pgxp: PgxpSettings(), pgxpUsePresets: false, vramReadbacks: .on,
                                displayEffect: effect)
        #expect(s.c.display_effect == Int32(effect.rawValue))
    }
}
