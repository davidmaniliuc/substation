import Testing
import Foundation
@testable import PS1

private func makeDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "rewind-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Test func rewindIsOffWith256MBAndNoPadButtonWhenNeverSet() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let setting = RewindSetting(defaults: defaults)
    #expect(!setting.enabled)
    #expect(setting.memoryMB == 256)
    #expect(setting.padButton == .none)
    #expect(setting.budgetBytes == 0)
}

@Test func rewindChoicesPersistAndOnlyOnSpendsTheBudget() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    var setting = RewindSetting(defaults: defaults)
    setting.setEnabled(true)
    setting.setMemoryMB(512)
    setting.setPadButton(.r3)
    let reread = RewindSetting(defaults: defaults)
    #expect(reread.enabled)
    #expect(reread.memoryMB == 512)
    #expect(reread.padButton == .r3)
    #expect(reread.budgetBytes == 512 << 20)
}

@Test func anUnknownRewindMemoryReadsAsTheDefaultAndIsRefused() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(300, forKey: RewindSetting.memoryKey)
    var setting = RewindSetting(defaults: defaults)
    #expect(setting.memoryMB == 256)
    setting.setMemoryMB(100)
    #expect(setting.memoryMB == 256)
}

@Test func theRewindPadButtonIsHeldOutOfTheGame() {
    var m = InputMap()
    m.press(.r3)
    m.press(.cross)
    #expect(RewindSetting.PadButton.r3.claims(m))
    #expect(!RewindSetting.PadButton.l3.claims(m))
    #expect(!RewindSetting.PadButton.none.claims(m))
    let game = RewindSetting.PadButton.r3.withheld(from: m)
    #expect(game.mask & PadButton.r3.rawValue != 0)      // released for the game
    #expect(game.mask & PadButton.cross.rawValue == 0)   // still pressed
}
