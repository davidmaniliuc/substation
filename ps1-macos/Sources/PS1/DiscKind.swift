import Foundation

/// What kind of image a disc file is, read off its extension. A `.cue` names
/// its tracks, a `.chd` carries its own, and a lone `.bin` is one data track.
/// An executable is no disc at all: the core boots it in place of one, and
/// tells its three formats apart by content, so one case covers them all.
enum DiscKind: Equatable, Sendable {
    case cue, bin, chd, exe

    /// The extensions an executable is listed under. Content decides whether
    /// it boots: a Windows `.exe` shares the first.
    static let exeExtensions: Set<String> = ["exe", "psexe", "ps-exe", "psx", "cpe", "elf"]

    init(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "cue": self = .cue
        case "chd": self = .chd
        case _ where Self.exeExtensions.contains(ext): self = .exe
        default: self = .bin
        }
    }
}
