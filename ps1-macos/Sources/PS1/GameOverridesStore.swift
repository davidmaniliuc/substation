import Foundation
import Observation

/// Per-game setting overrides for every game, persisted as one JSON file under
/// `Application Support/Substation/GameSettings/overrides.json`, keyed exactly
/// as play stats and resume states are (`SaveStateStore.key(for:)` of the first
/// disc: serial first, falling back to path hash), so all discs of a multi-disc
/// game share one profile and a renamed rip keeps its settings.
///
/// `@Observable` so open game windows, sheets and controls follow writes live.
/// A missing or damaged file reads as empty and is never deleted on read: it is
/// replaced only by the next write, matching `PlayStatsStore`.
@Observable
final class GameOverridesStore {
    private(set) var all: [String: GameOverrides]
    @ObservationIgnored private let file: URL

    init(directory: URL? = nil) {
        let directory = directory ?? AppSupport.directory("GameSettings")
        file = directory.appendingPathComponent("overrides.json")
        let decoded = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: GameOverrides].self, from: $0) } ?? [:]
        all = decoded.reduce(into: [:]) { result, pair in
            let normalized = pair.value.normalized()
            if !normalized.isEmpty { result[pair.key] = normalized }
        }
    }

    func overrides(for key: String) -> GameOverrides? {
        all[key]
    }

    func hasOverrides(for key: String) -> Bool {
        all[key]?.isEmpty == false
    }

    /// Replaces the stored profile for `key`. Clearing every field removes the
    /// game's entry cleanly. Unchanged values write nothing to disk.
    func set(_ overrides: GameOverrides, for key: String) {
        let normalized = overrides.normalized()
        let next: GameOverrides? = normalized.isEmpty ? nil : normalized
        guard all[key] != next else { return }
        all[key] = next
        save()
    }

    func update(for key: String, _ mutate: (inout GameOverrides) -> Void) {
        var copy = all[key] ?? GameOverrides()
        mutate(&copy)
        set(copy, for: key)
    }

    func remove(for key: String) {
        set(GameOverrides(), for: key)
    }

    /// Atomic write, so a crash mid-write leaves the previous file intact.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
