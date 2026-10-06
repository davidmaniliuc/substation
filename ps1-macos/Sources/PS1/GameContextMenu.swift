import AppKit
import SwiftUI

/// What a right-click on a game offers, in the grid and the list alike, so
/// the two views cannot drift apart.
struct GameContextMenu: View {
    let entry: GameEntry
    let play: () -> Void
    let chooseCover: () -> Void
    /// Nil when the disc names no serial: the collection is keyed on serials.
    let downloadCover: (() -> Void)?
    /// Nil when there is no custom cover to remove.
    let removeCover: (() -> Void)?

    var body: some View {
        Button("Play", action: play)
        Divider()
        Button("Choose Cover Image…", action: chooseCover)
        if let downloadCover {
            Button("Download Cover", action: downloadCover)
        }
        if let removeCover {
            Button("Remove Custom Cover", action: removeCover)
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }
}
