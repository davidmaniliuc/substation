import AppIntents
import AppKit

/// ⌘Q while a game runs asks first. `.terminateLater` holds the quit open
/// until the exit sheet answers through `terminateReply`.
///
/// Also receives discs Finder and Spotlight open with the app
/// (`CFBundleDocumentTypes` in `Info.plist`).
///
/// A launch FOR a disc in New Window mode never shows the library: the
/// window SwiftUI opens at launch hides at once and closes once the game's
/// window, or the floating resume sheet (`LaunchPanel`), is up. In Library
/// Window mode the sheet floats too, and the library stays: the game plays
/// there. A disc that
/// arrives before `applicationDidFinishLaunching` is the launch's own. `launchIsDefaultUserInfoKey` cannot say it: a plain
/// `open -a` reports a non-default launch too.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's one model, for its whole process. Here rather than on the
    /// `App`, so a disc can be opened before SwiftUI has built a window.
    let model = EmulatorViewModel()
    private let launchPanel = LaunchPanel()

    private var finishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.exitConfirmed else { return .terminateNow }
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
        launchPanel.follow(model)
        // Before any intent can run: Spotlight or Siri may be what launched us.
        let model = model
        AppDependencyManager.shared.add(dependency: model)
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
        model.open(url)
        if !finishedLaunching && (model.gameWindowShown || (model.launchInGameWindow && model.resumeInPanel)) {
            LibraryWindow.giveWayToGameWindow()
        }
    }
}
