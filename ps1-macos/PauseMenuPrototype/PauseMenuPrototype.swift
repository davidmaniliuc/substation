// PROTOTYPE, throwaway. The pause menu as a sidebar: flush to the window's
// edge (Music's lyrics pane) or inset with concentric corners (a macOS 27
// sidebar), on either edge. A second window holds the switches. Nothing here
// is wired to the core. Run: ps1-macos/PauseMenuPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Fake data

struct Game: Identifiable, Hashable {
    let id: String
    let title: String
    let image: NSImage
    let cover: NSImage?
}

func loadGames() -> [Game] {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Substation/ResumeStates")
    let names = ["SCUS-94163": "Final Fantasy VII", "SCUS-94244": "Crash Bandicoot: Warped",
                 "SCES-00344": "Crash Bandicoot", "SLUS-00707": "Silent Hill",
                 "SCES-00967": "Spyro the Dragon", "SCUS-94194": "Tomb Raider"]
    let covers = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Substation/Covers")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files
        .filter { $0.pathExtension == "png" && !$0.lastPathComponent.contains(".prev") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { url in
            let serial = url.deletingPathExtension().lastPathComponent
            guard let image = NSImage(contentsOf: url) else { return nil }
            let cover = NSImage(contentsOf: covers.appending(path: "\(serial).png"))
            return Game(id: serial, title: names[serial] ?? serial, image: image, cover: cover)
        }
}

enum Edge: String, CaseIterable, Identifiable {
    case leading = "Leading", trailing = "Trailing"
    var id: String { rawValue }
}

enum Attachment: String, CaseIterable, Identifiable {
    case flush = "Flush (Music)", inset = "Inset (Sidebar)"
    var id: String { rawValue }
}

enum Thumbnail: String, CaseIterable, Identifiable {
    case screenshot = "Paused frame", cover = "Cover", none = "None"
    var id: String { rawValue }
}

enum HintSeparator: String, CaseIterable, Identifiable {
    case bar = "Vertical bar", gap = "Gap only"
    var id: String { rawValue }
}

enum Style: String, CaseIterable, Identifiable {
    case inline = "Inline", refined = "Refined", previous = "Previous"
    var id: String { rawValue }
}

enum ResumeStyle: String, CaseIterable, Identifiable {
    case headerPlay = "Header play button", row = "First row", big = "Big button"
    var id: String { rawValue }
}

enum TypeSize: String, CaseIterable, Identifiable {
    case regular = "Regular", large = "Large"
    var id: String { rawValue }
}

enum Row: Int, CaseIterable {
    case resume, saveStates, saveState, loadState, changeDisc, quickSettings, gameInfo, reset, quitGame

    var title: String {
        switch self {
        case .resume: "Resume"
        case .saveStates: "Save States"
        case .saveState: "Save State"
        case .loadState: "Load State"
        case .changeDisc: "Change Disc"
        case .quickSettings: "Quick Settings"
        case .gameInfo: "Game Info"
        case .reset: "Reset"
        case .quitGame: "Quit Game"
        }
    }

    var icon: String {
        switch self {
        case .resume: "play.fill"
        case .saveStates: "rectangle.stack"
        case .saveState: "square.and.arrow.down"
        case .loadState: "clock.arrow.circlepath"
        case .changeDisc: "circle.circle"
        case .quickSettings: "slider.horizontal.3"
        case .gameInfo: "info.circle"
        case .reset: "arrow.counterclockwise"
        case .quitGame: "eject.fill"
        }
    }

    var drills: Bool { [.saveStates, .saveState, .loadState, .quickSettings, .gameInfo].contains(self) }
    var disabled: Bool { self == .changeDisc }
    var startsGroup: Bool { self == .saveState || self == .reset }
}

@Observable
final class Sim {
    var games = loadGames()
    var gameID = ""
    var menuOpen = true
    var edge = Edge.leading
    var attachment = Attachment.flush
    var style = Style.inline
    var typeSize = TypeSize.regular
    var thumbnail = Thumbnail.cover
    var hintSeparator = HintSeparator.bar
    var dim = 0.2
    var width = 300.0
    var selection = 0

    // Inline style: its own highlight and the settings it changes.
    var focus: InlineItem? = nil
    var speed = 1
    var scale = 4
    var volume = 0.8
    var muted = false
    var pgxp = true
    var analog = false
    var savedCount = 4
    var resumeStyle = ResumeStyle.headerPlay
    /// The pointer's highlight never scrolls the list; the keys' does.
    var keyboardMoved = false

    init() { gameID = games.first?.id ?? "" }

    func moveInline(_ delta: Int) {
        keyboardMoved = true
        let items = InlineItem.allCases.filter { $0 != .resume || resumeStyle == .row }
        let at = focus.flatMap { items.firstIndex(of: $0) } ?? (delta > 0 ? -1 : items.count)
        focus = items[min(max(at + delta, 0), items.count - 1)]
    }

    /// ← and → on the focused row; Return toggles a switch.
    func adjust(_ delta: Int) {
        switch focus {
        case .speed: speed = min(max(speed + delta, 1), 4)
        case .resolution: scale = min(max(scale + delta, 1), 8)
        case .volume: volume = min(max(volume + Double(delta) * 0.1, 0), 1); muted = false
        case .pgxp: pgxp.toggle()
        case .analog: analog.toggle()
        default: break
        }
    }

    var game: Game? { games.first { $0.id == gameID } }

    /// What the arrow keys step through: the rows the style shows.
    var navigable: [Row] {
        switch style {
        case .inline, .refined: [.saveStates, .quickSettings, .gameInfo, .reset, .quitGame]
        case .previous: Row.allCases.filter { $0 != .saveStates && !$0.disabled }
        }
    }

    func move(_ delta: Int) {
        let rows = navigable
        let at = rows.firstIndex { $0.rawValue == selection } ?? (delta > 0 ? -1 : 0)
        selection = rows[(at + delta + rows.count) % rows.count].rawValue
    }
}

// MARK: - App

@main
struct PauseMenuPrototypeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @State private var sim = Sim()

    var body: some Scene {
        WindowGroup("Pause Menu Prototype", id: "stage") {
            Stage(sim: sim)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1024, height: 768)

        Window("Switches", id: "switches") {
            Switches(sim: sim)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Switches: View {
    @Bindable var sim: Sim

    var body: some View {
        Form {
            Toggle("Menu open (Esc)", isOn: $sim.menuOpen)
            Picker("Edge", selection: $sim.edge) {
                ForEach(Edge.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Attachment", selection: $sim.attachment) {
                ForEach(Attachment.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Style", selection: $sim.style) {
                ForEach(Style.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Resume", selection: $sim.resumeStyle) {
                ForEach(ResumeStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Thumbnail", selection: $sim.thumbnail) {
                ForEach(Thumbnail.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Hint separator", selection: $sim.hintSeparator) {
                ForEach(HintSeparator.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Type", selection: $sim.typeSize) {
                ForEach(TypeSize.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(value: $sim.width, in: 260...420, step: 10) { Text("Width \(Int(sim.width))") }
            Picker("Dim", selection: $sim.dim) {
                Text("None").tag(0.0)
                Text("20%").tag(0.2)
                Text("40%").tag(0.4)
            }
            Picker("Game", selection: $sim.gameID) {
                ForEach(sim.games) { Text($0.title).tag($0.id) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Stage

struct Stage: View {
    @Bindable var sim: Sim
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            Color.black
            if let game = sim.game {
                Image(nsImage: game.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
            if sim.menuOpen {
                Color.black.opacity(sim.dim)
                    .onTapGesture { sim.menuOpen = false }
                    .transition(.opacity)
                Sidebar(sim: sim, isFullScreen: isFullScreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: sim.edge == .leading ? .leading : .trailing)
                    .transition(reduceMotion ? .opacity
                                : .move(edge: sim.edge == .leading ? .leading : .trailing))
            }
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.3), value: sim.menuOpen)
        .animation(.snappy(duration: 0.3), value: sim.edge)
        .animation(.snappy(duration: 0.3), value: sim.attachment)
        .onAppear { openWindow(id: "switches") }
        .background(KeyCatcher(sim: sim))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }
}

/// Esc toggles, arrows move, Return closes on Resume: enough to feel it.
struct KeyCatcher: NSViewRepresentable {
    let sim: Sim

    func makeNSView(context: Context) -> NSView {
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.title != "Switches" else { return event }
            if sim.style == .inline && sim.menuOpen {
                switch event.keyCode {
                case 53: sim.menuOpen = false
                case 126: sim.moveInline(-1)
                case 125: sim.moveInline(1)
                case 123: sim.adjust(-1)
                case 124: sim.adjust(1)
                case 36, 49:
                    switch sim.focus {
                    case nil, .resume: sim.menuOpen = false
                    case .pgxp, .analog: sim.adjust(1)
                    case .volume: sim.muted.toggle()
                    default: break
                    }
                default: return event
                }
                return nil
            }
            switch event.keyCode {
            case 53: sim.menuOpen.toggle()
            case 126 where sim.menuOpen: sim.move(-1)
            case 125 where sim.menuOpen: sim.move(1)
            case 36 where sim.menuOpen && sim.selection == Row.resume.rawValue: sim.menuOpen = false
            default: return event
            }
            return nil
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var monitor: Any? }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var sim: Sim
    let isFullScreen: Bool
    /// A short window: the header drops to one line of detail.
    @State private var compact = false

    /// The footer's rule and the edge against the game: one light hairline.
    static let rule = Color.white.opacity(0.16)

    private var large: Bool { sim.typeSize == .large }
    private var inset: CGFloat { sim.attachment == .inset ? 8 : 0 }
    /// Room for the traffic lights when they sit inside the panel.
    private var topClearance: CGFloat {
        let lightsInside = sim.edge == .leading && !isFullScreen
        return lightsInside ? 52 - inset : 24
    }

    var body: some View {
        // The footer takes its own strip: laid over the panel, a short window
        // scrolled the rows underneath it.
        VStack(spacing: 0) {
            Group {
                switch sim.style {
                case .inline: InlineMenu(sim: sim, large: large, compact: compact) { thumbnail }
                case .refined: refined
                case .previous: previous
                }
            }
            // Inline scrolls, and carries its own margin inside the scroll
            // view so the scroller runs along the panel's edge, not the rows.
            .padding(.horizontal, sim.style == .inline ? 0 : 10)
            .padding(.top, topClearance)
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < 640 } action: { compact = $0 }
        .frame(width: sim.width)
        .frame(maxHeight: .infinity)
        .background(alignment: sim.edge == .leading ? .trailing : .leading) {
            if sim.attachment == .flush {
                Rectangle().fill(Self.rule).frame(width: 1)
            }
        }
        .glassEffect(.regular, in: shape)
        .padding(inset)
    }

    // MARK: Refined

    /// A Mac sidebar's metrics: 13 pt rows, accent icons, section headings in
    /// place of rules, Resume as the one prominent button, and nothing shown
    /// that cannot be used.
    private var refined: some View {
        VStack(alignment: .leading, spacing: 0) {
            refinedHeader
            Button { sim.menuOpen = false } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.system(size: large ? 15 : 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, large ? 6 : 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 2)
            .padding(.bottom, 18)

            section("Game", [.saveStates, .quickSettings, .gameInfo])
            section("Machine", [.reset, .quitGame])
            Spacer(minLength: 0)
        }
    }

    private var refinedHeader: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(sim.game?.title ?? "Game")
                    .font(.system(size: large ? 17 : 14, weight: .semibold))
                    .lineLimit(2)
                Text("Paused · 42 min this session")
                    .font(.system(size: large ? 13 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 16)
    }

    private func section(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: large ? 12 : 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(rows, id: \.self) { row in
                SidebarRow(row: row, large: large, selected: row.rawValue == sim.selection)
                    .onHover { if $0 { sim.selection = row.rawValue } }
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: Previous

    private var previous: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            VStack(spacing: 2) {
                ForEach(Row.allCases.filter { $0 != .saveStates }, id: \.self) { row in
                    if row.startsGroup {
                        Divider().padding(.vertical, 4).padding(.horizontal, 12)
                    }
                    RowLabel(row: row, large: large, selected: row.rawValue == sim.selection)
                        .onHover { if $0 && !row.disabled { sim.selection = row.rawValue } }
                        .onTapGesture { if row == .resume { sim.menuOpen = false } }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var shape: some Shape {
        sim.attachment == .flush
            ? AnyShape(Rectangle())
            : AnyShape(ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true))
    }

    /// Album-art size: the cover's longer side, beside the title.
    private var thumbSide: CGFloat {
        switch sim.style {
        case .inline: compact ? (large ? 52 : 44) : (large ? 76 : 64)
        case .refined: large ? 60 : 48
        case .previous: large ? 72 : 56
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch sim.thumbnail {
        case .screenshot:
            if let image = sim.game?.image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(width: thumbSide * 4 / 3, height: thumbSide)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
            }
        case .cover:
            if let cover = sim.game?.cover {
                Image(nsImage: cover).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: thumbSide, maxHeight: thumbSide)
                    .clipShape(.rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            }
        case .none:
            EmptyView()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(sim.game?.title ?? "Game")
                    .font(.system(size: large ? 22 : 16, weight: .bold))
                    .lineLimit(2)
                Text("Paused")
                    .font(.system(size: large ? 15 : 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, large ? 14 : 10)
    }

    /// A rule across the whole panel, then the hints as one quiet line.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Self.rule).frame(height: 1)
            HStack(spacing: sim.hintSeparator == .bar ? 8 : 14) {
                if sim.style == .inline {
                    hint("↑↓", "Move")
                    separator
                    hint("←→", "Change")
                    separator
                    hint("esc", "Resume")
                } else {
                    hint("↑↓", sim.style == .refined ? "Move" : "to navigate")
                    separator
                    hint("↵", sim.style == .refined ? "Select" : "to select")
                    separator
                    hint("esc", sim.style == .refined ? "Resume" : "to resume")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: large ? 13 : 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var separator: some View {
        if sim.hintSeparator == .bar {
            Rectangle().fill(.separator).frame(width: 1, height: 12)
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: sim.style == .refined ? 5 : 3) {
            if sim.style != .previous {
                Text(key)
                    .font(.system(size: large ? 11 : 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 17)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            } else {
                Text(key).fontWeight(.semibold).foregroundStyle(.primary.opacity(0.75))
            }
            Text(text)
        }
        .fixedSize()
    }
}

struct RowLabel: View {
    let row: Row
    let large: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon).frame(width: large ? 26 : 20)
            Text(row.title)
            Spacer()
            if row == .resume {
                Text("Esc").foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
            if row.drills {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.6)
            }
        }
        .font(.system(size: large ? 19 : 14, weight: large ? .semibold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, large ? 11 : 9)
        .background(selected ? highlight.opacity(0.85) : .clear, in: .rect(cornerRadius: 10))
        .opacity(row.disabled ? 0.35 : 1)
        .contentShape(.rect)
    }

    private var highlight: Color { row == .quitGame ? .red : .accentColor }

    private var foreground: Color {
        if selected { return .white }
        return row == .quitGame ? .red : .primary
    }
}

/// A sidebar row as macOS draws one: 13 pt, accent icon, a tight accent
/// selection. Quit Game keeps red for its icon and title.
struct SidebarRow: View {
    let row: Row
    let large: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.icon)
                .font(.system(size: large ? 15 : 13))
                .foregroundStyle(iconColor)
                .frame(width: large ? 22 : 18)
            Text(row.title)
                .font(.system(size: large ? 15 : 13))
                .foregroundStyle(selected ? .white : (row == .quitGame ? .red : .primary))
            Spacer(minLength: 0)
            if row.drills {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? .white.opacity(0.7) : .secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: large ? 34 : 28)
        .background(selected ? fill : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }

    private var fill: Color { row == .quitGame ? .red.opacity(0.85) : .accentColor }

    private var iconColor: Color {
        if selected { return .white }
        return row == .quitGame ? .red : .accentColor
    }
}

// MARK: - Inline

enum InlineItem: CaseIterable {
    case resume, saveStates, speed, resolution, volume, pgxp, analog, reset, quitGame
}

/// Everything on one page: the header, Resume, the save-state manager, the
/// quick settings as real controls, the two machine actions, and the game's
/// facts last, since they are read-only and may sit at the bottom edge.
struct InlineMenu<Thumb: View>: View {
    @Bindable var sim: Sim
    let large: Bool
    let compact: Bool
    @ViewBuilder let thumbnail: () -> Thumb

    private var body13: Font { .system(size: large ? 15 : 13) }

    var body: some View {
        // The header and Resume stay put; only the list beneath them scrolls.
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 10)
            if sim.resumeStyle == .big {
                Button { sim.menuOpen = false } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: large ? 15 : 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, large ? 6 : 3)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
                .padding(.horizontal, 10)
            }
            list
        }
    }

    /// Scrolls to keep the keys' and the controller's highlight on screen.
    private var list: some View {
        ScrollViewReader { proxy in
            rows
                .onChange(of: sim.focus) { _, focus in
                    guard let focus, sim.keyboardMoved else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(focus) }
                }
        }
    }

    private var rows: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if sim.resumeStyle == .row {
                    item(.resume) {
                        rowIcon("play.fill")
                        Text("Resume").font(body13)
                        Spacer(minLength: 0)
                        Text("esc").font(.system(size: large ? 12 : 11)).foregroundStyle(.secondary)
                    }
                    .onTapGesture { sim.menuOpen = false }
                }
                item(.saveStates) {
                    rowIcon("rectangle.stack")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Save States").font(body13)
                        Text("\(sim.savedCount) saved · last 5 min ago")
                            .font(.system(size: large ? 12 : 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }

                heading("Quick Settings")
                item(.speed) {
                    rowIcon("gauge.with.dots.needle.67percent")
                    Text("Speed").font(body13)
                    Spacer(minLength: 8)
                    Picker("Speed", selection: $sim.speed) {
                        ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 132)
                }
                item(.resolution) {
                    rowIcon("square.resize")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Resolution").font(body13)
                        Text(verbatim: "\(320 * sim.scale)×\(240 * sim.scale)")
                            .font(.system(size: large ? 12 : 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(sim.scale)×").font(body13).monospacedDigit()
                    Stepper("Resolution", value: $sim.scale, in: 1...8).labelsHidden()
                        .controlSize(.small)
                }
                item(.volume) {
                    Button { sim.muted.toggle() } label: {
                        rowIcon(sim.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.plain)
                    .help(sim.muted ? "Unmute" : "Mute")
                    Text("Volume").font(body13)
                    Spacer(minLength: 8)
                    Slider(value: Binding(get: { sim.muted ? 0 : sim.volume },
                                          set: { sim.volume = $0; sim.muted = false }))
                        .controlSize(.small)
                        .frame(width: 110)
                }
                item(.pgxp) {
                    rowIcon("cube.transparent")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("PGXP").font(body13)
                        Text("Steadier 3D geometry")
                            .font(.system(size: large ? 12 : 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("PGXP", isOn: $sim.pgxp).labelsHidden().toggleStyle(.switch)
                        .controlSize(.small)
                }
                item(.analog) {
                    rowIcon("gamecontroller")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Analog").font(body13)
                        Text("DualShock sticks")
                            .font(.system(size: large ? 12 : 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Analog", isOn: $sim.analog).labelsHidden().toggleStyle(.switch)
                        .controlSize(.small)
                }

                heading("Machine")
                item(.reset) {
                    rowIcon("arrow.counterclockwise")
                    Text("Reset").font(body13)
                    Spacer(minLength: 0)
                }
                item(.quitGame, destructive: true) {
                    rowIcon("eject.fill", tint: .red)
                    Text("Quit Game").font(body13).foregroundStyle(.red)
                    Spacer(minLength: 0)
                }

                heading("About This Game")
                info
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.automatic)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    private var header: some View {
        HStack(spacing: 12) {
            thumbnail()
            VStack(alignment: .leading, spacing: 3) {
                Marquee(text: sim.game?.title ?? "Game",
                        font: .system(size: large ? 18 : 15, weight: .semibold))
                if !compact {
                    Text("\(sim.game?.id ?? "Unknown") · Europe")
                        .font(.system(size: large ? 12 : 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Label("Playing for 42 min", systemImage: "pause.fill")
                    .labelStyle(PausedLabel())
                    .font(.system(size: large ? 12 : 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if sim.resumeStyle == .headerPlay {
                Button { sim.menuOpen = false } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: large ? 18 : 15, weight: .semibold))
                        .frame(width: large ? 30 : 24, height: large ? 30 : 24)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Resume (esc)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, compact ? 10 : 16)
    }

    private var info: some View {
        let rows: [(String, String)] = [
            ("Disc", "1 of 1"),
            ("Time Played", "6 h 12 min"),
            ("Last Played", "Yesterday"),
            ("BIOS", "SCPH-7502"),
            ("Image", "CUE/BIN"),
        ]
        return VStack(spacing: 6) {
            ForEach(rows, id: \.0) { label, value in
                HStack {
                    Text(label).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).monospacedDigit()
                }
                .font(.system(size: large ? 13 : 12))
            }
        }
        .padding(.horizontal, 8)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: large ? 12 : 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func rowIcon(_ name: String, tint: Color = .accentColor) -> some View {
        Image(systemName: name)
            .font(.system(size: large ? 15 : 13))
            .foregroundStyle(tint)
            .frame(width: large ? 22 : 18)
    }

    /// A row the pointer and the keys both highlight, with a soft tint
    /// rather than a solid fill, since most rows carry a control.
    private func item(_ which: InlineItem, destructive: Bool = false,
                      @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 9) { content() }
            .padding(.horizontal, 8)
            .frame(minHeight: large ? 36 : 30)
            .padding(.vertical, 2)
            .background(sim.focus == which
                        ? (destructive ? Color.red.opacity(0.18) : Color.white.opacity(0.09))
                        : .clear,
                        in: .rect(cornerRadius: 8))
            .contentShape(.rect)
            .id(which)
            .onHover {
                sim.keyboardMoved = false
                if $0 { sim.focus = which } else if sim.focus == which { sim.focus = nil }
            }
    }
}

/// The paused glyph small and a step lighter than the words.
struct PausedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 8)).opacity(0.8)
            configuration.title
        }
    }
}

/// One line that scrolls sideways when it does not fit, as Music's
/// now-playing title does: it rests, scrolls one length plus a gap, and rests
/// again on the same text. A title that fits never moves; with Reduce Motion
/// it truncates instead.
struct Marquee: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var start = Date()

    private let gap: CGFloat = 32
    private let speed: CGFloat = 30   // points per second
    private let rest: Double = 2.5    // seconds still at the start of each pass
    private let fade: CGFloat = 12

    private var overflows: Bool { textWidth > boxWidth + 0.5 }

    var body: some View {
        // The plain line sets the height and reports the box's width.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                if overflows && !reduceMotion { scrolling } else {
                    Text(text).font(font).lineLimit(1).truncationMode(.tail)
                }
            }
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onChange(of: text) { start = Date() }
    }

    /// At rest only the trailing edge fades, so the first letters read
    /// clean; while it moves, both edges do.
    private var scrolling: some View {
        TimelineView(.animation) { context in
            let x = offset(at: context.date)
            HStack(spacing: gap) {
                Text(text).font(font).fixedSize()
                Text(text).font(font).fixedSize()
            }
            .offset(x: x)
            .frame(width: boxWidth, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [x < 0 ? .clear : .black, .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                }
            }
        }
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = textWidth + gap
        let travel = Double(distance / speed)
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: rest + travel)
        guard t > rest else { return 0 }
        return -CGFloat(t - rest) * speed
    }
}
