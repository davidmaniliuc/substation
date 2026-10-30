import Foundation
import Testing
@testable import PS1

struct RecentDiscsTests {
    @MainActor @Test func aDiscPlayedAgainMovesToTheTopOnce() {
        let recents = RecentDiscs.memory()
        let a = URL(fileURLWithPath: "/a.cue"), b = URL(fileURLWithPath: "/b.cue")
        recents.note(a)
        recents.note(b)
        recents.note(a)
        #expect(recents.urls() == [a, b])
        recents.clear()
        #expect(recents.urls().isEmpty)
    }

    /// The hosted test app must not write the real app's list.
    @MainActor @Test func theTestAppKeepsAListOfItsOwn() {
        #expect(!EmulatorViewModel.publishesToSystem)
        let url = URL(fileURLWithPath: "/never-in-appkit.cue")
        RecentDiscs.current.note(url)
        #expect(!RecentDiscs.system.urls().contains(url))
    }
}

@MainActor struct RecentDiscsViewModelTests {
    @Test func aStartedGameIsRecentAndAMissingDiscIsNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 524288).write(to: dir.appendingPathComponent("SCPH-1001.bin"))
        let key = "recent-bios-\(UUID().uuidString)"
        let bios = BiosLibrary(folderKey: key, explicitKey: key + ".explicit")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try? bios.setFolder(dir)
        let store = SaveStateStore(resumeDirectory: dir.appendingPathComponent("resume"),
                                   slotsDirectory: dir.appendingPathComponent("slots"))
        let suite = "recent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var autoSave = AutoSaveSetting(key: "a", defaults: defaults)
        autoSave.set(0)
        let model = EmulatorViewModel(saveStates: store, autoSave: autoSave, bios: bios)
        model.recents = .memory()
        model.makeSession = { _ throws(Ps1Error) in ScriptedSession() }
        // One fixed name: a started game is marked played in the shared stats.
        let disc = FileManager.default.temporaryDirectory.appendingPathComponent("vm-recent-disc.bin")
        try Data(repeating: 0, count: 2352).write(to: disc)

        model.load(disc: disc)
        model.ejectNowForTesting()
        #expect(model.recentDiscs == [disc])

        model.recents.note(dir.appendingPathComponent("gone.cue"))
        model.load(disc: disc)
        model.ejectNowForTesting()
        #expect(model.recentDiscs == [disc])

        model.clearRecentDiscs()
        #expect(model.recentDiscs.isEmpty)
    }

    @Test func theDockOffersResumeOnlyFromTheLibrary() {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        defer { model.ejectNowForTesting() }
        #expect(model.dockResumeGroup == nil)
    }
}
