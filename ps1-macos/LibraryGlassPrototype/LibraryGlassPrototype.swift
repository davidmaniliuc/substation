// PROTOTYPE, throwaway. The library as one panel on a translucent window:
// the desktop shows through the window's own material, the title bar carries
// the sections as capsule tabs, and the covers sit in a single inset panel.
// No game panel: a double click opens the resume sheet, which already shows
// the game. Covers and play time are the real ones in Application Support.
// Nothing is wired to the core.
// Run: ps1-macos/LibraryGlassPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Real data

let support = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Substation")

enum Region: String { case america = "North America", europe = "Europe" }

struct Saved: Identifiable {
    let id: String
    let title: String
    let date: Date
    let image: NSImage?
}

struct Game: Identifiable, Hashable {
    let id: String
    let title: String
    let discs: Int
    let region: Region
    let cover: NSImage?
    let states: [Saved]
    let seconds: Double
    let lastPlayed: Date?

    var resume: Saved? { states.first { $0.id == "resume" } }
    static func == (a: Game, b: Game) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The serials read off the discs in games/.
let catalogue: [(String, String, Int, Region)] = [
    ("SLUS-00067", "Castlevania: Symphony of the Night", 1, .america),
    ("SCES-00344", "Crash Bandicoot", 1, .europe),
    ("SCES-00967", "Crash Bandicoot 2: Cortex Strikes Back", 1, .europe),
    ("SCUS-94244", "Crash Bandicoot: Warped", 1, .america),
    ("SLUS-00530", "Croc: Legend of the Gobbos", 1, .america),
    ("SLES-00132", "Doom", 1, .europe),
    ("SLES-02966", "Final Fantasy IX", 4, .europe),
    ("SCUS-94163", "Final Fantasy VII", 3, .america),
    ("SCUS-94194", "Gran Turismo", 1, .america),
    ("SLUS-00106", "Grand Theft Auto", 1, .america),
    ("SLUS-00964", "Hot Wheels Turbo Racing", 1, .america),
    ("SLES-00049", "Rayman", 1, .europe),
    ("SLUS-00170", "Resident Evil", 1, .america),
    ("SLUS-00707", "Silent Hill", 1, .america),
    ("SCUS-94228", "Spyro the Dragon", 1, .america),
    ("SLUS-00292", "Suikoden", 1, .america),
    ("SLUS-00006", "Tekken", 1, .america),
    ("SLUS-00402", "Tekken 3", 1, .america),
    ("SLUS-00338", "Tetris Plus", 1, .america),
    ("SLUS-00152", "Tomb Raider", 1, .america),
    ("SLUS-00860", "Tony Hawk's Pro Skater", 1, .america),
]

struct Stat: Decodable { let seconds: Double; let lastPlayed: Double? }

func saved(_ id: String, _ title: String, _ url: URL) -> Saved? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .now
    return Saved(id: id, title: title, date: date, image: NSImage(contentsOf: url).flatMap(visible))
}

/// A screenshot taken on a black frame (a load, a fade) says nothing about
/// where the game is; it reads as a broken picture, so it counts as none and
/// the cover stands in.
func visible(_ image: NSImage) -> NSImage? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    guard let data = ctx.data else { return image }
    let bytes = data.bindMemory(to: UInt8.self, capacity: 256)
    let brightest = (0..<64).map { i in max(bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2]) }.max() ?? 0
    return brightest < 12 ? nil : image
}

func loadGames() -> [Game] {
    let stats = (try? Data(contentsOf: support.appending(path: "PlayStats/stats.json")))
        .flatMap { try? JSONDecoder().decode([String: Stat].self, from: $0) } ?? [:]
    return catalogue.map { serial, title, discs, region in
        let resume = support.appending(path: "ResumeStates")
        var states = [saved("resume", "Resume", resume.appending(path: "\(serial).png")),
                      saved("previous", "Previous Resume", resume.appending(path: "\(serial).prev.png"))]
        for n in 1...6 {
            states.append(saved("slot\(n)", "Slot \(n)",
                                support.appending(path: "SaveStates/\(serial)/slot\(n).png")))
        }
        let stat = stats[serial]
        return Game(
            id: serial, title: title, discs: discs, region: region,
            cover: NSImage(contentsOf: support.appending(path: "Covers/\(serial).png")),
            states: states.compactMap { $0 },
            seconds: stat?.seconds ?? 0,
            lastPlayed: stat?.lastPlayed.map(Date.init(timeIntervalSinceReferenceDate:)))
    }
}

func playTime(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "under 1 min" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h \(minutes % 60) min"
}

func relative(_ date: Date?) -> String {
    guard let date else { return "never" }
    return date.formatted(.relative(presentation: .named))
}

// MARK: - Model

enum Tab: String, CaseIterable, Identifiable {
    case all = "All Games", recent = "Recently Played", multiDisc = "Multi-Disc"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .recent: "clock"
        case .multiDisc: "opticaldisc"
        }
    }
}

enum Scheme: String, CaseIterable, Identifiable {
    case system = "System", dark = "Dark", light = "Light"
    var id: Self { self }
}

enum WindowMaterial: String, CaseIterable, Identifiable {
    case ultraThin = "Ultra Thin", thin = "Thin", regular = "Regular"
    var id: Self { self }
    var material: Material {
        switch self {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        }
    }
}

enum PanelStyle: String, CaseIterable, Identifiable {
    case filled = "Filled", outlined = "Outlined", none = "No Panel"
    var id: Self { self }
}

@Observable final class Sim {
    let games = loadGames()
    var scheme = Scheme.dark
    var windowMaterial = WindowMaterial.thin
    var panelStyle = PanelStyle.filled
    var showsContinue = true
    var continueArt = ContinueArt.disc
    var tab = Tab.all
    var search = ""
    var selection: Game.ID?
    /// What a double click would have opened: the app's resume sheet.
    var opened: Game?

    var recent: [Game] {
        games.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }
    }

    var shown: [Game] {
        let base: [Game] = switch tab {
        case .all: games
        case .recent: recent
        case .multiDisc: games.filter { $0.discs > 1 }
        }
        let words = search.split(separator: " ")
        guard !words.isEmpty else { return base }
        return base.filter { g in words.allSatisfy { g.title.localizedCaseInsensitiveContains($0) } }
    }
}

enum Metrics {
    static let gap: CGFloat = 10
    static let spacing: CGFloat = 18
    static let padding: CGFloat = 18

    /// Columns aiming at `target`, at least two, and the width that fills
    /// the row exactly.
    static func grid(width: CGFloat, target: CGFloat = 140) -> (columns: Int, tile: CGFloat) {
        let inner = max(0, width - padding * 2)
        let columns = max(2, Int((inner + spacing) / (target + spacing)))
        return (columns, (inner - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }
}

// MARK: - App

@main
struct LibraryGlassPrototypeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @State private var sim = Sim()

    var body: some Scene {
        WindowGroup("Substation", id: "library") {
            Library(sim: sim)
                .frame(minWidth: 560, minHeight: 460)
                .containerBackground(sim.windowMaterial.material, for: .window)
                .preferredColorScheme(sim.scheme == .dark ? .dark : sim.scheme == .light ? .light : nil)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)

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
            Picker("Panel", selection: $sim.panelStyle) {
                ForEach(PanelStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Window", selection: $sim.windowMaterial) {
                ForEach(WindowMaterial.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Appearance", selection: $sim.scheme) {
                ForEach(Scheme.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Continue capsule in the title bar", isOn: $sim.showsContinue)
            Picker("Continue cover", selection: $sim.continueArt) {
                ForEach(ContinueArt.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Window

struct Library: View {
    @Bindable var sim: Sim
    @Environment(\.openWindow) private var openWindow
    @State private var width: CGFloat = 1200

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(sim: sim, width: width)
            GridPanel(sim: sim)
                .padding(.horizontal, sim.panelStyle == .none ? 0 : Metrics.gap)
            HintLine(sim: sim)
        }
        .ignoresSafeArea(edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay {
            if let game = sim.opened { OpenedNote(game: game) { sim.opened = nil } }
        }
        .onAppear { openWindow(id: "switches") }
    }
}

/// The window's own title bar: identity leading (after the traffic lights),
/// the sections as capsule tabs, search trailing. Drags the window.
struct TitleBar: View {
    @Bindable var sim: Sim
    let width: CGFloat
    @FocusState private var searchFocused: Bool

    var body: some View {
        // One container for the bar's glass, so its pieces render as one.
        GlassEffectContainer(spacing: 14) {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Substation").font(.headline)
                    Text("\(sim.games.count) games").font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize()

            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    TabCapsule(tab: tab, isSelected: sim.tab == tab, compact: width < 820) { sim.tab = tab }
                }
            }
            .padding(Bar.inset)
            .frame(height: Bar.height)
            .glassEffect(.regular, in: .capsule)

            Spacer(minLength: 8)

            if sim.showsContinue, width >= 1000, let game = sim.recent.first {
                ContinueCapsule(game: game, art: sim.continueArt) { sim.opened = game }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $sim.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { sim.search = ""; searchFocused = false }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(width: width < 760 ? 130 : 200, height: Bar.height)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 58)
        .gesture(WindowDragGesture())
    }
}

struct TabCapsule: View {
    let tab: Tab
    let isSelected: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol).font(.system(size: 12))
                if !compact || isSelected { Text(tab.rawValue) }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: Bar.inner)
            .background {
                if isSelected { Capsule().fill(.primary.opacity(0.12)) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
    }
}

enum ContinueArt: String, CaseIterable, Identifiable {
    case disc = "Disc", rounded = "Rounded"
    var id: Self { self }
}

/// Every control in the title bar shares this height, so their rounded ends
/// match; anything nested inside one is inset by `inset` on every side and
/// takes the outer radius minus that inset (concentric corners).
enum Bar {
    static let height: CGFloat = 38
    static let inset: CGFloat = 4
    static var inner: CGFloat { height - inset * 2 }
}

/// The last game, one click to carry on: cover, title, when it was saved,
/// and a play button, on one piece of glass.
struct ContinueCapsule: View {
    let game: Game
    let art: ContinueArt
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            cover
            VStack(alignment: .leading, spacing: 0) {
                Text(game.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(game.resume.map { "Saved \(relative($0.date))" } ?? "Played \(relative(game.lastPlayed))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 200, alignment: .leading)
            Button(action: resume) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Bar.inner, height: Bar.inner)
                    .background(.tint, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Resume \(game.title)")
        }
        .padding(Bar.inset)
        .frame(height: Bar.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: resume)
    }

    @ViewBuilder private var cover: some View {
        switch art {
        case .disc:
            // Concentric with the capsule's round end: the cover as a disc.
            Cover(image: game.cover, corner: 0)
                .frame(width: Bar.inner, height: Bar.inner)
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
        case .rounded:
            Cover(image: game.cover, corner: 7)
                .frame(width: Bar.inner, height: Bar.inner)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)))
        }
    }
}

/// Key hints, as a terminal app's status line: hints only, nothing that
/// must be clicked lives down here (HIG Layout).
struct HintLine: View {
    let sim: Sim

    var body: some View {
        HStack(spacing: 6) {
            hint("Return", "Play")
            dot
            hint("⌘F", "Search")
            dot
            hint("⌘,", "Settings")
            Spacer()
            Text("\(sim.shown.count) of \(sim.games.count)")
                .foregroundStyle(.tertiary)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 18)
        .frame(height: 30)
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(.secondary)
            Text(action).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - The panel

struct GridPanel: View {
    @Bindable var sim: Sim
    @Environment(\.colorScheme) private var scheme
    @State private var width: CGFloat = 1000

    var body: some View {
        let games = sim.shown
        let grid = Metrics.grid(width: width)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: sim.tab.symbol).font(.system(size: 13)).foregroundStyle(.secondary)
                Text(sim.tab.rawValue).font(.headline)
                Text(sim.search.isEmpty ? "~/Games" : "matching “\(sim.search)”")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    Button { } label: { Image(systemName: "arrow.up.arrow.down") }.help("Sort By")
                    Button { } label: { Image(systemName: "arrow.down.circle") }.help("Download Missing Covers")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, sim.panelStyle == .none ? 24 : 16)
            .frame(height: 40)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(grid.tile), spacing: Metrics.spacing,
                                                             alignment: .top),
                                         count: grid.columns),
                          alignment: .leading, spacing: 22) {
                    ForEach(games) { game in
                        Tile(game: game, isSelected: sim.selection == game.id)
                            .onTapGesture(count: 2) { sim.opened = game }
                            .simultaneousGesture(TapGesture().onEnded { sim.selection = game.id })
                    }
                }
                .padding(Metrics.padding)
                .padding(.horizontal, sim.panelStyle == .none ? 6 : 0)
                .background {
                    Color.clear.contentShape(.rect).onTapGesture { sim.selection = nil }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if games.isEmpty { ContentUnavailableView.search(text: sim.search) }
            }
        }
        .background(fill, in: .rect(cornerRadius: 12))
        .overlay {
            if sim.panelStyle != .none {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(sim.panelStyle == .outlined ? 0.16 : 0.09))
            }
        }
        .clipShape(.rect(cornerRadius: sim.panelStyle == .none ? 0 : 12))
    }

    private var fill: Color {
        sim.panelStyle == .filled ? (scheme == .dark ? .black.opacity(0.28) : .white.opacity(0.55)) : .clear
    }
}

struct Tile: View {
    let game: Game
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Cover(image: game.cover, corner: 8)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)),
                                      lineWidth: isSelected ? 3 : 1)
                }
            Text(game.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, -4)
        }
        .contentShape(.rect)
        .help(game.title)
    }

    private var subtitle: String {
        if game.discs > 1 { return "\(game.discs) discs" }
        guard let last = game.lastPlayed else { return "Not played yet" }
        let text = relative(last)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

struct Cover: View {
    let image: NSImage?
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 30, weight: .thin))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipShape(.rect(cornerRadius: corner))
    }
}

/// Stands in for the app's resume sheet, which a double click opens.
struct OpenedNote: View {
    let game: Game
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 10) {
                Text("The resume sheet opens here").font(.headline)
                Text(game.title).foregroundStyle(.secondary)
                Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
    }
}
