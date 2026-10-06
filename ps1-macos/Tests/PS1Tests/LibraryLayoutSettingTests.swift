import Testing
import Foundation
@testable import PS1

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
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setViewMode(.list)
    setting.setTileSize(200)
    let reloaded = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    #expect(reloaded.viewMode == .list)
    #expect(reloaded.tileSize == 200)
}

@Test func theTileSizeIsClampedOnSetAndOnLoad() {
    let (mode, size) = keys()
    var setting = LibraryLayoutSetting(viewModeKey: mode, sizeKey: size)
    setting.setTileSize(999)
    #expect(setting.tileSize == 260)
    setting.setTileSize(10)
    #expect(setting.tileSize == 100)
    UserDefaults.standard.set(5000.0, forKey: size)
    #expect(LibraryLayoutSetting(viewModeKey: mode, sizeKey: size).tileSize == 260)
}
