import Testing
import Foundation
import CPs1
@testable import PS1

private func uniqueKey() -> String { "test-widescreen-\(UUID().uuidString)" }

@Test func widescreenRawValuesMatchTheHeader() {
    // The enum mirrors ps1.h's PS1_WIDESCREEN_*, which the core reads as the
    // GTE's X scale: a renumbering on one side alone compiles and squeezes
    // the world to another shape than the window shows.
    #expect(Widescreen.off.rawValue == Int(PS1_WIDESCREEN_OFF))
    #expect(Widescreen.wide16x10.rawValue == Int(PS1_WIDESCREEN_16_10))
    #expect(Widescreen.wide16x9.rawValue == Int(PS1_WIDESCREEN_16_9))
    #expect(Widescreen.wide21x9.rawValue == Int(PS1_WIDESCREEN_21_9))
    #expect(Widescreen.allCases.count == 4)
}

@Test func theWidescreenModesAreTitledForTheMenu() {
    #expect(Widescreen.allCases.map(\.title) == ["Off", "16:10", "16:9", "21:9"])
}

@Test func offIsTheConsolesOwnShape() {
    #expect(Widescreen.off.aspect == WindowConfigurator.aspect)
}

@Test func anUnusedWidescreenKeyLoadsAsOff() {
    #expect(WidescreenSetting(key: uniqueKey()).mode == .off)
    #expect(WidescreenSetting.defaultsKey == "widescreen")
}

@Test func theWidescreenModeRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = WidescreenSetting(key: key)
    written.set(.wide16x9)
    #expect(WidescreenSetting(key: key).mode == .wide16x9)
    UserDefaults.standard.set(9, forKey: key)
    #expect(WidescreenSetting(key: key).mode == .off)
}

@Test func theWidescreenModeReachesTheSessionStructWhole() {
    for mode in Widescreen.allCases {
        let s = SessionSettings(gain: 1, cpuEngine: .interpreter, runaheadFrames: 0, rewindBudget: 0,
                                scale: 1, dither: .off, textureFilter: .nearest, spriteFilter: .nearest,
                                pgxp: PgxpSettings(), pgxpUsePresets: false, vramReadbacks: .on,
                                widescreen: mode)
        #expect(s.c.widescreen == Int32(mode.rawValue))
    }
}
