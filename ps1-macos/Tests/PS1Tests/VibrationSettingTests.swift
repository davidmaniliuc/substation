import Foundation
import Testing
@testable import PS1

private func freshDefaults() -> UserDefaults {
    let name = "VibrationSettingTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

struct VibrationSettingTests {
    /// Default ON, so absence must not read as false.
    @Test func absentMeansOn() {
        #expect(VibrationSetting(defaults: freshDefaults()).enabled)
    }

    @Test func offPersists() {
        let d = freshDefaults()
        var s = VibrationSetting(defaults: d)
        s.set(false)
        #expect(!VibrationSetting(defaults: d).enabled)
    }
}
