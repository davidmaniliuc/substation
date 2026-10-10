import Testing
import Foundation
@testable import PS1

/// Which HUD surfaces are open, and what that does to the pause and to the
/// HUD's idle timer. A value type, driven here without a window.
@Suite struct HudSurfacesTests {
    @Test func theMenuPausesARunningGameAndResumesItOnClose() {
        var s = HudSurfaces()
        #expect(s.set(.pauseMenu, open: true, paused: false) == true)
        #expect(s.set(.pauseMenu, open: false, paused: true) == false)
    }

    @Test func aGameThePlayerPausedStaysPaused() {
        var s = HudSurfaces()
        #expect(s.set(.pauseMenu, open: true, paused: true) == true)
        #expect(s.set(.pauseMenu, open: false, paused: true) == true)
    }

    /// The panel opened from the menu: the menu still holds the pause, so
    /// the panel's own close must not resume the game under it.
    @Test func thePanelOpenedFromTheMenuDoesNotResumeOnItsOwnClose() {
        var s = HudSurfaces()
        _ = s.set(.pauseMenu, open: true, paused: false)
        #expect(s.set(.saveStates, open: true, paused: true) == nil)
        #expect(s.set(.saveStates, open: false, paused: true) == nil)
        #expect(s.set(.pauseMenu, open: false, paused: true) == false)
    }

    @Test func theSpeedTabHoldsTheHUDWithoutPausing() {
        var s = HudSurfaces()
        #expect(s.set(.speedTab, open: true, paused: false) == nil)
        #expect(s.holdsHUD)
    }

    @Test func reopeningAnOpenSurfaceChangesNothing() {
        var s = HudSurfaces()
        _ = s.set(.pauseMenu, open: true, paused: false)
        #expect(s.set(.pauseMenu, open: true, paused: true) == nil)
        #expect(s.set(.pauseMenu, open: false, paused: true) == false)
    }

    @Test func closeAllRestoresThePauseFromBefore() {
        var s = HudSurfaces()
        _ = s.set(.saveStates, open: true, paused: false)
        #expect(s.closeAll() == false)
        #expect(!s.holdsHUD)
    }

    @Test func closeAllWithNothingPausingLeavesThePause() {
        var s = HudSurfaces()
        _ = s.set(.speedTab, open: true, paused: false)
        #expect(s.closeAll() == nil)
    }
}

/// The same rules through the model, where they meet the HUD's timer, the
/// pause and the teardown.
@MainActor
@Suite struct HudSurfacesModelTests {
    @Test func anOpenMenuKeepsTheHUDUpThroughAClick() {
        let model = EmulatorViewModel()
        model.setSurface(.pauseMenu, open: true)
        model.hideHUDNow()
        #expect(model.hudVisible)
    }

    @Test func aClickClosesTheSpeedTabAndHidesTheHUD() {
        let model = EmulatorViewModel()
        model.setSurface(.speedTab, open: true)
        model.hideHUDNow()
        #expect(!model.isOpen(.speedTab))
        #expect(!model.hudVisible)
    }

    @Test func openingTheMenuPausesTheGameAndClosingResumesIt() throws {
        let model = EmulatorViewModel()
        let runner = try makeRunner()
        model.installRunnerForTesting(runner, resumeKey: nil)
        defer { model.ejectNowForTesting() }
        model.isPaused = false

        model.setSurface(.pauseMenu, open: true)
        #expect(model.isPaused)
        model.setSurface(.pauseMenu, open: false)
        #expect(!model.isPaused)
    }

    /// ⌘P over the panel reads Resume: it must close the panel and the menu
    /// under it, not leave them up over a running game.
    @Test func resumingClosesThePanelAndTheMenu() throws {
        let model = EmulatorViewModel()
        model.installRunnerForTesting(try makeRunner(), resumeKey: nil)
        defer { model.ejectNowForTesting() }
        model.isPaused = true
        model.setSurface(.pauseMenu, open: true)
        model.openSaveStates(from: .bar)

        model.togglePause()
        #expect(!model.isOpen(.saveStates))
        #expect(!model.isOpen(.pauseMenu))
        #expect(!model.isPaused)
    }

    @Test func ejectingClosesEverySurface() throws {
        let model = EmulatorViewModel()
        model.installRunnerForTesting(try makeRunner(), resumeKey: nil)
        model.setSurface(.pauseMenu, open: true)
        model.openSaveStates(from: .menuLoad)
        model.ejectNowForTesting()
        #expect(!model.isOpen(.pauseMenu))
        #expect(!model.isOpen(.saveStates))
    }

    /// A game installed after an eject with the menu open must not start
    /// paused by a menu that is no longer there.
    @Test func theNextGameDoesNotInheritTheMenusPause() throws {
        let model = EmulatorViewModel()
        model.installRunnerForTesting(try makeRunner(), resumeKey: nil)
        model.isPaused = false
        model.setSurface(.pauseMenu, open: true)
        model.ejectNowForTesting()

        let next = try makeRunner()
        model.installRunnerForTesting(next, resumeKey: nil)
        defer { model.ejectNowForTesting() }
        #expect(!model.isPaused)
        model.setSurface(.pauseMenu, open: true)
        model.setSurface(.pauseMenu, open: false)
        #expect(!model.isPaused)
    }

    /// Leaving the tab is ordinary aiming; only straying well beyond it
    /// closes it, and then the HUD's idle timer runs again.
    @Test func theSpeedTabClosesWhenThePointerStraysBeyondIt() {
        let model = EmulatorViewModel()
        model.speedTabFrame = CGRect(x: 100, y: 100, width: 48, height: 155)
        model.setSurface(.speedTab, open: true)

        model.hoverMoved(to: CGPoint(x: 100 + 48 + 30, y: 150))
        #expect(model.isOpen(.speedTab))
        model.hoverMoved(to: CGPoint(x: 100 + 48 + 50, y: 150))
        #expect(!model.isOpen(.speedTab))
    }

    @Test func thePanelRemembersWhereItWasOpenedFrom() {
        let model = EmulatorViewModel()
        model.openSaveStates(from: .menuSave)
        #expect(model.isOpen(.saveStates))
        #expect(model.saveStatesOrigin == .menuSave)
    }

    private func makeRunner() throws -> EmulatorRunner {
        let core = try Ps1Core()
        try core.loadBIOS(Data(repeating: 0, count: 524288))
        return EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                              cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                                  .appendingPathComponent("hud-cards-\(UUID().uuidString)")))
    }
}
