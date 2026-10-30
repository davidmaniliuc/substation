import Testing
@testable import PS1

/// Every notice says what kind of event it is with its icon, so the same
/// event always looks the same in the badge stack.
@MainActor
@Suite(.serialized) struct NoticeTests {
    @Test func theAnalogNoticeCarriesTheControllerIcon() {
        let model = EmulatorViewModel()
        model.simulateSessionEventForTesting(.pad(PadStatus(analog: true, small: 0, large: 0)))
        #expect(model.notice == Notice(icon: NoticeIcon.analog, text: "Analog on"))
    }

    /// ⌘R shows nothing else: the game simply starts over.
    @Test func aResetSaysSoOnceTheSessionAnswers() {
        let model = EmulatorViewModel()
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        model.reset()
        #expect(model.notice == nil)
        session.answerReset(nil)
        #expect(model.notice == Notice(icon: NoticeIcon.reset, text: "Game reset"))
    }

    @Test func aRefusedResetSaysNothing() {
        let model = EmulatorViewModel()
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: "k")
        defer { model.ejectNowForTesting() }

        model.reset()
        session.answerReset(.sessionStopped)
        #expect(model.notice == nil)
    }

    /// ⌘1…⌘8 change the picture with no other word on screen.
    @Test func aResolutionChangeInAGameIsANotice() {
        let model = EmulatorViewModel()
        let before = model.internalScale
        defer { model.internalScale = before }
        model.simulatePlayingForTesting()

        model.internalScale = before == 4 ? 3 : 4
        #expect(model.notice == Notice(icon: NoticeIcon.resolution, text: "Resolution \(model.internalScale)×"))
    }

    @Test func pgxpInAGameIsANotice() {
        let model = EmulatorViewModel()
        let before = model.pgxpEnabled
        defer { model.pgxpEnabled = before }
        model.simulatePlayingForTesting()

        model.pgxpEnabled = !before
        #expect(model.notice == Notice(icon: NoticeIcon.pgxp, text: before ? "PGXP off" : "PGXP on"))
    }

    /// The menu's own row shows the new value; a badge would say it twice.
    @Test func thePauseMenuChangesSettingsWithoutANotice() {
        let model = EmulatorViewModel()
        let scale = model.internalScale, pgxp = model.pgxpEnabled
        defer { model.internalScale = scale; model.pgxpEnabled = pgxp }
        model.simulatePlayingForTesting()
        model.setSurface(.pauseMenu, open: true)

        model.internalScale = scale == 4 ? 3 : 4
        model.pgxpEnabled = !pgxp
        #expect(model.notice == nil)
    }

    @Test func aSettingChangedInTheLibraryIsNoNotice() {
        let model = EmulatorViewModel()
        let before = model.internalScale
        defer { model.internalScale = before }

        model.internalScale = before == 4 ? 3 : 4
        #expect(model.notice == nil)
    }

    @Test func aControllerComingAndGoingInAGameIsANotice() {
        let model = EmulatorViewModel()
        model.simulatePlayingForTesting()

        model.simulateControllerConnectForTesting()
        #expect(model.notice == Notice(icon: NoticeIcon.controller, text: "Controller connected"))
        model.simulateControllerDisconnectForTesting(nil)
        #expect(model.notice == Notice(icon: NoticeIcon.controller, text: "Controller disconnected"))
    }

    @Test func aControllerInTheLibraryIsNoNotice() {
        let model = EmulatorViewModel()
        model.simulateControllerConnectForTesting()
        model.simulateControllerDisconnectForTesting(nil)
        #expect(model.notice == nil)
    }
}

/// The menu bar's audio keys, which change a persisted setting: each test
/// puts the level and the mute back.
@MainActor
@Suite(.serialized) struct AudioShortcutTests {
    private func withVolume(_ body: (EmulatorViewModel) -> Void) {
        let model = EmulatorViewModel()
        let level = model.volume, muted = model.isMuted
        defer {
            model.volume = level
            if model.isMuted != muted { model.toggleMute() }
        }
        body(model)
    }

    @Test func volumeStepsLandOnTenths() {
        withVolume { model in
            model.volume = 0.55
            model.stepVolume(by: 1)
            #expect(abs(model.volume - 0.6) < 1e-9)
            model.volume = 0.55
            model.stepVolume(by: -1)
            #expect(abs(model.volume - 0.5) < 1e-9)
            model.volume = 0.3
            model.stepVolume(by: -1)
            #expect(abs(model.volume - 0.2) < 1e-9)
            model.stepVolume(by: 1)
            #expect(abs(model.volume - 0.3) < 1e-9)
        }
    }

    @Test func volumeStopsAtItsEnds() {
        withVolume { model in
            model.volume = 1
            model.stepVolume(by: 1)
            #expect(model.volume == 1)
            model.volume = 0
            model.stepVolume(by: -1)
            #expect(model.volume == 0)
        }
    }

    @Test func aVolumeKeyUnmutesAndSaysTheLevelInAGame() {
        withVolume { model in
            model.simulatePlayingForTesting()
            model.volume = 0.5
            if !model.isMuted { model.toggleMute() }
            model.stepVolume(by: 1)
            #expect(!model.isMuted)
            #expect(model.notice == Notice(icon: NoticeIcon.volume, text: "Volume 60%"))
        }
    }

    @Test func muteFromTheMenuSaysSoInAGame() {
        withVolume { model in
            model.simulatePlayingForTesting()
            if model.isMuted { model.toggleMute() }
            model.toggleMuteFromMenu()
            #expect(model.notice == Notice(icon: NoticeIcon.muted, text: "Muted"))
            model.toggleMuteFromMenu()
            #expect(model.notice == Notice(icon: NoticeIcon.volume, text: "Sound on"))
        }
    }

    /// The HUD's speaker draws its own change.
    @Test func theHudSpeakerRaisesNoNotice() {
        withVolume { model in
            model.simulatePlayingForTesting()
            model.toggleMute()
            #expect(model.notice == nil)
        }
    }
}
