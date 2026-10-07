import Foundation

/// What kind of image a disc file is, read off its extension. A `.cue` names
/// its tracks, a `.chd` carries its own, and a lone `.bin` is one data track.
enum DiscKind: Equatable, Sendable {
    case cue, bin, chd

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "cue": self = .cue
        case "chd": self = .chd
        default: self = .bin
        }
    }
}
