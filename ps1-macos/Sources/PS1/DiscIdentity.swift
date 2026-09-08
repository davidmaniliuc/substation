import CPs1
import Foundation

/// What a disc says about itself.
///
/// The licence string the BIOS checks at LBA 4, and the boot executable named
/// by SYSTEM.CNF — whose four-letter prefix carries a region of its own. No
/// filename rule and no database, so a renamed rip still identifies and an
/// obscure disc identifies as well as a famous one.
///
/// Deliberately not here: a title, and which discs belong to one multi-disc
/// game. Neither is recorded on a PS1 disc — ISO 9660's volume-set fields read
/// 1-of-1 on every rip measured — so the library still groups on filenames.
/// DuckStation only answers those two by shipping a curated serial table.
struct DiscIdentity: Equatable, Hashable, Sendable {
    enum Region: Equatable, Hashable, Sendable { case america, europe, japan }

    let region: Region?
    /// `SLUS-00530`. Unique per DISC, not per game: Final Fantasy VII's three
    /// discs are SCUS-94163/94164/94165.
    let serial: String?
    /// The ISO volume identifier. Often absent, and never a title — it is
    /// `SLUS_00067` on Castlevania and empty on Silent Hill.
    let volumeID: String?

    /// A disc that answered nothing, or one that was never asked.
    static let unknown = DiscIdentity(region: nil, serial: nil, volumeID: nil)

    var isEmpty: Bool { self == .unknown }

    /// Identifies an image already in memory.
    ///
    /// The whole image, not a prefix: SYSTEM.CNF is reached through the ISO
    /// directory and its extent sits 497 MB into Croc and 607 MB into Resident
    /// Evil. A truncated buffer quietly yields no serial rather than an error.
    static func identify(image: Data) -> DiscIdentity {
        var raw = Ps1DiscId()
        let code = image.withUnsafeBytes { bytes in
            ps1_identify_disc(bytes.bindMemory(to: UInt8.self).baseAddress,
                              image.count, &raw)
        }
        guard code == PS1_OK else { return .unknown }

        return DiscIdentity(
            region: Region(raw.region),
            serial: string(from: &raw.serial),
            volumeID: string(from: &raw.volume_id))
    }

    /// Identifies whatever `url` names: a `.bin`, or the first FILE of a
    /// `.cue`. Nil when the file cannot be read at all.
    ///
    /// MAPPED, never read: identification touches four sectors of what may be
    /// a 700 MB image, and one of them can sit most of a disc in. Mapping
    /// makes a library scan cost page faults instead of gigabytes.
    static func identify(disc url: URL) -> DiscIdentity? {
        guard let image = try? Data(contentsOf: trackOneImage(of: url), options: .mappedIfSafe)
        else { return nil }
        return identify(image: image)
    }

    /// The image holding track 1. A cue names it; a bare `.bin` is it.
    private static func trackOneImage(of url: URL) -> URL {
        guard url.pathExtension.lowercased() == "cue",
              let text = try? String(contentsOf: url, encoding: .utf8),
              let name = CueSheet.firstImageName(in: text)
        else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// A NUL-terminated C array inside a struct, which Swift imports as a
    /// tuple — hence the pointer walk rather than a `String(cString:)` over
    /// the tuple itself. Empty becomes nil: the disc did not answer.
    private static func string<T>(from field: inout T) -> String? {
        let text = withUnsafePointer(to: &field) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
        return text.isEmpty ? nil : text
    }
}

extension DiscIdentity.Region {
    init?(_ raw: UInt8) {
        switch Ps1Region(UInt32(raw)) {
        case PS1_REGION_AMERICA: self = .america
        case PS1_REGION_EUROPE:  self = .europe
        case PS1_REGION_JAPAN:   self = .japan
        default: return nil   // PS1_REGION_UNKNOWN: fall back to your own rule
        }
    }
}
