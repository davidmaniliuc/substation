import AppKit
import SwiftUI

/// The resume sheet of a disc opened from outside the library (Finder,
/// Spotlight, Open Disc) in New Window mode, floating on its own as a quick
/// entry panel does: no window, no traffic lights and no black picture behind
/// it, since there is no game yet to draw one. Shown while
/// `EmulatorViewModel.resumeInPanel` holds; a choice clears the offer, and the
/// game window opens for the game, or for an alert, from there.
///
/// Its modality is the sheet's own: Return resumes, Escape cancels, and the
/// panel floats above other apps' windows until one of them is chosen.
@MainActor
final class LaunchPanel {
    private weak var model: EmulatorViewModel?
    private var panel: Panel?
    /// Taken from the panel's own SwiftUI content as it first appears. The
    /// library has given way by the time a choice starts the game, so this
    /// is what opens the game window: a view in the ordered-out panel gets
    /// no update to run `GameWindowOpener` from.
    private var openWindow: OpenWindowAction?
    private var opened: EmulatorViewModel.GameWindowContent?

    func follow(_ model: EmulatorViewModel) {
        self.model = model
        track()
    }

    /// Re-armed on every change: `withObservationTracking` fires once.
    private func track() {
        guard let model else { return }
        let (shown, content) = withObservationTracking {
            (model.resumeInPanel, model.gameWindowContent)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.track() }
        }
        shown ? show(model) : hide()
        if content != opened, content != nil { openWindow?(id: GameWindow.id) }
        opened = content
    }

    private func show(_ model: EmulatorViewModel) {
        let panel = panel ?? makePanel(model)
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        panel.center()
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        LibraryWindow.gameWindowOpened()
        // The library closes a turn later, and on a cold launch it is the key
        // window: taken back after it, or the first Return is lost.
        DispatchQueue.main.async { if panel.isVisible { panel.makeKey() } }
    }

    /// At once, not faded: the offer that filled the card is already gone.
    private func hide() {
        panel?.orderOut(nil)
    }

    /// Built once and kept, with its content.
    private func makePanel(_ model: EmulatorViewModel) -> Panel {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let host = NSHostingView(rootView: PanelContent(
            model: model, available: screen?.visibleFrame.width ?? 1200,
            openWindow: { [weak self] in self?.openWindow = $0 }))
        let panel = Panel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: [.borderless, .fullSizeContentView],
                          backing: .buffered, defer: false)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Borderless, so it must be told it may take the keyboard: Return and
    /// Escape are the sheet's buttons.
    private final class Panel: NSPanel {
        override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                      backing: NSWindow.BackingStoreType, defer flag: Bool) {
            super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
            isOpaque = false
            backgroundColor = .clear
            // The card draws its own shadow inside the margin: a window
            // shadow follows the glass's translucent pixels and reads ragged.
            hasShadow = false
            level = .floating
            isMovableByWindowBackground = true
            isReleasedWhenClosed = false
            hidesOnDeactivate = false
            collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}

/// The card, with room around it for its shadow.
private struct PanelContent: View {
    let model: EmulatorViewModel
    let available: CGFloat
    let openWindow: (OpenWindowAction) -> Void
    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        ZStack {
            if let offer = model.resumeOffer {
                ResumePrompt(model: model, offer: offer, available: available)
                    .glassEffect(.regular, in: .rect(cornerRadius: glassDialogRadius))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    .padding(48)
                    .fixedSize()
            }
        }
        .onAppear { openWindow(openWindowAction) }
    }
}
