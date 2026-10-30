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

    @Test func theVolumeSliderHoldsTheHUDWithoutPausing() {
        var s = HudSurfaces()
        #expect(s.set(.volume, open: true, paused: false) == nil)
        #expect(s.holdsHUD)
        #expect(!s.pausesGame)
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
        model.simulatePlayingForTesting()
        model.game!.setSurface(.pauseMenu, open: true)
        model.game!.hideHUDNow()
        #expect(model.game!.hudVisible)
    }

    @Test func aClickClosesTheSpeedTabAndHidesTheHUD() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        model.game!.setSurface(.speedTab, open: true)
        model.game!.hideHUDNow()
        #expect(!model.game!.isOpen(.speedTab))
        #expect(!model.game!.hudVisible)
    }

    /// A pointer resting on the open slider must not let the idle timer
    /// hide the HUD, which would fold the slider under it.
    @Test func anOpenVolumeSliderCancelsTheIdleHide() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        model.game!.showHUDThenHide()
        #expect(model.game!.hidePendingForTesting)
        model.game!.setSurface(.volume, open: true)
        model.game!.showHUDThenHide()
        #expect(model.game!.hudVisible)
        #expect(!model.game!.hidePendingForTesting)
    }

    @Test func aClickClosesTheVolumeSliderAndHidesTheHUD() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        model.game!.setSurface(.volume, open: true)
        model.game!.hideHUDNow()
        #expect(!model.game!.isOpen(.volume))
        #expect(!model.game!.hudVisible)
    }

    @Test func openingTheMenuPausesTheGameAndClosingResumesIt() throws {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        let game = model.game!
        defer { model.ejectNowForTesting() }
        game.isPaused = false

        game.setSurface(.pauseMenu, open: true)
        #expect(game.isPaused)
        game.setSurface(.pauseMenu, open: false)
        #expect(!game.isPaused)
    }

    /// ⌘P over the panel reads Resume: it must close the panel and the menu
    /// under it, not leave them up over a running game.
    @Test func resumingClosesThePanelAndTheMenu() throws {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        let game = model.game!
        defer { model.ejectNowForTesting() }
        game.isPaused = true
        game.setSurface(.pauseMenu, open: true)
        game.openSaveStates(from: .bar)

        game.togglePause()
        #expect(!game.isOpen(.saveStates))
        #expect(!game.isOpen(.pauseMenu))
        #expect(!game.isPaused)
    }

    @Test func ejectingClosesEverySurface() throws {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        let game = model.game!
        game.setSurface(.pauseMenu, open: true)
        game.openSaveStates(from: .menu)
        model.ejectNowForTesting()
        #expect(!game.isOpen(.pauseMenu))
        #expect(!game.isOpen(.saveStates))
    }

    /// A game installed after an eject with the menu open must not start
    /// paused by a menu that is no longer there.
    @Test func theNextGameDoesNotInheritTheMenusPause() throws {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        model.game!.isPaused = false
        model.game!.setSurface(.pauseMenu, open: true)
        model.ejectNowForTesting()

        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        defer { model.ejectNowForTesting() }
        #expect(!model.game!.isPaused)
        model.game!.setSurface(.pauseMenu, open: true)
        model.game!.setSurface(.pauseMenu, open: false)
        #expect(!model.game!.isPaused)
    }

    /// Leaving the tab is ordinary aiming; only straying well beyond it
    /// closes it, and then the HUD's idle timer runs again.
    @Test func theSpeedTabClosesWhenThePointerStraysBeyondIt() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        model.game!.speedTabFrame = CGRect(x: 100, y: 100, width: 48, height: 155)
        model.game!.setSurface(.speedTab, open: true)

        model.game!.hoverMoved(to: CGPoint(x: 100 + 48 + 30, y: 150))
        #expect(model.game!.isOpen(.speedTab))
        model.game!.hoverMoved(to: CGPoint(x: 100 + 48 + 50, y: 150))
        #expect(!model.game!.isOpen(.speedTab))
    }

    @Test func thePanelRemembersWhereItWasOpenedFrom() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()
        model.game!.openSaveStates(from: .menu)
        #expect(model.game!.isOpen(.saveStates))
        #expect(model.game!.saveStatesOrigin == .menu)
    }
}
