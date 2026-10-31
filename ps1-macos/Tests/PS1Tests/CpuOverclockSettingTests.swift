import CPs1
import Foundation
import Testing
@testable import PS1

/// A throwaway suite: the hosted tests share the app's defaults.
private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "cpu-overclock-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

struct CpuOverclockSettingTests {
    @Test func itShipsOffAtOneHundred() {
        withSuite { defaults in
            let s = CpuOverclockSetting(defaults: defaults)
            #expect(!s.enabled)
            #expect(s.percent == 100)
            #expect(s.effective == 100)
        }
    }

    @Test func aStoredPercentOutsideTheChoicesReadsAsTheDefault() {
        withSuite { defaults in
            for bad in [155, 2000, 0, -10] {
                defaults.set(bad, forKey: CpuOverclockSetting.percentKey)
                #expect(CpuOverclockSetting(defaults: defaults).percent == 100, "\(bad)")
            }
        }
    }

    @Test func theEffectivePercentIsOneHundredWhileDisabled() {
        withSuite { defaults in
            var s = CpuOverclockSetting(defaults: defaults)
            s.setPercent(200)
            #expect(s.effective == 100)
            s.setEnabled(true)
            #expect(s.effective == 200)
            let reread = CpuOverclockSetting(defaults: defaults)
            #expect(reread.enabled)
            #expect(reread.percent == 200)
            s.setEnabled(false)
            #expect(s.effective == 100)
            #expect(s.percent == 200)
        }
    }

    @Test func theChoicesStepByTenFromTenToOneThousand() {
        #expect(CpuOverclockSetting.choices.first == 10)
        #expect(CpuOverclockSetting.choices.last == 1000)
        #expect(CpuOverclockSetting.choices.count == 100)
    }

    @MainActor @Test func theSessionSettingsCarryTheEffectivePercent() {
        var s = SessionTests.settings
        s.cpuOverclock = 250
        #expect(s.c.cpu_overclock == 250)
        #expect(s.c.size == UInt32(MemoryLayout<Ps1SessionSettings>.size))
        #expect(SessionTests.settings.c.cpu_overclock == 100)
    }

    @Test func theTableNamesTheTwoUnderclocks() {
        #expect(Ps1Core.cpuOverclock(serial: "SLES-00275") == 95)
        #expect(Ps1Core.cpuOverclock(serial: "SLUS-00707") == nil)
        #expect(Ps1Core.cpuOverclock(serial: nil) == nil)
    }
}
