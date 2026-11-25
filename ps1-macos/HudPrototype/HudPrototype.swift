// PROTOTYPE, throwaway. In-game HUD round 2: two refined bars (A, B), both
// opening C's pause menu; the speed pill; the app's own Apple Music volume
// slider (VolumeControl*.swift are compiled in from Sources/PS1).
// Nothing here is wired to the core. Run: ps1-macos/HudPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Fake data

struct Game: Identifiable, Hashable {
    let id: String
    let title: String
    let image: NSImage
}

func loadGames() -> [Game] {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Substation/ResumeStates")
    let names = ["SCUS-94163": "Final Fantasy VII", "SCUS-94244": "Crash Bandicoot: Warped",
                 "SCES-00344": "Crash Bandicoot", "SLUS-00707": "Silent Hill"]
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files
        .filter { $0.pathExtension == "png" && !$0.lastPathComponent.contains(".prev") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { url in
            let serial = url.deletingPathExtension().lastPathComponent
            guard let image = NSImage(contentsOf: url) else { return nil }
            return Game(id: serial, title: names[serial] ?? serial, image: image)
        }
}

struct Notice: Equatable {
    let icon: String
    let text: String
}

enum Variant: String, CaseIterable, Identifiable {
    case final = "Capsule + title", a = "Bar A · One capsule", b = "Bar B · Split"
    var id: String { rawValue }
}

@MainActor @Observable
final class Sim {
    let games = loadGames()
    var variant: Variant = Variant(rawValue: ProcessInfo.processInfo.environment["PROTO_VARIANT"] ?? "") ?? .final
    var gameID: String = ""
    var paused = false
    var speed = 1
    var fastForward = false
    var saving = false
    var rewinding = false
    var notice: Notice?
    var volume = 0.8
    var muted = false
    var analog = true
    // PROTO_DISC=1 opens the pause menu with the disc flyout, for screenshots.
    var menuOpen = ProcessInfo.processInfo.environment["PROTO_DISC"] != nil
    var autoHide = false
    var hudVisible = true
    // PROTO_FULLSCREEN=1 draws the fullscreen strip without leaving the window, for screenshots.
    var fullscreen = ProcessInfo.processInfo.environment["PROTO_FULLSCREEN"] != nil
    /// When this session started, for "Playing for".
    let sessionStart = Date().addingTimeInterval(-42 * 60)

    /// The timed auto-save fired: a pill in the badge stack, nothing more.
    func autoSaved() { flash("clock.badge.checkmark.fill", "Auto-saved") }
    var scale = 4
    var pgxp = true
    var menuIcon = "ellipsis"
    var disc = 1
    /// The pointer, in the stage's space.
    var pointer: CGPoint = .zero
    var multiDisc = true

    private var hideTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init() { gameID = games.first(where: { $0.id == "SCUS-94244" })?.id ?? games.first?.id ?? "" }

    var game: Game? { games.first { $0.id == gameID } }
    var title: String { game?.title ?? "No Game" }

    /// What the app knows about the running disc, for Quick Settings' Game
    /// section. Fake values; the real ones come from DiscIdentity, PlayStats
    /// and the BIOS lookup.
    var gameInfo: [(icon: String, label: String, value: String)] {
        let region: String = switch gameID.prefix(4) {
        case "SCUS", "SLUS": "North America"
        case "SCES", "SLES": "Europe"
        case "SCPS", "SLPS", "SLPM": "Japan"
        default: "Unknown"
        }
        return [
            ("number", "Serial", gameID),
            ("globe", "Region", region),
            ("circle.circle", "Disc", multiDisc ? "\(disc) of 2" : "1 of 1"),
            ("hourglass", "Time Played", "12 h 40 min"),
            ("calendar", "Last Played", "Yesterday"),
            ("cpu", "BIOS", region == "Europe" ? "SCPH-7502" : "SCPH-1001"),
            ("doc", "Image", "CUE/BIN"),
        ]
    }
    var effectiveSpeed: Int { fastForward ? 4 : speed }

    func flash(_ icon: String, _ text: String) {
        notice = Notice(icon: icon, text: text)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { notice = nil }
        }
    }

    func poke() {
        hudVisible = true
        hideTask?.cancel()
        guard autoHide, !menuOpen, !statesOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { hudVisible = false }
        }
    }

    /// The Save States panel is up: the HUD stays, the game holds still.
    var statesOpen = false

    /// The resume state, then slots 1-6. Fake: the resume thumbnails stand in
    /// for saved frames, and slots 4-6 are empty.
    var slots: [Slot] {
        func image(_ i: Int) -> NSImage? { games.isEmpty ? nil : games[i % games.count].image }
        return [Slot(title: "Resume", image: image(0), saved: "2 min ago", automatic: true),
                Slot(title: "Slot 1", image: image(1), saved: "Yesterday, 21:14"),
                Slot(title: "Slot 2", image: image(2), saved: "6 October"),
                Slot(title: "Slot 3", image: image(3), saved: "2 October")]
            + (4...6).map { Slot(title: "Slot \($0)", image: nil, saved: nil) }
    }

    func openMenu() { menuOpen = true; paused = true }
    func closeMenu() { menuOpen = false; paused = false; poke() }
}

// MARK: - App

@main
struct HudPrototypeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @State private var sim = Sim()

    var body: some Scene {
        WindowGroup("HUD Prototype") {
            Stage(sim: sim)
                .frame(minWidth: 640, minHeight: 480)
                .toolbar { Controls(sim: sim) }
        }
        .defaultSize(width: 1024, height: 830)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Controls: ToolbarContent {
    @Bindable var sim: Sim

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Variant", selection: $sim.variant) {
                ForEach(Variant.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Picker("Game", selection: $sim.gameID) {
                ForEach(sim.games) { Text($0.title).tag($0.id) }
            }
        }
        ToolbarItem {
            Menu("Simulate") {
                Toggle("Fast-forward (Tab held)", isOn: $sim.fastForward)
                Toggle("Writing memory card", isOn: $sim.saving)
                Toggle("Rewinding", isOn: $sim.rewinding)
                Toggle("Multi-disc game", isOn: $sim.multiDisc)
                Divider()
                Button("Notice: Analog on") { sim.flash("gamecontroller.fill", "Analog on") }
                Button("Notice: Saved to Slot 2") { sim.flash("square.and.arrow.down.fill", "Saved to Slot 2") }
                Button("Notice: Controller disconnected") { sim.flash("gamecontroller", "Controller disconnected") }
                Button("Auto-save fires") { sim.autoSaved() }
                Divider()
                Toggle("Auto-hide HUD (2.5 s)", isOn: $sim.autoHide)
            }
        }
        ToolbarItem {
            Picker("Menu icon", selection: $sim.menuIcon) {
                ForEach(["ellipsis", "ellipsis.circle", "square.grid.2x2", "gearshape", "slider.horizontal.3", "gamecontroller", "chevron.up"], id: \.self) {
                    Label($0, systemImage: $0).tag($0)
                }
            }
        }
    }
}

// MARK: - Stage

struct Stage: View {
    @Bindable var sim: Sim
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            if let image = sim.game?.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .saturation(sim.paused ? 0.6 : 1)
                    .animation(.easeInOut(duration: 0.25), value: sim.paused)
            }

            if !sim.menuOpen {
                Group {
                    switch sim.variant {
                    case .final: BarFinal(sim: sim)
                    case .a: BarA(sim: sim)
                    case .b: BarB(sim: sim)
                    }
                }
                .opacity(sim.hudVisible ? 1 : 0)
                .allowsHitTesting(sim.hudVisible)
                .transition(.opacity)
            }

            if sim.menuOpen {
                Color.black.opacity(0.4)
                    .onTapGesture { sim.closeMenu() }
                    .transition(.opacity)
                PauseMenu(sim: sim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            BadgeStack(sim: sim, showPaused: !sim.hudVisible && !sim.menuOpen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)
                // The fullscreen strip owns the top-trailing corner while it shows.
                .padding(.top, sim.fullscreen && sim.hudVisible && sim.variant == .final ? 48 : 0)
        }
        .animation(.easeInOut(duration: 0.25), value: sim.hudVisible)
        .animation(.snappy(duration: 0.3), value: sim.menuOpen)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onChange(of: sim.menuOpen) { _, open in if !open { focused = true } }
        .onKeyPress(.escape) {
            guard !sim.menuOpen else { return .ignored }
            sim.openMenu()
            return .handled
        }
        .onContinuousHover(coordinateSpace: .named("stage")) {
            if case .active(let p) = $0 { sim.pointer = p; sim.poke() }
        }
        .coordinateSpace(.named("stage"))
        .onChange(of: sim.autoHide) { sim.poke() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in sim.fullscreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in sim.fullscreen = false }
    }
}

// MARK: - Shared pieces

/// One stack in one corner for every transient status, each with its own icon.
struct BadgeStack: View {
    @Bindable var sim: Sim
    let showPaused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if sim.effectiveSpeed > 1 { Badge(icon: "forward.fill", text: "\(sim.effectiveSpeed)×", mono: true) }
            if sim.rewinding { Badge(icon: "backward.fill", text: "12 s left", mono: true) }
            if sim.saving { Badge(icon: "sdcard.fill", text: "Saving", pulse: true) }
            if showPaused && sim.paused { Badge(icon: "pause.fill", text: "Paused") }
            if let n = sim.notice { Badge(icon: n.icon, text: n.text) }
        }
        .animation(.snappy(duration: 0.25), value: sim.effectiveSpeed)
        .animation(.snappy(duration: 0.25), value: sim.rewinding)
        .animation(.snappy(duration: 0.25), value: sim.saving)
        .animation(.snappy(duration: 0.25), value: sim.notice)
        .animation(.snappy(duration: 0.25), value: showPaused && sim.paused)
        .allowsHitTesting(false)
    }
}

struct Badge: View {
    let icon: String
    let text: String
    var mono = false
    var pulse = false

    var body: some View {
        Label(text, systemImage: icon)
            .symbolEffect(.pulse, isActive: pulse)
            .font(.system(size: 13, weight: .semibold, design: mono ? .monospaced : .default))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .trailing).combined(with: .opacity))
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

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 30)
                .contentShape(.capsule)
        }
        .buttonStyle(HoverStyle())
        .help(help)
    }
}

func fullscreenSymbol(_ on: Bool) -> String {
    on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
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

/// The bar's capsule with a tab rising out of it, one outline: concave
/// fillets where the tab leaves the bar, rounded corners at its top. The bar
/// occupies the bottom `barHeight` of the rect; the tab the space above.
struct BarShape: Shape {
    var tabMinX: CGFloat
    var tabWidth: CGFloat
    var rise: CGFloat
    /// The tab's full rise. Liquid Glass thickens with the size of its
    /// shape's bounds, so a speck at this height keeps the bar's material
    /// the same open or closed instead of frosting over as the tab grows.
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

/// Speed, the pop-up-button way: press on the value, slide to a speed, let
/// go. A plain click opens it for a second click instead, and a click on the
/// value again closes it. The bar draws the tab as part of its own glass; this
/// view only places the values in it.
struct SpeedButton: View {
    @Bindable var sim: Sim
    // PROTO_SPEED_OPEN=1 opens it at launch, for screenshots.
    @State private var open = ProcessInfo.processInfo.environment["PROTO_SPEED_OPEN"] != nil
    /// The speed under the pointer, 0-based, while pressing or hovering.
    @State private var tracking: Int?
    @State private var pressing = false
    @State private var wasOpen = false
    @State private var dragged = false
    @State private var hovering = false
    /// The button's frame in the stage's space, for the leave tolerance.
    @State private var frameInStage: CGRect = .zero

    private let space = "speed"
    /// How far the pointer may stray from the tab before it closes.
    private let tolerance: CGFloat = 40
    static let width: CGFloat = 40
    static let pad: CGFloat = 4
    static let slot: CGFloat = 28
    private let seat: CGFloat = 30
    static let separator: CGFloat = 9
    /// The bar's vertical padding, between the button and the bar's edge.
    static let barPad: CGFloat = 10
    /// How far the tab rises above the bar's top edge.
    static var rise: CGFloat { 4 * slot + separator + pad - barPad }

    var body: some View {
        Text("\(sim.speed)×")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .frame(width: Self.width, height: seat)
            .background(Capsule().fill(.white.opacity(hovering && !open ? 0.14 : 0)))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .gesture(press)
            .help("Emulation Speed  ·  hold Tab to fast-forward")
            .overlay(alignment: .bottom) {
                if open {
                    values.offset(y: -seat).transition(.opacity)
                }
            }
            .coordinateSpace(.named(space))
            .anchorPreference(key: SpeedTabKey.self, value: .bounds) { SpeedTab(anchor: $0, rise: open ? Self.rise : 0) }
            .animation(.snappy(duration: 0.22), value: open)
            .onChange(of: sim.hudVisible) { _, v in if !v { open = false } }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("stage")) } action: { frameInStage = $0 }
            .onChange(of: sim.pointer) { _, p in
                guard open, !pressing else { return }
                let tab = CGRect(x: frameInStage.minX - Self.pad,
                                 y: frameInStage.minY - (Self.rise + Self.barPad),
                                 width: frameInStage.width + 2 * Self.pad,
                                 height: frameInStage.height + Self.rise + 2 * Self.barPad)
                if !tab.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { open = false }
            }
    }

    private var values: some View {
        VStack(spacing: 0) {
            ForEach([4, 3, 2, 1], id: \.self) { n in
                Text("\(n)×")
                    .font(.system(size: 13, weight: sim.speed == n ? .bold : .semibold).monospacedDigit())
                    .frame(width: Self.width, height: Self.slot)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity(tracking == n - 1 ? 0.30 : sim.speed == n ? 0.12 : 0)))
            }
            Rectangle().fill(.white.opacity(0.3)).frame(width: Self.width - 14, height: 1)
                .frame(height: Self.separator)
        }
        .padding(.top, Self.pad)
        .contentShape(.rect)
        .gesture(press)
        .onContinuousHover(coordinateSpace: .named(space)) { phase in
            guard !pressing else { return }
            if case .active(let p) = phase { tracking = index(at: p) } else { tracking = nil }
        }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if !pressing {
                    pressing = true
                    wasOpen = open
                    dragged = false
                    open = true
                }
                if abs(v.translation.width) + abs(v.translation.height) > 4 { dragged = true }
                tracking = index(at: v.location)
            }
            .onEnded { v in
                pressing = false
                if let i = index(at: v.location) {
                    sim.speed = i + 1
                    open = false
                } else if dragged || wasOpen {
                    open = false
                }
                // Otherwise a plain click on a closed button: stay open.
                tracking = nil
            }
    }

    /// Which speed a point (in the button's space) is over, 0-based. The
    /// button is y 0...seat; above it the separator, then 1× upwards to 4×.
    private func index(at p: CGPoint) -> Int? {
        guard p.x > -Self.pad - 6, p.x < Self.width + Self.pad + 6, p.y < -Self.separator else { return nil }
        let i = Int(((-p.y - Self.separator) / Self.slot).rounded(.down))
        return (0...3).contains(i) ? i : nil
    }
}

/// A capsule that ends in the speaker, with the app's own Apple Music volume
/// pill laid over it from the trailing edge. Same three layers as GameHUD:
/// the capsule, the pill (outside the container so it covers rather than
/// merges), and the icon on top of both.
struct VolumeCapsule<Content: View, Trailing: View>: View {
    @Bindable var sim: Sim
    var hPad: CGFloat = 16
    var vPad: CGFloat = 10
    /// Width of whatever sits right of the speaker, spacing included.
    var trailingWidth: CGFloat = 0
    @ViewBuilder let content: Content
    @ViewBuilder var trailing: Trailing

    @State private var volume = VolumeControlState()
    private let iconSize: CGFloat = 28
    /// The speaker's seat, as wide as an `IconButton` so the bar's pitch
    /// stays even around it.
    private let seatWidth: CGFloat = 32
    private let pillInset: CGFloat = 7
    private var pillPadding: CGFloat { hPad - pillInset }
    /// Tighter on the right when a control sits there, so the pill stops
    /// short of it.
    private var pillRight: CGFloat { trailingWidth > 0 ? 4 : pillPadding }

    var body: some View {
        ZStack(alignment: .trailing) {
            Group {
                HStack(spacing: 6) {
                    content
                    seat
                    trailing
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .backgroundPreferenceValue(SpeedTabKey.self) { tab in
                    GeometryReader { geo in
                        let button = tab.anchor.map { geo[$0] }
                        Color.clear
                            .frame(width: geo.size.width, height: geo.size.height + SpeedButton.rise)
                            .glassEffect(.regular, in: BarShape(
                                tabMinX: (button?.minX ?? 0) - SpeedButton.pad,
                                tabWidth: (button?.width ?? 0) + 2 * SpeedButton.pad,
                                rise: tab.rise,
                                reach: SpeedButton.rise,
                                barHeight: geo.size.height))
                            .offset(y: -SpeedButton.rise)
                            .allowsHitTesting(false)
                            .animation(.snappy(duration: 0.22), value: tab.rise)
                    }
                }
            }

            ZStack(alignment: .trailing) {
                if volume.isExpanded { pill }
                VolumeButton(level: sim.volume, isMuted: sim.muted) {
                    if volume.iconTapped() == .toggleMute { sim.muted.toggle() }
                }
                .frame(width: seatWidth)
                .padding(.trailing, hPad + trailingWidth)
            }
            .onHover { if !$0 { volume.pointerExited() } }
        }
        .animation(.snappy(duration: 0.28), value: volume.isExpanded)
        .onChange(of: sim.hudVisible) { _, v in if !v { volume.collapse() } }
    }

    private var pill: some View {
        HStack(spacing: 12) {
            VolumeSlider(level: $sim.volume, isMuted: sim.muted) {
                if $0 { volume.adjustingBegan() } else { volume.adjustingEnded() }
            }
            .frame(width: VolumeSlider.width, height: iconSize)
            seat
        }
        .padding(.leading, pillPadding)
        .padding(.trailing, pillRight)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
        .padding(.trailing, hPad + trailingWidth - pillRight)
        .transition(.scale(scale: 0.1, anchor: .trailing).combined(with: .opacity))
    }

    private var seat: some View {
        Color.clear.frame(width: seatWidth, height: iconSize).allowsHitTesting(false)
    }
}

extension VolumeCapsule where Trailing == EmptyView {
    init(sim: Sim, hPad: CGFloat = 16, vPad: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.init(sim: sim, hPad: hPad, vPad: vPad, trailingWidth: 0, content: content, trailing: { EmptyView() })
    }
}

// MARK: - Bar A: one capsule

struct BarA: View {
    @Bindable var sim: Sim

    var body: some View {
        VolumeCapsule(sim: sim) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sim.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(sim.paused ? "Paused" : "60 FPS\(sim.analog ? "  ·  Analog" : "")")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .frame(minWidth: 120, maxWidth: 230, alignment: .leading)
            .padding(.trailing, 4)

            Divider().frame(height: 22)

            IconButton(symbol: sim.paused ? "play.fill" : "pause.fill", help: "Play/Pause  ⌘P", size: 17) { sim.paused.toggle() }
            IconButton(symbol: "square.and.arrow.down", help: "Quick Save  F5") { sim.flash("square.and.arrow.down.fill", "Quick saved") }
            IconButton(symbol: "clock.arrow.circlepath", help: "Quick Load  F8") { sim.flash("clock.arrow.circlepath", "Quick loaded") }

            Divider().frame(height: 22)

            SpeedButton(sim: sim)
            IconButton(symbol: fullscreenSymbol(sim.fullscreen), help: "Full Screen  ⌃⌘F") { NSApp.keyWindow?.toggleFullScreen(nil) }
            IconButton(symbol: sim.menuIcon, help: "Menu  Esc") { sim.openMenu() }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 24)
    }
}

// MARK: - Final: Bar A's capsule, Bar B's title on top

/// The game, QuickTime style: plain text over a scrim along the top edge,
/// fading with the bar.
struct TitleCapsule: View {
    @Bindable var sim: Sim

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sim.title).font(.system(size: 15, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\(sim.paused ? "Paused" : "60 FPS")  ·  Playing for \(playing(since: sim.sessionStart, now: context.date))")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            // Fullscreen hides the menu bar, and with it the time and the
            // battery: the strip gives both back, as a console overlay does.
            if sim.fullscreen {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 10) {
                        Text(context.date, format: .dateTime.hour().minute())
                        HStack(spacing: 4) {
                            Image(systemName: "battery.75percent")
                            Text("64%")
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 44)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }
}

/// "42 min", then "1 h 05 min" past the hour.
func playing(since start: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
}

struct BarFinal: View {
    @Bindable var sim: Sim

    var body: some View {
        VStack {
            TitleCapsule(sim: sim)
            Spacer()
            VolumeCapsule(sim: sim, trailingWidth: 38) {
                IconButton(symbol: sim.paused ? "play.fill" : "pause.fill", help: "Play/Pause  ⌘P", size: 17) { sim.paused.toggle() }
                SaveStatesButton(sim: sim)
                IconButton(symbol: "camera", help: "Screenshot") { sim.flash("camera.fill", "Screenshot saved") }

                Divider().frame(height: 22)

                SpeedButton(sim: sim)
                IconButton(symbol: fullscreenSymbol(sim.fullscreen), help: "Full Screen  ⌃⌘F") { NSApp.keyWindow?.toggleFullScreen(nil) }
            } trailing: {
                IconButton(symbol: sim.menuIcon, help: "Menu  Esc") { sim.openMenu() }
            }
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Bar B: split

struct BarB: View {
    @Bindable var sim: Sim

    var body: some View {
        VStack {
            TitleCapsule(sim: sim)

            Spacer()

            HStack(alignment: .bottom) {
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 4) {
                        IconButton(symbol: sim.paused ? "play.fill" : "pause.fill", help: "Play/Pause  ⌘P", size: 18) { sim.paused.toggle() }
                        SpeedButton(sim: sim)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }

                Spacer()

                HStack(spacing: 4) {
                    IconButton(symbol: "square.and.arrow.down", help: "Quick Save  F5") { sim.flash("square.and.arrow.down.fill", "Quick saved") }
                    IconButton(symbol: "clock.arrow.circlepath", help: "Quick Load  F8") { sim.flash("clock.arrow.circlepath", "Quick loaded") }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)

                Spacer()

                VolumeCapsule(sim: sim, hPad: 12, vPad: 8) {
                    IconButton(symbol: fullscreenSymbol(sim.fullscreen), help: "Full Screen  ⌃⌘F") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    IconButton(symbol: sim.menuIcon, help: "Menu  Esc") { sim.openMenu() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Pause menu (from C)

enum MenuPage: Equatable { case root, save, load, settings }

struct MenuItem {
    let icon: String
    let title: String
    var detail: String? = nil
    var drills = false
    var destructive = false
    /// Greyed, never highlighted, skipped by the arrow keys.
    var disabled = false
    /// A stepper row: ‹ value ›, moved with the arrows or the chevrons.
    var adjust: ((Int) -> Void)? = nil
    var action: () -> Void = {}
}

struct PauseMenu: View {
    @Bindable var sim: Sim
    @State private var page: MenuPage = .root
    @State private var selection = ProcessInfo.processInfo.environment["PROTO_DISC"] != nil ? 3 : 0
    /// Change Disc is a flyout beside its row, not a page: the menu stays put.
    @State private var flyout = ProcessInfo.processInfo.environment["PROTO_DISC"] != nil
    @State private var flyoutSelection = 1
    @FocusState private var focused: Bool

    private var isGrid: Bool { page == .save || page == .load }

    var items: [MenuItem] {
        switch page {
        case .root:
            return [
                MenuItem(icon: "play.fill", title: "Resume", detail: "Esc") { sim.closeMenu() },
                MenuItem(icon: "square.and.arrow.down", title: "Save State", drills: true) { go(.save) },
                MenuItem(icon: "clock.arrow.circlepath", title: "Load State", drills: true) { go(.load) },
                MenuItem(icon: "circle.circle", title: "Change Disc", detail: sim.multiDisc ? "Disc \(sim.disc) of 2" : nil,
                         drills: sim.multiDisc, disabled: !sim.multiDisc) { openFlyout() },
                MenuItem(icon: "slider.horizontal.3", title: "Quick Settings", drills: true) { go(.settings) },
                MenuItem(icon: "arrow.counterclockwise", title: "Reset") { sim.flash("arrow.counterclockwise", "Reset"); sim.closeMenu() },
                MenuItem(icon: "eject.fill", title: "Quit Game", destructive: true),
            ]
        case .save, .load:
            return (1...6).map { n in
                MenuItem(icon: "", title: "Slot \(n)") {
                    sim.flash(page == .save ? "square.and.arrow.down.fill" : "clock.arrow.circlepath",
                              page == .save ? "Saved to Slot \(n)" : "Loaded Slot \(n)")
                    sim.closeMenu()
                }
            }
        case .settings:
            return [
                MenuItem(icon: "forward", title: "Speed", detail: "\(sim.speed)×",
                         adjust: { sim.speed = min(4, max(1, sim.speed + $0)) }),
                MenuItem(icon: "square.resize", title: "Resolution", detail: "\(sim.scale)×",
                         adjust: { sim.scale = min(8, max(1, sim.scale + $0)) }),
                MenuItem(icon: "cube.transparent", title: "PGXP", detail: sim.pgxp ? "On" : "Off",
                         adjust: { _ in sim.pgxp.toggle() }),
                MenuItem(icon: "gamecontroller", title: "Analog", detail: sim.analog ? "On" : "Off",
                         adjust: { _ in sim.analog.toggle() }),
                MenuItem(icon: "speaker.wave.2", title: "Volume", detail: "\(Int(sim.volume * 100))%",
                         adjust: { sim.volume = min(1, max(0, sim.volume + Double($0) * 0.1)) }),
            ]
        }
    }

    var pageTitle: String {
        switch page {
        case .root: sim.title
        case .save: "Save State"
        case .load: "Load State"
        case .settings: "Quick Settings"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isGrid { slotGrid } else { list }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: isGrid ? 460 : 330)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.snappy(duration: 0.25), value: page)
        .animation(.snappy(duration: 0.2), value: flyout)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { flyout ? moveFlyout(-1) : move(isGrid ? -2 : -1) }
        .onKeyPress(.downArrow) { flyout ? moveFlyout(1) : move(isGrid ? 2 : 1) }
        .onKeyPress(.leftArrow) {
            if flyout { flyout = false; return .handled }
            if isGrid { return move(-1) }
            if let adjust = items[selection].adjust { adjust(-1); return .handled }
            if page != .root { go(.root); return .handled }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if flyout { return .handled }
            if isGrid { return move(1) }
            if let adjust = items[selection].adjust { adjust(1); return .handled }
            if items[selection].drills { items[selection].action(); return .handled }
            return .ignored
        }
        .onKeyPress(.return) {
            if flyout { pickDisc(flyoutSelection + 1); return .handled }
            if let adjust = items[selection].adjust { adjust(1) } else { items[selection].action() }
            return .handled
        }
        .onKeyPress(.escape) {
            if flyout { flyout = false; return .handled }
            if page == .root { sim.closeMenu() } else { go(.root) }
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page != .root {
                Button { go(.root) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .buttonStyle(HoverStyle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle).font(.system(size: 17, weight: .bold))
                if page == .root {
                    Text("Paused  ·  1:42 played today").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if page == .root && (i == 1 || i == 5) { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
                row(item, selected: i == selection && !item.disabled)
                    .opacity(item.disabled ? 0.35 : 1)
                    .allowsHitTesting(!item.disabled)
                    .onHover { if $0 { selection = i; if i != 3 { flyout = false } } }
                    .overlay(alignment: .topTrailing) {
                        if flyout && page == .root && i == 3 {
                            discFlyout
                                .offset(x: flyoutWidth + 26, y: -6)
                                .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                        }
                    }
            }
            if page == .settings { gameSection }
        }
    }

    /// Read-only, so it is not in `items`: the arrows never land on it.
    private var gameSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 8).padding(.horizontal, 8)
            Text("Game").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(sim.gameInfo, id: \.label) { info in
                HStack(spacing: 12) {
                    Image(systemName: info.icon).frame(width: 20).foregroundStyle(.secondary)
                    Text(info.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(info.value).monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
    }

    private func row(_ item: MenuItem, selected: Bool) -> some View {
        let tint: Color = item.destructive ? .red : .accentColor
        return Button(action: item.adjust == nil ? item.action : {}) {
            HStack(spacing: 12) {
                Image(systemName: item.icon).frame(width: 20)
                Text(item.title)
                Spacer()
                if let adjust = item.adjust {
                    HStack(spacing: 2) {
                        Button { adjust(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                            .buttonStyle(HoverStyle())
                        Text(item.detail ?? "").monospacedDigit().frame(minWidth: 40)
                        Button { adjust(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                            .buttonStyle(HoverStyle())
                    }
                    .font(.system(size: 13, weight: .semibold))
                } else if let d = item.detail {
                    Text(d).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
                if item.drills { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.6) }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(item.destructive && !selected ? .red : selected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, item.adjust == nil ? 9 : 5)
            .background(selected ? tint.opacity(0.85) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var slotGrid: some View {
        let thumbs = sim.games.map(\.image)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(0..<6, id: \.self) { i in
                let filled = i < 3 && !thumbs.isEmpty
                Button { items[i].action() } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                            if filled {
                                Image(nsImage: thumbs[(i + 2) % thumbs.count]).resizable().interpolation(.none)
                                    .clipShape(.rect(cornerRadius: 8))
                            } else {
                                Image(systemName: page == .save ? "plus" : "minus").font(.title2).foregroundStyle(.secondary)
                            }
                        }
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(i == selection ? Color.accentColor : .clear, lineWidth: 3))
                        HStack {
                            Text("Slot \(i + 1)").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(filled ? "\((i + 1) * 4) min ago" : "Empty").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(page == .load && !filled)
                .onHover { if $0 { selection = i } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("arrow.up.arrow.down", "Move")
            if page == .settings { hint("arrow.left.arrow.right", "Change") }
            hint("return", "Select")
            hint("escape", page == .root ? "Resume" : "Back")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) { Image(systemName: symbol); Text(text) }
    }

    private let flyoutWidth: CGFloat = 220

    private var discFlyout: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<2, id: \.self) { i in
                let n = i + 1
                let inserted = sim.disc == n
                let selected = i == flyoutSelection
                Button { pickDisc(n) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: inserted ? "circle.circle.fill" : "circle.circle").frame(width: 20)
                        Text("Disc \(n)")
                        Spacer()
                        if inserted { Text("Inserted").foregroundStyle(selected ? .white.opacity(0.8) : .secondary) }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(selected ? Color.accentColor.opacity(0.85) : .clear, in: .rect(cornerRadius: 10))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { flyoutSelection = i } }
            }
        }
        .padding(6)
        .frame(width: flyoutWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func openFlyout() {
        flyoutSelection = sim.disc == 1 ? 1 : 0
        flyout = true
    }

    private func moveFlyout(_ d: Int) -> KeyPress.Result {
        flyoutSelection = max(0, min(1, flyoutSelection + d))
        return .handled
    }

    private func pickDisc(_ n: Int) {
        guard n != sim.disc else { flyout = false; return }
        sim.disc = n
        flyout = false
        sim.flash("circle.circle", "Disc \(n) inserted")
        sim.closeMenu()
    }

    private func go(_ p: MenuPage) { page = p; selection = 0; flyout = false }

    private func move(_ d: Int) -> KeyPress.Result {
        let all = items
        var next = selection + d
        while all.indices.contains(next) && all[next].disabled { next += d > 0 ? 1 : -1 }
        if all.indices.contains(next) { selection = next }
        return .handled
    }
}


// MARK: - Save States panel

struct Slot: Hashable {
    let title: String
    let image: NSImage?
    /// When it was written; nil for an empty slot.
    let saved: String?
    /// The resume state: written by the auto-save and on quitting, never by
    /// the player, so it can only be loaded.
    var automatic = false
}

/// Opens the slots straight from the bar. A popover is a window of its own,
/// so the panel may spill past the game window, which an overlay never can.
struct SaveStatesButton: View {
    @Bindable var sim: Sim
    @State private var wasPaused = false

    var body: some View {
        IconButton(symbol: "rectangle.stack", help: "Save States") { sim.statesOpen.toggle() }
            .popover(isPresented: $sim.statesOpen, arrowEdge: .top) { SaveStatesPanel(sim: sim) }
            .onChange(of: sim.statesOpen) { _, open in
                if open { wasPaused = sim.paused; sim.paused = true } else { sim.paused = wasPaused; sim.poke() }
            }
    }
}

/// The resume state on its own beside the divider, slots 1-6 in a grid. Picking a tile
/// asks what to do with it rather than acting at once: one stray click must
/// never overwrite a save.
struct SaveStatesPanel: View {
    @Bindable var sim: Sim
    @State private var picked: Slot?

    var body: some View {
        let slots = sim.slots
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                // The title shares Resume's column, and the tile is centred
                // on the slots' height, set apart by the divider.
                SlotTile(slot: slots[0], width: 150) { picked = slots[0] }
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        Text("Save States").font(.system(size: 17, weight: .bold))
                    }
                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 12), count: 3), spacing: 12) {
                    ForEach(slots.dropFirst(), id: \.title) { slot in
                        SlotTile(slot: slot, width: 150) { picked = slot }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .overlay {
            if let slot = picked {
                ZStack {
                    Rectangle().fill(.black.opacity(0.35)).onTapGesture { picked = nil }
                    SlotSheet(slot: slot, cancel: { picked = nil }, save: {
                        sim.flash("square.and.arrow.down.fill", "Saved to \(slot.title)")
                        sim.statesOpen = false
                    }, load: {
                        sim.flash("clock.arrow.circlepath", "Loaded \(slot.title)")
                        sim.statesOpen = false
                    })
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: picked)
    }
}

struct SlotTile: View {
    let slot: Slot
    let width: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                SlotThumbnail(slot: slot)
                    .frame(width: width, height: width * 3 / 4)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(hover ? 0.7 : 0), lineWidth: 2))
                Text(slot.title).font(.system(size: 12, weight: .semibold))
                Text(slot.saved.map { slot.automatic ? "Auto-saved \($0)" : $0 } ?? "Empty")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct SlotThumbnail: View {
    let slot: Slot

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
            if let image = slot.image, slot.saved != nil {
                Image(nsImage: image).resizable().interpolation(.none).clipShape(.rect(cornerRadius: 8))
            } else {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// What to do with the picked slot. Load leads when there is something to
/// load; an empty slot can only be saved into, a full one says it will be
/// overwritten, and the resume state can only be loaded.
struct SlotSheet: View {
    let slot: Slot
    let cancel: () -> Void
    let save: () -> Void
    let load: () -> Void

    var body: some View {
        let empty = slot.saved == nil
        VStack(spacing: 12) {
            SlotThumbnail(slot: slot).frame(width: 200, height: 150)
            VStack(spacing: 2) {
                Text(slot.title).font(.system(size: 14, weight: .semibold))
                Text(slot.saved.map { slot.automatic ? "Auto-saved \($0)" : "Saved \($0)" } ?? "Empty").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if empty {
                    Button("Save Here", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    if !slot.automatic { Button("Overwrite", action: save) }
                    Button("Load", action: load).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
