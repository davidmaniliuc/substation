import Testing
import Foundation
@testable import PS1

/// The repo's BIOS images are gitignored, so a machine without them skips
/// rather than fails — the same convention the fixture gates use.
func repoBIOSImage(_ name: String) -> Data? {
    try? Data(contentsOf: FixtureFile.repoURL.appendingPathComponent(name))
}

@Test func aListedImageIdentifiesItselfFromItsBytes() throws {
    guard let data = repoBIOSImage("SCPH-1001_BIOS_1995_US.bin") else { return }

    let image = try #require(BiosIdentity.identify(data))
    #expect(image.model == "SCPH-1001")
    #expect(image.region == .us)
    #expect(image.revision == "v2.2 12-04-95 A")
}

/// Every image in the folder, so a table entry that names the wrong region or
/// model is caught here rather than at the region-lock screen.
@Test func everyBiosInTheRepoIdentifiesAsItsFilenameClaims() throws {
    let expected: [(String, String, BiosRegion)] = [
        ("SCPH-1000_BIOS_1994_JP.bin", "SCPH-1000", .japan),
        ("SCPH-1001_BIOS_1995_US.bin", "SCPH-1001", .us),
        ("SCPH-101_BIOS_2000_US.bin",  "SCPH-101",  .us),
        ("SCPH-3000_BIOS_1995_JP.bin", "SCPH-3000", .japan),
        ("SCPH-7502_BIOS_1997_EU.bin", "SCPH-7502", .europe),
    ]
    for (name, model, region) in expected {
        guard let data = repoBIOSImage(name) else { continue }
        let image = try #require(BiosIdentity.identify(data), "\(name) identifies as nothing")
        #expect(image.model == model, "\(name)")
        #expect(image.region == region, "\(name)")
    }
}

/// The table is curated: it knows the images someone put in it and nothing
/// else. An unlisted dump is UNIDENTIFIED, never rejected — the caller falls
/// back to the filename rule for it.
@Test func anUnlistedImageIdentifiesAsNothing() {
    #expect(BiosIdentity.identify(Data(repeating: 0, count: 524288)) == nil)
}

/// The whole point of hashing over a size check: a 512 KB file of the right
/// length is not evidence of anything.
@Test func oneCorruptedByteStopsAListedImageIdentifying() throws {
    guard var data = repoBIOSImage("SCPH-1001_BIOS_1995_US.bin") else { return }
    #expect(BiosIdentity.identify(data) != nil)

    data[0x1000] ^= 0xFF
    #expect(BiosIdentity.identify(data) == nil)
}
