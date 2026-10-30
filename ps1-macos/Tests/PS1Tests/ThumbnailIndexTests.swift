import Foundation
import Testing
@testable import PS1

struct ThumbnailIndexTests {
    private func disc(_ path: String) -> GameEntry {
        GameEntry(url: URL(fileURLWithPath: path), identity: DiscIdentity(region: nil, serial: nil, volumeID: nil))
    }

    @Test func aDiscShowsItsOwnCoverElseItsGames() {
        let one = disc("/games/FF/Disc 1.cue"), two = disc("/games/FF/Disc 2.cue")
        let covers = [one.url: URL(fileURLWithPath: "/covers/one.png")]
        let index = ThumbnailIndex.make([GameGroup(title: "FF", discs: [one, two])]) { covers[$0.url] }
        #expect(index == ["/games/FF/Disc 1.cue": "/covers/one.png",
                          "/games/FF/Disc 2.cue": "/covers/one.png"])
    }

    @Test func aDiscWithNoCoverAndABinAreLeftOut() {
        let bin = disc("/games/a.bin"), bare = disc("/games/b.chd")
        let index = ThumbnailIndex.make([GameGroup(title: "A", discs: [bin]),
                                         GameGroup(title: "B", discs: [bare])]) { entry in
            entry.url == bin.url ? URL(fileURLWithPath: "/covers/a.png") : nil
        }
        #expect(index.isEmpty)
    }

    @Test func theIndexRoundTripsAsJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ThumbnailIndex.write(["/a.cue": "/a.png"], to: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("index.json"))
        #expect(try JSONDecoder().decode([String: String].self, from: data) == ["/a.cue": "/a.png"])
    }
}
