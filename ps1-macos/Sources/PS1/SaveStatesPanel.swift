import AppKit
import SwiftUI

/// The Resume state on its own beside a divider, slots 1-6 in a 3×2 grid.
/// A click on an empty slot saves there; a filled tile does nothing on one
/// click and loads on a double click or its corner play button, so one stray
/// click never loses a save. Shown in a popover, a window of its own, so it
/// may leave the game window; the highlight and the sheet are
/// `SaveStatesNavigation`'s, so the keys and a controller drive the same
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
                // The popover clips the dimming to its own shape.
                ConfirmScrim(cornerRadius: 0, cancel: { model.pressSheet(.cancel) }) {
                    SlotSheet(source: Self.source(sheet.tile), info: info(sheet.tile),
                              sheet: sheet, showsFocus: nav?.showsSelection == true) { model.pressSheet($0) }
                }
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
        VStack(alignment: .leading, spacing: 6) {
            SlotThumbnail(url: info?.thumbnail)
                .frame(width: width, height: width * 3 / 4)
                .overlay {
                    // The dimming clear glass needs over a bright picture (HIG Materials).
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(pointed && info != nil ? 0.35 : 0))
                }
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(selected ? 1 : 0), lineWidth: 2.5))
            Text(source.title).font(.system(size: 12, weight: .semibold))
            Text(savedLine(source, info))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        // An empty slot saves on one click; a filled tile does nothing on one
        // and loads on two.
        .onTapGesture(count: info == nil ? 1 : 2) { if info == nil { pick() } else { corner(.load) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if info == nil { pick() } else { corner(.load) } }
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

/// What to do with the picked tile, or the question a corner control asks.
/// Its buttons and which one Return would press come from the navigation.
private struct SlotSheet: View {
    let source: StateSource
    let info: StateFile.Info?
    let sheet: SlotSheetState
    let showsFocus: Bool
    let press: (SlotSheetButton) -> Void

    var body: some View {
        ConfirmCard(title: title, message: message,
                    buttons: sheet.buttons.map { ConfirmButton(title: Self.title($0), destructive: $0 == .delete) },
                    highlighted: sheet.index, showsFocus: showsFocus) { press(sheet.buttons[$0]) }
    }

    private var title: String {
        if sheet.buttons.contains(.delete) { return "Delete \(source.title)?" }
        if !sheet.buttons.contains(.load) { return "Overwrite \(source.title)?" }
        return source.title
    }

    private var message: String {
        if sheet.buttons.contains(.delete) { return ConfirmCard.deleteMessage }
        return source == .resume ? savedLine(source, info) : "Saved \(savedLine(source, info))"
    }

    static func title(_ button: SlotSheetButton) -> String {
        switch button {
        case .cancel: "Cancel"
        case .overwrite: "Overwrite"
        case .load: "Load"
        case .delete: "Delete"
        }
    }
}
