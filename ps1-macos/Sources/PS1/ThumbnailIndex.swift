import Foundation

/// Where Finder's thumbnail extension (`Thumbnail/`) finds a disc's cover:
/// `Application Support/Substation/Thumbnails/index.json`, the canonical path
/// of every `.cue`, `.chd`, `.ccd`, `.ecm`, `.pbp` and `.mds` in the library to the cover file it shows.
///
/// The extension is sandboxed and is handed the one file Finder asks about,
/// so it can read neither the `.bin` behind a cue nor anything that would
/// identify the disc. The app has already identified every disc, so it
/// writes the answer down instead, and the extension only looks it up.
///
/// A disc shows its own cover, else its game's (the first disc's, as the
/// library's tile does). A disc with neither is left out, and Finder keeps
/// the document icon.
enum ThumbnailIndex {
    static let kinds: Set<String> = ["cue", "chd", "ccd", "ecm", "pbp", "mds"]

    static func make(_ groups: [GameGroup], cover: (GameEntry) -> URL?) -> [String: String] {
        var index: [String: String] = [:]
        for group in groups {
            let shared = cover(group.first)
            for disc in group.discs where kinds.contains(disc.url.pathExtension.lowercased()) {
                if let url = cover(disc) ?? shared {
                    index[canonicalPath(disc.url)] = url.path
                }
            }
        }
        return index
    }

    /// The extension's key for a file, which is not always the path the
    /// scanner walked (`/tmp` against `/private/tmp`, a symlinked folder).
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func write(_ index: [String: String], to directory: URL = AppSupport.directory("Thumbnails")) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(index)
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
