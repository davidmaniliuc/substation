import Testing
import Foundation
@testable import PS1

@Test func europeDiscSelectsThePALBios() {
    #expect(BiosRegion.forDisc(named: "Rayman (Europe) (En,Fr,De).cue") == .europe)
    #expect(BiosRegion.forDisc(named: "Doom (Europe) (EDC).cue") == .europe)
}

@Test func japanDiscSelectsTheJapaneseBios() {
    #expect(BiosRegion.forDisc(named: "Some Game (Japan).cue") == .japan)
}

@Test func everythingElseSelectsTheUSBios() {
    #expect(BiosRegion.forDisc(named: "Silent Hill (USA).cue") == .us)
    #expect(BiosRegion.forDisc(named: "Croc - Legend of the Gobbos.cue") == .us)
}

@Test func regionRawValueIsTheBiosFilenameStem() {
    #expect(BiosRegion.europe.rawValue == "SCPH-7502")
    #expect(BiosRegion.japan.rawValue == "SCPH-1000")
    #expect(BiosRegion.us.rawValue == "SCPH-1001")
}

@Test func matchIsCaseInsensitive() {
    #expect(BiosRegion.forDisc(named: "Game (EUROPE).cue") == .europe)
}

/// The repo's BIOS folder holds both `SCPH-1001_BIOS_1995_US.bin` and
/// `SCPH-101_BIOS_2000_US.bin`. Prefix matching must not mistake the second for
/// the first — SCPH-101 is the model every BIOS fails Crash Bandicoot on, so
/// silently selecting it would look like a core regression.
@Test func scph101IsNotMistakenForScph1001() throws {
    let (library, dir) = try library(holding: Data(repeating: 0, count: 524288),
                                     as: "SCPH-101_BIOS_2000_US.bin")
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: (any Error).self) {
        _ = try library.biosData(forDisc: "Silent Hill (USA).cue")
    }
}

/// The disc outranks its filename, which is the whole point: Final Fantasy IX
/// (France) carries no `(Europe)` token and drew a US BIOS under the filename
/// rule, so it stopped at the region-lock screen.
@Test func theDiscsOwnRegionBeatsItsFilename() {
    let europeanDisc = DiscIdentity(region: .europe, serial: "SLES-02966", volumeID: nil)
    #expect(BiosRegion.forDisc(europeanDisc, named: "Final Fantasy IX (France) (Disc 1).cue")
            == .europe)

    let americanDisc = DiscIdentity(region: .america, serial: "SLUS-00530", volumeID: nil)
    #expect(BiosRegion.forDisc(americanDisc, named: "Croc (Europe).cue") == .us)
}

@Test func aDiscThatNamesNoRegionFallsBackToItsFilename() {
    #expect(BiosRegion.forDisc(.unknown, named: "Rayman (Europe).cue") == .europe)
    #expect(BiosRegion.forDisc(.unknown, named: "Silent Hill (USA).cue") == .us)
}

// MARK: - Identification by content

/// A folder holding one BIOS image under `name`, and a library pointed at it.
private func library(holding image: Data, as name: String) throws -> (BiosLibrary, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bios-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    try image.write(to: dir.appendingPathComponent(name))
    let library = BiosLibrary()
    try library.setFolder(dir)
    return (library, dir)
}

/// Rename the file and it still works: the bytes say which model it is, so the
/// filename never has to.
@Test func aRenamedBiosIsStillFoundByItsHash() throws {
    guard let eu = repoBIOSImage("SCPH-7502_BIOS_1997_EU.bin") else { return }

    let (library, dir) = try library(holding: eu, as: "bios.bin")
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(try library.biosData(forDisc: "Rayman (Europe).cue") == eu)
}

/// A misnamed image is the failure the filename rule cannot see: handed to a
/// disc of the wrong region it stops at the region-lock screen, which reads as
/// a core bug. The bytes outrank the name here too.
@Test func aFileNamedForOneRegionButHoldingAnotherIsNotUsed() throws {
    guard let eu = repoBIOSImage("SCPH-7502_BIOS_1997_EU.bin") else { return }

    let (library, dir) = try library(holding: eu, as: "SCPH-1001_BIOS_1995_US.bin")
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: (any Error).self) {
        _ = try library.biosData(forDisc: "Silent Hill (USA).cue")
    }
}

/// The table is curated, so an image it does not list must still be reachable
/// by the old filename rule rather than rejected.
@Test func anUnidentifiedImageIsStillFoundByItsFilename() throws {
    let unlisted = Data(repeating: 0, count: 524288)

    let (library, dir) = try library(holding: unlisted, as: "SCPH-1001_BIOS_1995_US.bin")
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(try library.biosData(forDisc: "Silent Hill (USA).cue") == unlisted)
}
