import AppKit
import PS1

/// ⌘Q while a game runs asks first. `.terminateLater` holds the quit open
/// until the exit sheet answers through `terminateReply`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EmulatorViewModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.exitConfirmed else { return .terminateNow }
        switch model.requestExit(.quit) {
        case .proceed:
            return .terminateNow
        case .busy:
            return .terminateCancel
        case .prompted:
            model.terminateReply = { NSApp.reply(toApplicationShouldTerminate: $0) }
            return .terminateLater
        }
    }
}
