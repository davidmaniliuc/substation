// PROTOTYPE, throwaway. The Substation theme's animated backdrop, three ways,
// under a fake library table:
//   A  MeshGradient, animated (no shader at all)
//   B  MeshGradient + a grain colorEffect
//   C  our own shader: drifting points blended in Oklab, plus grain
// Every choice is in the toolbar. Reduce Motion and an inactive window both
// freeze the backdrop on its current frame. Nothing is wired to the core.
// Run: ps1-macos/BackdropPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Choices

enum Variant: String, CaseIterable, Identifiable {
    case mesh = "Mesh", meshGrain = "Mesh + Grain", shader = "Shader"
    var id: Self { self }
}

enum Scrim: String, CaseIterable, Identifiable {
    case none = "None", dim = "Dim", material = "Material"
    var id: Self { self }
}

struct Palette: Identifiable, Hashable {
    let name: String
    let colors: [Color]
    var id: String { name }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// Stands for the selected game's cover; resolved in ContentView.
    static let fromCover = Palette(name: "From Selected Game", colors: [])

    static let all = [
        Palette(name: "Substation", colors: [rgb(0.05, 0.06, 0.22), rgb(0.30, 0.12, 0.55), rgb(0.02, 0.35, 0.55),
                                             rgb(0.55, 0.10, 0.40), rgb(0.02, 0.02, 0.08), rgb(0.08, 0.45, 0.48)]),
        Palette(name: "PlayStation", colors: [rgb(0.50, 0.08, 0.12), rgb(0.55, 0.40, 0.04), rgb(0.03, 0.35, 0.22),
                                              rgb(0.06, 0.16, 0.50), rgb(0.02, 0.02, 0.04), rgb(0.03, 0.03, 0.10)]),
        Palette(name: "Midnight", colors: [rgb(0.02, 0.04, 0.12), rgb(0.05, 0.12, 0.32), rgb(0.10, 0.22, 0.45),
                                           rgb(0.04, 0.08, 0.22), rgb(0.01, 0.01, 0.04), rgb(0.12, 0.10, 0.35)]),
        Palette(name: "Graphite", colors: [rgb(0.10, 0.10, 0.12), rgb(0.20, 0.21, 0.24), rgb(0.14, 0.16, 0.22),
                                           rgb(0.26, 0.25, 0.27), rgb(0.03, 0.03, 0.04), rgb(0.12, 0.13, 0.16)]),
        Palette(name: "Ember", colors: [rgb(0.25, 0.03, 0.03), rgb(0.60, 0.18, 0.04), rgb(0.40, 0.05, 0.10),
                                        rgb(0.70, 0.38, 0.08), rgb(0.04, 0.01, 0.01), rgb(0.20, 0.05, 0.12)]),
        Palette(name: "Aurora", colors: [rgb(0.02, 0.10, 0.12), rgb(0.05, 0.55, 0.40), rgb(0.10, 0.25, 0.60),
                                         rgb(0.40, 0.15, 0.55), rgb(0.01, 0.03, 0.06), rgb(0.20, 0.65, 0.55)]),
        Palette(name: "Sunset", colors: [rgb(0.20, 0.04, 0.10), rgb(0.75, 0.30, 0.10), rgb(0.55, 0.08, 0.30),
                                         rgb(0.85, 0.55, 0.20), rgb(0.06, 0.02, 0.08), rgb(0.35, 0.10, 0.45)]),
    ]

    /// sRGB triples for the shader.
    var floats: [Float] {
        colors.flatMap { color -> [Float] in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
        }
    }
}

let shaders: ShaderLibrary = {
    let url = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "Backdrop.metallib")
    return ShaderLibrary(url: url)
}()

/// Six colours from a game's cover: the most vivid pixels of a 24x24
/// thumbnail with distinct hues, darkened so white text stays readable, and
/// a near-black anchor.
func coverPalette(serial: String) -> Palette? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Substation/Covers/\(serial).png")
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let side = 24
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard drawn else { return nil }

    var pixels: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
    for i in stride(from: 0, to: bytes.count, by: 4) {
        let c = NSColor(srgbRed: CGFloat(bytes[i]) / 255, green: CGFloat(bytes[i + 1]) / 255,
                        blue: CGFloat(bytes[i + 2]) / 255, alpha: 1)
        pixels.append((c.hueComponent, c.saturationComponent, c.brightnessComponent))
    }
    pixels.sort { $0.s * $0.b > $1.s * $1.b }

    var picked: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
    for p in pixels where picked.count < 5 {
        let distinct = picked.allSatisfy { q in
            let d = abs(p.h - q.h)
            return min(d, 1 - d) > 0.06 || abs(p.b - q.b) > 0.3
        }
        if distinct { picked.append(p) }
    }
    guard !picked.isEmpty else { return nil }
    var colors = picked.map { p in
        Color(hue: p.h, saturation: min(p.s * 1.1, 1), brightness: min(p.b, 0.7) * 0.7)
    }
    while colors.count < 5 { colors.append(colors[colors.count % picked.count]) }
    let anchor = Color(hue: picked[0].h, saturation: 0.6, brightness: 0.05)
    return Palette(name: serial, colors: colors + [anchor])
}

// MARK: - Backdrop

struct Backdrop: View {
    let variant: Variant
    let palette: Palette
    let fps: Double
    let speed: Double
    let grain: Double
    let paused: Bool

    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSince(start) * speed
            switch variant {
            case .mesh: mesh(t)
            case .meshGrain: mesh(t).colorEffect(shaders.grain(.float(grain)))
            case .shader: blobs(t)
            }
        }
    }

    /// 3x3 mesh: corners pinned, edge midpoints slide along their edge,
    /// the centre wanders.
    private func mesh(_ t: Double) -> some View {
        func s(_ f: Double, _ p: Double) -> Float { Float(sin(t * f + p)) }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + 0.3 * s(0.21, 0), 0], [1, 0],
            [0, 0.5 + 0.3 * s(0.17, 1)], [0.5 + 0.25 * s(0.13, 2), 0.5 + 0.25 * s(0.19, 3)], [1, 0.5 + 0.3 * s(0.23, 4)],
            [0, 1], [0.5 + 0.3 * s(0.15, 5), 1], [1, 1],
        ]
        let c = palette.colors
        return MeshGradient(width: 3, height: 3, points: points,
                            colors: [c[4], c[0], c[1], c[2], c[3], c[5], c[1], c[0], c[4]],
                            colorSpace: .perceptual)
    }

    private func blobs(_ t: Double) -> some View {
        let colors = palette.floats
        return GeometryReader { proxy in
            Rectangle().colorEffect(shaders.blobs(.float2(proxy.size), .float(t),
                                                  .floatArray(colors), .float(1.6), .float(grain)))
        }
    }
}

// MARK: - Fake library

struct GameRow: Identifiable {
    let id = UUID()
    let title, region, serial, played: String
}

let games = [
    GameRow(title: "Crash Bandicoot", region: "Europe", serial: "SCES-00344", played: "Today"),
    GameRow(title: "Crash Bandicoot: Warped", region: "USA", serial: "SCUS-94244", played: "Yesterday"),
    GameRow(title: "Croc: Legend of the Gobbos", region: "USA", serial: "SLUS-00238", played: "12 Oct"),
    GameRow(title: "Final Fantasy VII", region: "USA", serial: "SCUS-94163", played: "11 Oct"),
    GameRow(title: "Final Fantasy VIII", region: "USA", serial: "SLUS-00892", played: "10 Oct"),
    GameRow(title: "Rayman", region: "Europe", serial: "SLES-00049", played: "9 Oct"),
    GameRow(title: "Silent Hill", region: "USA", serial: "SLUS-00707", played: "8 Oct"),
    GameRow(title: "Spyro the Dragon", region: "USA", serial: "SCUS-94228", played: "2 Oct"),
    GameRow(title: "Tekken 3", region: "USA", serial: "SLUS-00402", played: "28 Sep"),
    GameRow(title: "Tomb Raider", region: "USA", serial: "SLUS-00152", played: "20 Sep"),
    GameRow(title: "Tony Hawk's Pro Skater", region: "USA", serial: "SLUS-00860", played: "14 Sep"),
]

// MARK: - Window

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    @State private var variant = Variant.shader
    @State private var palette = Palette.all[1]
    @State private var scrim = Scrim.dim
    @State private var fps = 30.0
    @State private var speed = 0.5
    @State private var grain = 3.0
    @State private var paused = false
    @State private var selection: GameRow.ID? = games.first?.id

    /// The palette on screen: the menu's choice, or the selected game's cover.
    private var shownPalette: Palette {
        guard palette == .fromCover else { return palette }
        let serial = games.first { $0.id == selection }?.serial
        return serial.flatMap { coverPalette(serial: $0) } ?? Palette.all[0]
    }

    var body: some View {
        Table(games, selection: $selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Region", value: \.region).width(90)
            TableColumn("Serial", value: \.serial).width(110)
            TableColumn("Last Played", value: \.played).width(110)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background {
            ZStack {
                Backdrop(variant: variant, palette: shownPalette, fps: fps, speed: speed, grain: grain,
                         paused: paused || reduceMotion || activeState == .inactive)
                    .id(shownPalette)
                    .transition(.opacity)
                switch scrim {
                case .none: EmptyView()
                case .dim: Color.black.opacity(0.45)
                case .material: Rectangle().fill(.thinMaterial)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: shownPalette)
            .ignoresSafeArea()
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Backdrop", selection: $variant) {
                    ForEach(Variant.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Menu("Options", systemImage: "slider.horizontal.3") {
                    Picker("Palette", selection: $palette) {
                        Text(Palette.fromCover.name).tag(Palette.fromCover)
                        Divider()
                        ForEach(Palette.all) { Text($0.name).tag($0) }
                    }
                    Picker("Scrim", selection: $scrim) {
                        ForEach(Scrim.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame Rate", selection: $fps) {
                        ForEach([10.0, 15, 30, 60], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                    }
                    Picker("Speed", selection: $speed) {
                        ForEach([0.25, 0.5, 1], id: \.self) { Text("\($0.formatted())x").tag($0) }
                    }
                    Picker("Grain", selection: $grain) {
                        ForEach([0.0, 3, 6, 12], id: \.self) { Text($0 == 0 ? "Off" : "\(Int($0))").tag($0) }
                    }
                }
            }
            ToolbarItem {
                Toggle("Pause", systemImage: paused ? "play.fill" : "pause.fill", isOn: $paused)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

@main
struct BackdropPrototype: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("Library") {
            ContentView()
                .preferredColorScheme(.dark)
                .onAppear { NSApp.activate() }
        }
        .defaultSize(width: 900, height: 560)
    }
}
