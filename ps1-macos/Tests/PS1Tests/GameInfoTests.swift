import Testing
import Foundation
@testable import PS1

/// The pause menu's Game Info page: what the app knows about the running
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
        model.simulateDiscsForTesting(discs, inserted: 1, bios: "SCPH-1001")
        let rows = model.gameInfo
        #expect(value("Serial", rows) == "SCUS-94164")
        #expect(value("Region", rows) == "North America")
        #expect(value("Disc", rows) == "2 of 3")
        #expect(value("BIOS", rows) == "SCPH-1001")
        #expect(value("Image", rows) == "CUE/BIN")
    }

    @Test func aChdAndAnUnknownRegionSaySo() throws {
        let dir = try folder()
        let model = EmulatorViewModel()
        model.simulateDiscsForTesting([disc("g.chd", serial: "SLES-00001", region: nil, in: dir)],
                                      inserted: 0, bios: nil)
        let rows = model.gameInfo
        #expect(value("Region", rows) == "Unknown")
        #expect(value("Image", rows) == "CHD")
        #expect(value("BIOS", rows) == "Unidentified")
    }

    @Test func patchAndSidecarRowsAppearOnlyWhenPresent() throws {
        let dir = try folder()
        let model = EmulatorViewModel()
        let entry = disc("ff9.cue", serial: "SLES-02965", region: .europe, in: dir)
        model.simulateDiscsForTesting([entry], inserted: 0, bios: nil)
        #expect(value("Patch", model.gameInfo) == nil)
        #expect(value("LibCrypt", model.gameInfo) == nil)

        try Data([1]).write(to: dir.appending(path: "ff9.ppf"))
        try Data([1]).write(to: dir.appending(path: "ff9.sbi"))
        #expect(value("Patch", model.gameInfo) == "PPF applied")
        #expect(value("LibCrypt", model.gameInfo) == "SBI sidecar")
    }
}
