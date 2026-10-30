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
