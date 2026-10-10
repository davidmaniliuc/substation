import AppKit
import SwiftUI

/// The game's name along the top, QuickTime style: plain text over a dark
/// gradient rather than glass, fading with the bar. Line 2 is whether the
/// core keeps up and how long this sitting has been. Fullscreen hides the
/// menu bar and with it the clock and the battery, so the strip gives both
/// back on its right.
struct TitleStrip: View {
    @Bindable var model: EmulatorViewModel
    let isFullScreen: Bool

    /// Clears the traffic lights, which share this band and fade with it.
    static let windowedLeading: CGFloat = 78
    static let fullScreenLeading: CGFloat = 20
    /// The height the badge stack drops by while the strip shows in
    /// fullscreen, where the clock owns the top-trailing corner.
    static let fullScreenClearance: CGFloat = 48

    var body: some View {
        // Every 30 s: "Playing for" counts minutes, and the clock shows them.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.discTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(status(at: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 16)
                if isFullScreen { clock(context.date) }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .padding(.leading, isFullScreen ? Self.fullScreenLeading : Self.windowedLeading)
        .padding(.trailing, 20)
        .padding(.top, 9)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    /// `60 FPS · Playing for 42 min`, with Paused in place of the count.
    /// Emulated frames, not presented ones: whether the core keeps up with
    /// the ~59.94 a real NTSC machine runs at.
    private func status(at _: Date) -> String {
        let rate = model.isPaused ? "Paused" : model.fps.map { "\(Int($0.rounded())) FPS" } ?? "… FPS"
        let played = PlayingFor.format(model.sessionPlayed(at: ProcessInfo.processInfo.systemUptime))
        return "\(rate) · Playing for \(played)"
    }

    private func clock(_ now: Date) -> some View {
        HStack(spacing: 10) {
            Text(now, format: .dateTime.hour().minute())
            if let battery = Battery.current() {
                HStack(spacing: 4) {
                    Image(systemName: battery.symbol)
                    Text("\(battery.percent)%")
                }
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
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
