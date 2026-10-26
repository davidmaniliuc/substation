import Testing
import Foundation
@testable import PS1

private func makeDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "runahead-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Test func runaheadIsOffWhenNeverSetAndPersists() {
    let (defaults, name) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    var setting = RunaheadSetting(key: "k", defaults: defaults)
    #expect(setting.frames == 0)
    setting.set(2)
    #expect(RunaheadSetting(key: "k", defaults: defaults).frames == 2)
    setting.set(9)
    #expect(setting.frames == 2)
    defaults.set(7, forKey: "k")
    #expect(RunaheadSetting(key: "k", defaults: defaults).frames == 0)
    #expect(RunaheadSetting.choices == [0, 1, 2, 3])
    #expect(RunaheadSetting.title(0) == "Off")
    #expect(RunaheadSetting.title(1) == "1 Frame")
}
