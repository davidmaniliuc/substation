import SwiftUI

/// The launch sheet: every saved state of the game as a strip of tiles,
/// Resume first and ringed as the default (Return), then Start Fresh past a
/// divider and Cancel under it all. A double click on a tile loads it, as does
/// its hover play button; one click does nothing. Its hover trash and context
/// menu delete it, confirmed in a `ConfirmCard`, and the sheet stays up.
///
/// The strip shows 1 to 3 whole tiles, as many as `available` (the window's
/// width) allows. Past that the next tile peeks at the trailing edge and
/// Apple Music's shelf arrows page it, shown only while the pointer is over
/// the strip and only on a side with more.
struct ResumePromptSheet: View {
    let offer: ResumeOffer
    let available: CGFloat
    let choose: (ResumeChoice) -> Void
    let delete: (StateSource) -> Void

    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0
    @State private var hovering = false
    @State private var pendingDelete: StateSource?

    private typealias Metrics = ResumeTileMetrics
    private static let padding: CGFloat = 20
    /// What the dialog leaves clear of the window's edges.
    private static let margin: CGFloat = 48
    /// Everything but the strip: padding, divider and the Start Fresh tile.
    private static let chrome: CGFloat = padding * 2 + Metrics.gap + 1 + Metrics.gap + Metrics.tile
    /// The least of the next tile that shows when the strip scrolls.
    private static let peek: CGFloat = 22

    /// Whole tiles that fit (1...3), leaving room for the peek.
    private var visible: Int {
        let strip = available - Self.margin - Self.chrome - Metrics.gap - Self.peek
        return max(1, min(3, Int((strip + Metrics.gap) / Metrics.step)))
    }

    var body: some View {
        let states = offer.states
        let scrolls = states.count > visible
        let width = CGFloat(min(states.count, visible)) * Metrics.step - Metrics.gap
            + (scrolls ? Metrics.gap + Self.peek : 0)
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(offer.title).font(.title3.weight(.semibold))
                Text("Pick up where you left off").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Metrics.gap) {
                if !states.isEmpty {
                    strip(states, width: width, scrolls: scrolls)
                    Divider().frame(height: Metrics.tile * 3 / 4)
                }
                FreshTile { choose(.freshBoot) }
            }
            .fixedSize()
            Button("Cancel") { choose(.cancel) }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(Self.padding)
        .fixedSize()
        .background { returnLoadsResume }
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
                        if button == 1 { withAnimation(.snappy) { delete(source) } }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: pendingDelete)
    }

    /// Return loads Resume, the ringed tile. An unseen button, since a tile
    /// answers a double click and not a press.
    @ViewBuilder private var returnLoadsResume: some View {
        if offer.states.contains(where: { $0.source == .resume }) && offer.resumeDisc != nil {
            Button("") { choose(.resume) }
                .keyboardShortcut(.defaultAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func strip(_ states: [SavedState], width: CGFloat, scrolls: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Metrics.gap) {
                ForEach(states, id: \.source) { tile($0) }
            }
            .scrollTargetLayout()
            .padding(.vertical, Metrics.inset)
        }
        .scrollIndicators(.never)
        .scrollDisabled(!scrolls)
        .scrollPosition($position)
        .scrollTargetBehavior(.viewAligned)
        // `scrollPosition` does not reliably report the visible tile; the
        // geometry does, and paging needs only the offset and its limit.
        .onScrollGeometryChange(for: [CGFloat].self) {
            [$0.contentOffset.x, $0.contentSize.width - $0.containerSize.width]
        } action: { _, g in
            offset = g[0]
            maxOffset = g[1]
        }
        .frame(width: width)
        .padding(.vertical, -Metrics.inset)
        .overlay(alignment: .topLeading) {
            if scrolls && hovering && offset > 1 {
                PageArrow(symbol: "chevron.left", help: "Previous") { page(by: -1) }
                    .padding(.leading, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if scrolls && hovering && offset < maxOffset - 1 {
                PageArrow(symbol: "chevron.right", help: "Next") { page(by: 1) }
                    .padding(.trailing, 6)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    /// Pages by the tiles in view, clamped to the ends.
    private func page(by direction: CGFloat) {
        let x = offset + direction * Metrics.step * CGFloat(visible)
        withAnimation(.snappy) { position.scrollTo(x: min(max(x, 0), maxOffset)) }
    }

    private func tile(_ saved: SavedState) -> some View {
        let source = saved.source
        // Only the resume names its disc up front; any other state on a disc
        // that is gone is refused when it loads, with the reason.
        let discMissing = source == .resume && offer.resumeDisc == nil
        let load = { choose(source == .resume ? .resume : .load(source)) }
        return StateTile(saved: saved, enabled: !discMissing,
                         note: discMissing ? "Disc missing" : nil,
                         load: load, delete: { pendingDelete = source })
            .help(discMissing ? "The disc this state was saved on is no longer in the library." : "")
            .contextMenu {
                if !discMissing {
                    Button("Load \(source.title)", action: load)
                    Divider()
                }
                Button("Delete \(source.title)…", role: .destructive) { pendingDelete = source }
            }
    }
}
