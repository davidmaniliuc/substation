import Testing
import Foundation
@testable import PS1

@Test func discKindReadsTheExtensionCaseInsensitively() {
    #expect(DiscKind(URL(fileURLWithPath: "/g/Croc.cue")) == .cue)
    #expect(DiscKind(URL(fileURLWithPath: "/g/Croc.CUE")) == .cue)
    #expect(DiscKind(URL(fileURLWithPath: "/g/GTA.chd")) == .chd)
    #expect(DiscKind(URL(fileURLWithPath: "/g/GTA.CHD")) == .chd)
    #expect(DiscKind(URL(fileURLWithPath: "/g/Loose.bin")) == .bin)
}

/// A converted copy resumes the original's state: both identify to one
/// serial, and the store keys on the serial.
@Test func aCueAndItsChdShareOneResumeKey() {
    let identity = DiscIdentity(region: .america, serial: "SLUS-00530",
                                volumeID: nil, gameTitle: nil, discNumber: nil)
    let cue = GameEntry(url: URL(fileURLWithPath: "/g/Croc/Croc.cue"), identity: identity)
    let chd = GameEntry(url: URL(fileURLWithPath: "/elsewhere/Croc.chd"), identity: identity)
    #expect(SaveStateStore.key(for: cue) == SaveStateStore.key(for: chd))
}

@MainActor @Test func aChdFindsTheSidecarBesideIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("SBI\0".utf8).write(to: dir.appendingPathComponent("FF9.sbi"))
    #expect(EmulatorViewModel.sidecar(forDisc: dir.appendingPathComponent("FF9.chd")) != nil)
}
