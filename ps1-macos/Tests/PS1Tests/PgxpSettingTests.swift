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

    // The four sub-settings. Two of them invert the reasoning in this type's
    // own doc comment, which is why they are pinned here: `culling` defaults
    // TRUE and `tolerance` defaults to -1, so for those two a missing key is
    // ambiguous under `bool`/`float(forKey:)` and has to be probed.

    @Test func cpuModeDefaultsOff() {
        let d = scratchDefaults("pgxp.cpu.default")
        #expect(PgxpSetting(key: "pgxp", defaults: d).cpu == false)
    }

    @Test func cullingDefaultsOnWhenTheKeyIsAbsent() {
        let d = scratchDefaults("pgxp.culling.absent")
        // bool(forKey:) would report false here, which is why this one probes.
        #expect(PgxpSetting(key: "pgxp", defaults: d).culling == true)
    }

    @Test func cullingSurvivesBeingTurnedOff() {
        let d = scratchDefaults("pgxp.culling.off")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.setCulling(false)
        // The case a plain default would silently undo on the next launch.
        #expect(PgxpSetting(key: "pgxp", defaults: d).culling == false)
    }

    @Test func vertexCacheDefaultsOff() {
        let d = scratchDefaults("pgxp.cache.default")
        #expect(PgxpSetting(key: "pgxp", defaults: d).vertexCache == false)
    }

    @Test func toleranceDefaultsToDisabled() {
        let d = scratchDefaults("pgxp.tolerance.absent")
        #expect(PgxpSetting(key: "pgxp", defaults: d).tolerance < 0)
    }

    @Test func toleranceOfZeroIsKeptApartFromAbsence() {
        let d = scratchDefaults("pgxp.tolerance.zero")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.setTolerance(0)
        // Zero is a legitimate setting -- it admits only a candidate exactly on
        // the integer grid -- and must not read back as "not set".
        #expect(PgxpSetting(key: "pgxp", defaults: d).tolerance == 0)
    }

    @Test func toleranceRoundTrips() {
        let d = scratchDefaults("pgxp.tolerance.persist")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.setTolerance(0.5)
        #expect(PgxpSetting(key: "pgxp", defaults: d).tolerance == 0.5)
    }

    @Test func theSubSettingsKeepTheirOwnKeys() {
        let d = scratchDefaults("pgxp.keys")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.set(true)
        s.setCpu(true)
        s.setVertexCache(true)
        s.setCulling(false)
        let reloaded = PgxpSetting(key: "pgxp", defaults: d)
        // One key per setting: a shared key would make the master toggle drag
        // the others with it.
        #expect(reloaded.enabled == true)
        #expect(reloaded.cpu == true)
        #expect(reloaded.vertexCache == true)
        #expect(reloaded.culling == false)
    }
}
