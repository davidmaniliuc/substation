import Testing
import Foundation
@testable import PS1

/// The pause menu's About This Game: what the app knows about the running
/// disc, read-only.
@MainActor
@Suite struct GameInfoTests {
    private func disc(_ name: String, serial: String, region: DiscIdentity.Region?,
                      in dir: URL) -> GameEntry {
        GameEntry(url: dir.appending(path: name),
                  identity: DiscIdentity(region: region, serial: serial, volumeID: nil))
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func value(_ label: String, _ rows: [GameInfoRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    @Test func itNamesTheDiscInTheDrive() throws {
        let dir = try folder()
        let model = EmulatorViewModel()
        let discs = [disc("a.cue", serial: "SCUS-94163", region: .america, in: dir),
                     disc("b.cue", serial: "SCUS-94164", region: .america, in: dir),
                     disc("c.cue", serial: "SCUS-94165", region: .america, in: dir)]
        let bios = BiosImage(models: ["SCPH-1001", "DTL-H1001"], description: "", region: .us)
        model.simulateDiscsForTesting(discs, inserted: 1, bios: bios)
        let rows = model.gameInfo(identityInHeader: false)
        #expect(value("Serial", rows) == "SCUS-94164")
        #expect(value("Region", rows) == "North America")
        #expect(value("Disc", rows) == "2 of 3")
        #expect(value("Console", rows) == "SCPH-1001 (North America)")
        #expect(value("Image", rows) == "CUE/BIN")
    }

    @Test func aChdAndAnUnknownRegionSaySo() throws {
        let dir = try folder()
        let model = EmulatorViewModel()
        model.simulateDiscsForTesting([disc("g.chd", serial: "SLES-00001", region: nil, in: dir)],
                                      inserted: 0, bios: nil)
        let rows = model.gameInfo(identityInHeader: false)
        #expect(value("Region", rows) == "Unknown")
        #expect(value("Image", rows) == "CHD")
        #expect(value("Console", rows) == "Unidentified")
    }

    @Test func patchAndSidecarRowsAppearOnlyWhenPresent() throws {
        let dir = try folder()
        let model = EmulatorViewModel()
        let entry = disc("ff9.cue", serial: "SLES-02965", region: .europe, in: dir)
        model.simulateDiscsForTesting([entry], inserted: 0, bios: nil)
        #expect(value("Patch", model.gameInfo(identityInHeader: true)) == nil)
        #expect(value("LibCrypt", model.gameInfo(identityInHeader: true)) == nil)

        try Data([1]).write(to: dir.appending(path: "ff9.ppf"))
        try Data([1]).write(to: dir.appending(path: "ff9.sbi"))
        #expect(value("Patch", model.gameInfo(identityInHeader: true)) == "PPF applied")
        #expect(value("LibCrypt", model.gameInfo(identityInHeader: true)) == "SBI sidecar")
    }

    /// Nothing the header already says, and nothing that only describes
    /// the game being played right now.
    @Test func itRepeatsNothingTheHeaderSays() throws {
        let dir = try folder()
        let model = EmulatorViewModel()
        model.simulateDiscsForTesting([disc("crash.cue", serial: "SCES-00344", region: .europe, in: dir)],
                                      inserted: 0, bios: nil)
        let labels = model.gameInfo(identityInHeader: true).map(\.label)
        #expect(labels == ["Total Play Time", "Console", "Image"])
    }

    /// The PAL v4.1 dump lists SCPH-7002 first; a European player's console
    /// is the SCPH-7502 the same image shipped in.
    @Test func theConsoleIsTheRegionsOwnModel() {
        let pal = BiosImage(models: ["SCPH-7002", "SCPH-7502", "SCPH-9002"], description: "",
                            region: .europe)
        #expect(GameInfo.console(pal) == "SCPH-7502 (Europe)")
        let japan = BiosImage(models: ["SCPH-3000"], description: "", region: .japan)
        #expect(GameInfo.console(japan) == "SCPH-3000 (Japan)")
    }
}

/// The Save States row's subtitle.
@Suite struct SaveStatesSummaryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func noStatesSaysSo() {
        #expect(SaveStatesSummary.text(count: 0, newest: nil, now: now) == "None saved")
    }

    @Test func recentSavesReadAsTheLibraryDoes() {
        #expect(SaveStatesSummary.text(count: 1, newest: now.addingTimeInterval(-20), now: now)
                == "1 saved · Just now")
        let five = now.addingTimeInterval(-5 * 60)
        #expect(SaveStatesSummary.text(count: 4, newest: five, now: now)
                == "4 saved · \(LibraryFormat.tileSubtitle(discs: 1, lastPlayed: five, now: now))")
        let three = now.addingTimeInterval(-3 * 3600)
        #expect(SaveStatesSummary.text(count: 2, newest: three, now: now)
                == "2 saved · \(LibraryFormat.tileSubtitle(discs: 1, lastPlayed: three, now: now))")
    }

    @Test func anOlderSaveNamesItsDay() {
        let old = now.addingTimeInterval(-3 * 86_400)
        #expect(SaveStatesSummary.text(count: 1, newest: old, now: now)
                == "1 saved · \(StateSource.savedAt(old, now: now))")
    }
}
