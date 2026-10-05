import AppKit

/// ⌘Q while a game runs asks first. `.terminateLater` holds the quit open
/// until the exit sheet answers through `terminateReply`.
///
/// Also receives discs Finder opens with the app (`CFBundleDocumentTypes` in
/// `Info.plist`). On a cold launch that arrives before the window's
/// `onAppear` hands over the model, so the disc waits in `pendingDisc`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EmulatorViewModel? {
        didSet {
            guard let model, let url = pendingDisc else { return }
            pendingDisc = nil
            MainActor.assumeIsolated { model.open(url) }
        }
    }

    private var pendingDisc: URL?

    /// `PS1_GPU_BENCH` turns the launch into a benchmark run: see `GpuBench`.
    /// The window still opens (SwiftUI owns the scene), and the process exits
    /// when the run finishes.
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = GpuBench.runFromEnvironment(ProcessInfo.processInfo.environment)
    }

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

    /// Only the first disc of a multi-file open: there is one drive.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { model.open(url) } else { pendingDisc = url }
    }
}
