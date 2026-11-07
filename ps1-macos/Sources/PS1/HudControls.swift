import AppKit
import SwiftUI

/// The speed tab's geometry and its pop-up-button rule, apart from the view
/// so both are tested without a window. Points are in the speed button's own
/// space: the button is y 0...`seat`, the separator sits just above it, and
/// the values rise from 1× to 4× above that.
enum SpeedPick {
    static let width: CGFloat = 40
    /// The tab's margin either side of the button.
    static let pad: CGFloat = Design.Spacing.xs
    static let slot: CGFloat = 28
    static let seat: CGFloat = 30
    static let separator: CGFloat = Design.Spacing.s
    /// The bar's vertical padding, between the button and the bar's edge.
    static let barPad: CGFloat = Design.Spacing.m
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

/// The bar's buttons, as Apple Music's player draws them: nothing on hover,
/// a dark disc only while the button is held down, dimmed when disabled. Over
/// a moving picture a hover highlight follows the pointer across the bar and
/// reads as noise.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration)
    }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(Capsule()
                    .fill(configuration.isPressed ? Design.Dim.scrim : .clear)
                    .frame(width: IconButton.width, height: IconButton.height))
                .opacity(isEnabled ? 1 : Design.disabledOpacity)
        }
    }
}

/// One of the bar's buttons: 32×30, a capsule for both its hit area and its
/// press fill. The
/// speaker's seat is the same width so the pitch around it stays even.
struct IconButton: View {
    static let width: CGFloat = 32
    static let height: CGFloat = 30

    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .symbolVariant(.fill)
                // Animated on the symbol itself: pause and full screen
                // change from keys and menus too, outside any transaction.
                .contentTransition(reduceMotion ? .identity
                                                : .symbolEffect(.replace.magic(fallback: .downUp)))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: symbol)
                .frame(width: Self.width, height: Self.height)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
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

    /// The tab's top corners; the highlight inside it is concentric.
    static let cornerRadius = Design.Radius.panel
    /// The concave joint where the tab leaves the bar: a cover's corner.
    static let fillet = Design.Radius.tile

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
            let fillet = min(Self.fillet, rise / 2)
            let corner = min(Self.cornerRadius, rise / 2, tabWidth / 2)
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
    @Bindable var game: OpenGame
    /// The speed under the pointer, 0-based, while pressing or hovering.
    @State private var tracking: Int?
    @State private var pressing = false
    @State private var wasOpen = false
    @State private var dragged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let space = "speed"
    private var open: Bool { game.isOpen(.speedTab) }

    var body: some View {
        Text("\(model.speed)×")
            .font(.body.weight(.semibold).monospacedDigit())
            .frame(width: SpeedPick.width, height: SpeedPick.seat)
            .contentShape(.rect)
            .gesture(press)
            .help("Emulation Speed (hold Tab to fast-forward)")
            .accessibilityLabel("Emulation speed")
            .accessibilityValue("\(model.speed) times")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { game.setSurface(.speedTab, open: !open) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.speed = min(model.speed + 1, SpeedSetting.choices.upperBound)
                case .decrement: model.speed = max(model.speed - 1, SpeedSetting.choices.lowerBound)
                @unknown default: break
                }
            }
            .overlay(alignment: .bottom) {
                if open {
                    values.offset(y: -SpeedPick.seat).transition(.opacity)
                }
            }
            .coordinateSpace(.named(space))
            .anchorPreference(key: SpeedTabKey.self, value: .bounds) {
                SpeedTab(anchor: $0, rise: open ? SpeedPick.rise : 0)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: open)
            // The model closes the tab when the pointer strays too far,
            // through the same hover it uses to show the HUD.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(GameScreen.space)) } action: {
                game.speedTabFrame = SpeedPick.tabFrame(around: $0)
            }
    }

    private var values: some View {
        VStack(spacing: 0) {
            ForEach([4, 3, 2, 1], id: \.self) { n in
                Text("\(n)×")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .frame(width: SpeedPick.width, height: SpeedPick.slot)
                    .background { highlight(n) }
            }
            Rectangle().fill(.separator)
                .frame(width: SpeedPick.width - 2 * Design.Spacing.s, height: Design.hairline)
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

    /// Under the pointer brightest, the current speed faintly. Concentric
    /// with the tab's corner, `SpeedPick.pad` inside it.
    @ViewBuilder private func highlight(_ n: Int) -> some View {
        let shape = Design.cardShape(Design.concentric(BarShape.cornerRadius, inset: SpeedPick.pad))
        if tracking == n - 1 {
            shape.fill(.fill)
        } else if model.speed == n {
            shape.fill(.fill.tertiary)
        }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if !pressing {
                    pressing = true
                    wasOpen = open
                    dragged = false
                    game.setSurface(.speedTab, open: true)
                }
                if abs(v.translation.width) + abs(v.translation.height) > 4 { dragged = true }
                tracking = SpeedPick.index(at: v.location)
            }
            .onEnded { v in
                pressing = false
                let outcome = SpeedPick.outcome(picked: SpeedPick.index(at: v.location),
                                                dragged: dragged, wasOpen: wasOpen)
                if let speed = outcome.speed { model.speed = speed }
                game.setSurface(.speedTab, open: outcome.open)
                tracking = nil
            }
    }
}
