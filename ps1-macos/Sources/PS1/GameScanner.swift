import Foundation

/// Walks a games folder and decides what counts as one game.
///
/// A game is a `.cue`, a `.chd`, a CloneCD `.ccd`, an Alcohol `.mds`, an
/// eboot `.pbp`, an `.ecm` or a lone image (`.bin`, `.iso`, `.img`, `.mdf`). The lone-image rule is per-DIRECTORY: one counts
/// only when its own directory holds no `.cue` at all. Nearly every rip is a
/// cue plus the bin it names, so listing both would show every game twice; a
/// lone image is still playable (as a single data track at LBA 0) and must
/// not disappear.
///
/// A converted copy kept beside its original is the same game, matched on
/// the file stem, and one stem in one folder is one entry, by precedence:
/// cue > chd > ccd > mds > pbp > ecm > lone image. So a `.ccd`'s own `.img` and
/// an `.mds`'s `.mdf` are never games of their own, and `Game.bin.ecm` (whose stem is `Game`, the image it
/// holds) hides a `Game.bin` beside it. An `.ecm` a cue in its folder names
/// is that cue's image, not a game. A file of another stem is another game.
///
/// An `.m3u` is one game, standing for every disc it names and identified
/// by its first, and each disc a playlist names is listed only through it.
/// A playlist that cannot be read is no game.
///
/// An executable (`DiscKind.exeExtensions`) is a game of its own when the
/// core would boot it, which keeps a Windows `.exe` out of the list. A
/// `libps.exe` is never one: it is the library a PS-X EXE beside it loads.
///
/// Every entry is also identified from the disc itself as it is found, which
/// is what gives covers a key that survives a rename.
enum GameScanner {
    static let libpsName = "libps.exe"

    static func scan(root: URL) -> [GameEntry] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [DiscKind: [URL: [URL]]] = [:]
        var exes: [URL] = []
        var playlists: [Playlist] = []

        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            let directory = url.deletingLastPathComponent().standardizedFileURL
            let kind = DiscKind(url)

            switch kind {
            case .exe:
                if url.lastPathComponent.lowercased() != libpsName { exes.append(url) }
            case .cue, .chd, .ccd, .mds, .pbp, .ecm, .iso:
                found[kind, default: [:]][directory, default: []].append(url)
            case .bin:
                // `.bin` is also the catch-all for an unknown extension.
                guard url.pathExtension.lowercased() == "bin" else { continue }
                found[kind, default: [:]][directory, default: []].append(url)
            case .m3u:
                if let playlist = try? Playlist.read(url) { playlists.append(playlist) }
            }
        }

        // Each disc is identified here, once per scan, rather than lazily at
        // display time: the answer keys the cover, and a tile that has to
        // touch the disc to draw itself would pay for it on every render.
        // Mapped rather than read, so the cost is a handful of page faults:
        // see `DiscIdentity.identify(disc:)`.
        func stem(_ url: URL) -> String {
            (DiscFiles.stems(of: url).last ?? url).lastPathComponent.lowercased()
        }
        func entry(_ url: URL) -> GameEntry {
            GameEntry(url: url, identity: DiscIdentity.identify(disc: url) ?? .unknown)
        }
        let cues = found[.cue] ?? [:]
        // The stems the kinds before this one have already listed, per folder.
        var taken: [URL: Set<String>] = [:]
        var entries: [GameEntry] = []
        func take(_ kind: DiscKind, where keep: (URL, URL) -> Bool = { _, _ in true }) {
            var listed: [URL: Set<String>] = [:]
            for (directory, urls) in found[kind] ?? [:] {
                let kept = urls.filter {
                    !(taken[directory]?.contains(stem($0)) ?? false) && keep(directory, $0)
                }
                entries += kept.map(entry)
                listed[directory] = Set(kept.map(stem))
            }
            taken.merge(listed) { $0.union($1) }
        }

        take(.cue)
        take(.chd)
        take(.ccd)
        take(.mds)
        take(.pbp)
        let cueImages = cues.mapValues(imagesNamed(by:))
        take(.ecm) { directory, url in
            !(cueImages[directory]?.contains(url.lastPathComponent.lowercased()) ?? false)
        }
        take(.iso) { directory, _ in cues[directory] == nil }
        take(.bin) { directory, _ in cues[directory] == nil }
        entries += exes.compactMap { url in
            DiscIdentity.identify(exe: url).map { GameEntry(url: url, identity: $0) }
        }

        let named = Set(playlists.flatMap(\.discs).map(\.path))
        entries.removeAll { named.contains(Playlist.canonical($0.url).path) }
        entries += playlists.map { playlist in
            let first = playlist.discs[0]
            let identity = DiscKind(first) == .exe ? nil : DiscIdentity.identify(disc: first)
            return GameEntry(url: playlist.url, identity: identity ?? .unknown,
                             playlist: playlist.discs)
        }

        return entries.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Every image file the cue sheets name, lowercased.
    private static func imagesNamed(by cues: [URL]) -> Set<String> {
        Set(cues.flatMap { cue -> [String] in
            guard let text = try? String(contentsOf: cue, encoding: .utf8) else { return [] }
            return CueSheet.lines(of: text).compactMap(CueSheet.imageName(inLine:)).map {
                URL(fileURLWithPath: $0).lastPathComponent.lowercased()
            }
        })
    }
}
