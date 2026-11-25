// PROTOTYPE, throwaway. The launch sheet's resume prompt, three ways:
// A (hero + state strip), B (compact column), C (tiles). Thumbnails are the
// real ones in Application Support. Nothing is wired to the core.
// Run: ps1-macos/ResumePrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Fake data

let support = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Substation")

struct SavedState: Identifiable, Hashable {
    let id: String
    let title: String
    let date: Date
    let image: NSImage?
    var isResume: Bool { id == "resume" }
}

struct Game: Identifiable, Hashable {
    let id: String
    let title: String
    let states: [SavedState]
}

func state(_ id: String, _ title: String, _ url: URL) -> SavedState? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
    return SavedState(id: id, title: title, date: date, image: NSImage(contentsOf: url))
}

func loadGames() -> [Game] {
    let rows = [("SCES-00344", "Crash Bandicoot"), ("SLUS-00707", "Silent Hill"),
                ("SCUS-94163", "Final Fantasy VII"), ("SLUS-00530", "Hot Wheels Turbo Racing")]
    return rows.compactMap { serial, title in
        let resume = support.appending(path: "ResumeStates")
        var states = [state("resume", "Resume", resume.appending(path: "\(serial).png")),
                      state("previous", "Previous Resume", resume.appending(path: "\(serial).prev.png"))]
        for n in 1...6 {
            states.append(state("slot\(n)", "Slot \(n)",
                                support.appending(path: "SaveStates/\(serial)/slot\(n).png")))
        }
        let found = states.compactMap { $0 }
        return found.isEmpty ? nil : Game(id: serial, title: title, states: found)
    }
}

func covers() -> [NSImage] {
    let dir = support.appending(path: "Covers")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "png" }.prefix(24).compactMap { NSImage(contentsOf: $0) }
}

func savedAt(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return "Today \(time)" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
    return "\(date.formatted(.dateTime.day().month(.abbreviated).year())) at \(time)"
}

enum Variant: String, CaseIterable, Identifiable {
    case a = "A · Hero + strip", b = "B · Compact", c = "C · Tiles", old = "Current"
    var id: String { rawValue }
}

struct Ctx {
    let game: Game
    let discMissing: Bool
    var width: CGFloat = 1000
    let choose: (String) -> Void
    var resume: SavedState? { game.states.first { $0.isResume } }
    var others: [SavedState] { game.states.filter { !$0.isResume } }
    func canLoad(_ s: SavedState) -> Bool { !(s.isResume && discMissing) }
}

// MARK: - Shared pieces

struct Thumb: View {
    let image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.black).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }
}

/// The screenshot with the game and the state's age laid over its foot.
struct Hero: View {
    let title: String
    let state: SavedState
    var radius: CGFloat = 16
    var body: some View {
        Thumb(image: state.image)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text("\(state.title) · \(savedAt(state.date))")
                        .font(.callout).foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                           startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .animation(.snappy, value: state)
    }
}

struct MissingDiscNote: View {
    var body: some View {
        Label("The disc this state was saved on is no longer in the library.",
              systemImage: "opticaldisc").font(.caption).foregroundStyle(.secondary)
    }
}

/// Start Fresh, with the destructive variant one click further away.
struct StartFreshMenu: View {
    let ctx: Ctx
    var body: some View {
        Menu("Start Fresh") {
            Button("Delete Resume & Start Fresh", systemImage: "trash", role: .destructive) {
                ctx.choose("Delete resume + previous, then fresh boot")
            }
        } primaryAction: {
            ctx.choose("Fresh boot (states kept)")
        }
        .fixedSize()
    }
}

// MARK: - A: hero + strip

struct VariantA: View {
    let ctx: Ctx
    @State private var selected: SavedState?

    var body: some View {
        let current = selected ?? ctx.resume ?? ctx.others[0]
        VStack(spacing: 14) {
            Hero(title: ctx.game.title, state: current)
            if ctx.game.states.count > 1 {
                HStack(spacing: 10) {
                    ForEach(ctx.game.states) { s in
                        Button { selected = s } label: {
                            VStack(spacing: 4) {
                                Thumb(image: s.image)
                                    .frame(width: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(s == current ? Color.accentColor : .white.opacity(0.12),
                                                      lineWidth: s == current ? 2.5 : 1))
                                Text(s.isResume ? "Resume" : s.title.replacingOccurrences(of: " Resume", with: ""))
                                    .font(.caption2)
                                    .foregroundStyle(s == current ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
            if ctx.discMissing && current.isResume { MissingDiscNote() }
            HStack(spacing: 10) {
                Button("Cancel") { ctx.choose("Cancel") }.keyboardShortcut(.cancelAction)
                Spacer()
                StartFreshMenu(ctx: ctx)
                Button(current.isResume ? "Resume" : "Load \(current.title)") {
                    ctx.choose("Load \(current.title)")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!ctx.canLoad(current))
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 540)
    }
}

// MARK: - B: compact column

struct VariantB: View {
    let ctx: Ctx
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 12) {
            if let resume = ctx.resume {
                Hero(title: ctx.game.title, state: resume, radius: 14)
            } else {
                Hero(title: ctx.game.title, state: ctx.others[0], radius: 14).opacity(0.5)
            }
            if ctx.discMissing { MissingDiscNote() }
            VStack(spacing: 8) {
                Button { ctx.choose("Load Resume") } label: {
                    Text("Resume").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(ctx.resume == nil || ctx.discMissing)
                Button { ctx.choose("Fresh boot (states kept)") } label: {
                    Text("Start Fresh").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            if !ctx.others.isEmpty {
                VStack(spacing: 0) {
                    Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                        HStack {
                            Text("Other States").font(.callout.weight(.medium))
                            Text("\(ctx.others.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        ForEach(ctx.others) { s in
                            Row(state: s) { ctx.choose("Load \(s.title)") }
                        }
                    }
                }
            }
            HStack {
                Button("Cancel") { ctx.choose("Cancel") }.keyboardShortcut(.cancelAction)
                Spacer()
                if ctx.resume != nil || ctx.others.contains(where: { $0.id == "previous" }) {
                    Button("Delete Resume…", role: .destructive) {
                        ctx.choose("Confirm, then delete resume + previous")
                    }
                    .foregroundStyle(.red)
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 380)
    }

    struct Row: View {
        let state: SavedState
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Thumb(image: state.image).frame(width: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.title).font(.callout)
                        Text(savedAt(state.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "play.fill").font(.caption).opacity(hover ? 1 : 0)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

// MARK: - C: tiles

/// Resume pinned on the left, the other states scrolling beside it, and
/// Start Fresh set apart past a divider.
struct VariantC: View {
    let ctx: Ctx
    static let tile: CGFloat = 150
    static let gap: CGFloat = 12
    static let step = tile + gap
    /// Everything but the strip: padding, divider and the Start Fresh tile.
    static let chrome: CGFloat = 20 * 2 + gap + 1 + gap + tile
    /// The least of the next tile that peeks when the strip scrolls.
    static let peek: CGFloat = 22
    static let inset: CGFloat = 4

    /// Whole tiles that fit the width the sheet has (1...3); past that the
    /// strip pages and the next tile peeks.
    var visible: Int {
        let strip = ctx.width - 48 - Self.chrome - Self.gap - Self.peek
        return max(1, min(3, Int((strip + Self.gap) / Self.step)))
    }

    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0
    @State private var hovering = false
    @State private var pendingDelete: SavedState?

    var body: some View {
        let states = ctx.game.states
        let scrolls = states.count > visible
        let width = CGFloat(min(states.count, visible)) * Self.step - Self.gap + (scrolls ? Self.gap + Self.peek : 0)
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(ctx.game.title).font(.title3.weight(.semibold))
                Text("Pick up where you left off").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Self.gap) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(states) { tile($0) }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, Self.inset)
                }
                .scrollIndicators(.never)
                .scrollDisabled(!scrolls)
                .scrollPosition($position)
                .scrollTargetBehavior(.viewAligned)
                .onScrollGeometryChange(for: [CGFloat].self) {
                    [$0.contentOffset.x, $0.contentSize.width - $0.containerSize.width]
                } action: { _, g in
                    offset = g[0]
                    maxOffset = g[1]
                }
                .frame(width: width)
                .padding(.vertical, -Self.inset)
                .overlay(alignment: .topLeading) {
                    if scrolls && hovering && offset > 1 {
                        PageArrow(symbol: "chevron.left") { page(by: -1) }
                            .padding(.leading, 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if scrolls && hovering && offset < maxOffset - 1 {
                        PageArrow(symbol: "chevron.right") { page(by: 1) }
                            .padding(.trailing, 6)
                    }
                }
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
                Divider().frame(height: Self.tile * 3 / 4)
                FreshTile { ctx.choose("Fresh boot (states kept)") }
            }
            .fixedSize()
            Button("Cancel") { ctx.choose("Cancel") }.keyboardShortcut(.cancelAction)
                .buttonStyle(.glass).controlSize(.large)
        }
        .padding(20)
        .fixedSize()
        .alert("Delete \(pendingDelete?.title ?? "")?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { s in
            Button("Delete") { ctx.choose("Delete \(s.title)") }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    /// Pages by the tiles in view, clamped to the ends.
    private func page(by direction: CGFloat) {
        let x = offset + direction * Self.step * CGFloat(visible)
        withAnimation(.snappy) { position.scrollTo(x: min(max(x, 0), maxOffset)) }
    }

    /// The paging arrow Apple Music puts on a shelf: a flat grey pill over
    /// the content, not glass, shown while the pointer is over the shelf.
    struct PageArrow: View {
        let symbol: String
        let action: () -> Void
        @State private var pressed = false
        var body: some View {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 52)
                    .background(Capsule().fill(Color(white: 0.42).opacity(0.92)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressDim())
            .padding(.top, VariantC.tile * 3 / 8 - 26 + VariantC.inset)
            .transition(.opacity)
        }
    }

    /// Every custom button needs a press state (HIG, Buttons).
    struct PressDim: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
        }
    }

    private func tile(_ s: SavedState) -> some View {
        Tile(state: s, enabled: ctx.canLoad(s), note: s.isResume && ctx.discMissing ? "Disc missing" : nil,
             action: { ctx.choose("Load \(s.title)") },
             delete: { pendingDelete = s })
            .contextMenu {
                Button("Load \(s.title)") { ctx.choose("Load \(s.title)") }
                Divider()
                Button("Delete \(s.title)…", role: .destructive) { pendingDelete = s }
            }
    }

    /// A state: its screenshot, the accent outline on Resume (the default,
    /// Return), and on hover only a play glyph, as Music's shelves do.
    struct Tile: View {
        let state: SavedState
        let enabled: Bool
        let note: String?
        let action: () -> Void
        let delete: () -> Void
        @State private var hover = ProcessInfo.processInfo.environment["PROTO_HOVER"] != nil
        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    Thumb(image: state.image)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(state.isResume ? Color.accentColor : .white.opacity(0.12),
                                          lineWidth: state.isResume ? 2.5 : 1))
                        .overlay {
                            // The dimming layer clear glass needs over a bright image (HIG: 35%).
                            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(hover ? 0.35 : 0))
                        }
                    Text(state.title).font(.callout.weight(state.isResume ? .semibold : .regular))
                    Text(note ?? savedAt(state.date)).font(.caption)
                        .foregroundStyle(note == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                .frame(width: VariantC.tile)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .disabled(!enabled)
            .keyboardShortcut(state.isResume ? .defaultAction : nil)
            .overlay(alignment: .top) {
                // Music's hover controls: matching circles in the bottom corners
                // of the artwork, play leading and the secondary action trailing.
                if hover {
                    HStack {
                        if enabled {
                            CornerButton(symbol: "play.fill", help: "Load \(state.title)", action: action)
                        }
                        Spacer()
                        CornerButton(symbol: "trash", help: "Delete \(state.title)", destructive: true, action: delete)
                    }
                    .padding(8)
                    .frame(width: VariantC.tile, height: VariantC.tile * 3 / 4, alignment: .bottom)
                    .transition(.opacity)
                }
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
    }

    /// A hover control on the artwork: clear Liquid Glass, the HIG's variant
    /// for controls over media, on the tile's dimming scrim. The destructive
    /// one fills red only under the pointer.
    struct CornerButton: View {
        let symbol: String
        let help: String
        var destructive = false
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(destructive && hover ? Color.red : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(PressDim())
            .glassEffect(.clear.interactive(), in: Circle())
            .help(help)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
    }

    /// Start Fresh, set apart past the divider.
    struct FreshTile: View {
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.25))
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay { Image(systemName: "power").font(.system(size: 26)).foregroundStyle(.secondary) }
                    Text("Start Fresh").font(.callout)
                    Text("Boot the disc").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: VariantC.tile)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
        }
    }
}

// MARK: - The current sheet, for comparison

struct Current: View {
    let ctx: Ctx
    var body: some View {
        VStack(spacing: 14) {
            Text("Resume \(ctx.game.title)?").font(.headline)
            Thumb(image: (ctx.resume ?? ctx.others[0]).image).frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(ctx.resume.map { "Saved \(savedAt($0.date))" } ?? "No resume state.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Cancel") {}
                if !ctx.others.isEmpty { Menu("Other States") {}.fixedSize() }
                Spacer()
                Button("Delete & Boot", role: .destructive) {}
                Button("Fresh Boot") {}
                Button("Resume") {}.buttonStyle(.glassProminent)
            }
            .buttonStyle(.glass).controlSize(.large)
        }
        .padding(24).frame(width: 520)
    }
}

// MARK: - Shell

struct Root: View {
    let games = loadGames()
    let backdrop = covers()
    @State private var variant = Variant.c
    @State private var gameID = loadGames().first?.id ?? ""
    @State private var discMissing = false
    @State private var last = ""
    @State private var extra = 3
    @State private var width: CGFloat = 1000

    var body: some View {
        let base = games.first { $0.id == gameID } ?? games[0]
        let game = Game(id: base.id, title: base.title, states: base.states + (0..<extra).map { i in
            let pool = games.flatMap(\.states)
            let s = pool[i % pool.count]
            return SavedState(id: "fake\(i)", title: "Slot \(i + 2)", date: s.date, image: s.image)
        })
        let ctx = Ctx(game: game, discMissing: discMissing, width: width) { last = $0 }
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $variant) {
                    ForEach(Variant.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Picker("Game", selection: $gameID) {
                    ForEach(games) { Text("\($0.title) (\($0.states.count))").tag($0.id) }
                }
                .fixedSize()
                Toggle("Disc missing", isOn: $discMissing)
                Stepper("Extra slots: \(extra)", value: $extra, in: 0...5)
                Spacer()
            }
            .padding(10)
            ZStack {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 6), spacing: 18) {
                    ForEach(backdrop.indices, id: \.self) { i in
                        Image(nsImage: backdrop[i]).resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 160).clipped()
                    }
                }
                .padding(20)
                .blur(radius: 14)
                .overlay(Color.black.opacity(0.45))
                Group {
                    switch variant {
                    case .a: VariantA(ctx: ctx)
                    case .b: VariantB(ctx: ctx)
                    case .c: VariantC(ctx: ctx)
                    case .old: Current(ctx: ctx)
                    }
                }
                .id("\(variant)-\(gameID)-\(extra)")
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                .shadow(radius: 30)
                if !last.isEmpty {
                    Text("→ \(last)")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .clipped()
            .background(.black)
        }
        .frame(minWidth: 480, minHeight: 560)
        .preferredColorScheme(.dark)
    }
}

@main
struct ResumePrototypeApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Resume Prompt Prototype") { Root() }
    }
}
