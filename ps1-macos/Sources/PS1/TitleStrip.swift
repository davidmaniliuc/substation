import AppKit
import SwiftUI

/// The game's name along the top, beside the traffic lights as a unified
/// toolbar places a window's title, over the blurred band the display
/// shader draws behind it (`ToolbarBand`). Fades with the bar. Line 2 is
/// whether the core keeps up and how long this sitting has been.
struct TitleStrip: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame
    let isFullScreen: Bool
    /// Where the traffic lights sit, measured: both windows carry a unified
    /// toolbar, which centres them in a 52 pt band.
    @State private var lights: CGRect?

    static let fullScreenLeading: CGFloat = 20
    static let fullScreenTop: CGFloat = 9
    /// From the zoom button's trailing edge to the title, a toolbar item's gap.
    static let besideLights: CGFloat = 14
    static let trailing: CGFloat = 20

    var body: some View {
        // Every 30 s: "Playing for" counts minutes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // The library's title and count: a toolbar's title and subtitle.
            VStack(alignment: .leading, spacing: 0) {
                Text(game.discTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(status(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        // Windowed, centred on the traffic lights' line and just past the
        // zoom button; they share this band and fade with it.
        .frame(height: windowed.map { $0.midY * 2 }, alignment: .center)
        .padding(.leading, windowed.map { $0.maxX + Self.besideLights } ?? Self.fullScreenLeading)
        .padding(.trailing, Self.trailing)
        .padding(.top, windowed == nil ? Self.fullScreenTop : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .background(TrafficLightReader { lights = $0 })
    }

    private var windowed: CGRect? { isFullScreen ? nil : lights }

    /// `60 FPS · Playing for 42 min`, with Paused in place of the rate.
    /// Emulated frames, not presented ones: whether the core keeps up with
    /// the ~59.94 a real NTSC machine runs at.
    private func status(at _: Date) -> String {
        let rate = game.showsPaused ? "Paused" : game.fps.map { "\(Int($0.rounded())) FPS" } ?? "… FPS"
        return PlayingFor.status(rate: rate, played: game.sessionPlayed(at: ProcessInfo.processInfo.systemUptime))
    }
}

/// Reports the traffic lights' extent, top-down from the window's top-left,
/// whenever the close or zoom button moves: showing or hiding a toolbar
/// moves them.
private struct TrafficLightReader: NSViewRepresentable {
    let changed: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.changed = changed
    }

    private final class Probe: NSView {
        var changed: ((CGRect) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for button in [window.standardWindowButton(.closeButton),
                           window.standardWindowButton(.zoomButton)].compactMap({ $0 }) {
                button.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: button, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            guard let window, let content = window.contentView,
                  let close = window.standardWindowButton(.closeButton),
                  let zoom = window.standardWindowButton(.zoomButton) else { return }
            let span = close.convert(close.bounds, to: nil).union(zoom.convert(zoom.bounds, to: nil))
            let height = content.bounds.height
            changed?(CGRect(x: span.minX, y: height - span.maxY,
                            width: span.width, height: span.height))
        }
    }
}

/// Reports whether its window is fullscreen. From the four transition
/// notifications, filtered on its own window, never from `styleMask`, which
/// AppKit clears part way through an exit (see `WindowConfigurator`). A
/// transition counts as the state it is heading to; `settled` is true only
/// once the window has stopped moving (the DID notifications).
struct FullScreenReader: NSViewRepresentable {
    let changed: (_ fullScreen: Bool, _ settled: Bool) -> Void

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.changed = changed
    }

    private final class Probe: NSView {
        var changed: ((Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            changed?(window.styleMask.contains(.fullScreen), true)
            let states: [(Notification.Name, Bool, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true, false),
                (NSWindow.didEnterFullScreenNotification, true, true),
                (NSWindow.willExitFullScreenNotification, false, false),
                (NSWindow.didExitFullScreenNotification, false, true),
            ]
            for (name, state, settled) in states {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.changed?(state, settled) }
                })
            }
        }
    }
}
