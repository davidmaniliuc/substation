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
    private static let spacing: CGFloat = 20
    private static let padding: CGFloat = 20
    /// The column alone, wide enough for the footer's three buttons.
    private static let compactColumn: CGFloat = 360
    /// What the dialog leaves clear of the window's edges.
    private static let margin: CGFloat = 24
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
                        VStack(alignment: .leading, spacing: 12) {
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
        .clipShape(.rect(cornerRadius: glassDialogRadius))
        .fixedSize()
        .background { escapeCancels }
        // Under the card, nothing takes a click or a key but the card.
        .disabled(pendingDelete != nil)
        .overlay {
            if let source = pendingDelete {
                ConfirmScrim(cornerRadius: glassDialogRadius, cancel: { pendingDelete = nil }) {
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
                StateScreenshot(image: thumbnails[source], radius: Design.Radius.panel)
                    .id(source)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.hero)
        .animation(.easeOut(duration: 0.15), value: selected?.source)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let coverImage {
                    Image(nsImage: coverImage).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: Design.Radius.thumbnail).fill(.quaternary)
                        .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.thumbnail).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            Marquee(text: offer.title, font: .system(size: 15, weight: .semibold))
        }
    }

    /// The system draws the focus ring and the selection, accent while
    /// focused and grey while not.
    private var list: some View {
        List(offer.states, id: \.source, selection: $selection) { saved in
            HStack(spacing: 10) {
                StateScreenshot(image: thumbnails[saved.source], radius: Design.Radius.thumbnail).frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(saved.source.title).font(.system(size: 13))
                    if discMissing(saved.source) {
                        Text("Disc missing").font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        Text(StateSource.savedAt(saved.info.savedAt)).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .help(discMissing(saved.source) ? Self.discMissingHelp : "")
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background(InsetFill(), in: .rect(cornerRadius: Design.Radius.row))
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
            HStack(spacing: 8) {
                if let saved = selected {
                    // The selected state's delete, in view: never only behind
                    // the context menu or ⌫ (HIG Context Menus).
                    Button(role: .destructive) { pendingDelete = saved.source } label: {
                        Label("Delete…", systemImage: "trash").font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(HoverOutline())
                    .foregroundStyle(.red)
                    .help("Delete \(saved.source.title)")
                }
                Spacer(minLength: 0)
                buttons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(InsetFill())
        }
    }

    /// Start Fresh, then the default: the selected state's name, or Start
    /// Fresh itself once no state is left.
    private var buttons: some View {
        HStack(spacing: 8) {
            if let saved = selected {
                Button("Start Fresh") { choose(.freshBoot) }
                Button(saved.source.title) { load(saved.source) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(discMissing(saved.source))
                    .help(discMissing(saved.source) ? Self.discMissingHelp : "")
            } else {
                Button("Start Fresh") { choose(.freshBoot) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .buttonStyle(.glass)
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
        RoundedRectangle(cornerRadius: radius).fill(.black)
            .overlay {
                if let image { Image(nsImage: image).resizable().interpolation(.high) }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(.rect(cornerRadius: radius))
            // The hairline every system thumbnail has, so a dark frame keeps its edge.
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
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

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.06 : 0)))
                .overlay(Capsule().strokeBorder(.primary.opacity(hover || configuration.isPressed ? 0.22 : 0),
                                                lineWidth: 1))
                .contentShape(Capsule())
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
    }
}
