import Testing
@testable import PS1

/// Arrow-key movement over the library grid, as plain indices: the rule is
/// reachable without a window, and the view only maps an index to a group.

@Test func leftAndRightStepOneTileAndStopAtTheEnds() {
    #expect(GridSelection.move(from: 3, .right, count: 10, columns: 4) == 4)
    #expect(GridSelection.move(from: 4, .left, count: 10, columns: 4) == 3)
    #expect(GridSelection.move(from: 0, .left, count: 10, columns: 4) == 0)
    #expect(GridSelection.move(from: 9, .right, count: 10, columns: 4) == 9)
}

@Test func upAndDownStepOneRow() {
    #expect(GridSelection.move(from: 1, .down, count: 10, columns: 4) == 5)
    #expect(GridSelection.move(from: 5, .up, count: 10, columns: 4) == 1)
    #expect(GridSelection.move(from: 2, .up, count: 10, columns: 4) == 2)
}

/// Ten tiles in rows of four leave a last row of two; going down from a
/// column the last row does not reach lands on its last tile, as Finder does.
@Test func downIntoAShortLastRowLandsOnItsLastTile() {
    #expect(GridSelection.move(from: 7, .down, count: 10, columns: 4) == 9)
    #expect(GridSelection.move(from: 9, .down, count: 10, columns: 4) == 9)
    #expect(GridSelection.move(from: 8, .down, count: 10, columns: 4) == 8)
}

@Test func aSingleColumnMovesByOneEitherWay() {
    #expect(GridSelection.move(from: 2, .down, count: 5, columns: 1) == 3)
    #expect(GridSelection.move(from: 2, .up, count: 5, columns: 1) == 1)
}

@Test func nothingSelectedStartsAtTheFirstTile() {
    #expect(GridSelection.move(from: nil, .right, count: 10, columns: 4) == 0)
    #expect(GridSelection.move(from: nil, .down, count: 10, columns: 4) == 0)
    #expect(GridSelection.move(from: nil, .down, count: 0, columns: 4) == nil)
}

/// The same count `.adaptive(minimum: 132, spacing: 20)` lays out: as many
/// minimum-width tracks as fit, never fewer than one.
@Test func columnsMatchTheAdaptiveGrid() {
    #expect(GridSelection.columns(width: 132, minimum: 132, spacing: 20) == 1)
    #expect(GridSelection.columns(width: 283, minimum: 132, spacing: 20) == 1)
    #expect(GridSelection.columns(width: 284, minimum: 132, spacing: 20) == 2)
    #expect(GridSelection.columns(width: 50, minimum: 132, spacing: 20) == 1)
}
