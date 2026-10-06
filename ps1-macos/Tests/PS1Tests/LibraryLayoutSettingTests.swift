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

@Test func theTileSizeIsClampedOnSetAndOnLoad() {
    let (mode, size) = keys()
    defer { UserDefaults.standard.removeObject(forKey: size) }
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(999)
    #expect(setting.tileSize == 260)
    setting.setTileSize(10)
    #expect(setting.tileSize == 100)
    UserDefaults.standard.set(5000.0, forKey: size)
    #expect(LibraryLayoutSetting(viewModeKey: mode, sizeKey: size).tileSize == 260)
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
        #expect(reachable == Array(reachable.first!...reachable.last!))
        for count in reachable {
            let size = LibraryLayoutSetting.size(forColumns: count, width: width)!
            #expect(columns(size, width) == count)
            #expect(LibraryLayoutSetting.sizeRange.contains(size))
            if size > LibraryLayoutSetting.sizeRange.lowerBound {
                #expect(columns(size - 1, width) != count)
            }
        }
    }
}

/// At the bounds there is no further column, and the press does nothing.
@Test func noColumnStepPastTheSizeRange() {
    let width = 952.0
    #expect(columns(100, width) == 8)
    #expect(columns(260, width) == 3)
    #expect(LibraryLayoutSetting.size(forColumns: 9, width: width) == nil)
    #expect(LibraryLayoutSetting.size(forColumns: 2, width: width) == nil)
    #expect(LibraryLayoutSetting.size(forColumns: 8, width: width) == 100)
    #expect(LibraryLayoutSetting.size(forColumns: 0, width: width) == nil)
}
