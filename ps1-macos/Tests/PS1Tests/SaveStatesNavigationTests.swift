import Testing
@testable import PS1

/// The Save States panel driven by keys or a controller: Resume (row 0) and
/// slots 1-6 in one list, the bar of buttons under it, and the confirmation
/// Overwrite and Delete ask.
@Suite struct SaveStatesNavigationTests {
    @Test func itOpensOnTheFirstSave() {
        #expect(SaveStatesNavigation(filled: [0, 2]).selection == 0)
        #expect(SaveStatesNavigation(filled: [3, 5]).selection == 3)
        #expect(SaveStatesNavigation(filled: []).selection == 1)
    }

    @Test func upAndDownWalkTheListAndStopAtItsEnds() {
        var nav = SaveStatesNavigation(filled: [0])
        _ = nav.handle(.up)
        #expect(nav.selection == 0)
        for _ in 0..<8 { _ = nav.handle(.down) }
        #expect(nav.selection == 6)
        _ = nav.handle(.up)
        #expect(nav.selection == 5)
    }

    /// The app writes the resume state, never the player: with none there
    /// is nothing to load, so neither the mouse nor the keys can take it.
    @Test func resumeWithNoStateCannotBeTaken() {
        var nav = SaveStatesNavigation(filled: [])
        _ = nav.handle(.up)
        #expect(nav.selection == 1)
        nav.select(0)
        #expect(nav.selection == 1)
        #expect(nav.activate(0) == SaveStatesAction.none)
        #expect(!nav.isSelectable(0))
    }

    @Test func eachRowOffersItsOwnBarThePrimaryLast() {
        #expect(SaveStatesNavigation.buttons(row: 0, filled: true) == [.delete, .load])
        #expect(SaveStatesNavigation.buttons(row: 2, filled: true) == [.delete, .overwrite, .load])
        #expect(SaveStatesNavigation.buttons(row: 2, filled: false) == [.save])
    }

    @Test func returnPressesThePrimaryButton() {
        var nav = SaveStatesNavigation(filled: [0, 2])
        #expect(nav.handle(.confirm) == .load(.resume))
        nav.select(2)
        #expect(nav.button == .load)
        #expect(nav.handle(.confirm) == .load(.slot(2)))
        nav.select(4)
        #expect(nav.button == .save)
        #expect(nav.handle(.confirm) == .save(4))
        #expect(nav.sheet == nil)
    }

    @Test func aDoubleClickPressesTheRowsPrimaryButton() {
        var nav = SaveStatesNavigation(filled: [2])
        #expect(nav.activate(2) == .load(.slot(2)))
        #expect(nav.activate(5) == .save(5))
        #expect(nav.selection == 5)
    }

    @Test func leftAndRightMoveAlongTheBarAndANewRowStartsOnThePrimary() {
        var nav = SaveStatesNavigation(filled: [2])
        nav.select(2)
        _ = nav.handle(.left)
        #expect(nav.button == .overwrite)
        _ = nav.handle(.left)
        _ = nav.handle(.left)
        #expect(nav.button == .delete)
        _ = nav.handle(.down)
        #expect(nav.button == .save)
        _ = nav.handle(.up)
        #expect(nav.button == .load)
    }

    /// Only what loses a save asks first.
    @Test func overwriteAndDeleteAskFirst() {
        var nav = SaveStatesNavigation(filled: [0, 2])
        nav.select(2)
        #expect(nav.press(.overwrite) == SaveStatesAction.none)
        #expect(nav.sheet?.highlighted == .overwrite)
        #expect(nav.handle(.confirm) == .save(2))

        nav.select(0)
        #expect(nav.press(.delete) == SaveStatesAction.none)
        #expect(nav.sheet?.highlighted == .cancel)
        _ = nav.handle(.right)
        #expect(nav.handle(.confirm) == .delete(.resume))
        nav.removed(0)
        #expect(!nav.isSelectable(0))
        #expect(nav.selection == 1)
    }

    @Test func aButtonTheRowDoesNotHaveDoesNothing() {
        var nav = SaveStatesNavigation(filled: [])
        #expect(nav.press(.load) == SaveStatesAction.none)
        #expect(nav.press(.delete) == SaveStatesAction.none)
        #expect(nav.sheet == nil)
    }

    @Test func cancelAndBackCloseTheConfirmationAndNothingElse() {
        var nav = SaveStatesNavigation(filled: [2])
        nav.select(2)
        _ = nav.press(.delete)
        #expect(nav.answer(.cancel) == SaveStatesAction.none)
        #expect(nav.sheet == nil)
        _ = nav.press(.delete)
        #expect(nav.handle(.back) == SaveStatesAction.none)
        #expect(nav.sheet == nil)
    }

    @Test func backOnTheListClosesThePanel() {
        var nav = SaveStatesNavigation(filled: [])
        #expect(nav.handle(.back) == .close)
    }

    /// The panel stays up after a save, so the row's bar must follow it.
    @Test func aFinishedSaveFillsTheRowUnderTheSelection() {
        var nav = SaveStatesNavigation(filled: [])
        nav.select(3)
        nav.saved(3)
        #expect(nav.buttons == [.delete, .overwrite, .load])
        #expect(nav.button == .load)
    }

    /// The pointer clicks what it means, so the ring is drawn only once a key
    /// or the controller has moved.
    @Test func theFocusRingShowsOnlyForKeys() {
        var nav = SaveStatesNavigation(filled: [2])
        #expect(!nav.showsFocus)
        _ = nav.handle(.down)
        #expect(nav.showsFocus)
        nav.select(4)
        #expect(!nav.showsFocus)
        #expect(nav.selection == 4)
    }
}
