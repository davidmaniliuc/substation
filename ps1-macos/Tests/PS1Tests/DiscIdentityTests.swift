import Testing
import Foundation
@testable import PS1

/// The licence area exactly as it sits on a real rip. The padding lands inside
/// the words, which is what defeats a literal comparison.
private let licenseAmerica =
    "          Licensed  by          Sony Computer Entertainment Amer  ica "
private let licenseEurope =
    "          Licensed  by          Sony Computer Entertainment Euro pe   "

private let sectorBytes = 2352
private let rootDirLBA = 22
private let systemCnfLBA = 30

/// A disc image with the layout every rip has: licence area at LBA 4, primary
/// volume descriptor at 16, its root directory past that, SYSTEM.CNF past
/// that. Mode 2, so its user data starts at 018h.
private func makeImage(
    license: String = licenseAmerica,
    volumeID: String = "CROC",
    systemCnf: String? = "BOOT = cdrom:\\SLUS_005.30;1\r\nTCB = 4\r\n"
) -> Data {
    var image = Data(repeating: 0, count: sectorBytes * 40)

    func writeSector(_ lba: Int, _ payload: Data) {
        let base = lba * sectorBytes
        image[base + 15] = 0x02
        image.replaceSubrange((base + 24)..<(base + 24 + payload.count), with: payload)
    }

    func directoryRecord(extent: UInt32, length: Int, name: String) -> Data {
        let nameBytes = Array(name.utf8)
        var record = Data(repeating: 0, count: 33 + nameBytes.count + (nameBytes.count + 1) % 2)
        record[0] = UInt8(record.count)
        withUnsafeBytes(of: extent.littleEndian) { record.replaceSubrange(2..<6, with: $0) }
        withUnsafeBytes(of: UInt32(length).littleEndian) {
            record.replaceSubrange(10..<14, with: $0)
        }
        record[32] = UInt8(nameBytes.count)
        record.replaceSubrange(33..<(33 + nameBytes.count), with: nameBytes)
        return record
    }

    writeSector(4, Data(license.utf8))

    guard let systemCnf else { return image }

    var pvd = Data(repeating: 0, count: 2048)
    pvd[0] = 1
    pvd.replaceSubrange(1..<6, with: Data("CD001".utf8))
    pvd.replaceSubrange(40..<72, with: Data(repeating: 0x20, count: 32))
    pvd.replaceSubrange(40..<(40 + volumeID.utf8.count), with: Data(volumeID.utf8))
    let root = directoryRecord(extent: UInt32(rootDirLBA), length: 2048, name: "\0")
    pvd.replaceSubrange(156..<(156 + root.count), with: root)
    writeSector(16, pvd)

    var directory = Data()
    directory += root
    directory += directoryRecord(extent: UInt32(rootDirLBA), length: 2048, name: "\u{01}")
    directory += directoryRecord(extent: UInt32(systemCnfLBA),
                                 length: systemCnf.utf8.count, name: "SYSTEM.CNF;1")
    writeSector(rootDirLBA, directory)
    writeSector(systemCnfLBA, Data(systemCnf.utf8))

    return image
}

@Test func aDiscNamesItsOwnRegionSerialAndVolume() {
    let id = DiscIdentity.identify(image: makeImage())
    #expect(id.region == .america)
    #expect(id.serial == "SLUS-00530")
    #expect(id.volumeID == "CROC")
}

/// The reason the matcher strips whitespace instead of comparing literals the
/// way DuckStation does: three spellings are in circulation and the padding
/// falls inside the words.
@Test func theLicenceRegionSurvivesItsOwnPadding() {
    #expect(DiscIdentity.identify(image: makeImage(license: licenseEurope)).region == .europe)
    #expect(DiscIdentity.identify(image: makeImage(
        license: "          Licensed  by          Sony Computer Entertainment(Europe)"
    )).region == .europe)
    #expect(DiscIdentity.identify(image: makeImage(
        license: "          Licensed  by          Sony Computer Entertainment of America"
    )).region == .america)
}

@Test func aDiscThatAnswersNothingIsUnknownRatherThanGuessed() {
    let id = DiscIdentity.identify(image: Data(repeating: 0, count: sectorBytes * 8))
    #expect(id == .unknown)
    #expect(id.isEmpty)
}

@Test func anImageTooSmallToHoldASectorIsNotIdentified() {
    #expect(DiscIdentity.identify(image: Data(repeating: 0, count: 16)) == .unknown)
}

/// The serial is the fallback signal, and it is the one that saves a disc
/// whose licence area is not one of the known spellings.
@Test func theSerialNamesTheRegionWhenTheLicenceDoesNot() {
    let id = DiscIdentity.identify(image: makeImage(
        license: "scrambled",
        systemCnf: "BOOT=cdrom:\\SLES_029.66;1\r\n"))
    #expect(id.region == .europe)
    #expect(id.serial == "SLES-02966")
}

@Test func aDiscWithNoFilesystemStillReportsItsLicence() {
    let id = DiscIdentity.identify(image: makeImage(license: licenseEurope, systemCnf: nil))
    #expect(id.region == .europe)
    #expect(id.serial == nil)
    #expect(id.volumeID == nil)
}

/// A cue names the image holding track 1, and only track 1 carries a
/// filesystem. A per-track rip that identified off the cue itself — or off
/// track 2 — would find nothing.
@Test func aCueIsIdentifiedThroughTheImageItNames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cue-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bin = directory.appendingPathComponent("Game (Track 1).bin")
    try makeImage().write(to: bin)
    let cue = directory.appendingPathComponent("Game.cue")
    // CRLF, as every ripper writes it.
    try Data("""
    FILE "Game (Track 1).bin" BINARY\r
      TRACK 01 MODE2/2352\r
        INDEX 01 00:00:00\r
    FILE "Game (Track 2).bin" BINARY\r
      TRACK 02 AUDIO\r
        INDEX 01 00:00:00\r
    """.utf8).write(to: cue)

    #expect(DiscIdentity.identify(disc: cue)?.serial == "SLUS-00530")
}

@Test func aBareBinIsIdentifiedDirectly() throws {
    let bin = FileManager.default.temporaryDirectory
        .appendingPathComponent("bare-\(UUID().uuidString).bin")
    try makeImage().write(to: bin)
    defer { try? FileManager.default.removeItem(at: bin) }

    #expect(DiscIdentity.identify(disc: bin)?.serial == "SLUS-00530")
}

@Test func aDiscThatCannotBeReadIsNil() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("nothing-\(UUID().uuidString).bin")
    #expect(DiscIdentity.identify(disc: missing) == nil)
}

@Test func theFirstImageIsFoundThroughACRLFSheet() {
    let text = "REM COMMENT\r\nFILE \"A.bin\" BINARY\r\n  TRACK 01 MODE2/2352\r\n"
    #expect(CueSheet.firstImageName(in: text) == "A.bin")
}
