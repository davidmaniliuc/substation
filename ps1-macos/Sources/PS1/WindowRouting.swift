import AppKit
import SwiftUI

/// A launch's resume sheet and its alerts. Presented by ONE window at a
/// time: the library's for a click in the library, the game's for a disc
/// opened from outside it in New Window mode (`launchInGameWindow`), so a
/// Finder open never needs the library on screen. That launch's resume
/// sheet is the exception: it floats in `LaunchPanel`, with no window.
struct LaunchDialogs: ViewModifier {
    @Bindable var model: EmulatorViewModel
    let active: Bool
    /// The window's width: the resume sheet shows as many tiles as it allows.
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if active, !model.resumeInPanel, let offer = model.resumeOffer {
                    GlassDialog { ResumePrompt(model: model, offer: offer, available: width) }
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
            .alert("Opened as a raw .bin", isPresented: .init(
                get: { active && model.showRawBinWarning },
                set: { model.showRawBinWarning = $0 }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("A raw .bin is a single data track at LBA 0 and cannot represent audio tracks. If this game has CD-DA music, it will be silent. Open the .cue instead.")
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
    let available: CGFloat

    var body: some View {
        ResumePromptSheet(offer: offer, available: available,
                          choose: { model.chooseResume($0) },
                          delete: { model.deleteOfferedState($0) })
    }
}

/// Opens the game window for each game or launch that goes in it, and brings
/// it forward when its exit sheet goes up. On every window the app has, since
/// either of the other two may be closed: `openWindow` is the environment's,
/// not the window's.
struct GameWindowOpener: ViewModifier {
    let model: EmulatorViewModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: model.gameWindowContent) { _, content in
                if content != nil { openWindow(id: GameWindow.id) }
            }
            .onChange(of: model.exitPrompt) { _, prompt in
                if prompt != nil && model.gameWindowShown { openWindow(id: GameWindow.id) }
            }
    }
}

/// The library's window. Only needed to close it once at launch: a disc
/// Finder opened the app with, in New Window mode, plays without it.
@MainActor
enum LibraryWindow {
    static weak var current: NSWindow?
    /// Set at launch; the game window acts on it once it is on screen, so
    /// the app always has a window and never reads as closed.
    private static var closeWhenGameWindowOpens = false

    /// The library hides at once and closes once the game window, or the
    /// floating resume sheet, is up.
    static func giveWayToGameWindow() {
        closeWhenGameWindowOpens = true
        current?.alphaValue = 0
    }

    /// Called by the game window, or `LaunchPanel`, as it reaches the screen.
    static func gameWindowOpened() {
        guard closeWhenGameWindowOpens else { return }
        closeWhenGameWindowOpens = false
        // A turn later: not from inside AppKit's own window setup.
        DispatchQueue.main.async {
            current?.close()
            current?.alphaValue = 1
        }
    }

    struct Marker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Probe() }

        func updateNSView(_ nsView: NSView, context: Context) {
            if let window = nsView.window { LibraryWindow.current = window }
        }

        private final class Probe: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                LibraryWindow.current = window
                if LibraryWindow.closeWhenGameWindowOpens { window.alphaValue = 0 }
            }
        }
    }
}
