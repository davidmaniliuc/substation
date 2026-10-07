import Testing
import Foundation
@testable import PS1

/// Default OFF, so unlike `MultiDiscSetting` the absent key and `false` agree.
struct FastBootSettingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aMissingKeyMeansOff() {
        let d = scratchDefaults("fastboot.default")
        #expect(FastBootSetting(key: "fastboot", defaults: d).enabled == false)
    }

    @Test func persistsBothWays() {
        let d = scratchDefaults("fastboot.persist")
        var s = FastBootSetting(key: "fastboot", defaults: d)

        s.set(true)
        #expect(FastBootSetting(key: "fastboot", defaults: d).enabled == true)
        s.set(false)
        #expect(FastBootSetting(key: "fastboot", defaults: d).enabled == false)
    }
}
