import Testing
@testable import PS1

/// The pause menu driven by arrows, Return and Esc (or the D-pad, ✕ and ○),
/// without a window.
@Suite struct PauseMenuNavigationTests {
    private func menu(discs: Int = 1, inserted: Int = 0, pgxpLocked: Bool = false) -> PauseMenuNavigation {
        var m = PauseMenuNavigation()
        m.open(discCount: discs, insertedDisc: inserted, pgxpLocked: pgxpLocked)
        return m
    }

    private func focused(_ item: PauseMenuItem, discs: Int = 1) -> PauseMenuNavigation {
        var m = menu(discs: discs)
        m.point(at: item)
        return m
    }

    @Test func itOpensWithNothingHighlightedAndReturnResumes() {
        var m = menu()
        #expect(m.focus == nil)
        #expect(m.handle(.confirm) == .close)
    }

    @Test func escapeResumesFromAnyRow() {
        var m = focused(.volume)
        #expect(m.handle(.back) == .close)
    }

    @Test func downFromNothingLandsOnTheFirstRowAndUpOnTheLast() {
        var down = menu()
        _ = down.handle(.down)
        #expect(down.focus == .saveStates)
        var up = menu()
        _ = up.handle(.up)
        #expect(up.focus == .quitGame)
    }

    @Test func theEndsDoNotWrap() {
        var m = focused(.saveStates)
        _ = m.handle(.up)
        #expect(m.focus == .saveStates)
        m.point(at: .quitGame)
        _ = m.handle(.down)
        #expect(m.focus == .quitGame)
    }

    @Test func aSingleDiscGameHasNoDiscRow() {
        var m = focused(.saveStates)
        #expect(!m.isShown(.disc))
        _ = m.handle(.down)
        #expect(m.focus == .speed)
        m.point(at: .disc)
        #expect(m.focus == .speed)
    }

    @Test func aMultiDiscGameStopsOnTheDiscRow() {
        var m = focused(.saveStates, discs: 2)
        _ = m.handle(.down)
        #expect(m.focus == .disc)
    }

    @Test func theDiscRowPicksWithTheArrowsAndInsertsOnReturn() {
        var m = menu(discs: 3, inserted: 0)
        m.point(at: .disc)
        #expect(m.handle(.right) == PauseMenuAction.none)
        #expect(m.handle(.right) == PauseMenuAction.none)
        #expect(m.handle(.right) == PauseMenuAction.none)
        #expect(m.discChoice == 2)
        #expect(m.handle(.confirm) == .insertDisc(2))
    }

    @Test func returnOnTheInsertedDiscDoesNothing() {
        var m = menu(discs: 2, inserted: 1)
        m.point(at: .disc)
        #expect(m.discChoice == 1)
        #expect(m.handle(.confirm) == PauseMenuAction.none)
    }

    @Test func theArrowsStepTheSettingUnderTheHighlight() {
        var m = focused(.speed)
        #expect(m.handle(.left) == .adjust(.speed, -1))
        #expect(m.handle(.right) == .adjust(.speed, 1))
        _ = m.handle(.down)
        #expect(m.handle(.right) == .adjust(.resolution, 1))
        _ = m.handle(.down)
        #expect(m.handle(.left) == .adjust(.volume, -1))
    }

    @Test func returnTogglesASwitchAndMutesVolume() {
        #expect(focused(.pgxp).confirming() == .toggle(.pgxp))
        #expect(focused(.analog).confirming() == .toggle(.analog))
        #expect(focused(.volume).confirming() == .toggle(.volume))
        #expect(focused(.speed).confirming() == PauseMenuAction.none)
    }

    @Test func saveStatesOpensOnReturnOrRight() {
        var m = focused(.saveStates)
        #expect(m.handle(.confirm) == .saveStates)
        #expect(m.handle(.right) == .saveStates)
        #expect(m.handle(.left) == PauseMenuAction.none)
    }

    @Test func resetAndQuitGameAreTheirOwnActions() {
        #expect(focused(.reset).confirming() == .reset)
        #expect(focused(.quitGame).confirming() == .quitGame)
    }

    @Test func aLockedPgxpIsSkippedAndNeverHighlighted() {
        var m = menu(pgxpLocked: true)
        m.point(at: .volume)
        _ = m.handle(.down)
        #expect(m.focus == .analog)
        m.point(at: .pgxp)
        #expect(m.focus == .analog)
    }

    @Test func leavingARowClearsOnlyItsOwnHighlight() {
        var m = focused(.reset)
        m.leave(.reset)
        #expect(m.focus == nil)

        m.point(at: .reset)
        _ = m.handle(.down)          // the keys moved on
        m.leave(.reset)
        #expect(m.focus == .quitGame)
    }

    @Test func onlyAKeyMoveScrollsTheList() {
        var m = focused(.speed)
        #expect(!m.focusFromKeys)
        _ = m.handle(.down)
        #expect(m.focusFromKeys)
        m.point(at: .speed)
        #expect(!m.focusFromKeys)
    }

    @Test func reopeningForgetsTheHighlightAndThePickedDisc() {
        var m = menu(discs: 2)
        m.point(at: .disc)
        _ = m.handle(.right)
        m.open(discCount: 2, insertedDisc: 0, pgxpLocked: false)
        #expect(m.focus == nil)
        #expect(m.discChoice == 0)
    }
}

private extension PauseMenuNavigation {
    func confirming() -> PauseMenuAction {
        var copy = self
        return copy.handle(.confirm)
    }
}
