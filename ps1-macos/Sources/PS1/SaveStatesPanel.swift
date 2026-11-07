import AppKit
import SwiftUI

/// Resume under Auto-Save, slots 1-6 under Slots, as a list, and a bar of
/// buttons for the selected row under it. A list rather than a grid: the
/// panel is mostly names and times, and an empty slot costs one row rather
/// than a black box. One click selects, a double click or Return presses the
/// bar's primary button (Load, or Save Here for an empty slot); Overwrite and
/// Delete ask first. Shown in a popover from the bar and from the pause menu
/// alike; the selection and the confirmation are `SaveStatesNavigation`'s, so
/// the keys and a controller drive the same panel the mouse does.
struct SaveStatesPanel: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame

    var body: some View {
        let nav = game.saveStatesNav
        VStack(alignment: .leading, spacing: 0) {
            section("Auto-Save")
            row(0, nav: nav)
            section("Slots").padding(.top, Design.Spacing.xs)
            ForEach(Array(StateSource.slots), id: \.self) { row($0, nav: nav) }
            Divider().padding(.top, Design.Spacing.s)
            if let nav {
                StateBar(buttons: nav.buttons, highlighted: nav.button,
                         showsFocus: nav.showsFocus && nav.sheet == nil) { game.pressButton($0) }
                    .padding(.horizontal, Panel.inset)
                    .padding(.vertical, Design.Spacing.m)
            }
        }
        .padding(.top, Design.Spacing.xs)
        .frame(width: Design.Size.card)
        .overlay {
            if let sheet = nav?.sheet {
                // The popover clips the dimming to its own shape.
                ConfirmScrim(cornerRadius: 0, cancel: { game.pressSheet(.cancel) }) {
                    SlotSheet(source: SaveStatesNavigation.source(sheet.row), info: info(sheet.row),
                              sheet: sheet, showsFocus: nav?.showsFocus == true) { game.pressSheet($0) }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: nav?.sheet)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, Panel.inset).padding(.top, Design.Spacing.s).padding(.bottom, Design.Spacing.xs)
    }

    private func row(_ n: Int, nav: SaveStatesNavigation?) -> some View {
        StateRow(source: SaveStatesNavigation.source(n), info: info(n),
                 selected: nav?.selection == n,
                 enabled: nav?.isSelectable(n) ?? false,
                 select: { game.selectRow(n) },
                 activate: { game.activateRow(n) },
                 press: { button in
                     game.selectRow(n)
                     game.pressButton(button)
                 })
    }

    private func info(_ row: Int) -> StateFile.Info? { game.stateInfo(SaveStatesNavigation.source(row)) }
}

/// The panel's one leading edge: headings, row contents and the button bar.
private enum Panel {
    static let inset = Design.Spacing.l
    /// A row's own padding; the rest of `inset` sits outside its highlight.
    static let rowPadding = Design.Spacing.s
}

/// "Auto-saved Today at 14:32" for Resume, the time alone for a slot.
private func savedLine(_ source: StateSource, _ info: StateFile.Info?) -> String {
    guard let info else { return "Empty" }
    let when = StateSource.savedAt(info.savedAt)
    return source == .resume ? "Auto-saved \(when)" : when
}

private struct StateRow: View {
    let source: StateSource
    let info: StateFile.Info?
    let selected: Bool
    let enabled: Bool
    let select: () -> Void
    let activate: () -> Void
    /// A context-menu item: the row's bar button, on this row.
    let press: (StateButton) -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            StateThumbnail(url: info?.thumbnail).frame(width: 56, height: 42)
            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                Text(source.title).font(.body.weight(.medium))
                Text(savedLine(source, info)).font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // The system's selected-row colours, which keep their contrast on
        // any accent; the subtitle's `.secondary` derives from them.
        .foregroundStyle(selected ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                         : AnyShapeStyle(.primary))
        .environment(\.backgroundProminence, selected ? .increased : .standard)
        .padding(.horizontal, Panel.rowPadding).padding(.vertical, Design.Spacing.xs)
        // A list's selection: the accent fill. Hover only brightens.
        .background(Design.cardShape(Design.Radius.row)
            .fill(selected ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
                  : hover && enabled ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear)))
        .padding(.horizontal, Panel.inset - Panel.rowPadding)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: activate)
        .simultaneousGesture(TapGesture().onEnded(select))
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Design.disabledOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        .contextMenu {
            if enabled {
                if info == nil {
                    Button("Save to \(source.title)") { press(.save) }
                } else {
                    Button("Load \(source.title)") { press(.load) }
                    if source != .resume { Button("Overwrite \(source.title)…") { press(.overwrite) } }
                    Divider()
                    Button("Delete \(source.title)…", role: .destructive) { press(.delete) }
                }
            }
        }
    }
}

private struct StateThumbnail: View {
    let url: URL?
    /// Concentric with the row's highlight, `Design.Spacing.xs` inside it.
    private let radius = Design.concentric(Design.Radius.row, inset: Design.Spacing.xs)

    var body: some View {
        ZStack {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .clipShape(Design.cardShape(radius))
                    // The hairline system thumbnails carry, so a dark frame keeps its edge.
                    .overlay(Design.cardShape(radius).strokeBorder(.separator, lineWidth: 0.5))
            } else {
                Design.cardShape(radius).fill(.fill.quaternary)
            }
        }
    }
}

/// The selected row's buttons: Delete alone on the leading side, the rest
/// trailing with the primary one last and prominent (HIG Buttons). The
/// prominent button is what Return presses until a key or the controller
/// moves along the bar; only then does a ring mark the other button it
/// moved to. A ring round the prominent one too read as a second outline.
private struct StateBar: View {
    let buttons: [StateButton]
    let highlighted: StateButton
    let showsFocus: Bool
    let press: (StateButton) -> Void

    var body: some View {
        HStack(spacing: Design.Spacing.buttonGap) {
            if buttons.contains(.delete) { button(.delete) }
            Spacer(minLength: 0)
            ForEach(buttons.filter { $0 != .delete }, id: \.self) { button($0) }
        }
    }

    @ViewBuilder private func button(_ b: StateButton) -> some View {
        let base = Button(role: b == .delete ? .destructive : nil) { press(b) } label: { Text(Self.title(b)) }
        Group {
            if b == buttons.last {
                base.buttonStyle(.borderedProminent)
            } else {
                base.buttonStyle(.bordered)
            }
        }
        .focusRing(showsFocus && b == highlighted && b != buttons.last, in: Capsule())
        // One shape for every button, so the ring can follow it.
        .buttonBorderShape(.capsule)
    }

    static func title(_ b: StateButton) -> String {
        switch b {
        case .delete: "Delete…"
        case .overwrite: "Overwrite…"
        case .load: "Load"
        case .save: "Save Here"
        }
    }
}

/// The question Overwrite or Delete asks before it acts.
private struct SlotSheet: View {
    let source: StateSource
    let info: StateFile.Info?
    let sheet: SlotSheetState
    let showsFocus: Bool
    let press: (SlotSheetButton) -> Void

    private var deletes: Bool { sheet.buttons.contains(.delete) }

    var body: some View {
        ConfirmCard(title: deletes ? "Delete \(source.title)?" : "Overwrite \(source.title)?",
                    message: deletes ? ConfirmCard.deleteMessage
                        : source == .resume ? savedLine(source, info) : "Saved \(savedLine(source, info))",
                    buttons: sheet.buttons.map { ConfirmButton(title: Self.title($0), destructive: $0 == .delete) },
                    highlighted: sheet.index, showsFocus: showsFocus) { press(sheet.buttons[$0]) }
    }

    static func title(_ button: SlotSheetButton) -> String {
        switch button {
        case .cancel: "Cancel"
        case .overwrite: "Overwrite"
        case .delete: "Delete"
        }
    }
}
