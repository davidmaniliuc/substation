import Testing
@testable import PS1

/// The Save States panel driven by keys or a controller: Resume in its own
/// column (tile 0), slots 1-6 in a 3×2 grid, and the sheet a pick opens.
@Suite struct SaveStatesNavigationTests {
    @Test func itOpensOnTheFirstSaveForALoad() {
        #expect(SaveStatesNavigation(filled: [0, 2], origin: .bar).selection == 0)
        #expect(SaveStatesNavigation(filled: [3, 5], origin: .menuLoad).selection == 3)
        #expect(SaveStatesNavigation(filled: [], origin: .bar).selection == 1)
    }

    @Test func itOpensOnSlotOneForASave() {
        #expect(SaveStatesNavigation(filled: [0, 4], origin: .menuSave).selection == 1)
    }

    @Test func leftFromTheFirstColumnReachesResumeOnlyWhenThereIsOne() {
        var nav = SaveStatesNavigation(filled: [0], origin: .menuSave)
        nav.point(at: 4)
        _ = nav.handle(.left)
        #expect(nav.selection == 0)

        var empty = SaveStatesNavigation(filled: [], origin: .bar)
        _ = empty.handle(.left)
        #expect(empty.selection == 1)
    }

    @Test func rightFromResumeLandsOnSlotOne() {
        var nav = SaveStatesNavigation(filled: [0], origin: .bar)
        _ = nav.handle(.right)
        #expect(nav.selection == 1)
    }

    @Test func theGridMovesByRowsAndStopsAtItsEdges() {
        var nav = SaveStatesNavigation(filled: [], origin: .bar)
        nav.point(at: 2)
        _ = nav.handle(.down)
        #expect(nav.selection == 5)
        _ = nav.handle(.down)
        #expect(nav.selection == 5)
        _ = nav.handle(.up)
        #expect(nav.selection == 2)
        nav.point(at: 3)
        _ = nav.handle(.right)
        #expect(nav.selection == 3)
    }

    @Test func eachTileOffersItsOwnButtons() {
        #expect(SaveStatesNavigation.buttons(tile: 0) == [.cancel, .load])
        #expect(SaveStatesNavigation.buttons(tile: 2) == [.cancel, .overwrite, .load])
    }

    @Test func aFullSlotOffersLoadFirstUnlessThePlayerChoseSaveState() {
        var load = SaveStatesNavigation(filled: [2], origin: .menuLoad)
        _ = load.pick(2)
        #expect(load.sheet?.highlighted == .load)

        var save = SaveStatesNavigation(filled: [2], origin: .menuSave)
        _ = save.pick(2)
        #expect(save.sheet?.highlighted == .overwrite)
    }

    @Test func resumeAlwaysOffersLoad() {
        var nav = SaveStatesNavigation(filled: [0], origin: .menuSave)
        _ = nav.pick(0)
        #expect(nav.sheet?.highlighted == .load)
    }

    @Test func confirmingTheSheetLoadsOrSaves() {
        var nav = SaveStatesNavigation(filled: [0, 2], origin: .bar)
        _ = nav.handle(.confirm)                        // Resume's sheet
        #expect(nav.handle(.confirm) == .load(.resume))

        _ = nav.pick(2)
        #expect(nav.handle(.confirm) == .load(.slot(2)))

        #expect(nav.pick(4) == .save(4))               // empty: no sheet
        #expect(nav.sheet == nil)
    }

    @Test func overwriteIsOneStepLeftOfLoad() {
        var nav = SaveStatesNavigation(filled: [2], origin: .bar)
        _ = nav.pick(2)
        _ = nav.handle(.left)
        #expect(nav.sheet?.highlighted == .overwrite)
        #expect(nav.handle(.confirm) == .save(2))
    }

    @Test func cancelAndBackCloseTheSheetAndNothingElse() {
        var nav = SaveStatesNavigation(filled: [2], origin: .bar)
        _ = nav.pick(2)
        #expect(nav.press(.cancel) == SaveStatesAction.none)
        #expect(nav.sheet == nil)
        _ = nav.pick(2)
        #expect(nav.handle(.back) == SaveStatesAction.none)
        #expect(nav.sheet == nil)
    }

    @Test func backOnTheGridClosesThePanel() {
        var nav = SaveStatesNavigation(filled: [], origin: .bar)
        #expect(nav.handle(.back) == .close)
    }

    /// The app writes the resume state, never the player: with none there
    /// is nothing to load, so neither the mouse nor the keys can take it.
    @Test func resumeWithNoStateCannotBeTaken() {
        var nav = SaveStatesNavigation(filled: [], origin: .bar)
        #expect(nav.pick(0) == SaveStatesAction.none)
        #expect(nav.sheet == nil)
        nav.point(at: 0)
        #expect(nav.selection == 1)
        #expect(!nav.isSelectable(0))
    }

    /// A corner acts at once only where no save is lost.
    @Test func cornersAskBeforeOverwritingOrDeleting() {
        var nav = SaveStatesNavigation(filled: [0, 2], origin: .bar)
        #expect(nav.corner(.load, on: 2) == .load(.slot(2)))
        #expect(nav.corner(.save, on: 4) == SaveStatesAction.none)
        #expect(nav.corner(.save, on: 0) == SaveStatesAction.none)

        #expect(nav.corner(.save, on: 2) == SaveStatesAction.none)
        #expect(nav.sheet?.highlighted == .overwrite)
        #expect(nav.handle(.confirm) == .save(2))

        #expect(nav.corner(.delete, on: 0) == SaveStatesAction.none)
        #expect(nav.sheet?.highlighted == .cancel)
        _ = nav.handle(.right)
        #expect(nav.handle(.confirm) == .delete(.resume))
        nav.removed(0)
        #expect(!nav.isSelectable(0))
        #expect(nav.selection == 1)
    }

    /// The pointer shows its own hover, so the highlight is drawn only once
    /// a key or the controller has moved it.
    @Test func theHighlightShowsOnlyForKeys() {
        var nav = SaveStatesNavigation(filled: [2], origin: .bar)
        #expect(!nav.showsSelection)
        _ = nav.handle(.right)
        #expect(nav.showsSelection)
        nav.point(at: 4)
        #expect(!nav.showsSelection)
        #expect(nav.selection == 4)
    }
}
