import Testing
import Foundation
@testable import PS1

/// The preset table as the app sees it through the C ABI, and the switch that
/// decides whether it applies.
struct PgxpPresetTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aListedGameOverridesOnlyWhatItLists() {
        // Spyro the Dragon (USA): CPU mode on, culling correction off.
        let spyro = PgxpPreset.lookup(serial: "SCUS-94228")
        #expect(spyro?.cpu == true)
        #expect(spyro?.culling == false)
        #expect(spyro?.enabled == nil)
        #expect(spyro?.tolerance == nil)
    }

    @Test func aToleranceCrossesAsAValue() {
        // Tekken 3 (USA).
        #expect(PgxpPreset.lookup(serial: "SLUS-00402")?.tolerance == 3)
    }

    @Test func anUnlistedOrMissingSerialHasNoPreset() {
        #expect(PgxpPreset.lookup(serial: "SLUS-00707") == nil)  // Silent Hill (USA)
        #expect(PgxpPreset.lookup(serial: "") == nil)
        #expect(PgxpPreset.lookup(serial: nil) == nil)
    }

    @Test func changesUseTheSettingsWindowsTitles() {
        let preset = PgxpPreset(cpu: true, culling: false, tolerance: 3)
        #expect(preset.changes == ["Culling Correction off", "CPU Mode on", "Tolerance 3 px"])
        #expect(PgxpPreset().changes.isEmpty)
    }

    @Test func perGameFixesDefaultOnWhenTheKeyIsAbsent() {
        let d = scratchDefaults("pgxp.usePresets.absent")
        // bool(forKey:) would report false here, which is why this one probes.
        #expect(PgxpSetting(key: "pgxp", defaults: d).usePresets == true)
    }

    @Test func perGameFixesSurviveBeingTurnedOffAndRestore() {
        let d = scratchDefaults("pgxp.usePresets.off")
        var s = PgxpSetting(key: "pgxp", defaults: d)
        s.setUsePresets(false)
        #expect(PgxpSetting(key: "pgxp", defaults: d).usePresets == false)
        #expect(!s.isDefault)
        s.restoreDefaults()
        #expect(s.usePresets == true)
        #expect(s.isDefault)
    }
}
