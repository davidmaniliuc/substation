import Foundation

/// Which saved machine: the resume state the app writes on exit and on a
/// timer, the one it replaced, or one of the player's manual slots.
enum StateSource: Hashable, Sendable {
    case resume, previous, slot(Int)

    static let slots = 1...6

    var title: String {
        switch self {
        case .resume: "Resume"
        case .previous: "Previous Resume"
        case .slot(let n): "Slot \(n)"
        }
    }

    /// The menu item: the time it was saved, in the launch sheet's format,
    /// so a player picking a slot to overwrite can tell them apart.
    func menuTitle(_ info: StateFile.Info?, now: Date = .now) -> String {
        "\(title) · \(info.map { Self.savedAt($0.savedAt, now: now) } ?? "Empty")"
    }

    /// When a state was saved, for the menus and the launch sheet: "Today
    /// 14:32" and "Yesterday 09:05" for the two days a player thinks of
    /// that way, the abbreviated date and time before that. The time keeps
    /// the system's short style.
    static func savedAt(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Today \(time)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday \(time)")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct SavedState: Equatable {
    let source: StateSource
    let info: StateFile.Info
}

/// Every saved machine of every game, on disk.
///
/// **Resume** is the machine's own bookmark:
/// `Application Support/Substation/ResumeStates/<key>.state` + `.png`. The
/// player loads it but never saves into it. Every write keeps the one it
/// replaces as `<key>.prev.*`, so a resume written at a bad moment can be
/// undone: the new state is staged as `<key>.new.*`, the current one renamed
/// to previous, then the staged one renamed into place. A crash leaves the
/// old resume (after staging) or a previous with no resume (after the first
/// rename), never nothing.
///
/// **Slots** are the player's: `SaveStates/<key>/slot<N>.*`, N in 1...6.
/// Nothing automatic writes one, and Delete & Boot never removes one.
///
/// Keyed on the game's FIRST disc, so a multi-disc game has one set, and a
/// state's own header says which disc was in the tray. Serial first, path
/// hash for a disc that names none: the `CoverStore` rule, so a rip that is
/// moved or renamed keeps its states.
///
/// Every write goes through one queue: an exit save and a timed auto-save
/// can arrive together from two threads, and the rotation is three steps.
final class SaveStateStore: Sendable {
    typealias Info = StateFile.Info

    private let resumeDirectory: URL
    private let slotsDirectory: URL
    private let queue = DispatchQueue(label: "PS1.SaveStateStore")

    init(resumeDirectory: URL? = nil, slotsDirectory: URL? = nil) {
        self.resumeDirectory = resumeDirectory ?? AppSupport.directory("ResumeStates")
        self.slotsDirectory = slotsDirectory ?? AppSupport.directory("SaveStates")
    }

    static func key(for game: GameEntry) -> String {
        game.serial ?? game.pathKey
    }

    func file(_ source: StateSource, key: String) -> StateFile {
        switch source {
        case .resume:
            StateFile(directory: resumeDirectory, stem: key)
        case .previous:
            StateFile(directory: resumeDirectory, stem: "\(key).prev")
        case .slot(let n):
            StateFile(directory: slotsDirectory.appendingPathComponent(key, isDirectory: true),
                      stem: "slot\(n)")
        }
    }

    func info(_ source: StateSource, key: String) -> Info? {
        file(source, key: key).info
    }

    func load(_ source: StateSource, key: String) -> Data? {
        file(source, key: key).load()
    }

    /// Every state the game has, in menu order: resume, previous, slots.
    func saved(key: String) -> [SavedState] {
        ([.resume, .previous] + StateSource.slots.map { .slot($0) }).compactMap { source in
            info(source, key: key).map { SavedState(source: source, info: $0) }
        }
    }

    func saveResume(state: Data, thumbnail: Data?, key: String) throws {
        try queue.sync {
            let current = file(.resume, key: key)
            let staged = StateFile(directory: resumeDirectory, stem: "\(key).new")
            try staged.write(state: state, thumbnail: thumbnail)
            // Only a resume that exists is rotated: after a crash mid-rotation
            // the previous is the only state left, and it must survive.
            if current.info != nil { try current.move(to: file(.previous, key: key)) }
            try staged.move(to: current)
        }
    }

    func saveSlot(_ n: Int, state: Data, thumbnail: Data?, key: String) throws {
        precondition(StateSource.slots.contains(n), "slot \(n) is outside \(StateSource.slots)")
        try queue.sync {
            try file(.slot(n), key: key).write(state: state, thumbnail: thumbnail)
        }
    }

    /// Delete & Boot: the resume and its previous, never a slot.
    func removeResume(_ key: String) {
        queue.sync {
            file(.resume, key: key).remove()
            file(.previous, key: key).remove()
            StateFile(directory: resumeDirectory, stem: "\(key).new").remove()
        }
    }
}
