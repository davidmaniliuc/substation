import AppKit
import SwiftUI

/// First launch. Both folders are captured here; either can be done first.
struct OnboardingView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        ZStack {
            model.libraryTheme.backdrop.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(spacing: 0) {
                    FolderRow(
                        title: "BIOS",
                        note: "Images are identified by their contents, so any file names work. Each disc uses the BIOS for its region.",
                        folder: model.biosFolderURL,
                        choose: model.chooseBIOSFolder)

                    Divider().padding(.horizontal, 14)

                    FolderRow(
                        title: "Games",
                        note: "Subfolders are included. Reads .cue, .chd and .bin.",
                        folder: model.gamesFolderURL,
                        choose: model.chooseGamesFolder)
                }
                .background(.quinary, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

                HStack {
                    Text("You can change these later in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue") { model.finishOnboarding() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isReady)
                }
            }
            .frame(maxWidth: 560)
            .padding(32)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text("Substation")
                    .font(.title.weight(.semibold))
                Text("Choose where your BIOS images and games are kept.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isReady: Bool {
        model.biosFolderURL != nil && model.gamesFolderURL != nil
    }
}

/// One folder setting: its name, the folder once chosen, and how it is read.
private struct FolderRow: View {
    let title: String
    let note: String
    let folder: URL?
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: folder == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(folder == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                location
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button(folder == nil ? "Choose…" : "Change…", action: choose)
        }
        .padding(14)
    }

    /// The folder as Finder shows it: its own icon and a home-relative path.
    @ViewBuilder private var location: some View {
        if let folder {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            }
            .font(.callout)
        } else {
            Text("Not set")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}
