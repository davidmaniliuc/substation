import Testing
@testable import PS1

/// The pause menu driven by arrows, Return and Esc (or the D-pad, ✕ and ○),
/// without a window.
@Suite struct PauseMenuNavigationTests {
    private func menu(discs: Int = 1, inserted: Int = 0) -> PauseMenuNavigation {
        var m = PauseMenuNavigation()
        m.discCount = discs
        m.insertedDisc = inserted
        return m
    }

    private func row(_ m: PauseMenuNavigation) -> PauseMenuRow { PauseMenuRow.allCases[m.selection] }

    @Test func downFromResumeLandsOnSaveState() {
        var m = menu()
        #expect(m.handle(.down) == PauseMenuAction.none)
        #expect(row(m) == .saveState)
    }

    @Test func aSingleDiscGameSkipsChangeDisc() {
        var m = menu()
        m.point(at: 2)                       // Load State
        _ = m.handle(.down)
        #expect(row(m) == .quickSettings)
        _ = m.handle(.up)
        #expect(row(m) == .loadState)
    }

    @Test func aMultiDiscGameStopsOnChangeDisc() {
        var m = menu(discs: 2)
        m.point(at: 2)
        _ = m.handle(.down)
        #expect(row(m) == .changeDisc)
    }

    @Test func theEndsDoNotWrap() {
        var m = menu()
        _ = m.handle(.up)
        #expect(row(m) == .resume)
        m.point(at: PauseMenuRow.allCases.count - 1)
        _ = m.handle(.down)
        #expect(row(m) == .quitGame)
    }

    @Test func pointingAtADisabledRowSelectsNothing() {
        var m = menu()
        m.point(at: 3)                       // Change Disc, one disc
        #expect(row(m) == .resume)
    }

    @Test func saveAndLoadStateOpenThePanelFromTheirRow() {
        var m = menu()
        m.point(at: 1)
        #expect(m.handle(.confirm) == .saveStates(.menuSave))
        m.point(at: 2)
        #expect(m.handle(.right) == .saveStates(.menuLoad))
    }

    @Test func resumeCloses() {
        var m = menu()
        #expect(m.handle(.confirm) == .close)
    }

    @Test func backAtTheRootCloses() {
        var m = menu()
        #expect(m.handle(.back) == .close)
    }

    @Test func resetAndQuitGameAreTheirOwnActions() {
        var m = menu()
        m.point(at: 6)
        #expect(m.handle(.confirm) == .reset)
        m.point(at: 7)
        #expect(m.handle(.confirm) == .quitGame)
    }

    @Test func changeDiscOpensItsFlyoutOnTheFirstDiscNotInserted() {
        var m = menu(discs: 3, inserted: 0)
        m.point(at: 3)
        #expect(m.handle(.confirm) == PauseMenuAction.none)
        #expect(m.flyout == 1)
    }

    @Test func theFlyoutInsertsAnotherDisc() {
        var m = menu(discs: 3, inserted: 0)
        m.point(at: 3)
        _ = m.handle(.confirm)
        _ = m.handle(.down)
        #expect(m.handle(.confirm) == .insertDisc(2))
        #expect(m.flyout == nil)
    }

    @Test func pickingTheInsertedDiscOnlyClosesTheFlyout() {
        var m = menu(discs: 2, inserted: 1)
        m.point(at: 3)
        _ = m.handle(.confirm)
        #expect(m.flyout == 0)
        _ = m.handle(.down)
        #expect(m.handle(.confirm) == PauseMenuAction.none)
        #expect(m.flyout == nil)
    }

    @Test func backAndLeftCloseTheFlyoutButNotTheMenu() {
        var m = menu(discs: 2)
        m.point(at: 3)
        _ = m.handle(.confirm)
        #expect(m.handle(.back) == PauseMenuAction.none)
        #expect(m.flyout == nil)
        _ = m.handle(.confirm)
        #expect(m.handle(.left) == PauseMenuAction.none)
        #expect(m.flyout == nil)
    }

    @Test func pointingAtAnotherRowClosesTheFlyout() {
        var m = menu(discs: 2)
        m.point(at: 3)
        _ = m.handle(.confirm)
        m.point(at: 4)
        #expect(m.flyout == nil)
    }

    @Test func quickSettingsOpensOnItsFirstRow() {
        var m = menu()
        m.point(at: 4)
        #expect(m.handle(.right) == PauseMenuAction.none)
        #expect(m.page == .quickSettings)
        #expect(m.selection == 0)
    }

    @Test func quickSettingsRowsStepTheirValue() {
        var m = menu()
        m.point(at: 4)
        _ = m.handle(.confirm)
        #expect(m.handle(.left) == .adjust(.speed, -1))
        #expect(m.handle(.right) == .adjust(.speed, 1))
        #expect(m.handle(.confirm) == .adjust(.speed, 1))
        _ = m.handle(.down)
        #expect(m.handle(.right) == .adjust(.resolution, 1))
    }

    @Test func backFromQuickSettingsReturnsToItsRow() {
        var m = menu()
        m.point(at: 4)
        _ = m.handle(.confirm)
        _ = m.handle(.down)
        #expect(m.handle(.back) == PauseMenuAction.none)
        #expect(m.page == .root)
        #expect(row(m) == .quickSettings)
    }

    @Test func gameInfoIsReadOnly() {
        var m = menu()
        m.point(at: 5)
        _ = m.handle(.confirm)
        #expect(m.page == .gameInfo)
        #expect(m.handle(.down) == PauseMenuAction.none)
        #expect(m.handle(.confirm) == PauseMenuAction.none)
        _ = m.handle(.left)
        #expect(m.page == .root)
        #expect(row(m) == .gameInfo)
    }

    @Test func resetReturnsToTheRootOnResume() {
        var m = menu()
        m.point(at: 4)
        _ = m.handle(.confirm)
        m.reset()
        #expect(m.page == .root)
        #expect(m.selection == 0)
        #expect(m.flyout == nil)
    }
}
