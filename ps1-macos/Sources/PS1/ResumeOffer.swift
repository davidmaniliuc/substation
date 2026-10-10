import Foundation

enum ResumeChoice {
    case resume, load(StateSource), freshBoot, cancel
}

/// What the launch sheet shows: there IS a state for the game being opened.
struct ResumeOffer: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let key: String
    /// The disc the player clicked; Start Fresh boots it.
    let launching: GameEntry
    /// The disc that was in the tray when the state was saved, or nil when
    /// that disc is no longer in the library; Resume is then disabled rather
    /// than booting a disc the core would refuse.
    let resumeDisc: GameEntry?
    /// The resume state's, or nil when the game has only a previous resume or slots.
    private(set) var info: SaveStateStore.Info?
    /// Previous resume and filled slots, menu order.
    private(set) var others: [SavedState]

    /// The sheet's strip: the resume first, then the others.
    var states: [SavedState] {
        (info.map { [SavedState(source: .resume, info: $0)] } ?? []) + others
    }

    /// A state deleted from the sheet. In place, keeping `id`, because the
    /// sheet stays up: a new offer would replay the dialog's transition.
    mutating func remove(_ source: StateSource) {
        if source == .resume { info = nil }
        others.removeAll { $0.source == source }
    }

    /// Nil when the game has no state at all. A state that cannot be decoded
    /// still produces an offer (so its tile can be deleted) resuming on
    /// the launching disc, where the core's refusal then explains the damage.
    static func make(launching: GameEntry, siblings: [GameEntry],
                     store: SaveStateStore) -> ResumeOffer? {
        let first = siblings.first ?? launching
        let key = SaveStateStore.key(for: first)
        let saved = store.saved(key: key)
        guard !saved.isEmpty else { return nil }
        let info = saved.first { $0.source == .resume }?.info
        let resumeDisc = store.load(.resume, key: key)
            .map { disc(for: $0, launching: launching, siblings: siblings) } ?? launching
        return ResumeOffer(title: DiscGrouping.baseTitle(first.title), key: key,
                           launching: launching, resumeDisc: resumeDisc, info: info,
                           others: saved.filter { $0.source != .resume })
    }

    /// The disc a state should resume on: the one whose serial it names.
    /// `peekStateSerial` THROWS for an unreadable header and returns nil for
    /// a readable one whose disc names no serial: two different answers, so
    /// they are not collapsed with `try?`. An unreadable state resumes on
    /// the launching disc, whose load then explains the damage.
    static func disc(for state: Data, launching: GameEntry, siblings: [GameEntry]) -> GameEntry? {
        do {
            return disc(forSerial: try Ps1Core.peekStateSerial(state), in: siblings)
        } catch {
            return launching
        }
    }

    static func disc(forSerial serial: String?, in siblings: [GameEntry]) -> GameEntry? {
        guard let serial else { return siblings.first }
        return siblings.first { $0.serial == serial }
    }

    static func == (a: ResumeOffer, b: ResumeOffer) -> Bool { a.id == b.id }
}
