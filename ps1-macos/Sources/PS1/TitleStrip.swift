import AppKit
import SwiftUI

/// The game's name along the top, QuickTime style: plain text over a dark
/// gradient rather than glass, fading with the bar. Line 2 is whether the
/// core keeps up and how long this sitting has been.
struct TitleStrip: View {
    @Bindable var model: EmulatorViewModel
    let isFullScreen: Bool
    /// Where the traffic lights sit, measured: the main window's toolbar
    /// puts them at 19 pt and the game window's bare title bar at 9.
    @State private var lights: CGRect?

    static let fullScreenLeading: CGFloat = 20
    static let fullScreenTop: CGFloat = 9
    /// From the traffic lights' bottom edge to the title's.
    static let belowLights: CGFloat = 8
    static let trailing: CGFloat = 20

    var body: some View {
        // Every 30 s: "Playing for" counts minutes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(model.discTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(status(at: context.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        // Windowed, under the traffic lights and level with their left
        // edge; they share this band and fade with it.
        .padding(.leading, windowed.map(\.minX) ?? Self.fullScreenLeading)
        .padding(.trailing, Self.trailing)
        .padding(.top, windowed.map { $0.maxY + Self.belowLights } ?? Self.fullScreenTop)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .background(TrafficLightReader { lights = $0 })
    }

    private var windowed: CGRect? { isFullScreen ? nil : lights }

    /// `60 FPS · Playing for 42 min`, with Paused in place of the count.
    /// Emulated frames, not presented ones: whether the core keeps up with
    /// the ~59.94 a real NTSC machine runs at.
    private func status(at _: Date) -> String {
        let rate = model.isPaused ? "Paused" : model.fps.map { "\(Int($0.rounded())) FPS" } ?? "… FPS"
        let played = PlayingFor.format(model.sessionPlayed(at: ProcessInfo.processInfo.systemUptime))
        return "\(rate) · Playing for \(played)"
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
/// transition counts as the state it is heading to.
struct FullScreenReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.changed = changed
    }

    private final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            changed?(window.styleMask.contains(.fullScreen))
            let states: [(Notification.Name, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true),
                (NSWindow.didEnterFullScreenNotification, true),
                (NSWindow.willExitFullScreenNotification, false),
                (NSWindow.didExitFullScreenNotification, false),
            ]
            for (name, state) in states {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.changed?(state) }
                })
            }
        }
    }
}
