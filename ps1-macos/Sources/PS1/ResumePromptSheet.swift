import AppKit
import SwiftUI

/// The launch sheet: the selected state's screenshot large on the leading
/// side, and beside it the game (cover and title) over a native list of
/// every saved state: Resume, Previous Resume, then the slots. Below both, a
/// darker footer strip holds Delete leading, then Start Fresh and the default
/// button, titled with the selected state's name.
///
/// The list has the keyboard from the start, with Resume selected: ↑↓ pick,
/// Return loads, ⌫ deletes after asking, Escape cancels. A double click on a
/// row loads it; one click only selects. A delete keeps the sheet up and
/// selects the neighbouring state; with none left the sheet keeps only the
/// header and Start Fresh.
///
/// In a window too narrow for the whole card the screenshot is left out
/// (`showsHero`), and the list's thumbnails show the states alone.
struct ResumePromptSheet: View {
    let offer: ResumeOffer
    let cover: URL?
    var showsHero = true
    let choose: (ResumeChoice) -> Void
    let delete: (StateSource) -> Void

    @State private var selection: StateSource?
    @State private var pendingDelete: StateSource?
    @State private var thumbnails: [StateSource: NSImage] = [:]
    @State private var coverImage: NSImage?

    private static let hero: CGFloat = 360
    private static let column: CGFloat = 270
    private static let spacing = Design.Spacing.xl
    private static let padding = Design.Spacing.dialog
    /// The hero and the list beside it are siblings in one card: one step.
    private static let insetRadius = Design.Radius.panel
    /// The column alone, wide enough for the footer's three buttons.
    private static let compactColumn: CGFloat = 360
    /// What the dialog leaves clear of the window's edges.
    private static let margin = Design.Spacing.xxl
    private static let wideWidth = padding * 2 + hero + spacing + column

    /// Whether a window this wide has room for the screenshot.
    static func showsHero(inWindowWidth width: CGFloat) -> Bool {
        width >= wideWidth + margin * 2
    }

    private var selected: SavedState? {
        offer.states.first { $0.source == selection } ?? offer.states.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if offer.states.isEmpty {
                    header
                } else {
                    HStack(alignment: .top, spacing: Self.spacing) {
                        if showsHero { heroImage }
                        VStack(alignment: .leading, spacing: Design.Spacing.m) {
                            header
                            list
                        }
                        .frame(height: Self.hero * 3 / 4)
                    }
                }
            }
            .frame(width: showsHero ? Self.wideWidth - Self.padding * 2 : Self.compactColumn,
                   alignment: .leading)
            .padding(Self.padding)
            footer
        }
        .fixedSize()
        .background { escapeCancels }
        // Under the card, nothing takes a click or a key but the card.
        .disabled(pendingDelete != nil)
        .overlay {
            if let source = pendingDelete {
                ConfirmScrim(cornerRadius: Design.Radius.dialog, cancel: { pendingDelete = nil }) {
                    ConfirmCard(title: "Delete \(source.title)?", message: ConfirmCard.deleteMessage,
                                buttons: [ConfirmButton(title: "Cancel"),
                                          ConfirmButton(title: "Delete", destructive: true)],
                                bindsKeys: true) { button in
                        pendingDelete = nil
                        if button == 1 { remove(source) }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: pendingDelete)
        .onAppear { selection = offer.states.first?.source }
        .task(id: offer.states.map(\.info.thumbnail)) {
            thumbnails = offer.states.reduce(into: [:]) { images, saved in
                images[saved.source] = saved.info.thumbnail.flatMap(NSImage.init(contentsOf:))
            }
        }
        .task(id: cover) { coverImage = cover.flatMap(NSImage.init(contentsOf:)) }
    }

    /// The selected state's picture, cross-fading as the selection moves.
    private var heroImage: some View {
        ZStack {
            if let source = selected?.source {
                StateScreenshot(image: thumbnails[source],
                                radius: Self.insetRadius)
                    .id(source)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.hero)
        .animation(.easeOut(duration: 0.15), value: selected?.source)
    }

    private var header: some View {
        HStack(spacing: Design.Spacing.m) {
            Group {
                if let coverImage {
                    Image(nsImage: coverImage).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Design.cardShape(Design.Radius.thumbnail).fill(.quaternary)
                        .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Design.cardShape(Design.Radius.thumbnail))
            .overlay(Design.cardShape(Design.Radius.thumbnail).strokeBorder(.separator, lineWidth: 0.5))
            .designShadow(.thumbnail)
            Marquee(text: offer.title, font: .title3.weight(.semibold))
        }
    }

    /// The system draws the focus ring and the selection, accent while
    /// focused and grey while not.
    private var list: some View {
        List(offer.states, id: \.source, selection: $selection) { saved in
            HStack(spacing: Design.Spacing.m) {
                StateScreenshot(image: thumbnails[saved.source], radius: Design.Radius.thumbnail).frame(width: 40)
                VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                    Text(saved.source.title).font(.body)
                    if discMissing(saved.source) {
                        Label("Disc missing", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(StateSource.savedAt(saved.info.savedAt)).font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, Design.Spacing.xxs)
            .help(discMissing(saved.source) ? Self.discMissingHelp : "")
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background(InsetFill(), in: Design.cardShape(Self.insetRadius))
        .background(ListFocus(isFocused: pendingDelete == nil))
        .contextMenu(forSelectionType: StateSource.self) { sources in
            if let source = sources.first {
                if !discMissing(source) {
                    Button("Load \(source.title)") { load(source) }
                    Divider()
                }
                Button("Delete \(source.title)…", role: .destructive) { pendingDelete = source }
            }
        } primaryAction: { sources in
            if let source = sources.first, !discMissing(source) { load(source) }
        }
        .onDeleteCommand { pendingDelete = selected?.source }
    }

    /// The buttons in an inset strip under a hairline, the same fill as the
    /// list and the library's panel.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Design.Spacing.buttonGap) {
                if let saved = selected {
                    // The selected state's delete, in view: never only behind
                    // the context menu or ⌫ (HIG Context Menus).
                    Button(role: .destructive) { pendingDelete = saved.source } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                    .buttonStyle(HoverOutline())
                    .help("Delete \(saved.source.title)")
                }
                Spacer(minLength: 0)
                buttons
            }
            .padding(.horizontal, Self.padding)
            .padding(.vertical, Design.Spacing.m)
            // An explicit rectangle: with no shape, the fill takes the
            // card's rounded shape and the strip grows corners of its own
            // under the hairline. The card's clip rounds its bottom.
            .background(InsetFill(), in: Rectangle())
        }
    }

    /// Start Fresh, then the default: the selected state's name, or Start
    /// Fresh itself once no state is left.
    private var buttons: some View {
        HStack(spacing: Design.Spacing.buttonGap) {
            if let saved = selected {
                Button("Start Fresh") { choose(.freshBoot) }
                Button(saved.source.title) { load(saved.source) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(discMissing(saved.source))
                    .help(discMissing(saved.source) ? Self.discMissingHelp : "")
            } else {
                Button("Start Fresh") { choose(.freshBoot) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// Escape cancels: an unseen button, since the sheet shows no Cancel
    /// (HIG Sheets asks for one only beside a Done; every button here ends it).
    private var escapeCancels: some View {
        Button("") { choose(.cancel) }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let discMissingHelp = "The disc this state was saved on is no longer in the library."

    /// Only the resume names its disc up front; any other state on a disc
    /// that is gone is refused when it loads, with the reason.
    private func discMissing(_ source: StateSource) -> Bool {
        source == .resume && offer.resumeDisc == nil
    }

    private func load(_ source: StateSource) {
        choose(source == .resume ? .resume : .load(source))
    }

    private func remove(_ source: StateSource) {
        let next = offer.neighbour(of: source)
        withAnimation(.snappy) {
            delete(source)
            selection = next
        }
    }
}

/// Gives the list the keyboard as the sheet opens and again as a delete's
/// confirmation closes. `.focused` on a `List` does not make its table view
/// first responder, and one that is not draws its selection grey and ignores
/// the arrow keys. Only on a change, so a click on a footer button keeps the
/// focus it took.
private struct ListFocus: NSViewRepresentable {
    let isFocused: Bool

    final class Coordinator { var wasFocused = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard isFocused != coordinator.wasFocused else { return }
        coordinator.wasFocused = isFocused
        guard isFocused else { return }
        NearestTable.whenFound(near: view) { table, window in window.makeFirstResponder(table) }
    }
}

/// A state's picture on black, or black alone for one saved without (or a
/// damaged state): it still loads, and the load explains the damage.
private struct StateScreenshot: View {
    let image: NSImage?
    let radius: CGFloat

    var body: some View {
        Design.cardShape(radius).fill(.black)
            .overlay {
                if let image { Image(nsImage: image).resizable().interpolation(.high) }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(Design.cardShape(radius))
            // The hairline every system thumbnail has, so a dark frame keeps its edge.
            .overlay(Design.cardShape(radius).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// The footer's quiet button: bare at rest, a hairline capsule with a faint fill
/// under the pointer, a firmer fill while pressed (HIG: every custom button
/// has a press state; on a Mac, hover brightens, never moves).
private struct HoverOutline: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Outlined(configuration: configuration)
    }

    private struct Outlined: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let active = isEnabled && (hover || configuration.isPressed)
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .padding(.horizontal, Design.Spacing.m)
                .padding(.vertical, Design.Spacing.xs)
                .frame(minHeight: 28)
                .background(Capsule().fill(configuration.isPressed ? AnyShapeStyle(.fill.secondary)
                                           : hover && isEnabled ? AnyShapeStyle(.fill.tertiary)
                                           : AnyShapeStyle(.clear)))
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 1).opacity(active ? 1 : 0))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : Design.disabledOpacity)
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
    }
}
