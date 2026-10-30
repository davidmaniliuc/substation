import Testing
import Foundation
@testable import PS1

/// A throwaway suite: the hosted tests share the app's defaults.
private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "vram-readbacks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

/// A serial the core's readback table lists, pinned beside the core's own test.
private let listed = "SCPS-45116"

@Test func aChoiceIsKeptPerSerial() {
    withSuite { defaults in
        var setting = VramReadbacksSetting(key: "k", defaults: defaults)
        setting.set(.on, serial: "SLUS-00594")
        let reread = VramReadbacksSetting(key: "k", defaults: defaults)
        #expect(reread.choice(serial: "SLUS-00594") == .on)
        #expect(reread.choice(serial: "SLUS-00707") == .automatic)
        #expect(reread.choice(serial: nil) == .automatic)
    }
}

@Test func automaticRemovesTheSerialsEntry() {
    withSuite { defaults in
        var setting = VramReadbacksSetting(key: "k", defaults: defaults)
        setting.set(.off, serial: "SLUS-00594")
        setting.set(.automatic, serial: "SLUS-00594")
        let stored = defaults.dictionary(forKey: "k") ?? [:]
        #expect(stored["SLUS-00594"] == nil)
    }
}

@Test func anUnchangedChoiceWritesNothing() {
    withSuite { defaults in
        var setting = VramReadbacksSetting(key: "k", defaults: defaults)
        setting.set(.automatic, serial: "SLUS-00594")
        #expect(defaults.object(forKey: "k") == nil)
    }
}

@Test func aStoredValueNoCaseMatchesReadsAsAutomatic() {
    withSuite { defaults in
        defaults.set(["SLUS-00594": 99], forKey: "k")
        let setting = VramReadbacksSetting(key: "k", defaults: defaults)
        #expect(setting.choice(serial: "SLUS-00594") == .automatic)
    }
}

@Test func theTableIsTheCores() {
    #expect(Ps1Core.gameNeedsDualVram(serial: listed))
    #expect(!Ps1Core.gameNeedsDualVram(serial: "SLUS-00707"))
    #expect(!Ps1Core.gameNeedsDualVram(serial: nil))
    #expect(!Ps1Core.gameNeedsDualVram(serial: ""))
}

// MARK: - The view model

@MainActor private func makeModel(_ defaults: UserDefaults) -> EmulatorViewModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vram-vm-\(UUID().uuidString)")
    let store = SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                               slotsDirectory: root.appendingPathComponent("slots"))
    var autoSave = AutoSaveSetting(key: "a", defaults: defaults)
    autoSave.set(0)
    return EmulatorViewModel(saveStates: store, autoSave: autoSave,
                             vramReadbacks: VramReadbacksSetting(key: "k", defaults: defaults))
}

private func makeEntry(serial: String) throws -> GameEntry {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vram-disc-\(UUID().uuidString).bin")
    try Data(repeating: 0, count: 2352).write(to: url)
    return GameEntry(url: url, identity: DiscIdentity(region: nil, serial: serial, volumeID: nil))
}

@MainActor @Test func aSwapCarriesTheIncomingDiscsChoice() throws {
    try withSuite { defaults in
        var setting = VramReadbacksSetting(key: "k", defaults: defaults)
        setting.set(.on, serial: "SLUS-00594")
        let model = makeModel(defaults)
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        model.game!.changeDisc(to: try makeEntry(serial: "SLUS-00594"))
        #expect(session.pendingSwap?.readbacks == .on)
        model.game!.changeDisc(to: try makeEntry(serial: "SLUS-00707"))
        #expect(session.pendingSwap?.readbacks == .automatic)
    }
}

@MainActor @Test func changingTheChoicePushesAtOnce() throws {
    try withSuite { defaults in
        let model = makeModel(defaults)
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.game!.changeDisc(to: try makeEntry(serial: "SLUS-00594"))
        session.answerSwap(nil)
        #expect(model.vramReadbacksAvailable)

        model.vramReadbacks = .on
        #expect(session.calls.last == "setSettings")
        #expect(session.settings.last?.vramReadbacks == .on)
        #expect(VramReadbacksSetting(key: "k", defaults: defaults).choice(serial: "SLUS-00594") == .on)
    }
}

@MainActor @Test func theChoiceIsUnavailableWithNoGame() {
    withSuite { defaults in
        let model = makeModel(defaults)
        #expect(!model.vramReadbacksAvailable)
    }
}

@MainActor @Test func automaticNamesWhatItResolvedToForTheRunningGame() throws {
    try withSuite { defaults in
        let model = makeModel(defaults)
        #expect(model.vramReadbacksTitle(.automatic) == "Automatic")
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }
        model.game!.changeDisc(to: try makeEntry(serial: listed))
        session.answerSwap(nil)
        #expect(model.vramReadbacksTitle(.automatic) == "Automatic (On)")
        #expect(model.vramReadbacksTitle(.off) == "Off")
        model.game!.changeDisc(to: try makeEntry(serial: "SLUS-00707"))
        session.answerSwap(nil)
        #expect(model.vramReadbacksTitle(.automatic) == "Automatic (Off)")
    }
}
