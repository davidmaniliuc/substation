import Foundation

enum ResumeChoice {
    case resume, freshBoot, deleteAndBoot, cancel
}

/// What the launch sheet shows: there IS a state for the game being opened.
struct ResumeOffer: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let key: String
    /// The disc the player clicked; Fresh Boot and Delete & Boot boot it.
    let launching: GameEntry
    /// The disc that was in the tray when the state was saved, or nil when
    /// that disc is no longer in the library — Resume is then disabled rather
    /// than booting a disc the core would refuse.
    let resumeDisc: GameEntry?
    let info: ResumeStateStore.Info

    /// Nil when the game has no state. A state that cannot be decoded still
    /// produces an offer — so Delete & Boot is reachable — resuming on the
    /// launching disc, where the core's refusal then explains the damage.
    static func make(launching: GameEntry, siblings: [GameEntry],
                     store: ResumeStateStore) -> ResumeOffer? {
        let first = siblings.first ?? launching
        let key = ResumeStateStore.key(for: first)
        guard let info = store.info(key) else { return nil }

        // `peekStateSerial` THROWS for an unreadable header and returns nil
        // for a readable one whose disc names no serial — two different
        // answers, so they are not collapsed with `try?`.
        var resumeDisc: GameEntry? = launching
        if let state = store.load(key) {
            do {
                resumeDisc = disc(forSerial: try Ps1Core.peekStateSerial(state), in: siblings)
            } catch {
                resumeDisc = launching
            }
        }
        return ResumeOffer(title: DiscGrouping.baseTitle(first.title), key: key,
                           launching: launching, resumeDisc: resumeDisc, info: info)
    }

    static func disc(forSerial serial: String?, in siblings: [GameEntry]) -> GameEntry? {
        guard let serial else { return siblings.first }
        return siblings.first { $0.serial == serial }
    }

    static func == (a: ResumeOffer, b: ResumeOffer) -> Bool { a.id == b.id }
}
