import AppKit

/// ⌘Q while a game runs asks first. `.terminateLater` holds the quit open
/// until the exit sheet answers through `terminateReply`.
///
/// Also receives discs Finder opens with the app (`CFBundleDocumentTypes` in
/// `Info.plist`). On a cold launch that arrives before the window's
/// `onAppear` hands over the model, so the disc waits in `pendingDisc`.
///
/// A launch FOR a disc in New Window mode never shows the library: the
/// window SwiftUI opens at launch hides at once and closes once the game's
/// window is up. Measured, Finder's open arrives after the window and the
/// model but BEFORE `applicationDidFinishLaunching`, which is what marks it
/// as the launch's own. `launchIsDefaultUserInfoKey` cannot say it: a plain
/// `open -a` reports a non-default launch too.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EmulatorViewModel? {
        didSet {
            guard let model, let url = pendingDisc else { return }
            pendingDisc = nil
            openDisc(url, in: model)
        }
    }

    private var pendingDisc: URL?
    private var finishedLaunching = false

    /// `PS1_GPU_BENCH` turns the launch into a benchmark run: see `GpuBench`.
    /// The window still opens (SwiftUI owns the scene), and the process exits
    /// when the run finishes.
    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        _ = GpuBench.runFromEnvironment(ProcessInfo.processInfo.environment)
    }

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

    /// Only the first disc of a multi-file open: there is one drive.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { openDisc(url, in: model) } else { pendingDisc = url }
    }

    private func openDisc(_ url: URL, in model: EmulatorViewModel) {
        model.open(url)
        if !finishedLaunching && model.gameWindowShown { LibraryWindow.giveWayToGameWindow() }
    }
}
