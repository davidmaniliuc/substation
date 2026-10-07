import Testing
@testable import PS1

struct MotorDriveTests {
    @Test func theLargeMotorScalesAndTheSmallOneSwitches() {
        let d = MotorDrive(status: PadStatus(analog: true, small: 255, large: 0x80), allowed: true)
        #expect(d.large == Float(0x80) / 255)
        #expect(d.small)
    }

    @Test func aStillPadDrivesNothing() {
        #expect(MotorDrive(status: .idle, allowed: true) == .stopped)
    }

    /// Paused, a dialog up, the app in the background or Vibration off: the
    /// motors stop, and the same status drives them again once allowed,
    /// because the motor values are machine state, not events.
    @Test func disallowedStopsAndReallowedResumes() {
        let s = PadStatus(analog: true, small: 255, large: 0xFF)
        #expect(MotorDrive(status: s, allowed: false) == .stopped)
        let resumed = MotorDrive(status: s, allowed: true)
        #expect(resumed.large == 1)
        #expect(resumed.small)
    }

    /// A controller with one actuator group plays whichever motor is stronger.
    @Test func oneEngineTakesTheStrongerMotor() {
        #expect(MotorDrive(large: 0.25, small: false).combined == 0.25)
        #expect(MotorDrive(large: 0.25, small: true).combined == 1)
        #expect(MotorDrive.stopped.combined == 0)
    }
}
