import Testing
import Foundation
@testable import PS1

/// The title strip's "Playing for": ACTIVE play since this game loaded, by
/// the play clock's rules, and its wording.
@Suite struct PlayingForTests {
    @Test func aStoppedClockHasNoStretchInProgress() {
        let clock = PlayClock()
        #expect(clock.elapsed(at: 100) == 0)
    }

    @Test func aCountingClockReportsItsStretchSoFar() {
        var clock = PlayClock()
        _ = clock.update(running: true, paused: false, active: true, at: 100)
        #expect(clock.elapsed(at: 130) == 30)
    }

    @Test func underAMinuteReadsZero() {
        #expect(PlayingFor.format(59) == "0 min")
    }

    @Test func minutesUnderTheHour() {
        #expect(PlayingFor.format(42 * 60 + 30) == "42 min")
    }

    @Test func pastTheHourTheMinutesArePadded() {
        #expect(PlayingFor.format(65 * 60) == "1 h 05 min")
    }

    @Test func thePauseMenuSaysPausedAndHowLongBefore() {
        #expect(PlayingFor.pausedAfter(59) == "Paused")
        #expect(PlayingFor.pausedAfter(42 * 60) == "Paused after 42 min")
    }
}

@MainActor
@Suite struct SessionPlayTests {
    @Test func theSessionCountsActivePlayAndEndsWithTheGame() throws {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        model.simulateAppActiveForTesting(true)
        model.isPaused = false
        let now = ProcessInfo.processInfo.systemUptime
        #expect(model.sessionPlayed(at: now + 90) >= 90)

        // A pause banks the stretch: it is still this session's.
        model.isPaused = true
        #expect(model.sessionPlayed(at: now + 10_000) >= 0)
        #expect(model.sessionPlayed(at: now + 10_000) < 60)

        model.ejectNowForTesting()
        #expect(model.sessionPlayed(at: now + 10_000) == 0)
    }
}
