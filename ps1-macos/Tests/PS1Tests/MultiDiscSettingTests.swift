import Testing
import Foundation
@testable import PS1

/// Shaped after `PgxpSetting`, with the one difference that matters: this
/// setting defaults to TRUE, so `bool(forKey:)`'s false-for-absent is
/// ambiguous and absence has to be probed the way `VolumeSetting` probes its
/// level. Getting that wrong ships the feature off on every first launch.
struct MultiDiscSettingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aMissingKeyMeansOn() {
        let d = scratchDefaults("merge.default")
        #expect(MultiDiscSetting(key: "merge", defaults: d).merging == true)
    }

    @Test func persistsBothWays() {
        let d = scratchDefaults("merge.persist")
        var s = MultiDiscSetting(key: "merge", defaults: d)

        s.set(false)
        #expect(MultiDiscSetting(key: "merge", defaults: d).merging == false)
        s.set(true)
        #expect(MultiDiscSetting(key: "merge", defaults: d).merging == true)
    }
}
