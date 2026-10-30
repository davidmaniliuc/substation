import Foundation

/// Which open game runs, and the steps that hand the machine over from one to
/// another. Only one game ever runs; every other sits paused. The two share
/// one pair of memory-card files, so a switch is the hardware's card pulled
/// from one console and pushed into the other: the outgoing game writes its
/// cards out, then the incoming one reads them back, and only then runs.
///
/// A value type so the order is testable without a window or a session; the
/// model carries the steps out and chains them on each request's answer.
struct GameSwitch: Equatable {
    enum Step: Equatable {
        /// Paused behind the player's own pause, and its held input let go.
        case background(UUID)
        case flushCards(UUID)
        case reinstallCards(UUID)
        /// Handed back the pause it had before it went to the background.
        case foreground(UUID)
    }

    /// The game that runs, or will once a deferred switch lands.
    private(set) var running: UUID?
    /// A switch waiting for the outgoing game's card write to settle: a PS1
    /// save is a burst of blocks over several frames, and handing the card
    /// over mid-burst would leave half a save in the file. The saving game
    /// keeps RUNNING meanwhile, so its burst can finish; the incoming one
    /// waits paused.
    private(set) var deferred: (from: UUID, to: UUID)?

    init(running: UUID?) { self.running = running }

    static func == (l: GameSwitch, r: GameSwitch) -> Bool {
        l.running == r.running && l.deferred?.from == r.deferred?.from && l.deferred?.to == r.deferred?.to
    }

    /// `incoming`'s window came forward. `outgoingSaving` is whether the
    /// running game's card write is still settling.
    mutating func request(to incoming: UUID, outgoingSaving: Bool) -> [Step] {
        if let d = deferred {
            // Back to the saving game, which never stopped.
            if incoming == d.from {
                deferred = nil
                running = incoming
                return []
            }
            deferred = (d.from, incoming)
            running = incoming
            return []
        }
        guard incoming != running else { return [] }
        guard let outgoing = running else {
            running = incoming
            return [.reinstallCards(incoming), .foreground(incoming)]
        }
        running = incoming
        if outgoingSaving {
            deferred = (outgoing, incoming)
            return []
        }
        return [.background(outgoing), .flushCards(outgoing), .reinstallCards(incoming), .foreground(incoming)]
    }

    /// The outgoing game's card write has settled: a deferred switch lands.
    mutating func outgoingSettled() -> [Step] {
        guard let d = deferred else { return [] }
        deferred = nil
        return [.background(d.from), .flushCards(d.from), .reinstallCards(d.to), .foreground(d.to)]
    }

    /// A game closed. Its session wrote its cards as it stopped, so an
    /// incoming game waiting on it goes in at once; a saving game whose
    /// incoming game closed simply runs on. No paused game resumes.
    mutating func removed(_ id: UUID) -> [Step] {
        if let d = deferred {
            if d.from == id {
                deferred = nil
                return [.reinstallCards(d.to), .foreground(d.to)]
            }
            if d.to == id {
                deferred = nil
                running = d.from
                return []
            }
        }
        if running == id { running = nil }
        return []
    }

    /// A game that starts with nothing else running reads the cards itself.
    mutating func adopt(_ id: UUID) {
        running = id
    }
}
