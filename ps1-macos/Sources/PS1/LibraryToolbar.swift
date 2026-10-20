import AppKit
import SwiftUI

/// Which of the library toolbar's items fit a window `width` wide. The
/// search field and Continue fold before anything crowds the tabs.
enum LibraryToolbarLayout {
    /// The tabs show their icons alone below this.
    static func tabsShowTitles(width: CGFloat) -> Bool { width >= 900 }

    /// Room for the tabs, the search field and the capsule beside them.
    static func showsContinue(width: CGFloat) -> Bool { width >= 1100 }
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
                    let label = Label(tab.title, systemImage: tab.symbol)
                    Group {
                        if LibraryToolbarLayout.tabsShowTitles(width: width) {
                            label
                        } else {
                            label.labelStyle(.iconOnly)
                        }
                    }
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

    /// The disc and the play button: the toolbar capsule's height less its
    /// inset, so both sit concentric in its round ends.
    private static let side: CGFloat = 28

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 9) {
                art
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
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
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.side, height: Self.side)
                    .background(.tint, in: .circle)
            }
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
