import AppKit
import SwiftUI

enum ResumeTileMetrics {
    static let tile: CGFloat = 150
    static let gap: CGFloat = 12
    static let step = tile + gap
    static let radius: CGFloat = 10
    /// Room inside the strip's scroll view for Resume's ring.
    static let inset: CGFloat = 4
}

/// One saved state: its 4:3 screenshot, title and age. A double click loads
/// it; one click does nothing. Resume carries the accent ring of the default
/// button (Return, which the sheet binds).
///
/// Hover neither zooms nor changes the outline (macOS has no lift): the
/// picture dims and Music's two corner controls appear, load leading and
/// delete trailing.
struct StateTile: View {
    let saved: SavedState
    let enabled: Bool
    let note: String?
    let load: () -> Void
    let delete: () -> Void

    @State private var image: NSImage?
    @State private var hover = false

    private typealias Metrics = ResumeTileMetrics
    private var isResume: Bool { saved.source == .resume }
    private var savedAt: String { StateSource.savedAt(saved.info.savedAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StateScreenshot(image: image)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(isResume ? Color.accentColor : .white.opacity(0.12),
                                  lineWidth: isResume ? 2.5 : 1))
                .overlay {
                    // The dimming clear glass needs over a bright picture (HIG Materials).
                    RoundedRectangle(cornerRadius: Metrics.radius).fill(.black.opacity(hover ? 0.35 : 0))
                }
            Text(saved.source.title).font(.callout.weight(isResume ? .semibold : .regular))
            Text(note ?? savedAt).font(.caption)
                .foregroundStyle(note == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        .frame(width: Metrics.tile)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        // One click does nothing: a load is a double click or the play button.
        .onTapGesture(count: 2) { if enabled { load() } }
        .overlay(alignment: .top) {
            if hover {
                TileCorners(title: saved.source.title, width: Metrics.tile,
                            load: enabled ? load : nil, delete: delete)
            }
        }
        // Both corner controls hang off this: without it there is no way to
        // delete but the context menu.
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(saved.source.title), \(note ?? savedAt)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { load() } }
        .accessibilityAction(named: "Delete", delete)
        .task(id: saved.info.thumbnail) {
            image = saved.info.thumbnail.flatMap(NSImage.init(contentsOf:))
        }
    }
}

/// A state's picture, or a placeholder for one saved without (or a damaged
/// state): the tile still loads, and the load explains the damage.
private struct StateScreenshot: View {
    let image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.black)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }
}

/// A tile's controls over its screenshot, shown under the pointer: Load and
/// Save on the leading side, Delete alone on the trailing one. The resume
/// sheet and the in-game Save States panel share them.
struct TileCorners: View {
    let title: String
    let width: CGFloat
    var load: (() -> Void)?
    /// Overwrites this tile's state, after asking.
    var save: (() -> Void)?
    var delete: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let load { CornerButton(symbol: "play.fill", help: "Load \(title)", action: load) }
            if let save {
                CornerButton(symbol: "square.and.arrow.down",
                             help: "Overwrite \(title)…", action: save)
            }
            Spacer()
            if let delete {
                CornerButton(symbol: "trash", help: "Delete \(title)…", destructive: true, action: delete)
            }
        }
        .padding(8)
        .frame(width: width, height: width * 3 / 4, alignment: .bottom)
        .transition(.opacity)
    }
}

/// A control over the screenshot: clear Liquid Glass, the HIG's variant for
/// controls over media, on the tile's dimming. The destructive one fills red
/// only under the pointer.
private struct CornerButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(destructive && hover ? Color.red : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressDim())
        .glassEffect(.clear.interactive(), in: Circle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Start Fresh, set apart past the divider: boots the disc, keeping every state.
struct FreshTile: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: ResumeTileMetrics.radius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(0.25))
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { Image(systemName: "power").font(.system(size: 26)).foregroundStyle(.secondary) }
                Text("Start Fresh").font(.callout)
                Text("Boot the disc").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: ResumeTileMetrics.tile)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }
}

/// Apple Music's shelf arrow: a flat grey pill over the strip, not glass.
struct PageArrow: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 52)
                .background(Capsule().fill(Color(white: 0.42).opacity(0.92)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressDim())
        .help(help)
        // Centred on the screenshot, not on the whole tile.
        .padding(.top, ResumeTileMetrics.tile * 3 / 8 - 26 + ResumeTileMetrics.inset)
        .transition(.opacity)
    }
}

/// Every custom button needs a press state (HIG Buttons).
private struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
