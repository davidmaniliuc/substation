import AppKit
import SwiftUI

/// The speed tab's geometry and its pop-up-button rule, apart from the view
/// so both are tested without a window. Points are in the speed button's own
/// space: the button is y 0...`seat`, the separator sits just above it, and
/// the values rise from 1× to 4× above that.
enum SpeedPick {
    static let width: CGFloat = 40
    /// The tab's margin either side of the button.
    static let pad: CGFloat = 4
    static let slot: CGFloat = 28
    static let seat: CGFloat = 30
    static let separator: CGFloat = 9
    /// The bar's vertical padding, between the button and the bar's edge.
    static let barPad: CGFloat = 10
    /// How far the tab rises above the bar's top edge.
    static let rise: CGFloat = 4 * slot + separator + pad - barPad
    /// How far the pointer may stray beyond the tab before it closes.
    static let tolerance: CGFloat = 40

    struct Outcome: Equatable {
        let speed: Int?
        let open: Bool
    }

    /// Which speed a point is over, 0-based (0 is 1×), or nil.
    static func index(at p: CGPoint) -> Int? {
        guard p.x > -pad - 6, p.x < width + pad + 6, p.y < -separator else { return nil }
        let i = Int(((-p.y - separator) / slot).rounded(.down))
        return (0...3).contains(i) ? i : nil
    }

    /// What a press does when it ends: a value picked sets it and closes; a
    /// drag released on nothing closes; a plain click opens the tab for a
    /// second click, or closes it when it was already open.
    static func outcome(picked: Int?, dragged: Bool, wasOpen: Bool) -> Outcome {
        if let picked { return Outcome(speed: picked + 1, open: false) }
        return Outcome(speed: nil, open: !(dragged || wasOpen))
    }

    /// The whole tab, open, around a button whose frame is `button`: what the
    /// pointer may stray `tolerance` beyond.
    static func tabFrame(around button: CGRect) -> CGRect {
        CGRect(x: button.minX - pad, y: button.minY - rise - barPad,
               width: button.width + 2 * pad, height: button.height + rise + 2 * barPad)
    }
}

/// A soft capsule behind a control while the pointer is over it.
struct HoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration) }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.26 : hover ? 0.14 : 0)))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// One of the bar's buttons: 32×30, wide enough for its hover capsule. The
/// speaker's seat is the same width so the pitch around it stays even.
struct IconButton: View {
    static let width: CGFloat = 32
    static let height: CGFloat = 30

    let symbol: String
    let help: String
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                // Animated on the symbol itself: pause and full screen
                // change from keys and menus too, outside any transaction.
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                .animation(.snappy(duration: 0.25), value: symbol)
                .frame(width: Self.width, height: Self.height)
                .contentShape(.capsule)
        }
        .buttonStyle(HoverStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Where the speed button sits in the bar, and how far its tab rises above
/// the bar's top edge (0 while closed), so the bar can draw the tab as part
/// of its OWN glass shape.
struct SpeedTab: Equatable {
    var anchor: Anchor<CGRect>?
    var rise: CGFloat = 0
}

struct SpeedTabKey: PreferenceKey {
    static let defaultValue = SpeedTab()
    static func reduce(value: inout SpeedTab, nextValue: () -> SpeedTab) {
        let next = nextValue()
        if next.anchor != nil { value = next }
    }
}

/// The bar's capsule with the speed tab rising out of it, as ONE outline:
/// concave fillets where the tab leaves the bar, rounded corners at its top.
/// The bar occupies the bottom `barHeight` of the rect, the tab the space
/// above. One shape, so the tab reads as the bar's own glass growing rather
/// than a second piece laid on it.
struct BarShape: Shape {
    var tabMinX: CGFloat
    var tabWidth: CGFloat
    var rise: CGFloat
    /// The tab's full rise. Liquid Glass thickens with the size of its
    /// SHAPE's bounds, not the view's frame, so an invisible speck at this
    /// height keeps the bar's material the same open or closed instead of
    /// frosting over as the tab grows (measured on screenshots).
    var reach: CGFloat
    var barHeight: CGFloat

    var animatableData: CGFloat {
        get { rise }
        set { rise = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = rect.maxY - barHeight
        let bottom = rect.maxY
        let r = barHeight / 2
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: top))
        if rise > 0.5 {
            let l = tabMinX, rr = tabMinX + tabWidth, t = top - rise
            let fillet = min(10, rise / 2)
            let corner = min(14, rise / 2, tabWidth / 2)
            p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: l, y: t), radius: fillet)
            p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: rr, y: t), radius: corner)
            p.addArc(tangent1End: CGPoint(x: rr, y: t), tangent2End: CGPoint(x: rr, y: top), radius: corner)
            p.addArc(tangent1End: CGPoint(x: rr, y: top), tangent2End: CGPoint(x: rect.maxX, y: top), radius: fillet)
        }
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: top), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        p.closeSubpath()
        p.addRect(CGRect(x: rect.midX, y: top - reach, width: 0.01, height: 0.01))
        return p
    }
}

/// The emulation speed, the pop-up-button way: press on the value, slide to
/// a speed, let go. A plain click opens it for a second click instead, and a
/// click on the value again closes it. The bar draws the tab as part of its
/// own glass; this view only places the values in it. It sets the persisted
/// base speed: holding Tab is shown by the badge, never here.
struct SpeedButton: View {
    @Bindable var model: EmulatorViewModel
    /// The speed under the pointer, 0-based, while pressing or hovering.
    @State private var tracking: Int?
    @State private var pressing = false
    @State private var wasOpen = false
    @State private var dragged = false
    @State private var hovering = false

    private let space = "speed"
    private var open: Bool { model.isOpen(.speedTab) }

    var body: some View {
        Text("\(model.speed)×")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .frame(width: SpeedPick.width, height: SpeedPick.seat)
            .background(Capsule().fill(.white.opacity(hovering && !open ? 0.14 : 0)))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .gesture(press)
            .help("Emulation Speed (hold Tab to fast-forward)")
            .accessibilityLabel("Emulation speed \(model.speed) times")
            .overlay(alignment: .bottom) {
                if open {
                    values.offset(y: -SpeedPick.seat).transition(.opacity)
                }
            }
            .coordinateSpace(.named(space))
            .anchorPreference(key: SpeedTabKey.self, value: .bounds) {
                SpeedTab(anchor: $0, rise: open ? SpeedPick.rise : 0)
            }
            .animation(.snappy(duration: 0.22), value: open)
            // The model closes the tab when the pointer strays too far,
            // through the same hover it uses to show the HUD.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(GameScreen.space)) } action: {
                model.speedTabFrame = SpeedPick.tabFrame(around: $0)
            }
    }

    private var values: some View {
        VStack(spacing: 0) {
            ForEach([4, 3, 2, 1], id: \.self) { n in
                Text("\(n)×")
                    .font(.system(size: 13, weight: model.speed == n ? .bold : .semibold).monospacedDigit())
                    .frame(width: SpeedPick.width, height: SpeedPick.slot)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(highlight(n))))
            }
            Rectangle().fill(.white.opacity(0.3)).frame(width: SpeedPick.width - 14, height: 1)
                .frame(height: SpeedPick.separator)
        }
        .padding(.top, SpeedPick.pad)
        .contentShape(.rect)
        .gesture(press)
        .onContinuousHover(coordinateSpace: .named(space)) { phase in
            guard !pressing else { return }
            if case .active(let p) = phase { tracking = SpeedPick.index(at: p) } else { tracking = nil }
        }
    }

    /// Under the pointer brightest, the current speed faintly.
    private func highlight(_ n: Int) -> Double {
        if tracking == n - 1 { return 0.30 }
        return model.speed == n ? 0.12 : 0
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if !pressing {
                    pressing = true
                    wasOpen = open
                    dragged = false
                    model.setSurface(.speedTab, open: true)
                }
                if abs(v.translation.width) + abs(v.translation.height) > 4 { dragged = true }
                tracking = SpeedPick.index(at: v.location)
            }
            .onEnded { v in
                pressing = false
                let outcome = SpeedPick.outcome(picked: SpeedPick.index(at: v.location),
                                                dragged: dragged, wasOpen: wasOpen)
                if let speed = outcome.speed { model.speed = speed }
                model.setSurface(.speedTab, open: outcome.open)
                tracking = nil
            }
    }
}
