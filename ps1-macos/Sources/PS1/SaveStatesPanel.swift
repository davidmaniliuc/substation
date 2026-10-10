import AppKit
import SwiftUI

/// The Resume state on its own beside a divider, slots 1-6 in a 3×2 grid.
/// A click on an empty slot saves there; a filled tile asks what to do with
/// it rather than acting at once: one stray click must never overwrite a save. Shown in a popover, a window of
/// its own, so it may leave the game window; the highlight and the sheet
/// are `SaveStatesNavigation`'s, so the keys and a controller drive the same
/// panel the mouse does.
struct SaveStatesPanel: View {
    @Bindable var model: EmulatorViewModel

    static let tileWidth: CGFloat = 150

    var body: some View {
        let nav = model.saveStatesNav
        HStack(alignment: .top, spacing: 16) {
            // The title shares Resume's column, and the tile is centred on
            // the slots' height.
            tile(0, nav: nav)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text("Save States").font(.system(size: 17, weight: .bold))
                }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tileWidth), spacing: 12), count: 3),
                      spacing: 12) {
                ForEach(Array(StateSource.slots), id: \.self) { tile($0, nav: nav) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .overlay {
            if let sheet = nav?.sheet {
                ZStack {
                    Rectangle().fill(.black.opacity(0.35))
                        .onTapGesture { model.pressSheet(.cancel) }
                    SlotSheet(source: Self.source(sheet.tile), info: info(sheet.tile),
                              sheet: sheet) { model.pressSheet($0) }
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: nav?.sheet)
    }

    private func tile(_ n: Int, nav: SaveStatesNavigation?) -> some View {
        SlotTile(source: Self.source(n), info: info(n),
                 selected: nav?.selection == n && nav?.sheet == nil && nav?.showsSelection == true,
                 enabled: nav?.isSelectable(n) ?? false,
                 width: Self.tileWidth,
                 hover: { model.pointTile(n) },
                 pick: { model.pickTile(n) },
                 corner: { model.pressCorner($0, on: n) })
    }

    private func info(_ tile: Int) -> StateFile.Info? { model.stateInfo(Self.source(tile)) }

    static func source(_ tile: Int) -> StateSource { SaveStatesNavigation.source(tile) }
}

/// "Auto-saved Today 14:32" for Resume, the time alone for a slot.
private func savedLine(_ source: StateSource, _ info: StateFile.Info?) -> String {
    guard let info else { return "Empty" }
    let when = StateSource.savedAt(info.savedAt)
    return source == .resume ? "Auto-saved \(when)" : when
}

private struct SlotTile: View {
    let source: StateSource
    let info: StateFile.Info?
    let selected: Bool
    let enabled: Bool
    let width: CGFloat
    let hover: () -> Void
    let pick: () -> Void
    let corner: (TileCorner) -> Void

    @State private var pointed = false

    /// The player writes the slots, never Resume.
    private var savable: Bool { source != .resume }

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                SlotThumbnail(url: info?.thumbnail)
                    .frame(width: width, height: width * 3 / 4)
                    .overlay {
                        // The dimming clear glass needs over a bright picture (HIG Materials).
                        RoundedRectangle(cornerRadius: 8).fill(.black.opacity(pointed && info != nil ? 0.35 : 0))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(selected ? 0.7 : 0), lineWidth: 2))
                Text(source.title).font(.system(size: 12, weight: .semibold))
                Text(savedLine(source, info))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .overlay(alignment: .top) {
            // An empty slot needs none: a click on it saves there.
            if pointed && info != nil {
                TileCorners(title: source.title, width: width, load: { corner(.load) },
                            save: savable ? { corner(.save) } : nil, delete: { corner(.delete) })
            }
        }
        .onHover { h in
            if h { hover() }
            withAnimation(.easeOut(duration: 0.12)) { pointed = h }
        }
        .contextMenu {
            if enabled {
                if info != nil { Button("Load \(source.title)") { corner(.load) } }
                if savable && info == nil { Button("Save to \(source.title)", action: pick) }
                if savable && info != nil { Button("Overwrite \(source.title)…") { corner(.save) } }
                if info != nil {
                    Divider()
                    Button("Delete \(source.title)…", role: .destructive) { corner(.delete) }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct SlotThumbnail: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.none)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What to do with the picked tile. Its buttons and which one Return would
/// press come from the navigation; the highlighted one is drawn prominent,
/// so the keys and a controller can see where they are.
private struct SlotSheet: View {
    let source: StateSource
    let info: StateFile.Info?
    let sheet: SlotSheetState
    let press: (SlotSheetButton) -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(sheet.buttons.contains(.delete) ? "Delete \(source.title)?" : source.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(info == nil || source == .resume
                     ? savedLine(source, info) : "Saved \(savedLine(source, info))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(sheet.buttons, id: \.self) { button in
                    if button == sheet.highlighted {
                        Button(Self.title(button), role: Self.role(button)) { press(button) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(Self.title(button), role: Self.role(button)) { press(button) }
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    static func role(_ button: SlotSheetButton) -> ButtonRole? { button == .delete ? .destructive : nil }

    static func title(_ button: SlotSheetButton) -> String {
        switch button {
        case .cancel: "Cancel"
        case .overwrite: "Overwrite"
        case .load: "Load"
        case .delete: "Delete"
        }
    }
}
