import Testing
import CoreGraphics
@testable import PS1

/// The speed tab's pop-up-button rule. Points are in the speed button's own
/// space: the button is y 0...30, the separator sits just above it and the
/// values rise from 1× to 4× above that.
@Suite struct SpeedPickTests {
    @Test func theButtonItselfPicksNothing() {
        #expect(SpeedPick.index(at: CGPoint(x: 20, y: 10)) == nil)
    }

    @Test func theSeparatorPicksNothing() {
        #expect(SpeedPick.index(at: CGPoint(x: 20, y: -4)) == nil)
    }

    @Test func justAboveTheSeparatorIsOneTimes() {
        #expect(SpeedPick.index(at: CGPoint(x: 20, y: -SpeedPick.separator - 1)) == 0)
    }

    @Test func theTopSlotIsFourTimes() {
        let top = -SpeedPick.separator - 4 * SpeedPick.slot + 1
        #expect(SpeedPick.index(at: CGPoint(x: 20, y: top)) == 3)
        #expect(SpeedPick.index(at: CGPoint(x: 20, y: top - 2)) == nil)
    }

    @Test func outsideTheTabsWidthPicksNothing() {
        #expect(SpeedPick.index(at: CGPoint(x: SpeedPick.width + 20, y: -20)) == nil)
        #expect(SpeedPick.index(at: CGPoint(x: -20, y: -20)) == nil)
    }

    @Test func aPickSetsTheSpeedAndCloses() {
        #expect(SpeedPick.outcome(picked: 2, dragged: true, wasOpen: false) == .init(speed: 3, open: false))
    }

    @Test func aDragReleasedOnNothingCloses() {
        #expect(SpeedPick.outcome(picked: nil, dragged: true, wasOpen: false) == .init(speed: nil, open: false))
    }

    @Test func aPlainClickOpensTheTabForASecondClick() {
        #expect(SpeedPick.outcome(picked: nil, dragged: false, wasOpen: false) == .init(speed: nil, open: true))
    }

    @Test func aClickOnTheValueOfAnOpenTabClosesIt() {
        #expect(SpeedPick.outcome(picked: nil, dragged: false, wasOpen: true) == .init(speed: nil, open: false))
    }
}

@Suite struct BatteryTests {
    @Test func theSymbolFollowsTheCharge() {
        #expect(Battery(percent: 5, charging: false).symbol == "battery.0percent")
        #expect(Battery(percent: 30, charging: false).symbol == "battery.25percent")
        #expect(Battery(percent: 64, charging: false).symbol == "battery.50percent")
        #expect(Battery(percent: 80, charging: false).symbol == "battery.75percent")
        #expect(Battery(percent: 100, charging: false).symbol == "battery.100percent")
        #expect(Battery(percent: 40, charging: true).symbol == "battery.100percent.bolt")
    }
}
