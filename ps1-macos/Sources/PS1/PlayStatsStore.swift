import Foundation
import Observation

/// One game's history: when it was last started and how long it has been
/// actively played (`PlayClock`'s rule).
struct PlayStats: Codable, Equatable, Sendable {
    var lastPlayed: Date?
    var seconds: TimeInterval = 0
}

/// Play stats for every game, one JSON file, keyed exactly as resume states
/// are (`SaveStateStore.key(for:)`: the first disc's serial, else the path
/// hash), so a multi-disc game has one record and a renamed rip keeps its
/// history.
///
/// `@Observable` so the list view's columns follow a write without a revision
/// counter. A missing or unreadable file reads as empty and is never deleted
/// on read: a damaged file is replaced only by the next successful write.
@Observable
final class PlayStatsStore {
    private(set) var all: [String: PlayStats]
    @ObservationIgnored private let file: URL

    init(directory: URL? = nil) {
        let directory = directory ?? AppSupport.directory("PlayStats")
        file = directory.appendingPathComponent("stats.json")
        all = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: PlayStats].self, from: $0) } ?? [:]
    }

    func stats(for key: String) -> PlayStats? { all[key] }

    func markPlayed(_ key: String, at date: Date) {
        all[key, default: PlayStats()].lastPlayed = date
        save()
    }

    func add(_ seconds: TimeInterval, to key: String) {
        guard seconds > 0 else { return }
        all[key, default: PlayStats()].seconds += seconds
        save()
    }

    /// Atomic, so a crash mid-write leaves the previous file.
    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
