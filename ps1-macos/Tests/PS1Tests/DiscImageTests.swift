import Testing
import Foundation
@testable import PS1

/// Writes a cue and the images it names into a throwaway directory, and hands
/// back the cue's URL. Each image is filled with a distinct byte so the order
/// the concatenation put them in is readable from the result.
private func makeRip(cue: String, images: [(name: String, sectors: Int, fill: UInt8)]) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("rip-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for image in images {
        try Data(repeating: image.fill, count: image.sectors * 2352)
            .write(to: root.appendingPathComponent(image.name))
    }
    let url = root.appendingPathComponent("game.cue")
    try Data(cue.utf8).write(to: url)
    return url
}

private let singleFileCue = """
FILE "game.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
"""

/// A per-track rip, the shape Tekken 3, Castlevania and Rayman ship in.
private let perTrackCue = """
FILE "t1.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
FILE "t2.bin" BINARY
  TRACK 02 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
"""

@MainActor
@Test func aSingleFileCueIsReadWhole() throws {
    let cue = try makeRip(cue: singleFileCue,
                          images: [("game.bin", 8, 0xAA)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    let image = try EmulatorViewModel.discImage(forCue: cue)

    #expect(image.bin.count == 8 * 2352)
    #expect(image.bin.allSatisfy { $0 == 0xAA })
}

@MainActor
@Test func aPerTrackRipIsConcatenatedInCueOrder() throws {
    let cue = try makeRip(cue: perTrackCue,
                          images: [("t1.bin", 100, 0x11), ("t2.bin", 50, 0x22)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    let image = try EmulatorViewModel.discImage(forCue: cue)

    #expect(image.bin.count == 150 * 2352)
    #expect(image.bin[0] == 0x11)
    #expect(image.bin[100 * 2352 - 1] == 0x11)
    #expect(image.bin[100 * 2352] == 0x22)
}

/// The sizes are the only record of where the images were joined, so they have
/// to reach the core — and BEFORE the FILE they measure, which is the end
/// `initFromCue` consumes them from.
@MainActor
@Test func eachFileIsPrecededByItsSize() throws {
    let cue = try makeRip(cue: perTrackCue,
                          images: [("t1.bin", 100, 0x11), ("t2.bin", 50, 0x22)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    let text = String(decoding: try EmulatorViewModel.discImage(forCue: cue).cue, as: UTF8.self)
    let lines = text.split(separator: "\n").map(String.init)

    #expect(lines.first == "REM FILESIZE \(100 * 2352)")
    let secondFile = try #require(lines.firstIndex(where: { $0.hasPrefix("FILE \"t2.bin\"") }))
    #expect(lines[secondFile - 1] == "REM FILESIZE \(50 * 2352)")
}

/// The end-to-end shape of the bug this pair exists for: before the images
/// were concatenated the core saw one track's bytes under a two-FILE cue and
/// refused it outright.
@MainActor
@Test func aPerTrackRipLoadsAndPlacesItsSecondTrack() throws {
    let cue = try makeRip(cue: perTrackCue,
                          images: [("t1.bin", 100, 0x11), ("t2.bin", 50, 0x22)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    let image = try EmulatorViewModel.discImage(forCue: cue)
    let core = try Ps1Core()
    try core.loadDisc(bin: image.bin, cue: image.cue, sbi: nil)
}

@MainActor
@Test func aCueNamingAMissingImageFails() throws {
    let cue = try makeRip(cue: perTrackCue, images: [("t1.bin", 100, 0x11)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    #expect(throws: (any Error).self) {
        _ = try EmulatorViewModel.discImage(forCue: cue)
    }
}

/// EVERY cue a ripper writes is CRLF, and Swift folds "\r\n" into one Character
/// that does not equal "\n" — so a split on the scalar returns the whole sheet
/// as a single line, and the FILE match then reads from the first quote in the
/// file to the last. A one-FILE cue holds exactly two quotes and survives that
/// by accident, which is why only per-track rips ever showed the symptom.
@MainActor
@Test func aCrlfPerTrackRipIsSplitPerLine() throws {
    let cue = try makeRip(cue: perTrackCue.replacingOccurrences(of: "\n", with: "\r\n"),
                          images: [("t1.bin", 100, 0x11), ("t2.bin", 50, 0x22)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    let image = try EmulatorViewModel.discImage(forCue: cue)

    #expect(image.bin.count == 150 * 2352)
    #expect(image.bin[100 * 2352] == 0x22)
}

/// The half of the CRLF bug that predates the concatenation: with the sheet
/// unsplit, `lastIndex(of:)` reached past the first FILE's closing quote and
/// named a file that does not exist.
@MainActor
@Test func aCrlfCueNamesEachImageAndNotTheSpanBetweenThem() throws {
    let cue = try makeRip(cue: perTrackCue.replacingOccurrences(of: "\n", with: "\r\n"),
                          images: [("t1.bin", 100, 0x11), ("t2.bin", 50, 0x22)])
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    let text = String(decoding: try EmulatorViewModel.discImage(forCue: cue).cue, as: UTF8.self)

    #expect(text.contains("REM FILESIZE \(100 * 2352)"))
    #expect(text.contains("REM FILESIZE \(50 * 2352)"))
}
