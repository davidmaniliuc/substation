import Testing
import Foundation
@testable import PS1

/// A fresh defaults key pair per test, as `VolumeSettingTests` does: these
/// write to the real `UserDefaults`, so every test that may write removes
/// its keys again.
private func keys() -> (String, String) {
    let id = UUID().uuidString
    return ("test-libview-\(id)", "test-libsize-\(id)")
}

@Test func anAbsentLayoutIsTheGridAtTodaysSize() {
    let (mode, size) = keys()
    let setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    #expect(setting.viewMode == .grid)
    #expect(setting.tileSize == 132)
}

@Test func theLayoutPersists() {
    let (mode, size) = keys()
    defer {
        UserDefaults.standard.removeObject(forKey: mode)
        UserDefaults.standard.removeObject(forKey: size)
    }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setViewMode(.list)
    setting.setTileSize(200)
    setting.commitTileSize()
    let reloaded = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    #expect(reloaded.viewMode == .list)
    #expect(reloaded.tileSize == 200)
}

@Test func theTileSizeIsFlooredOnSetAndOnLoad() {
    let (mode, size) = keys()
    defer { UserDefaults.standard.removeObject(forKey: size) }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(10)
    #expect(setting.tileSize == 100)
    UserDefaults.standard.set(5.0, forKey: size)
    #expect(LibraryLayoutSetting(viewModeKey: mode, sizeKey: size).tileSize == 100)
}

@Test func settingTheCurrentViewModeWritesNothing() {
    let (mode, size) = keys()
    defer { UserDefaults.standard.removeObject(forKey: mode) }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setViewMode(.grid)
    #expect(UserDefaults.standard.object(forKey: mode) == nil)
    setting.setViewMode(.list)
    #expect(UserDefaults.standard.object(forKey: mode) != nil)
}

@Test func settingTheCurrentTileSizeWritesNothing() {
    let (mode, size) = keys()
    defer { UserDefaults.standard.removeObject(forKey: size) }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(LibraryLayoutSetting.defaultSize)
    setting.commitTileSize()
    #expect(UserDefaults.standard.object(forKey: size) == nil)
}

@Test func aLiveTileSizeIsNotPersistedUntilCommitted() {
    let (mode, size) = keys()
    defer { UserDefaults.standard.removeObject(forKey: size) }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(119.47)
    #expect(setting.tileSize == 119.47)
    #expect(UserDefaults.standard.object(forKey: size) == nil)
    setting.commitTileSize()
    #expect(UserDefaults.standard.double(forKey: size) == 119.47)
}

@Test func persistedChoiceIgnoresAnUnchangedValue() {
    let key = "test-choice-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var choice = PersistedChoice<LibraryViewMode>(key: key, defaults: .standard, fallback: .grid)
    choice.set(.grid)
    #expect(UserDefaults.standard.object(forKey: key) == nil)
    choice.set(.list)
    #expect(UserDefaults.standard.integer(forKey: key) == 1)
}

@Test func actualSizeResetsToTheDefaultAndPersists() {
    let (mode, size) = keys()
    defer { UserDefaults.standard.removeObject(forKey: size) }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(220)
    setting.commitTileSize()
    setting.resetTileSize()
    #expect(setting.tileSize == LibraryLayoutSetting.defaultSize)
    #expect(LibraryLayoutSetting(viewModeKey: mode, sizeKey: size).tileSize == 132)
}

private func columns(_ size: Double, _ width: Double) -> Int {
    GridSelection.columns(width: width, minimum: size, spacing: LibraryLayoutSetting.tileSpacing)
}

/// A step is one column, never a no-op: at three window widths, every
/// reachable column count gets a size that lays out exactly that count, and
/// it is the smallest such size.
@Test func aColumnStepAlwaysLandsOnTheColumnCount() {
    for width in [666.0, 952.0, 1392.0] {
        let reachable = (1...20).filter { LibraryLayoutSetting.size(forColumns: $0, width: width) != nil }
        #expect(!reachable.isEmpty)
        // Contiguous: from any reachable count the next one up or down is
        // reachable too, until the range runs out.
        #expect(reachable == Array(1...reachable.last!))
        let range = LibraryLayoutSetting.sizeRange(width: width, height: 0)
        for count in reachable {
            let size = LibraryLayoutSetting.size(forColumns: count, width: width)!
            #expect(columns(size, width) == count)
            #expect(range.contains(size) || count < 2)
            if size > range.lowerBound {
                #expect(columns(size - 1, width) != count)
            }
        }
    }
}

/// At the bounds there is no further column, and the press does nothing.
@Test func noColumnStepPastTheSizeRange() {
    let width = 952.0
    #expect(columns(100, width) == 8)
    #expect(LibraryLayoutSetting.size(forColumns: 9, width: width) == nil)
    #expect(LibraryLayoutSetting.size(forColumns: 8, width: width) == 100)
    #expect(LibraryLayoutSetting.size(forColumns: 0, width: width) == nil)
}

/// The biggest cover is no taller than `coverHeightShare` of the visible
/// height, and never fewer than two to a row: two in half a screen, three
/// in a full one, four on a big display.
@Test func theFewestColumnsFollowTheWidthAndTheHeight() {
    #expect(LibraryLayoutSetting.fewestColumns(width: 672, height: 850) == 2)
    #expect(LibraryLayoutSetting.fewestColumns(width: 1392, height: 850) == 3)
    #expect(LibraryLayoutSetting.fewestColumns(width: 2512, height: 1350) == 4)
    // A short window wants smaller covers than a tall one as wide.
    #expect(LibraryLayoutSetting.fewestColumns(width: 952, height: 600) == 3)
    #expect(LibraryLayoutSetting.fewestColumns(width: 952, height: 1200) == 2)
    // No height yet: two.
    #expect(LibraryLayoutSetting.fewestColumns(width: 1392, height: 0) == 2)
    // Too narrow for two even at the smallest size: one.
    #expect(LibraryLayoutSetting.fewestColumns(width: 200, height: 800) == 1)
}

/// The range's top is the fewest columns' step, its bottom the most.
@Test func theSizeRangeEndsAtTheFewestColumns() {
    for (width, height) in [(672.0, 850.0), (1392.0, 850.0), (2512.0, 1350.0)] {
        let range = LibraryLayoutSetting.sizeRange(width: width, height: height)
        let fewest = LibraryLayoutSetting.fewestColumns(width: width, height: height)
        #expect(range.upperBound == LibraryLayoutSetting.size(forColumns: fewest, width: width))
        #expect(columns(range.upperBound, width) == fewest)
        #expect(range.lowerBound == LibraryLayoutSetting.minimumSize)
    }
    #expect(LibraryLayoutSetting.sizeRange(width: 0, height: 0)
        == LibraryLayoutSetting.minimumSize...LibraryLayoutSetting.defaultSize)
}

/// A size chosen in a bigger window, or stored before the ceiling, lays out
/// the fewest columns rather than fewer.
@Test func aTooBigSizeIsFitted() {
    let (width, height) = (1392.0, 850.0)
    let three = LibraryLayoutSetting.size(forColumns: 3, width: width)!
    #expect(LibraryLayoutSetting.fitted(600, width: width, height: height) == three)
    #expect(LibraryLayoutSetting.fitted(150, width: width, height: height) == 150)
    #expect(LibraryLayoutSetting.fitted(600, width: 0, height: 0) == 600)
}

/// The slider moves in the column steps: every value inside one column
/// count lands on that count's step, and a value with no grid width yet is
/// only clamped.
@Test func aSliderDragSnapsToTheColumnStep() {
    let (width, height) = (952.0, 1200.0)
    let three = LibraryLayoutSetting.size(forColumns: 3, width: width)!
    for value in stride(from: three, to: three + 60, by: 7) where columns(value, width) == 3 {
        #expect(LibraryLayoutSetting.snapped(value, width: width, height: height) == three)
    }
    #expect(LibraryLayoutSetting.snapped(999, width: width, height: height)
        == LibraryLayoutSetting.size(forColumns: 2, width: width))
    #expect(LibraryLayoutSetting.snapped(999, width: width, height: 600) == three)
    #expect(LibraryLayoutSetting.snapped(143.5, width: 0, height: 0) == 143.5)
}
