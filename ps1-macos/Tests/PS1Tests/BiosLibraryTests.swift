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
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bios-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try Data(repeating: 0, count: 524288)
        .write(to: dir.appendingPathComponent("SCPH-101_BIOS_2000_US.bin"))

    let library = BiosLibrary()
    library.setFolder(dir)

    #expect(throws: (any Error).self) {
        _ = try library.biosData(forDisc: "Silent Hill (USA).cue")
    }
}
