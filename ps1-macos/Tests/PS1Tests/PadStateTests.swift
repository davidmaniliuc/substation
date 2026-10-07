import Foundation
import Testing
@testable import PS1

struct PadStateTests {
    @Test func stickExtremesAndCentreMapToTheWireBytes() {
        #expect(Sticks.byte(-1) == 0x00)
        #expect(Sticks.byte(0) == 0x80)
        #expect(Sticks.byte(1) == 0xFF)
    }

    @Test func outOfRangeValuesClamp() {
        #expect(Sticks.byte(-1.5) == 0x00)
        #expect(Sticks.byte(2) == 0xFF)
    }

    @Test func aNaNIsCentred() {
        #expect(Sticks.byte(.nan) == 0x80)
    }

    /// GameController's Y grows UP; the pad's grows DOWN.
    @Test func pushingUpIsZeroOnTheWire() {
        let s = Sticks(leftX: 0, leftY: 1, rightX: 0, rightY: -1)
        #expect(s.ly == 0x00)
        #expect(s.ry == 0xFF)
        #expect(s.lx == 0x80)
    }

    @Test func sticksAndStatusSurviveTheirPacking() {
        let s = Sticks(lx: 1, ly: 2, rx: 3, ry: 4)
        #expect(Sticks(packed: s.packed) == s)
        let p = PadStatus(analog: true, small: 255, large: 0x40)
        #expect(PadStatus(packed: p.packed) == p)
        #expect(PadStatus(packed: PadStatus.idle.packed) == .idle)
    }

    @Test func aPressIsDrainedOnce() throws {
        let core = try Ps1Core()
        let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity), cards: nil)
        #expect(!runner.takeAnalogPress())
        runner.pressAnalogButton()
        runner.pressAnalogButton()
        #expect(runner.takeAnalogPress())
        #expect(!runner.takeAnalogPress())
    }

    @Test func aFreshCoreReportsADigitalPadAtRest() throws {
        let core = try Ps1Core()
        #expect(core.padStatus() == .idle)
    }
}
