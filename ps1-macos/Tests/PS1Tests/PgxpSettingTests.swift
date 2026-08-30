import Testing
import Foundation
@testable import PS1

/// The same shape as `InternalResolution`, and the same reason it is a type:
/// the rule is reachable from a test without a window.
///
/// Unlike `VolumeSetting`, an absent key is NOT ambiguous here —
/// `bool(forKey:)` returns false for a missing key and false is the intended
/// default — so no `object(forKey:)` probe is needed.
struct PgxpSettingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsToOff() {
        let d = scratchDefaults("pgxp.default")
        #expect(PgxpSetting(key: "pgxp", defaults: d).enabled == false)
    }

    @Test func persistsAndReloads() {
        let d = scratchDefaults("pgxp.persist")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.set(true)
        #expect(PgxpSetting(key: "pgxp", defaults: d).enabled == true)
        s.set(false)
        #expect(PgxpSetting(key: "pgxp", defaults: d).enabled == false)
    }
}
