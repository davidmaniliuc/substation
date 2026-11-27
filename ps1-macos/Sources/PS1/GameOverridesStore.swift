import Foundation
import Observation

/// Per-game setting overrides for every game, persisted as one JSON file under
/// `Application Support/Substation/GameSettings/overrides.json`, keyed exactly
/// as play stats and resume states are (`SaveStateStore.key(for:)` of the first
/// disc: serial first, falling back to path hash), so all discs of a multi-disc
/// game share one profile and a renamed rip keeps its settings.
///
/// `@Observable` so open game windows, sheets and controls follow writes live.
///
/// Each game's record is decoded on its own. A record this build cannot read
/// (a setting renamed or renumbered since it was written) is kept verbatim and
/// written back untouched, so one bad field never costs every other game its
/// profile. A file that is not JSON at all is moved aside to
/// `overrides.damaged.json` by the first write rather than overwritten.
@Observable
final class GameOverridesStore {
    private(set) var all: [String: GameOverrides]
    @ObservationIgnored private let file: URL
    /// Records that did not decode, as they were read.
    @ObservationIgnored private var unreadable: [String: Any] = [:]
    @ObservationIgnored private var damaged = false

    init(directory: URL? = nil) {
        let directory = directory ?? AppSupport.directory("GameSettings")
        file = directory.appendingPathComponent("overrides.json")
        all = [:]
        guard let data = try? Data(contentsOf: file) else { return }
        guard let records = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            damaged = true
            return
        }
        let decoder = JSONDecoder()
        for (key, record) in records {
            guard let json = try? JSONSerialization.data(withJSONObject: record),
                  let decoded = try? decoder.decode(GameOverrides.self, from: json) else {
                unreadable[key] = record
                continue
            }
            let normalized = decoded.normalized()
            if !normalized.isEmpty { all[key] = normalized }
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
        // A profile written now supersedes whatever could not be read for it.
        unreadable[key] = nil
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
        guard let encoded = try? JSONEncoder().encode(all),
              var records = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
        else { return }
        records.merge(unreadable) { readable, _ in readable }
        guard let data = try? JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if damaged {
            let aside = file.deletingLastPathComponent().appendingPathComponent("overrides.damaged.json")
            try? fm.removeItem(at: aside)
            try? fm.moveItem(at: file, to: aside)
            damaged = false
        }
        try? data.write(to: file, options: .atomic)
    }
}
