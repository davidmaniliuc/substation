import AppKit
import SwiftUI

/// Which of the library toolbar's items fit a window `width` wide. Continue
/// HIDES rather than shrinking: items that change shape with the width were
/// tried, and the toolbar does not re-lay them out reliably, so a stale wide
/// form slid under the traffic lights.
enum LibraryToolbarLayout {
    /// Room for the tabs, the search field and the capsule beside them.
    static func showsContinue(width: CGFloat) -> Bool { width >= 1100 }
}

/// The library's toolbar: "Library", the sections as a
/// segmented control, the Continue capsule and the search. Real toolbar
/// items, so the system draws their glass, lines them up with the traffic
/// lights and keeps the bar draggable.
struct LibraryToolbar: ToolbarContent {
    @Bindable var model: EmulatorViewModel
    let width: CGFloat

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // The title alone: the panel's header counts what the open tab
            // shows, and a second count here only repeated it.
            Text("Library").font(.headline)
                .padding(.horizontal, Design.Spacing.s)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            Picker("Section", selection: Binding(
                get: { model.libraryTabShown },
                set: { model.libraryTab = $0 }
            )) {
                // Icons, named on hover: a toolbar's segmented control draws
                // them alone, and titles that came and went with the width
                // were what broke its layout.
                ForEach(model.libraryTabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .labelStyle(.iconOnly)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }

        ToolbarSpacer(.flexible)

        if LibraryToolbarLayout.showsContinue(width: width), let group = model.continueGroup {
            ToolbarItem(placement: .primaryAction) {
                ContinueButton(group: group,
                               cover: model.coverURL(for: group.first),
                               lastPlayed: model.lastPlayedByGroup[group.id]) {
                    model.continuePlaying(group)
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            LibrarySearchBox(
                text: $model.librarySearch,
                folds: LibrarySearchLayout.folds(width: width),
                focusRequest: model.librarySearchFocusRequest)
        }
    }
}

/// The game played last, one click from carrying on, as Music's toolbar
/// shows what is playing: its cover as a disc (concentric with the glass
/// capsule's round end), its title and when it was played, and a play
/// button in the accent colour, the bar's only colour.
struct ContinueButton: View {
    let group: GameGroup
    let cover: URL?
    let lastPlayed: Date?
    let resume: () -> Void

    /// The disc and the play button, and their inset from the glass on every
    /// side: the toolbar draws its capsule tight around this item, so the
    /// inset is ours to give, and an even one is what keeps both circles
    /// concentric with the capsule's round ends.
    private static let side: CGFloat = 28
    private static let inset = Design.Spacing.xs

    var body: some View {
        Button(action: resume) {
            HStack(spacing: Design.Spacing.s) {
                art
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let lastPlayed {
                        Text("Played \(LibraryFormat.relative(lastPlayed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 200, alignment: .leading)
                .padding(.trailing, Design.Spacing.xxs)
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: Self.side, height: Self.side)
                    .background(.tint, in: .circle)
            }
            .padding(Self.inset)
            .contentShape(.capsule)
        }
        .buttonStyle(CapsulePressStyle())
        .help("Resume \(group.title)")
        .accessibilityLabel("Resume \(group.title)")
    }

    /// Hover and press fills inside the capsule, as the glass has none of
    /// its own for a plain button.
    private struct CapsulePressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Fill(configuration: configuration)
        }

        private struct Fill: View {
            let configuration: Configuration
            @State private var hovering = false

            var body: some View {
                configuration.label
                    .background {
                        if configuration.isPressed {
                            Capsule().fill(.fill.secondary)
                        } else if hovering {
                            Capsule().fill(.fill.tertiary)
                        }
                    }
                    .onHover { hovering = $0 }
            }
        }
    }

    @ViewBuilder private var art: some View {
        if let image = cover.flatMap(NSImage.init(contentsOf:)) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "opticaldisc").foregroundStyle(.secondary)
            }
        }
    }
}
