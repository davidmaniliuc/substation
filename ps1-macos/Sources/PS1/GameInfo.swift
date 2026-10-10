import Foundation

/// One read-only line of the pause menu's Game Info page.
struct GameInfoRow: Equatable {
    let icon: String
    let label: String
    let value: String
}

/// What the app knows about the disc in the drive, for Game Info. A pure
/// function of what the model already holds, so it is tested without a game.
enum GameInfo {
    static func rows(disc: GameEntry, index: Int, count: Int, bios: String?,
                     played: TimeInterval, lastPlayed: Date?) -> [GameInfoRow] {
        var rows = [
            GameInfoRow(icon: "number", label: "Serial", value: disc.serial ?? "Unknown"),
            GameInfoRow(icon: "globe", label: "Region", value: region(disc.identity.region)),
            GameInfoRow(icon: "circle.circle", label: "Disc", value: "\(index + 1) of \(count)"),
            GameInfoRow(icon: "hourglass", label: "Time Played", value: PlayingFor.format(played)),
            GameInfoRow(icon: "calendar", label: "Last Played",
                        value: lastPlayed.map { StateSource.savedAt($0) } ?? "Never"),
            GameInfoRow(icon: "cpu", label: "BIOS", value: bios ?? "Unidentified"),
            GameInfoRow(icon: "doc", label: "Image", value: image(disc.kind)),
        ]
        if exists(disc.url, "ppf") {
            rows.append(GameInfoRow(icon: "bandage", label: "Patch", value: "PPF applied"))
        }
        if exists(disc.url, "sbi") {
            rows.append(GameInfoRow(icon: "lock.open", label: "LibCrypt", value: "SBI sidecar"))
        }
        return rows
    }

    private static func region(_ region: DiscIdentity.Region?) -> String {
        switch region {
        case .america: "North America"
        case .europe: "Europe"
        case .japan: "Japan"
        case nil: "Unknown"
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
