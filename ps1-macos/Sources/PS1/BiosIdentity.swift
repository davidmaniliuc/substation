import CryptoKit
import Foundation

/// What a BIOS image says about itself, read from its BYTES rather than from
/// its filename.
struct BiosImage: Equatable {
    /// The single model stem selection matches on — `BiosRegion.rawValue`.
    /// Sony shipped several models per image (the v1.0 dump is SCPH-1000 and
    /// DTL-H1000; the v4.1 PAL dump is SCPH-7002, 7502 and 9002 alike), and
    /// the aliases are recorded in the table's comments rather than here,
    /// because a set would have to be searched where a stem is compared.
    let model: String
    let revision: String
    let region: BiosRegion
}

/// Identifies a BIOS image by content hash.
///
/// It replaces two weak checks at once: the `hasPrefix("scph-1001")` filename
/// match, which a rename defeats and a MISNAMED file defeats worse — an EU
/// image called `SCPH-1001_...bin` handed to a US disc stops at the region-lock
/// screen, which reads as a core regression — and the bare 512 KB size test,
/// which any corrupt file of the right length passes.
///
/// **It is a CURATED table and that is a real limit, not an oversight.** It
/// knows the images someone put in it and nothing else, so an image it cannot
/// name is UNIDENTIFIED, never rejected: `BiosLibrary` falls back to the
/// filename rule for it. A hash therefore cannot tell "corrupt" from "a valid
/// dump nobody has listed yet" — what it does is let a listed image be
/// preferred over both.
///
/// **Provenance of the five entries, which matters more than the values.** The
/// sha256s were computed from the images in this repo; the model, revision and
/// region beside each were then cross-checked against DuckStation's own BIOS
/// table (`src/core/bios.cpp`, ~170 entries keyed on MD5) by matching each
/// file's MD5 to an entry there. All five matched, and one corrected a guess
/// worth recording: `SCPH-101_BIOS_2000_US.bin` is **v4.5 05-25-00**, not the
/// v4.4 03-24-00 image that a from-memory table would likely have named — the
/// two are distinct dumps with distinct hashes. Do not add a row from memory;
/// hash the file, then find that hash in a real source.
///
/// Extending the table needs the image itself, since DuckStation publishes MD5
/// and this table is sha256. Adding a row for a dump nobody here has means
/// switching hashes, not copying a column.
enum BiosIdentity {
    /// Every PS1 BIOS image is exactly this long. A file of any other length is
    /// not a candidate and is never hashed.
    static let byteCount = 524288

    /// nil means "not in the table" — unidentified, not invalid.
    static func identify(_ data: Data) -> BiosImage? { table[sha256(data)] }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let table: [String: BiosImage] = [
        // SCPH-1000, DTL-H1000
        "cfc1fc38eb442f6f80781452119e931bcae28100c1c97e7e6c5f2725bbb0f8bb":
            BiosImage(model: "SCPH-1000", revision: "v1.0", region: .japan),
        // SCPH-1001, 5003, DTL-H1201, H3001
        "71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3":
            BiosImage(model: "SCPH-1001", revision: "v2.2 12-04-95 A", region: .us),
        // SCPH-101 — the PSone. Note v4.5, not the v4.4 dump of the same model.
        "aca9cbfa974b933646baad6556a867eca9b81ce65d8af343a7843f7775b9ffc8":
            BiosImage(model: "SCPH-101", revision: "v4.5 05-25-00 A", region: .us),
        // SCPH-3000, DTL-H1000H
        "5eb3aee495937558312b83b54323d76a4a015190decd4051214f1b6df06ac34b":
            BiosImage(model: "SCPH-3000", revision: "v1.1 01-22-95", region: .japan),
        // SCPH-7002, 7502, 9002
        "5e84a94818cf5282f4217591fefd88be36b9b174b3cc7cb0bcd75199beb450f1":
            BiosImage(model: "SCPH-7502", revision: "v4.1 12-16-97 E", region: .europe),
    ]
}
