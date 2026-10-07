import CPs1
import Foundation

/// What a BIOS image says about itself, read from its BYTES rather than from
/// its filename.
struct BiosImage: Equatable {
    /// The single model stem selection matches on; `BiosRegion.rawValue`.
    /// Sony shipped several models per image (the v1.0 dump is SCPH-1000 and
    /// DTL-H1000; the v4.1 PAL dump is SCPH-7002, 7502 and 9002 alike), and
    /// the aliases are recorded in the table's comments rather than here,
    /// because a set would have to be searched where a stem is compared.
    let model: String
    let revision: String
    let region: BiosRegion
}

/// Identifies a BIOS image by content hash, through the core's curated table
/// (`ps1-core/src/bios.zig`, which documents where every row came from).
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
              let model = cString(&raw.model),
              let revision = cString(&raw.revision),
              let region = DiscIdentity.Region(raw.region)
        else { return nil }
        return BiosImage(model: model, revision: revision, region: BiosRegion(region))
    }
}
