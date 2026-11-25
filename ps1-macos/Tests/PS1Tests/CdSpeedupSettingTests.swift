import CPs1
import Foundation
import Testing
@testable import PS1

/// A throwaway suite: the hosted tests share the app's defaults.
private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "cd-speedup-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

struct CdSpeedupSettingTests {
    @Test func bothShipAtTheRealDrive() {
        withSuite { defaults in
            let s = CdSpeedupSetting(defaults: defaults)
            #expect(s.read == 1)
            #expect(s.seek == 1)
        }
    }

    @Test func aStoredFactorOutsideTheChoicesReadsAsTheRealDrive() {
        withSuite { defaults in
            for bad in [0, 11, -2, 100] {
                defaults.set(bad, forKey: CdSpeedupSetting.readKey)
                defaults.set(bad, forKey: CdSpeedupSetting.seekKey)
                let s = CdSpeedupSetting(defaults: defaults)
                #expect(s.read == 1, "\(bad)")
                #expect(s.seek == 1, "\(bad)")
            }
        }
    }

    @Test func eachDirectionPersistsOnItsOwn() {
        withSuite { defaults in
            var s = CdSpeedupSetting(defaults: defaults)
            s.setRead(2)
            s.setSeek(10)
            s.setSeek(11)
            let reread = CdSpeedupSetting(defaults: defaults)
            #expect(reread.read == 2)
            #expect(reread.seek == 10)
        }
    }

    @Test func onlyTheRealDriveIsLabelled() {
        #expect(CdSpeedupSetting.title(1) == "1× (Real)")
        #expect(CdSpeedupSetting.title(4) == "4×")
    }

    @MainActor @Test func theSessionSettingsCarryBothFactors() {
        var s = SessionTests.settings
        s.cdReadSpeedup = 2
        s.cdSeekSpeedup = 10
        #expect(s.c.cd_read_speedup == 2)
        #expect(s.c.cd_seek_speedup == 10)
        #expect(s.c.size == UInt32(MemoryLayout<Ps1SessionSettings>.size))
        #expect(SessionTests.settings.c.cd_read_speedup == 1)
        #expect(SessionTests.settings.c.cd_seek_speedup == 1)
    }
}
