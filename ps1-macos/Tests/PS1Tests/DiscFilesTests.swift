import Testing
import Foundation
@testable import PS1

/// A throwaway folder holding `files`, each name to its bytes.
private func makeFolder(_ files: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("discfiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, data) in files { try data.write(to: root.appendingPathComponent(name)) }
    return root
}

private let sbi = Data("SBI\0".utf8) + Data([0x03, 0x08, 0x05, 0x01])

/// A CloneCD set hands the core its sheet, its `.img` and its raw `.sub`.
@Test func aCloneCDSetPassesItsImageSheetAndSubchannel() throws {
    let sheet = Data("[CloneCD]\r\nVersion=3\r\n".utf8)
    let img = Data(repeating: 1, count: 2352)
    let sub = Data(repeating: 2, count: 96)
    let root = try makeFolder(["b.ccd": sheet, "b.img": img, "b.sub": sub, "b.sbi": sbi])
    defer { try? FileManager.default.removeItem(at: root) }

    let disc = try DiscFiles.read(root.appendingPathComponent("b.ccd"))

    #expect(disc.bin == img)
    #expect(disc.cue == sheet)
    #expect(disc.sbi == sub)
}

/// With no `.sub`, a CloneCD set still takes an `.sbi` of its stem.
@Test func aCloneCDSetFallsBackToAnSbi() throws {
    let root = try makeFolder(["b.ccd": Data("[CloneCD]\n".utf8),
                               "b.img": Data(repeating: 1, count: 2352), "b.sbi": sbi])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try DiscFiles.read(root.appendingPathComponent("b.ccd")).sbi == sbi)
}

@Test func aCloneCDSheetWithoutItsImageThrows() throws {
    let root = try makeFolder(["b.ccd": Data("[CloneCD]\n".utf8)])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try DiscFiles.read(root.appendingPathComponent("b.ccd")) }
}

/// `c.bin.ecm` is `c.bin` compressed: its sidecar is the `.bin`'s.
@Test func anEcmFindsTheSidecarOfTheImageItHolds() throws {
    let ecm = Data("ECM\0".utf8) + Data(repeating: 0, count: 64)
    let root = try makeFolder(["c.bin.ecm": ecm, "c.bin.sbi": sbi, "c.sbi": Data("SBI\0".utf8)])
    defer { try? FileManager.default.removeItem(at: root) }

    let disc = try DiscFiles.read(root.appendingPathComponent("c.bin.ecm"))

    #expect(disc.bin == ecm)
    #expect(disc.cue == nil)
    #expect(disc.sbi == sbi)
}

@Test func anEcmFallsBackToTheBareStemsSidecar() throws {
    let root = try makeFolder(["c.bin.ecm": Data("ECM\0".utf8), "c.sbi": sbi,
                               "c.ppf": Data("PPF".utf8)])
    defer { try? FileManager.default.removeItem(at: root) }
    let disc = try DiscFiles.read(root.appendingPathComponent("c.bin.ecm"))
    #expect(disc.sbi == sbi)
    #expect(disc.ppf == Data("PPF".utf8))
}

/// A cue whose one FILE is an `.ecm` passes the ECM bytes as they are:
/// the core decodes them, and the sheet goes over untouched.
@Test func aCueNamingAnEcmPassesItUnchanged() throws {
    let ecm = Data("ECM\0".utf8) + Data(repeating: 7, count: 32)
    let sheet = Data("FILE \"e.bin.ecm\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n".utf8)
    let root = try makeFolder(["e.cue": sheet, "e.bin.ecm": ecm])
    defer { try? FileManager.default.removeItem(at: root) }

    let disc = try DiscFiles.read(root.appendingPathComponent("e.cue"))

    #expect(disc.bin == ecm)
    #expect(disc.cue == sheet)
}

/// The core holds one source, so an ECM cannot be one FILE of several.
@Test func aCueWithAnEcmAmongSeveralFilesIsRefused() throws {
    let sheet = Data("""
        FILE "t1.bin.ecm" BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00
        FILE "t2.bin" BINARY
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        """.utf8)
    let root = try makeFolder(["s.cue": sheet, "t1.bin.ecm": Data("ECM\0".utf8),
                               "t2.bin": Data(repeating: 0, count: 2352)])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: Ps1Error.badCue) { try DiscFiles.read(root.appendingPathComponent("s.cue")) }
}

/// A plain cue still concatenates its FILEs with the seams written in.
@Test func aPlainCueStillLaysOutItsFiles() throws {
    let sheet = Data("FILE \"a.bin\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n".utf8)
    let bin = Data(repeating: 3, count: 2352)
    let root = try makeFolder(["a.cue": sheet, "a.bin": bin, "a.sbi": sbi])
    defer { try? FileManager.default.removeItem(at: root) }

    let disc = try DiscFiles.read(root.appendingPathComponent("a.cue"))

    #expect(disc.bin == bin)
    #expect(String(decoding: disc.cue ?? Data(), as: UTF8.self).hasPrefix("REM FILESIZE 2352\n"))
    #expect(disc.sbi == sbi)
}

@Test func aLoneIsoIsPassedWithNoSheet() throws {
    let iso = Data(repeating: 4, count: 2048 * 4)
    let root = try makeFolder(["d.iso": iso])
    defer { try? FileManager.default.removeItem(at: root) }
    let disc = try DiscFiles.read(root.appendingPathComponent("d.iso"))
    #expect(disc.bin == iso)
    #expect(disc.cue == nil)
    #expect(disc.sbi == nil)
}

/// The two image codes reach the player as their own words, never as
/// "unknown(-28)".
@MainActor @Test func theImageCodesMapAndAreDescribed() {
    #expect(Ps1Error.from(-28) == .badECM)
    #expect(Ps1Error.from(-29) == .badCCD)
    for error in [Ps1Error.badECM, .badCCD] {
        #expect(!EmulatorViewModel.describe(error).contains("Ps1Error"))
    }
}

/// Only a lone raw image loses its audio tracks; an `.iso` has none.
@MainActor @Test func onlyALoneBinOrImgWarnsOfSilentAudio() {
    let warns = ["a.bin", "a.IMG", "a.iso", "a.cue", "a.ccd", "a.chd", "a.bin.ecm"].filter {
        EmulatorViewModel.warnsOfSilentAudio(URL(fileURLWithPath: "/g/\($0)"))
    }
    #expect(warns == ["a.bin", "a.IMG"])
}

/// A playlist is not a disc: it names discs.
@Test func aPlaylistIsNotReadAsADisc() throws {
    let root = try makeFolder(["g.m3u": Data("a.cue\n".utf8)])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try DiscFiles.read(root.appendingPathComponent("g.m3u")) }
}

/// A CloneCD set is identified by the image it controls, never by the
/// sheet's own bytes: with the `.img` missing there is nothing to read.
@Test func aCloneCDSetIdentifiesItsImage() throws {
    let root = try makeFolder(["b.ccd": Data(repeating: 0x41, count: 2352 * 20)])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DiscIdentity.identify(disc: root.appendingPathComponent("b.ccd")) == nil)
}

/// An Alcohol set hands the core its sheet over the `.mdf` of its stem.
@Test func anAlcoholSetPassesItsImageAndSheet() throws {
    let sheet = Data("MEDIA DESCRIPTOR".utf8)
    let mdf = Data(repeating: 3, count: 2352)
    let root = try makeFolder(["y.mds": sheet, "y.mdf": mdf, "y.sbi": sbi, "y.ppf": Data("PPF30".utf8)])
    defer { try? FileManager.default.removeItem(at: root) }

    let disc = try DiscFiles.read(root.appendingPathComponent("y.mds"))

    #expect(disc.bin == mdf)
    #expect(disc.cue == sheet)
    #expect(disc.sbi == sbi)
    #expect(disc.ppf == Data("PPF30".utf8))
    #expect(disc.disc == 0)
}

@Test func anAlcoholSheetWithoutItsImageThrows() throws {
    let root = try makeFolder(["y.mds": Data("MEDIA DESCRIPTOR".utf8)])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try DiscFiles.read(root.appendingPathComponent("y.mds")) }
}

/// A patch applies to an eboot's first disc only.
@Test func anEbootsPatchAppliesToDiscZeroOnly() throws {
    let eboot = Data(repeating: 4, count: 64)
    let ppf = Data("PPF30".utf8)
    let root = try makeFolder(["x.pbp": eboot, "x.ppf": ppf, "x.sbi": sbi])
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("x.pbp")

    let first = try DiscFiles.read(url)
    #expect(first.bin == eboot)
    #expect(first.cue == nil)
    #expect(first.ppf == ppf)
    #expect(first.disc == 0)

    let second = try DiscFiles.read(url, disc: 1)
    #expect(second.ppf == nil)
    #expect(second.sbi == sbi)
    #expect(second.disc == 1)
}
