import Foundation

/// Gathers the files a disc is made of into what the session takes: the one
/// place that knows which file holds the image, which holds the sheet, and
/// which sidecars sit beside them. A game's first load and a disc swap both
/// come through here, so the two cannot disagree on a format.
///
/// The core tells every format apart by content (`ps1.h`); this only picks
/// the files. A `.cue` is laid out by `image(forCue:)`; a CloneCD `.ccd` is
/// the sheet over the `.img` of its stem, with its raw `.sub` in the `sbi`
/// slot; an Alcohol `.mds` is the sheet over the `.mdf` of its stem; anything
/// else is its own image (a `.pbp` too, with the disc of it to read).
///
/// The image handed over is READ into memory, never mapped: the core borrows
/// it for the whole game, and a mapped file on a drive that is unplugged, or
/// truncated mid-game, would fault the app. Only a cue's images are mapped,
/// for the moment it takes to copy them into one buffer; identification
/// (`DiscIdentity`) maps, since it reads a few sectors and lets go.
enum DiscFiles {
    static func read(_ url: URL, disc: Int = 0) throws -> DiscBytes {
        let kind = DiscKind(url)
        precondition(disc == 0 || kind == .pbp, "only an eboot holds more than one disc")
        switch kind {
        case .cue:
            let image = try image(forCue: url)
            return DiscBytes(bin: image.bin, cue: image.cue,
                             sbi: sidecar(forDisc: url), ppf: patch(forDisc: url))
        case .ccd:
            // The `.sub` carries the LibCrypt sectors' broken Q itself; an
            // `.sbi` is only the fallback for a set ripped without one.
            let image = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("img"))
            return DiscBytes(bin: image, cue: try Data(contentsOf: url),
                             sbi: beside(url, ext: "sub") ?? sidecar(forDisc: url),
                             ppf: patch(forDisc: url))
        case .mds:
            // The image is the `.mdf` of the sheet's stem. Its own LibCrypt
            // records win when it was dumped with subchannel; the core
            // decides, so an `.sbi` is passed whenever one sits beside it.
            let image = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("mdf"))
            return DiscBytes(bin: image, cue: try Data(contentsOf: url),
                             sbi: sidecar(forDisc: url), ppf: patch(forDisc: url))
        case .pbp:
            // A patch names bytes of one image: it applies to disc 0 only.
            return DiscBytes(bin: try Data(contentsOf: url), cue: nil,
                             sbi: sidecar(forDisc: url),
                             ppf: disc == 0 ? patch(forDisc: url) : nil, disc: UInt32(disc))
        case .m3u:
            // A playlist names discs; it is not one.
            throw CocoaError(.fileReadUnsupportedScheme)
        case .bin, .chd, .exe, .iso, .ecm:
            return DiscBytes(bin: try Data(contentsOf: url), cue: nil,
                             sbi: sidecar(forDisc: url), ppf: patch(forDisc: url))
        }
    }

    /// The image and the sheet a `.cue` hands the core.
    ///
    /// Most rips are one `FILE`, but a per-track rip is not (Tekken 3 has 3,
    /// Castlevania 2, Rayman 51), and `Disc` holds ONE data slice. The images
    /// are therefore concatenated and a `REM FILESIZE <bytes>` line emitted
    /// before each `FILE`: that size is all `initFromCue` has left to recover
    /// the boundary the concatenation erased. Without it every FILE stacks at
    /// the same base LBA, so `ps1_load_disc` refuses the cue outright.
    ///
    /// An `.ecm` FILE is passed as it is, compressed, with the sheet
    /// untouched: the core decodes it, and a seam measured in compressed
    /// bytes would describe nothing. It can only be the sheet's one FILE,
    /// since a `Disc` reads one source.
    ///
    /// Sizes come from the bytes actually read rather than from a separate
    /// stat, so the cue cannot describe a layout the slice does not have.
    static func image(forCue cue: URL) throws -> (bin: Data, cue: Data) {
        let text = try String(contentsOf: cue, encoding: .utf8)
        let directory = cue.deletingLastPathComponent()
        let names = CueSheet.lines(of: text).compactMap(CueSheet.imageName(inLine:))
        guard !names.isEmpty else { throw Ps1Error.badCue }

        if names.contains(where: { DiscKind(URL(fileURLWithPath: $0)) == .ecm }) {
            guard names.count == 1 else { throw Ps1Error.badCue }
            let image = try Data(contentsOf: directory.appendingPathComponent(names[0]))
            return (image, try Data(contentsOf: cue))
        }

        var images: [Data] = []
        var augmented = ""
        for raw in CueSheet.lines(of: text) {
            if let name = CueSheet.imageName(inLine: raw) {
                // Mapped: a per-track rip of a full disc is read in its
                // entirety here, and the copy into `bin` below is the only
                // one that has to be resident, and the only one the core
                // borrows.
                let image = try Data(contentsOf: directory.appendingPathComponent(name),
                                     options: .mappedIfSafe)
                images.append(image)
                augmented += "REM FILESIZE \(image.count)\n"
            }
            augmented += raw
            augmented += "\n"
        }

        var bin = Data(capacity: images.reduce(0) { $0 + $1.count })
        for image in images { bin.append(image) }
        return (bin, Data(augmented.utf8))
    }

    /// The LibCrypt sidecar sitting beside `disc` under the same stem, or nil
    /// when the disc has none.
    ///
    /// Much of Sony Europe's own PAL catalogue (Final Fantasy IX among it)
    /// hides a key in the subchannel Q of a few dozen sectors. No .bin or .cue
    /// can carry it, so without the sidecar the protection check never passes
    /// and the game sits behind a black screen sweeping those sectors forever.
    ///
    /// Matched on the stem alone, never on "the only .sbi in the directory":
    /// FF9's four discs share a folder and each sidecar names sectors of its
    /// own image, so the wrong one is worth exactly as much as no sidecar.
    /// A missing one is the ordinary case and is not an error: the sidecar is
    /// only checked once the core has it, where a corrupt file is refused.
    static func sidecar(forDisc disc: URL) -> Data? {
        beside(disc, ext: "sbi")
    }

    /// The PPF patch sitting beside `disc` under the same stem, or nil when
    /// the disc has none: a fan translation or fix kept next to an untouched
    /// rip. Matched on the stem for the sidecar's reason, since a patch names
    /// byte offsets of one image. The core validates it on load.
    static func patch(forDisc disc: URL) -> Data? {
        beside(disc, ext: "ppf")
    }

    /// Whether `disc` has a file of `ext` beside it, as `beside` finds one.
    static func hasSidecar(_ disc: URL, ext: String) -> Bool {
        stems(of: disc).contains {
            FileManager.default.fileExists(atPath: $0.appendingPathExtension(ext).path)
        }
    }

    private static func beside(_ disc: URL, ext: String) -> Data? {
        for stem in stems(of: disc) {
            if let data = try? Data(contentsOf: stem.appendingPathExtension(ext)) { return data }
        }
        return nil
    }

    /// The stems a sidecar of `disc` may carry, the game's own last.
    /// `Game.bin.ecm` is `Game.bin` compressed, so a sidecar named for the
    /// image it holds comes first, then one named for the game. Only an
    /// image extension is stripped twice: `Game (v1.1).ecm` is `Game (v1.1)`.
    static func stems(of disc: URL) -> [URL] {
        let stem = disc.deletingPathExtension()
        guard DiscKind(disc) == .ecm, heldExtensions.contains(stem.pathExtension.lowercased())
        else { return [stem] }
        return [stem, stem.deletingPathExtension()]
    }

    private static let heldExtensions: Set<String> = ["bin", "img", "iso"]
}
