import Testing
import Foundation
@testable import PS1

@Test func createAndDestroy() throws {
    let core = try Ps1Core()
    _ = core
}

@Test func rejectsWrongBIOSSize() throws {
    let core = try Ps1Core()
    #expect(throws: Ps1Error.badBIOSSize) {
        try core.loadBIOS(Data(repeating: 0, count: 16))
    }
}

@Test func acceptsCorrectBIOSSize() throws {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
}

/// A multi-FILE cue with no sizes cannot be laid out — the images were joined
/// somewhere the cue no longer records, so every FILE would stack at LBA 0.
@Test func rejectsMultiFileCueWithoutSizes() throws {
    let core = try Ps1Core()
    let cue = """
    FILE "a.bin" BINARY
      TRACK 01 MODE2/2352
        INDEX 01 00:00:00
    FILE "b.bin" BINARY
      TRACK 02 AUDIO
        INDEX 01 00:00:00
    """
    #expect(throws: Ps1Error.multiFileCue) {
        try core.loadDisc(bin: Data(repeating: 0, count: 2352),
                          cue: Data(cue.utf8), sbi: nil)
    }
}

/// With the sizes present the same shape of cue is accepted: that is the whole
/// difference between a per-track rip the app can boot and one it cannot.
@Test func acceptsMultiFileCueCarryingItsSizes() throws {
    let core = try Ps1Core()
    let cue = """
    REM FILESIZE 235200
    FILE "a.bin" BINARY
      TRACK 01 MODE2/2352
        INDEX 01 00:00:00
    REM FILESIZE 117600
    FILE "b.bin" BINARY
      TRACK 02 AUDIO
        INDEX 01 00:02:00
    """
    try core.loadDisc(bin: Data(repeating: 0, count: 150 * 2352), cue: Data(cue.utf8), sbi: nil)
}

@Test func displayReportsProgrammedArea() throws {
    let core = try Ps1Core()
    let d = core.display()
    // A freshly constructed core reports a 256x240 NTSC area — measured
    // against the real core while planning, not assumed.
    #expect(d.width == 256)
    #expect(d.height == 240)
    #expect(d.pal == 0)
}

@Test func readAudioIsEmptyOnAFreshCore() throws {
    let core = try Ps1Core()
    var buf = [Float](repeating: 0, count: 64)
    let n = buf.withUnsafeMutableBufferPointer { core.readAudio(into: $0.baseAddress!, maxFloats: $0.count) }
    #expect(n == 0)
}
