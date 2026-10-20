import AppKit
import SwiftUI

/// Which of the library toolbar's items fit a window `width` wide. Things
/// fold rather than vanish: the search into its glass, Continue into its
/// disc and play button, the tabs into their icons.
enum LibraryToolbarLayout {
    /// The tabs show their icons alone below this.
    static func tabsShowTitles(width: CGFloat) -> Bool { width >= 900 }

    /// Room for Continue's title beside the tabs and the search field;
    /// narrower, it keeps its disc and play button.
    static func continueShowsTitle(width: CGFloat) -> Bool { width >= 1100 }
}

/// The library's toolbar: "Library" and its game count, the sections as a
/// segmented control, the Continue capsule and the search. Real toolbar
/// items, so the system draws their glass, lines them up with the traffic
/// lights and keeps the bar draggable.
struct LibraryToolbar: ToolbarContent {
    @Bindable var model: EmulatorViewModel
    let width: CGFloat

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Library").font(.headline)
                // Not "0 games" beside "Scanning…" during the first scan.
                if !(model.library.isScanning && model.groups.isEmpty) {
                    Text(LibraryFormat.gameCount(model.groups.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            Picker("Section", selection: Binding(
                get: { model.libraryTabShown },
                set: { model.libraryTab = $0 }
            )) {
                ForEach(model.libraryTabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            // On the Picker, not its rows: a toolbar's segmented control
            // draws icons alone whatever style a row's label carries.
            .labelStyle(LibraryToolbarLayout.tabsShowTitles(width: width)
                        ? AnyLabelStyle.titleAndIcon : .iconOnly)
        }

        ToolbarSpacer(.flexible)

        if let group = model.continueGroup {
            ToolbarItem(placement: .primaryAction) {
                ContinueButton(group: group,
                               showsTitle: LibraryToolbarLayout.continueShowsTitle(width: width),
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
    /// Off in a narrow window: the disc and the play button alone, the
    /// title in the tooltip.
    let showsTitle: Bool
    let cover: URL?
    let lastPlayed: Date?
    let resume: () -> Void

    /// The disc and the play button, and their inset from the glass on every
    /// side: the toolbar draws its capsule tight around this item, so the
    /// inset is ours to give, and an even one is what keeps both circles
    /// concentric with the capsule's round ends.
    private static let side: CGFloat = 26
    private static let inset: CGFloat = 5

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 9) {
                art
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                if showsTitle {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if let lastPlayed {
                            Text("Played \(LibraryFormat.relative(lastPlayed))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 200, alignment: .leading)
                    .padding(.trailing, 2)
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.side, height: Self.side)
                    .background(.tint, in: .circle)
            }
            .padding(Self.inset)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Resume \(group.title)")
        .accessibilityLabel("Resume \(group.title)")
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

/// The two label styles the tabs switch between, as one type a ternary can
/// return.
private enum AnyLabelStyle: LabelStyle {
    case titleAndIcon, iconOnly

    func makeBody(configuration: Configuration) -> some View {
        switch self {
        case .titleAndIcon: Label(configuration).labelStyle(.titleAndIcon)
        case .iconOnly: Label(configuration).labelStyle(.iconOnly)
        }
    }
}
