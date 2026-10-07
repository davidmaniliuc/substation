import CPs1
import Foundation

/// What a BIOS image says about itself, read from its BYTES rather than from
/// its filename.
struct BiosImage: Equatable {
    /// Every model the image shipped in, aliases expanded: the v4.1 PAL dump
    /// is SCPH-7002, SCPH-7502 and SCPH-9002 alike. Selection asks whether the
    /// region's preferred model (`BiosRegion.rawValue`) is among them, never
    /// whether it is the first: that one is SCPH-7002 here.
    let models: [String]
    /// "SCPH-7002, 7502, 9002 (v4.1 12-16-97 E)", as DuckStation names it.
    let description: String
    let region: BiosRegion
}

/// Identifies a BIOS image by content hash, through the core's table: the 24
/// PS1 images DuckStation knows (`ps1-core/src/bios.zig`, generated from its
/// 0BSD `bios.cpp`), so every retail revision and the DTL units.
///
/// It replaces two weak checks at once: the `hasPrefix("scph-1001")` filename
/// match, which a rename defeats and a MISNAMED file defeats worse, and the
/// bare 512 KB size test, which any corrupt file of the right length passes.
/// An image the table cannot name is UNIDENTIFIED, never rejected:
/// `BiosLibrary` falls back to the filename rule for it.
enum BiosIdentity {
    /// Every PS1 BIOS image is exactly this long. A file of any other length is
    /// not a candidate and is never hashed.
    static let byteCount = 524288

    /// nil means "not in the core's table": unidentified, not invalid.
    static func identify(_ data: Data) -> BiosImage? {
        var raw = Ps1BiosId()
        let found = data.withUnsafeBytes { bytes in
            ps1_identify_bios(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &raw)
        }
        guard found != 0,
              let models = cString(&raw.models),
              let description = cString(&raw.description),
              let region = DiscIdentity.Region(raw.region)
        else { return nil }
        return BiosImage(models: models.split(separator: ",").map(String.init),
                         description: description,
                         region: BiosRegion(region))
    }
}
