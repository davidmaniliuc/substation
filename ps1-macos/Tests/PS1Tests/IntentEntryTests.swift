import Testing
import Foundation
@testable import PS1

private func makeStore() -> SaveStateStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("intent-states-\(UUID().uuidString)")
    return SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                          slotsDirectory: root.appendingPathComponent("slots"))
}

/// A game no library holds, so its key is the path hash `launch` falls back
/// to for a disc it cannot find among the scanned entries.
private func outsideGame() -> GameGroup {
    let disc = GameEntry(url: URL(fileURLWithPath: "/intent-tests/\(UUID().uuidString)/Game.cue"))
    return GameGroup(title: disc.title, discs: [disc])
}

/// Serialized: each test drives the one shared exit gate of its own model,
/// but a running game installs app-wide observers.
@MainActor @Suite(.serialized)
struct IntentEntryTests {
    @Test func intentsRefuseBeforeOnboarding() async {
        let model = EmulatorViewModel(saveStates: makeStore(), autoSave: AutoSaveSetting())
        model.simulateOnboardingForTesting()
        await #expect(throws: IntentFailure.notSetUp) { try await model.intentGames() }
    }

    @Test func resumeFromOutsideAsksWhileAGamePlays() {
        let model = EmulatorViewModel(saveStates: makeStore(), autoSave: AutoSaveSetting())
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        let game = outsideGame()
        model.resumeFromIntent(game)
        #expect(model.exitPrompt == .resume(game))
        #expect(model.stage == .playing)
    }

    @Test func anIntentWhileTheSheetIsUpDoesNothing() {
        let model = EmulatorViewModel(saveStates: makeStore(), autoSave: AutoSaveSetting())
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        #expect(model.requestExit(.eject) == .prompted)
        model.resumeFromIntent(outsideGame())
        #expect(model.exitPrompt == .eject)
    }

    /// Only a slot, no resume: Resume Game shows the offer, as the Continue
    /// capsule does, and it is an outside launch.
    @Test func resumeWithNoStateOffersTheLaunch() throws {
        let store = makeStore()
        let model = EmulatorViewModel(saveStates: store, autoSave: AutoSaveSetting())
        model.eject()
        let game = outsideGame()
        try store.saveSlot(1, state: Data([1, 2, 3]), thumbnail: nil, key: game.first.pathKey)

        model.resumeFromIntent(game)
        #expect(model.resumeOffer?.key == game.first.pathKey)
        #expect(model.launchFromOutside)
        model.resumeOffer = nil
    }

    @Test func openLibraryAsksEveryWindowForTheLibrary() {
        let model = EmulatorViewModel(saveStates: makeStore(), autoSave: AutoSaveSetting())
        let before = model.libraryRequests
        model.openLibraryFromIntent()
        #expect(model.libraryRequests == before + 1)
    }

    @Test func failureMessagesAreTheSpecsCopy() {
        #expect(IntentFailure.notSetUp.message == "Choose a games folder in Substation first.")
        #expect(IntentFailure.gameMissing.message == "That game is no longer in your library.")
        #expect(IntentFailure.nothingPlayed.message == "You haven't played anything yet.")
    }
}
