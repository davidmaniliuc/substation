import AppKit
import SwiftUI

/// A launch's resume sheet and its alerts. Presented by ONE window at a
/// time: the library's for a click in the library, the game's for a disc
/// opened from outside it in New Window mode (`launchInGameWindow`), so a
/// Finder open never needs the library on screen. The resume sheet of any
/// launch from outside the library is the exception, in either mode: it
/// floats in `LaunchPanel`, with no window.
struct LaunchDialogs: ViewModifier {
    @Bindable var model: EmulatorViewModel
    let active: Bool
    /// The window's width: a narrow one leaves the sheet's screenshot out.
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if active, !model.resumeInPanel, let offer = model.resumeOffer {
                    // A click beside the card is Cancel, as Escape is.
                    ModalDialog(dismiss: { model.chooseResume(.cancel) }) {
                        ResumePrompt(model: model, offer: offer,
                                     showsHero: ResumePromptSheet.showsHero(inWindowWidth: width))
                    }
                }
            }
            .animation(.smooth(duration: 0.2), value: model.resumeOffer?.id)
            .alert("Could not load", isPresented: .init(
                get: { active && model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("Opened Without Audio Tracks", isPresented: .init(
                get: { active && model.showRawBinWarning },
                set: { model.showRawBinWarning = $0 }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("A lone .bin or .img file holds one data track, so music this game plays from the disc will be silent. Open the game’s .cue file instead, or its .ccd file for a CloneCD rip.")
            }
            // `presenting:` hands each button the failure it was raised for, so
            // Start Fresh still has its URL whichever runs first: the action or
            // the dismissal clearing `resumeFailure`.
            .alert("Could not resume", isPresented: .init(
                get: { active && model.resumeFailure != nil },
                set: { if !$0 { model.resumeFailure = nil } }
            ), presenting: model.resumeFailure) { failure in
                Button("Start Fresh") {
                    model.resumeFailure = nil
                    model.load(disc: failure.freshBoot)
                }
                Button("Cancel", role: .cancel) { model.cancelResumeFailure() }
            } message: { failure in
                Text(failure.message)
            }
    }
}

/// The resume sheet bound to the model, wherever it is drawn.
struct ResumePrompt: View {
    let model: EmulatorViewModel
    let offer: ResumeOffer
    /// The floating panel always has room for it.
    var showsHero = true

    var body: some View {
        ResumePromptSheet(offer: offer, cover: model.coverURL(for: offer.first), showsHero: showsHero,
                          choose: { model.chooseResume($0) },
                          delete: { model.deleteOfferedState($0) })
    }
}

/// Opens or brings forward the game window the model asks for: a new game's,
/// one whose exit sheet went up, an open game opened again, and the window
/// for a launch's alerts. On every window the app has, since any of the
/// others may be closed: `openWindow` is the environment's, not the window's.
struct GameWindowOpener: ViewModifier {
    let model: EmulatorViewModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: model.windowRequest) { _, request in
                if let request { openWindow(value: request.content) }
            }
            .onChange(of: model.launchWindowShown) { _, shown in
                if shown { openWindow(value: GameWindowContent.launch) }
            }
            .onChange(of: model.libraryRequests) { openWindow(id: LibraryWindow.id) }
    }
}

/// The library's window. Only needed to close it once at launch: a disc
/// Finder opened the app with, in New Window mode, plays without it.
@MainActor
enum LibraryWindow {
    static let id = "main"
    static weak var current: NSWindow?
    /// Set at launch: the library stays hidden, and closes once the game
    /// window or the floating resume sheet is up, so the app always has a
    /// window and never reads as closed.
    private static var givingWay = false
    /// What it gives way to is on screen. A launch that did not activate the
    /// app (Spotlight) may build the library only AFTER that, so the
    /// library's own arrival closes it too.
    private static var replacementUp = false

    /// The library hides at once and closes once the game window, or the
    /// floating resume sheet, is up.
    static func giveWayToGameWindow() {
        givingWay = true
        current?.alphaValue = 0
    }

    /// Called by the game window, or `LaunchPanel`, as it reaches the screen.
    static func gameWindowOpened() {
        guard givingWay else { return }
        replacementUp = true
        closeSoon()
    }

    /// A turn later: not from inside AppKit's own window setup.
    private static func closeSoon() {
        DispatchQueue.main.async {
            guard givingWay, replacementUp, let window = current else { return }
            givingWay = false
            replacementUp = false
            window.close()
            window.alphaValue = 1
        }
    }

    struct Marker: NSViewRepresentable {
        /// The window came forward: a game playing in it runs.
        let becameKey: () -> Void

        func makeNSView(context: Context) -> NSView {
            let probe = Probe()
            probe.becameKey = becameKey
            return probe
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            (nsView as? Probe)?.becameKey = becameKey
            if let window = nsView.window { LibraryWindow.current = window }
        }

        private final class Probe: NSView {
            var becameKey: (() -> Void)?
            private var observer: NSObjectProtocol?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                LibraryWindow.current = window
                if LibraryWindow.givingWay {
                    window.alphaValue = 0
                    LibraryWindow.closeSoon()
                }
                observer.map(NotificationCenter.default.removeObserver)
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.becameKey?() } }
            }
        }
    }
}
