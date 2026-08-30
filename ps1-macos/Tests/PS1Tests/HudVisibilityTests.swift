import Testing
import CoreGraphics
@testable import PS1

/// The OSD's show/hide policy, driven directly on the model — `ContentView`
/// only forwards a tap and a hover point into these two methods, so the rule
/// is testable without a window or a running game.

@MainActor
@Test func aClickHidesTheHUDImmediately() {
    let model = EmulatorViewModel()
    model.showHUDThenHide()
    #expect(model.hudVisible)

    model.hideHUDNow()
    #expect(model.hudVisible == false)
}

/// The load-bearing half. `onContinuousHover` reports the pointer on a click
/// too, so re-showing on every hover callback would undo the hiding click in
/// the same runloop turn and the OSD would never go away.
@MainActor
@Test func theClicksOwnPointerPositionDoesNotBringTheHUDBack() {
    let model = EmulatorViewModel()
    let p = CGPoint(x: 120, y: 90)

    model.hoverMoved(to: p)
    model.hideHUDNow()
    #expect(model.hudVisible == false)

    model.hoverMoved(to: p)
    #expect(model.hudVisible == false)
}

@MainActor
@Test func movingTheMouseAfterAClickBringsTheHUDBack() {
    let model = EmulatorViewModel()
    let p = CGPoint(x: 120, y: 90)

    model.hoverMoved(to: p)
    model.hideHUDNow()

    model.hoverMoved(to: CGPoint(x: p.x + 1, y: p.y))
    #expect(model.hudVisible)
}

/// The first hover after launch has no previous point to differ from, and must
/// still count as a move — otherwise the OSD stays down until the second one.
@MainActor
@Test func theFirstHoverCountsAsAMove() {
    let model = EmulatorViewModel()
    model.hideHUDNow()

    model.hoverMoved(to: CGPoint(x: 4, y: 4))
    #expect(model.hudVisible)
}
