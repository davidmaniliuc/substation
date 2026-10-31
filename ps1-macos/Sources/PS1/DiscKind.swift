import Foundation

/// What kind of image a disc file is, read off its extension. A `.cue` names
/// its tracks, a `.chd` carries its own, and a lone `.bin` is one data track.
/// An `.iso` or a lone `.img` is a lone image too, raw or cooked: the core
/// tells them apart by content. A `.ccd` is a CloneCD control file over the
/// `.img` of its stem, an `.ecm` a compressed image the core decodes, and an
/// `.m3u` a playlist naming the discs of one game. A `.pbp` is a PSP eboot
/// holding one or more discs; an `.mds` is an Alcohol sheet over the `.mdf`
/// of its stem.
/// An executable is no disc at all: the core boots it in place of one, and
/// tells its three formats apart by content, so one case covers them all.
enum DiscKind: Hashable, Sendable {
    case cue, bin, chd, exe, iso, ccd, ecm, m3u, pbp, mds

    /// The extensions an executable is listed under. Content decides whether
    /// it boots: a Windows `.exe` shares the first.
    static let exeExtensions: Set<String> = ["exe", "psexe", "ps-exe", "psx", "cpe", "elf"]

    init(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "cue": self = .cue
        case "chd": self = .chd
        // An `.mdf` is an Alcohol image with no sheet in hand: a lone image,
        // which the core sniffs.
        case "iso", "img", "mdf": self = .iso
        case "pbp": self = .pbp
        case "mds": self = .mds
        case "ccd": self = .ccd
        case "ecm": self = .ecm
        case "m3u": self = .m3u
        case _ where Self.exeExtensions.contains(ext): self = .exe
        default: self = .bin
        }
    }
}
