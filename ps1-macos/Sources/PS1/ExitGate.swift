import Foundation

/// Every way of leaving a running game, and the question the exit sheet asks
/// for each.
enum ExitIntent: Equatable {
    case quit
    case closeWindow
    case eject
    case open(URL)

    var question: String {
        switch self {
        case .quit, .closeWindow: "Are you sure you want to exit the application?"
        case .eject, .open: "Are you sure you want to exit the game?"
        }
    }
}

enum ExitDecision {
    /// Nothing is running: the caller goes ahead at once.
    case proceed
    /// The sheet is now up; the caller waits for Yes or No.
    case prompted
    /// A sheet is ALREADY up. Nothing changed. For ⌘Q the caller must answer
    /// `.terminateCancel`: a `.terminateLater` here would never be replied to.
    case busy
}

/// Which leave-request the exit sheet is answering. A value type so the
/// one-sheet-at-a-time rule is reachable from a test without a window.
struct ExitGate {
    private(set) var pending: ExitIntent?

    mutating func request(_ intent: ExitIntent, playing: Bool) -> ExitDecision {
        guard playing else { return .proceed }
        guard pending == nil else { return .busy }
        pending = intent
        return .prompted
    }

    /// Yes: hands back what to finish.
    mutating func take() -> ExitIntent? {
        defer { pending = nil }
        return pending
    }

    /// No: hands back what was declined (a declined ⌘Q needs its reply).
    mutating func cancel() -> ExitIntent? {
        defer { pending = nil }
        return pending
    }
}

/// Finishes an exit exactly once. The save's completion and a fallback timer
/// both fire it, so a save the emulator thread never services (a wedged
/// frame), still lets the app quit.
@MainActor
final class ExitCompletion {
    private var body: (() -> Void)?

    init(_ body: @escaping () -> Void) { self.body = body }

    func fire() {
        let run = body
        body = nil
        run?()
    }
}
