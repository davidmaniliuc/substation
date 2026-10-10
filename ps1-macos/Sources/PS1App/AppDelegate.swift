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
/// window, or the floating resume sheet (`LaunchPanel`), is up. A disc that
/// arrives before the model, or before `applicationDidFinishLaunching`, is
/// the launch's own. `launchIsDefaultUserInfoKey` cannot say it: a plain
/// `open -a` reports a non-default launch too.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EmulatorViewModel? {
        didSet {
            guard let model else { return }
            launchPanel.follow(model)
            guard let url = pendingDisc else { return }
            pendingDisc = nil
            openDisc(url, in: model, launchedApp: true)
        }
    }
    private let launchPanel = LaunchPanel()

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

    /// Takes Finder's open-documents event before SwiftUI does. Left to
    /// SwiftUI, it routes the open to a scene: on a warm open that CLOSED the
    /// library window (`activateWindowForExternalEvent`, caught at a
    /// breakpoint), and a scene matching no events opens no window at all
    /// on a cold launch for a disc, so the model never arrived. Taken here,
    /// the launch is a plain one to SwiftUI and the disc is ours alone.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let urls = list.numberOfItems == 0
            ? [list.fileURLValue].compactMap { $0 }
            : (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }
        open(urls)
    }

    /// Only the first disc of a multi-file open: there is one drive.
    private func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        if let model {
            openDisc(url, in: model, launchedApp: !finishedLaunching)
        } else {
            pendingDisc = url
        }
    }

    private func openDisc(_ url: URL, in model: EmulatorViewModel, launchedApp: Bool) {
        model.open(url)
        if launchedApp && (model.gameWindowShown || model.resumeInPanel) {
            LibraryWindow.giveWayToGameWindow()
        }
    }
}
