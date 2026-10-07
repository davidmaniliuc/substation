import Testing
import Foundation
@testable import PS1

private func disc(_ path: String, _ serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

private func makeStore() -> ResumeStateStore {
    ResumeStateStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("offer-\(UUID().uuidString)"))
}

/// A real state with no disc (empty serial), from a BIOS of zeros.
private func biosOnlyState() throws -> Data {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    return try core.saveState()
}

@Test func noStateMeansNoOffer() {
    let d1 = disc("/g/Game (Disc 1).cue", "SCUS-1")
    #expect(ResumeOffer.make(launching: d1, siblings: [d1], store: makeStore()) == nil)
}

@Test func theOfferIsKeyedOnTheFirstDiscWhicheverDiscIsLaunched() throws {
    let d1 = disc("/g/Game (Disc 1).cue", "SCUS-1")
    let d2 = disc("/g/Game (Disc 2).cue", "SCUS-2")
    let store = makeStore()
    try store.save(state: try biosOnlyState(), thumbnail: nil, key: "SCUS-1")
    let offer = try #require(ResumeOffer.make(launching: d2, siblings: [d1, d2], store: store))
    #expect(offer.key == "SCUS-1")
    #expect(offer.launching == d2)
}

@Test func theResumeDiscIsTheOneWhoseSerialTheStateNames() {
    let d1 = disc("/g/Game (Disc 1).cue", "SCUS-1")
    let d2 = disc("/g/Game (Disc 2).cue", "SCUS-2")
    #expect(ResumeOffer.disc(forSerial: "SCUS-2", in: [d1, d2]) == d2)
    // A state for a disc that names no serial resumes on the first disc.
    #expect(ResumeOffer.disc(forSerial: nil, in: [d1, d2]) == d1)
    // A disc that is no longer in the library cannot be resumed.
    #expect(ResumeOffer.disc(forSerial: "SCUS-3", in: [d1, d2]) == nil)
}

@Test func aDamagedStateStillProducesAnOffer() throws {
    // So Delete & Boot stays reachable; Resume then explains the damage.
    let d1 = disc("/g/Game.cue", "SLUS-9")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offer-\(UUID().uuidString)")
    let store = ResumeStateStore(directory: dir)
    try store.save(state: Data([1]), thumbnail: nil, key: "SLUS-9")
    try Data("garbage".utf8).write(to: dir.appendingPathComponent("SLUS-9.state"))
    let offer = try #require(ResumeOffer.make(launching: d1, siblings: [d1], store: store))
    #expect(offer.resumeDisc == d1)
}
