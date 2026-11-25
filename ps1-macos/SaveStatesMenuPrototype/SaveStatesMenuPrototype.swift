// PROTOTYPE, throwaway. The in-game Save States popover as a list or a
// filmstrip; the filmstrip can magnify under the pointer as the Dock does. The popover is a real one, hung off a stand-in HUD bar over
// a real screenshot. Thumbnails are the real ones in Application Support;
// "Fill" borrows other games' resume screenshots to show a full panel.
// Nothing is wired to the core. Run: ps1-macos/SaveStatesMenuPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Data

let support = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Substation")

struct Entry: Identifiable, Hashable {
    /// 0 is Resume, 1...6 the slots.
    let id: Int
    var date: Date?
    var image: NSImage?
    var isResume: Bool { id == 0 }
    var isEmpty: Bool { date == nil }
    var title: String { isResume ? "Resume" : "Slot \(id)" }
    var subtitle: String {
        guard let date else { return "Empty" }
        return isResume ? "Auto-saved \(savedAt(date))" : savedAt(date)
    }
}

func png(_ url: URL) -> (Date, NSImage)? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .now
    return (date, image)
}

enum Fill: String, CaseIterable, Identifiable {
    case real = "Real"
    case half = "Half full"
    case full = "Full"
    var id: String { rawValue }
}

/// Crash Bandicoot's real states; `fill` tops the slots up with other games'
/// resume screenshots, dated an hour apart.
func loadEntries(_ fill: Fill) -> [Entry] {
    let serial = "SCES-00344"
    var entries = (0...6).map { n -> Entry in
        let url = n == 0
            ? support.appending(path: "ResumeStates/\(serial).png")
            : support.appending(path: "SaveStates/\(serial)/slot\(n).png")
        let found = png(url)
        return Entry(id: n, date: found?.0, image: found?.1)
    }
    let borrowed = ((try? FileManager.default.contentsOfDirectory(
        at: support.appending(path: "ResumeStates"), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasPrefix(serial) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap(png)
    let wanted = fill == .full ? 6 : fill == .half ? 3 : 0
    var next = 0
    for n in 1...6 where entries[n].isEmpty && n <= wanted && next < borrowed.count {
        entries[n].image = borrowed[next].1
        entries[n].date = Date.now.addingTimeInterval(-Double(n) * 3600 * 7)
        next += 1
    }
    return entries
}

func savedAt(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return "Today \(time)" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

// MARK: - Actions

enum Action: Hashable {
    case load, save, overwrite, delete

    func title(_ e: Entry) -> String {
        switch self {
        case .load: "Load"
        case .save: "Save Here"
        case .overwrite: "Overwrite…"
        case .delete: "Delete…"
        }
    }

    /// The trailing buttons, primary last; Delete sits alone on the leading side.
    static func trailing(_ e: Entry) -> [Action] {
        if e.isEmpty { return [.save] }
        return e.isResume ? [.load] : [.overwrite, .load]
    }
}

/// Every mockup reports what it would do through this.
struct Report {
    let send: (Action, Entry) -> Void
    func callAsFunction(_ a: Action, _ e: Entry) { send(a, e) }
}

// MARK: - Shared pieces

struct Thumb: View {
    let entry: Entry
    var radius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(entry.isEmpty ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.black))
            .overlay {
                if let image = entry.image {
                    Image(nsImage: image).resizable().interpolation(.high)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(.rect(cornerRadius: radius))
            // The hairline system thumbnails carry, so a dark frame keeps its edge.
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(entry.isEmpty ? 0 : 0.12), lineWidth: 0.5))
    }
}

struct EntryMenu: View {
    let entry: Entry
    let report: Report

    var body: some View {
        if entry.isEmpty {
            Button("Save to \(entry.title)") { report(.save, entry) }
        } else {
            Button("Load \(entry.title)") { report(.load, entry) }
            if !entry.isResume { Button("Overwrite \(entry.title)…") { report(.overwrite, entry) } }
            Divider()
            Button("Delete \(entry.title)…", role: .destructive) { report(.delete, entry) }
        }
    }
}

/// Arrow keys move the selection, Return is the action bar's default button.
extension View {
    func arrowSelection(_ selection: Binding<Int>, columns: Int, count: Int = 7) -> some View {
        focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { selection.wrappedValue = max(0, selection.wrappedValue - columns); return .handled }
            .onKeyPress(.downArrow) { selection.wrappedValue = min(count - 1, selection.wrappedValue + columns); return .handled }
            .onKeyPress(.leftArrow) { selection.wrappedValue = max(0, selection.wrappedValue - 1); return .handled }
            .onKeyPress(.rightArrow) { selection.wrappedValue = min(count - 1, selection.wrappedValue + 1); return .handled }
    }
}

/// A selected row or tile: the accent highlight a list or a Finder icon view
/// draws (HIG Focus and Selection). Hover only brightens.
struct Highlight: ViewModifier {
    let selected: Bool
    var radius: CGFloat = 8
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                      : AnyShapeStyle(.white.opacity(hover ? 0.06 : 0))))
            .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}

/// Delete on the leading side, the rest trailing with the primary last and
/// on Return (HIG Buttons).
struct ActionBar: View {
    let entry: Entry
    let report: Report

    var body: some View {
        HStack(spacing: 8) {
            if !entry.isEmpty {
                Button("Delete…", role: .destructive) { report(.delete, entry) }
            }
            Spacer()
            let actions = Action.trailing(entry)
            ForEach(actions, id: \.self) { a in
                if a == actions.last {
                    Button(a.title(entry)) { report(a, entry) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(a.title(entry)) { report(a, entry) }
                }
            }
        }
        .controlSize(.regular)
    }
}

// MARK: - List

/// A table, not a grid: the panel is mostly text, and five empty slots cost
/// one line each instead of five black boxes. Select, then act from the bar.
struct ListPanel: View {
    let entries: [Entry]
    let report: Report
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Auto-Save")
            row(entries[0])
            section("Slots").padding(.top, 6)
            ForEach(entries.dropFirst()) { row($0) }
            Divider().padding(.top, 8)
            ActionBar(entry: entries[selection], report: report).padding(12)
        }
        .padding(.top, 6)
        .frame(width: 340)
        .arrowSelection($selection, columns: 1)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
    }

    private func row(_ e: Entry) -> some View {
        let selected = selection == e.id
        return HStack(spacing: 10) {
            Thumb(entry: e, radius: 4).frame(width: 56)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 13, weight: .medium))
                Text(e.subtitle).font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Spacer()
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .modifier(Highlight(selected: selected, radius: 6))
        .padding(.horizontal, 10)
        .contentShape(.rect)
        .onTapGesture(count: 2) { report(Action.trailing(e).last!, e) }
        .simultaneousGesture(TapGesture().onEnded { selection = e.id })
        .contextMenu { EntryMenu(entry: e, report: report) }
    }
}

// MARK: - Filmstrip

/// One row, short enough to leave the game visible above it: Resume, a
/// divider, then the six slots. The selection's name and the bar sit under
/// the strip, so the tiles carry no captions at all.
///
/// With `magnification` above 1 it is a Dock instead of a popover: a glass
/// shelf over the HUD bar whose tiles grow under the pointer and rise out of
/// it into clear space, as the Dock's icons do. A popover could only let them
/// grow into room it kept empty at rest. Like the Dock's, it is a setting and
/// ships off.
struct StripPanel: View {
    let entries: [Entry]
    let report: Report
    @Binding var selection: Int
    var magnification: CGFloat = 1

    var body: some View {
        Group {
            if magnification > 1.001 {
                DockShelf(entries: entries, magnification: magnification,
                          tile: { tile($0, width: $1) }, footer: { footer })
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        tile(entries[0], width: DockShelf<EmptyView, EmptyView>.tileWidth)
                        Divider().frame(height: 60).padding(.horizontal, 4)
                        ForEach(entries.dropFirst()) { tile($0, width: DockShelf<EmptyView, EmptyView>.tileWidth) }
                    }
                    .padding(12)
                    Divider()
                    footer
                }
            }
        }
        .fixedSize()
        .arrowSelection($selection, columns: 7)
    }

    private var footer: some View {
        let e = entries[selection]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(e.title).font(.system(size: 13, weight: .semibold))
                Text(e.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            ActionBar(entry: e, report: report).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func tile(_ e: Entry, width: CGFloat) -> some View {
        let selected = selection == e.id
        return Thumb(entry: e, radius: 6)
            .overlay {
                if e.isEmpty {
                    Text(e.isResume ? "" : "\(e.id)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: width)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.3) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(.rect)
            .onTapGesture(count: 2) { report(Action.trailing(e).last!, e) }
            .simultaneousGesture(TapGesture().onEnded { selection = e.id })
            .contextMenu { EntryMenu(entry: e, report: report) }
            .help(magnification > 1.001 ? "" : "\(e.title) · \(e.subtitle)")
    }
}

/// Resume, a divider and the slots on a glass shelf, laid out by hand so the
/// row can magnify. Each tile grows by its distance from the pointer on a
/// cosine falloff, the row spreads outward from the point under the pointer
/// so that point stays put, and the shelf widens with it. The footer keeps
/// its rest width so its buttons never move. The view's frame is fixed at
/// its largest; everything outside the shelf is clear.
struct DockShelf<Tile: View, Footer: View>: View {
    let entries: [Entry]
    let magnification: CGFloat
    @ViewBuilder let tile: (Entry, CGFloat) -> Tile
    @ViewBuilder let footer: () -> Footer
    @State private var pointer: CGFloat?

    static var tileWidth: CGFloat { 104 }
    /// A tile's padding round the picture, for the selection ring.
    static var inset: CGFloat { 3 }
    static var gap: CGFloat { 6 }
    static var dividerWidth: CGFloat { 17 }
    static var labelHeight: CGFloat { 30 }
    static var pad: CGFloat { 12 }
    static var footerHeight: CGFloat { 54 }

    private var itemWidth: CGFloat { Self.tileWidth + 2 * Self.inset }
    private var restHeight: CGFloat { Self.tileWidth * 3 / 4 + 2 * Self.inset }
    /// How far the pointer's pull reaches either side: about two and a half tiles.
    private var reach: CGFloat { itemWidth * 2.5 }

    /// nil marks the divider.
    private var items: [Entry?] { [entries[0], nil] + entries.dropFirst().map { $0 } }

    private func restWidth(_ item: Entry?) -> CGFloat { item == nil ? Self.dividerWidth : itemWidth }

    private var restTotal: CGFloat {
        items.map(restWidth).reduce(0, +) + Self.gap * CGFloat(items.count - 1)
    }

    private var restLefts: [CGFloat] {
        var x: CGFloat = 0
        return items.map { item in
            defer { x += restWidth(item) + Self.gap }
            return x
        }
    }

    private func scale(_ i: Int, pointer p: CGFloat?, origin: CGFloat) -> CGFloat {
        guard let p, items[i] != nil else { return 1 }
        let centre = origin + restLefts[i] + restWidth(items[i]) / 2
        let d = abs(p - centre) / reach
        guard d < 1 else { return 1 }
        return 1 + (magnification - 1) * (1 + cos(.pi * d)) / 2
    }

    /// The most the row widens, wherever the pointer is.
    private var maxExtra: CGFloat {
        stride(from: 0, through: restTotal, by: 4).map { p in
            items.indices.map { i in restWidth(items[i]) * (scale(i, pointer: p, origin: 0) - 1) }.reduce(0, +)
        }.max() ?? 0
    }

    var body: some View {
        let extra = maxExtra
        let pad = Self.pad
        let width = restTotal + extra + 2 * pad
        let headroom = Self.tileWidth * 3 / 4 * (magnification - 1) + Self.labelHeight
        let height = headroom + pad + restHeight + pad + Self.footerHeight
        let rowBottom = headroom + pad + restHeight
        let origin = pad + extra / 2
        let layout = place(origin: origin, frame: width)
        let shelfLeft = min(layout.first!.0, origin) - pad
        let shelfRight = max(layout.last!.0 + layout.last!.1, origin + restTotal) + pad
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20).fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .frame(width: shelfRight - shelfLeft, height: height - headroom)
                .offset(x: shelfLeft, y: headroom)
            ForEach(items.indices, id: \.self) { i in
                let (left, w) = layout[i]
                if let entry = items[i] {
                    let picture = w - 2 * Self.inset
                    let h = picture * 3 / 4 + 2 * Self.inset
                    tile(entry, picture).position(x: left + w / 2, y: rowBottom - h / 2)
                } else {
                    Rectangle().fill(.separator).frame(width: 1, height: restHeight * 0.6)
                        .position(x: left + w / 2, y: rowBottom - restHeight / 2)
                }
            }
            if let label = hovered(layout) {
                let (left, w) = layout[label]
                let h = (w - 2 * Self.inset) * 3 / 4 + 2 * Self.inset
                DockLabel(entry: items[label]!)
                    .position(x: left + w / 2, y: rowBottom - h - Self.labelHeight / 2 + 2)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Divider()
                footer()
            }
            .frame(width: restTotal + 2 * pad, height: Self.footerHeight)
            .offset(x: origin - pad, y: height - Self.footerHeight)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onContinuousHover { phase in
            switch phase {
            case .active(let at) where at.y > headroom - Self.labelHeight && at.y < rowBottom + pad:
                pointer = at.x
            default:
                if pointer != nil { withAnimation(.easeOut(duration: 0.18)) { pointer = nil } }
            }
        }
        .animation(.easeOut(duration: 0.12), value: pointer == nil)
    }

    /// Left edge and width of every item. The magnified row is shifted so the
    /// point under the pointer stays under it, then kept inside the frame.
    private func place(origin: CGFloat, frame: CGFloat) -> [(CGFloat, CGFloat)] {
        let widths = items.indices.map { restWidth(items[$0]) * scale($0, pointer: pointer, origin: origin) }
        var x: CGFloat = 0
        let lefts = widths.map { w in
            defer { x += w + Self.gap }
            return x
        }
        let total = x - Self.gap
        guard let p = pointer else { return zip(lefts, widths).map { ($0 + origin, $1) } }
        // Where the pointer's rest position lands in the magnified row.
        var landed = total
        for i in items.indices {
            let restLeft = origin + restLefts[i]
            let restRight = restLeft + restWidth(items[i])
            if p < restLeft {
                landed = lefts[i] - (restLeft - p)
                break
            }
            if p <= restRight {
                landed = lefts[i] + (p - restLeft) / restWidth(items[i]) * widths[i]
                break
            }
        }
        let shift = min(max(p - landed, Self.pad), frame - Self.pad - total)
        return zip(lefts, widths).map { ($0 + shift, $1) }
    }

    private func hovered(_ layout: [(CGFloat, CGFloat)]) -> Int? {
        guard let p = pointer else { return nil }
        return items.indices.first { i in
            items[i] != nil && p >= layout[i].0 - Self.gap / 2 && p <= layout[i].0 + layout[i].1 + Self.gap / 2
        }
    }
}

/// The name over the magnified tile, as the Dock names an app.
struct DockLabel: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 4) {
            Text(entry.title).fontWeight(.medium)
            if let date = entry.date { Text(savedAt(date)).foregroundStyle(.white.opacity(0.7)) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

// MARK: - Shell

let startFill = Fill(rawValue: ProcessInfo.processInfo.environment["FILL"] ?? "") ?? .real

enum Mockup: String, CaseIterable, Identifiable {
    case list = "List"
    case strip = "Filmstrip"
    var id: String { rawValue }
}

struct Root: View {
    @State private var mockup = Mockup(rawValue: ProcessInfo.processInfo.environment["MOCKUP"] ?? "") ?? .list
    @State private var fill = startFill
    /// Stands in for the Settings switch and its size slider, as the Dock's.
    @State private var magnify = ProcessInfo.processInfo.environment["MAGNIFY"] != nil
    @State private var size: CGFloat = 1.8
    @State var shown = true
    @State private var selection = 1
    @State var last = ""
    @State var entries = loadEntries(startFill)
    let backdrop = png(support.appending(path: "ResumeStates/SCES-00344.png"))?.1

    var body: some View {
        let report = Report(send: act)
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mockup) {
                    ForEach(Mockup.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Picker("Fill", selection: $fill) {
                    ForEach(Fill.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                if mockup == .strip {
                    Toggle("Magnification", isOn: $magnify)
                    Slider(value: $size, in: 1.2...2.6) { Text("Size") }
                        .frame(width: 140)
                        .disabled(!magnify)
                }
                Spacer()
            }
            .padding(10)
            .background(.bar)
            .zIndex(1)
            ZStack(alignment: .bottom) {
                if let backdrop {
                    Image(nsImage: backdrop).resizable().interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                let docked = mockup == .strip && magnify
                if docked && shown {
                    StripPanel(entries: entries, report: report, selection: $selection, magnification: size)
                        .onKeyPress(.escape) { shown = false; return .handled }
                        .padding(.bottom, 100)
                        .transition(.opacity)
                }
                HudBar(shown: $shown, popover: !docked) {
                    Group {
                        switch mockup {
                        case .list: ListPanel(entries: entries, report: report, selection: $selection)
                        case .strip:
                            StripPanel(entries: entries, report: report, selection: $selection)
                        }
                    }
                    .onKeyPress(.escape) { shown = false; return .handled }
                }
                .padding(.bottom, 28)
                if !last.isEmpty {
                    Text("→ \(last)")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
        .frame(minWidth: 1000, minHeight: 720)
        .preferredColorScheme(.dark)
        .onChange(of: fill) { entries = loadEntries(fill) }
        .onChange(of: magnify) { shown = false; DispatchQueue.main.async { shown = true } }
        .onChange(of: mockup) { shown = false; DispatchQueue.main.async { shown = true } }
    }
}

extension Root {
    /// Load goes back to the game, so it closes the panel. Save, Overwrite
    /// and Delete leave it open with the slot changed in place: the new
    /// screenshot appearing is the confirmation. Overwrite and Delete would
    /// ask with an alert first; the prototype skips it.
    func act(_ a: Action, _ e: Entry) {
        switch a {
        case .load:
            shown = false
            last = "Loaded \(e.title)"
        case .save, .overwrite:
            entries[e.id] = Entry(id: e.id, date: .now, image: backdrop)
            last = a == .save ? "Saved to \(e.title)" : "Overwrote \(e.title) (after an alert)"
        case .delete:
            entries[e.id] = Entry(id: e.id)
            last = "Deleted \(e.title) (after an alert)"
        }
    }
}

/// A stand-in for the game HUD: only the Save States button does anything.
struct HudBar<Panel: View>: View {
    @Binding var shown: Bool
    /// Off while the filmstrip floats as a Dock, which the stage draws itself.
    let popover: Bool
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: "play.fill")
            Button { shown.toggle() } label: {
                Image(systemName: "rectangle.stack").frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .popover(isPresented: popover ? $shown : .constant(false), arrowEdge: .top, content: panel)
            Image(systemName: "camera")
            Divider().frame(height: 20)
            Text("1×").font(.system(size: 15, weight: .medium))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
            Image(systemName: "speaker.wave.2.fill")
            Image(systemName: "ellipsis")
        }
        .font(.system(size: 17))
        .foregroundStyle(.white)
        .padding(.horizontal, 26).padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
    }
}

@main
struct SaveStatesMenuPrototypeApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Save States Mockups") { Root() }
    }
}
