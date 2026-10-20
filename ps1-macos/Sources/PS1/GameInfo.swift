import Foundation

/// One read-only line of the pause menu's About This Game.
struct GameInfoRow: Equatable {
    let label: String
    let value: String
}

/// What the app knows about the disc in the drive, for About This Game. A
/// pure function of what the model already holds, so it is tested without a
/// game. Nothing the menu's header already says: the serial and region only
/// when a short window has dropped them from it, and no Last Played, which
/// is now. The disc number only for a game with more than one.
enum GameInfo {
    static func rows(disc: GameEntry, index: Int, count: Int, bios: BiosImage?,
                     played: TimeInterval, identityInHeader: Bool) -> [GameInfoRow] {
        var rows: [GameInfoRow] = []
        if !identityInHeader {
            rows.append(GameInfoRow(label: "Serial", value: disc.serial ?? "Unknown"))
            rows.append(GameInfoRow(label: "Region", value: region(disc.identity.region)))
        }
        if count > 1 {
            rows.append(GameInfoRow(label: "Disc", value: "\(index + 1) of \(count)"))
        }
        rows += [
            GameInfoRow(label: "Total Play Time", value: PlayingFor.format(played)),
            GameInfoRow(label: "Console", value: bios.map(console) ?? "Unidentified"),
            GameInfoRow(label: "Image", value: image(disc.kind)),
        ]
        if exists(disc.url, "ppf") {
            rows.append(GameInfoRow(label: "Patch", value: "PPF applied"))
        }
        if exists(disc.url, "sbi") {
            rows.append(GameInfoRow(label: "LibCrypt", value: "SBI sidecar"))
        }
        return rows
    }

    /// The BIOS as the console it came in, "SCPH-7502 (Europe)": the model
    /// alone read as a second serial beside the disc's. The region's own
    /// model when the image shipped in it, since the table lists SCPH-7002
    /// first for the dump every PAL SCPH-7502 carries.
    static func console(_ bios: BiosImage) -> String {
        "\(model(bios)) (\(region(bios.region)))"
    }

    static func model(_ bios: BiosImage) -> String {
        bios.models.contains(bios.region.rawValue) ? bios.region.rawValue
            : bios.models.first ?? bios.region.rawValue
    }

    static func region(_ region: DiscIdentity.Region?) -> String {
        switch region {
        case .america: "North America"
        case .europe: "Europe"
        case .japan: "Japan"
        case nil: "Unknown"
        }
    }

    /// `BiosRegion.init(_:)` reversed, so a console and a disc name a
    /// region in the same words.
    static func region(_ region: BiosRegion) -> String {
        switch region {
        case .us: Self.region(DiscIdentity.Region.america)
        case .europe: Self.region(DiscIdentity.Region.europe)
        case .japan: Self.region(DiscIdentity.Region.japan)
        }
    }

    private static func image(_ kind: DiscKind) -> String {
        switch kind {
        case .cue: "CUE/BIN"
        case .chd: "CHD"
        case .bin: "BIN"
        }
    }

    /// Beside the disc on its own stem, as the loader looks for them.
    private static func exists(_ disc: URL, _ ext: String) -> Bool {
        FileManager.default.fileExists(
            atPath: disc.deletingPathExtension().appendingPathExtension(ext).path)
    }
}

/// The pause menu's Save States subtitle: "4 saved · 5 minutes ago", when the
/// newest was written.
enum SaveStatesSummary {
    static func text(count: Int, newest: Date?, now: Date = .now) -> String {
        guard count > 0, let newest else { return "None saved" }
        return "\(count) saved · \(ago(newest, now: now))"
    }

    /// The library's "5 minutes ago" for the last half day, then the day and
    /// time `StateSource.savedAt` gives.
    private static func ago(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 12 * 3600 { return LibraryFormat.tileSubtitle(discs: 1, lastPlayed: date, now: now) }
        return StateSource.savedAt(date, now: now)
    }
}
