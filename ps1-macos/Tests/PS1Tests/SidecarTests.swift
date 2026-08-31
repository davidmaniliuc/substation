import Testing
import Foundation
@testable import PS1

/// Writes a disc's files into a throwaway directory and hands back the URL of
/// the one that would be opened. `sbi` is written only when non-nil, because a
/// disc with no sidecar is the ordinary case, not an error case.
private func makeDisc(named name: String, sbi: Data?) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let disc = root.appendingPathComponent(name)
    try Data(repeating: 0, count: 2352).write(to: disc)
    if let sbi {
        let stem = disc.deletingPathExtension().lastPathComponent
        try sbi.write(to: root.appendingPathComponent("\(stem).sbi"))
    }
    return disc
}

/// The first record of Final Fantasy IX (France) disc 1's `.sbi`.
private let ff9Sbi = Data([0x53, 0x42, 0x49, 0x00,
                           0x03, 0x08, 0x05, 0x01, 0x41, 0x01, 0x01,
                           0x07, 0x06, 0x05, 0x00, 0x23, 0x08, 0x05])

@MainActor
@Test func aSidecarSittingNextToTheCueIsFound() throws {
    let cue = try makeDisc(named: "Final Fantasy IX (France) (Disc 1).cue", sbi: ff9Sbi)
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    #expect(EmulatorViewModel.sidecar(forDisc: cue) == ff9Sbi)
}

@MainActor
@Test func aSidecarIsFoundForARawBinToo() throws {
    let bin = try makeDisc(named: "Final Fantasy IX (France) (Disc 1).bin", sbi: ff9Sbi)
    defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

    #expect(EmulatorViewModel.sidecar(forDisc: bin) == ff9Sbi)
}

/// The overwhelming majority of discs are unprotected, so a missing sidecar is
/// the normal case and must read as "none", never as a failure to load.
@MainActor
@Test func aDiscWithNoSidecarReportsNone() throws {
    let cue = try makeDisc(named: "Croc.cue", sbi: nil)
    defer { try? FileManager.default.removeItem(at: cue.deletingLastPathComponent()) }

    #expect(EmulatorViewModel.sidecar(forDisc: cue) == nil)
}

/// FF9's four discs share a directory, and each has its own sidecar naming
/// sectors of its own image. Picking the wrong one leaves the game looping on
/// its check exactly as if none had been supplied, so the match is on the
/// disc's own stem and nothing else.
@MainActor
@Test func aSiblingDiscsSidecarIsNotUsed() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let disc1 = root.appendingPathComponent("Final Fantasy IX (France) (Disc 1).cue")
    try Data(repeating: 0, count: 2352).write(to: disc1)
    try ff9Sbi.write(to: root.appendingPathComponent("Final Fantasy IX (France) (Disc 2).sbi"))

    #expect(EmulatorViewModel.sidecar(forDisc: disc1) == nil)
}

@Test func loadDiscAcceptsASidecar() throws {
    let core = try Ps1Core()
    try core.loadDisc(bin: Data(repeating: 0, count: 2352), cue: nil, sbi: ff9Sbi)
}

/// A corrupt sidecar must not be dropped in silence: without it the game hangs
/// on a black screen, and the player needs to be told why.
@Test func loadDiscRejectsASidecarWithoutTheMagic() throws {
    let core = try Ps1Core()
    #expect(throws: Ps1Error.badSBI) {
        try core.loadDisc(bin: Data(repeating: 0, count: 2352),
                          cue: nil,
                          sbi: Data("NOTSBI\0\0".utf8) + ff9Sbi.dropFirst(4))
    }
}
