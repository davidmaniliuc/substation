import Foundation

/// An `.m3u`: the discs of one game, in order, one path per line.
///
/// Read without touching the discs it names: a missing one is found only when
/// it is chosen, so one disc gone does not hide the whole set. Paths are
/// canonical, as `EmulatorViewModel.canonicalPath` spells them, so a disc
/// named here and the same file found by the scanner compare equal.
struct Playlist: Hashable, Sendable {
    let url: URL
    let discs: [URL]

    enum Error: Swift.Error, Equatable {
        /// Another playlist, an executable, or the playlist itself: a set of
        /// discs holds only discs.
        case unsupportedEntry(String)
        case empty
    }

    static func read(_ url: URL) throws -> Playlist {
        let text = try String(contentsOf: url, encoding: .utf8)
        let folder = url.deletingLastPathComponent()
        let discs = try CueSheet.lines(of: text).compactMap { raw -> URL? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let disc = canonical(URL(fileURLWithPath: line, relativeTo: folder))
            switch DiscKind(disc) {
            case .m3u, .exe: throw Error.unsupportedEntry(disc.lastPathComponent)
            default: return disc
            }
        }
        guard !discs.isEmpty else { throw Error.empty }
        return Playlist(url: url, discs: discs)
    }

    static func canonical(_ url: URL) -> URL {
        url.absoluteURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
