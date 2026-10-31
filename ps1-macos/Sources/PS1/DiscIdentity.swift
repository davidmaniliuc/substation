import CPs1
import Foundation

/// What a disc says about itself.
///
/// The licence string the BIOS checks at LBA 4, and the boot executable named
/// by SYSTEM.CNF, whose four-letter prefix carries a region of its own. No
/// filename rule and no database, so a renamed rip still identifies and an
/// obscure disc identifies as well as a famous one.
///
/// Not read off the disc: a title, and which discs belong to one multi-disc
/// game. Neither is recorded on a PS1 disc (ISO 9660's volume-set fields read
/// 1-of-1 on every rip measured), so both come from the core's serial tables,
/// with the filename as the fallback.
struct DiscIdentity: Equatable, Hashable, Sendable {
    enum Region: Equatable, Hashable, Sendable { case america, europe, japan }

    let region: Region?
    /// `SLUS-00530`. Unique per DISC, not per game: Final Fantasy VII's three
    /// discs are SCUS-94163/94164/94165.
    let serial: String?
    /// The ISO volume identifier. Often absent, and never a title: it is
    /// `SLUS_00067` on Castlevania and empty on Silent Hill.
    let volumeID: String?
    /// The disc's catalogued title, per disc: "Final Fantasy VII (Disc 1)".
    let title: String?
    /// Canonical title of a known multi-disc set, supplied by the serial table.
    let gameTitle: String?
    /// One-based disc ordinal from that same table.
    let discNumber: Int?

    init(region: Region?, serial: String?, volumeID: String?, title: String? = nil,
         gameTitle: String? = nil, discNumber: Int? = nil) {
        self.region = region
        self.serial = serial
        self.volumeID = volumeID
        self.title = title
        self.gameTitle = gameTitle
        self.discNumber = discNumber
    }

    /// A disc that answered nothing, or one that was never asked.
    static let unknown = DiscIdentity(region: nil, serial: nil, volumeID: nil)

    var isEmpty: Bool { self == .unknown }

    /// Identifies an image already in memory.
    ///
    /// The whole image, not a prefix: SYSTEM.CNF is reached through the ISO
    /// directory and its extent sits 497 MB into Croc and 607 MB into Resident
    /// Evil. A truncated buffer quietly yields no serial rather than an error.
    /// `sheet` is an Alcohol `.mds`'s bytes, and `disc` the disc of an eboot.
    static func identify(image: Data, sheet: Data? = nil, disc: Int = 0) -> DiscIdentity {
        guard let raw = identifyRaw(image: image, sheet: sheet, disc: disc)?.id else { return .unknown }
        return DiscIdentity(raw)
    }

    /// What `ps1_identify_disc_image` answers for `image`, or nil on a refusal.
    private static func identifyRaw(image: Data, sheet: Data?, disc: Int)
        -> (id: Ps1DiscId, info: Ps1ImageInfo)? {
        var raw = Ps1DiscId()
        var info = Ps1ImageInfo()
        let code = image.withUnsafeBytes { bytes in
            (sheet ?? Data()).withUnsafeBytes { sheetBytes in
                ps1_identify_disc_image(
                    bytes.bindMemory(to: UInt8.self).baseAddress, image.count,
                    sheet == nil ? nil : sheetBytes.bindMemory(to: UInt8.self).baseAddress,
                    sheet?.count ?? 0, UInt32(disc), &raw, &info)
            }
        }
        return code == PS1_OK ? (raw, info) : nil
    }

    private init(_ raw: Ps1DiscId) {
        var raw = raw
        let serial = cString(&raw.serial)
        var set = Ps1DiscSet()
        let hasSet = serial?.withCString { ps1_lookup_disc_set($0, &set) != 0 } ?? false
        var title = Ps1GameTitle()
        let hasTitle = serial?.withCString { ps1_lookup_game_title($0, &title) != 0 } ?? false

        self.init(
            region: Region(raw.region),
            serial: serial,
            volumeID: cString(&raw.volume_id),
            title: hasTitle ? cString(&title.title) : nil,
            gameTitle: hasSet ? cString(&set.game_title) : nil,
            discNumber: hasSet ? Int(set.disc_number) : nil)
    }

    /// How many discs `url` holds and what it calls itself: an eboot's count
    /// and title, 1 and "" for every other image. Nil when the core refuses
    /// the file or it cannot be read.
    static func imageInfo(_ url: URL) -> (discs: Int, title: String)? {
        guard let (image, sheet) = imageAndSheet(of: url),
              var info = identifyRaw(image: image, sheet: sheet, disc: 0)?.info
        else { return nil }
        return (Int(info.disc_count), cString(&info.title) ?? "")
    }

    /// Identifies whatever `url` names: a lone image, the first FILE of a
    /// `.cue`, or a `.ccd`'s `.img`. Nil when the file cannot be read at all,
    /// or when the core refuses it (an eboot's `index` past its last disc).
    ///
    /// MAPPED, never read: identification touches four sectors of what may be
    /// a 700 MB image, and one of them can sit most of a disc in. Mapping
    /// makes a library scan cost page faults instead of gigabytes.
    static func identify(disc url: URL, index: Int = 0) -> DiscIdentity? {
        guard let (image, sheet) = imageAndSheet(of: url),
              let raw = identifyRaw(image: image, sheet: sheet, disc: index)?.id
        else { return nil }
        return DiscIdentity(raw)
    }

    /// The mapped image `url` names and the sheet that goes with it: only an
    /// `.mds` passes one, over its `.mdf`.
    private static func imageAndSheet(of url: URL) -> (Data, Data?)? {
        guard let image = try? Data(contentsOf: trackOneImage(of: url), options: .mappedIfSafe)
        else { return nil }
        if DiscKind(url) == .mds {
            guard let sheet = try? Data(contentsOf: url) else { return nil }
            return (image, sheet)
        }
        return (image, nil)
    }

    /// What an executable says about itself: only a PS-X EXE header's
    /// licence marker names a region. Nil for bytes `ps1_load_exe` would
    /// refuse, a Windows `.exe` among them.
    static func identify(exeImage: Data) -> DiscIdentity? {
        var raw = Ps1ExeId()
        let code = exeImage.withUnsafeBytes { bytes in
            ps1_identify_exe(bytes.bindMemory(to: UInt8.self).baseAddress, exeImage.count, &raw)
        }
        guard code == PS1_OK else { return nil }
        return DiscIdentity(region: Region(raw.region), serial: nil, volumeID: nil)
    }

    /// Whether `image` is a PS-X EXE the core would boot, the one format a
    /// `libps.exe` may be.
    static func isPsExe(_ image: Data) -> Bool {
        var raw = Ps1ExeId()
        let code = image.withUnsafeBytes { bytes in
            ps1_identify_exe(bytes.bindMemory(to: UInt8.self).baseAddress, image.count, &raw)
        }
        return code == PS1_OK && raw.format == 1
    }

    /// `identify(exeImage:)` over a file, mapped as a disc is.
    static func identify(exe url: URL) -> DiscIdentity? {
        guard let image = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return identify(exeImage: image)
    }

    /// The image holding track 1. A cue names it; a CloneCD sheet controls
    /// the `.img` of its stem; a lone image, an `.ecm` or a `.chd` is it (the
    /// core sniffs which).
    private static func trackOneImage(of url: URL) -> URL {
        switch DiscKind(url) {
        case .ccd:
            return DiscFiles.companion(of: url, ext: "img")
        case .mds:
            return DiscFiles.companion(of: url, ext: "mdf")
        case .cue:
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let name = CueSheet.firstImageName(in: text)
            else { return url }
            return url.deletingLastPathComponent().appendingPathComponent(name)
        default:
            return url
        }
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
