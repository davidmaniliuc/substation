import AppKit
import SwiftUI

/// First launch. Both folders are captured here; either can be done first.
struct OnboardingView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        ZStack {
            model.libraryTheme.backdrop.ignoresSafeArea()

            VStack(spacing: 28) {
                header

                VStack(spacing: 0) {
                    FolderStep(
                        symbol: "memorychip",
                        title: "BIOS Folder",
                        detail: "The folder with your BIOS files. They are detected automatically, whatever their names, and each disc starts with its region's BIOS.",
                        chosen: model.biosFolderName,
                        choose: model.chooseBIOSFolder)

                    Divider().padding(.leading, 64)

                    FolderStep(
                        symbol: "square.stack.3d.up",
                        title: "Games Folder",
                        detail: "Searched with its subfolders for .cue, .chd and .bin discs.",
                        chosen: model.gamesFolderName,
                        choose: model.chooseGamesFolder)
                }
                .background(.quinary, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))

                VStack(spacing: 10) {
                    Button { model.finishOnboarding() } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady)

                    Text("Both folders can be changed later in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260)
            }
            .frame(maxWidth: 480)
            .padding(32)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Welcome to Substation")
                .font(.largeTitle.weight(.semibold))

            Text("Choose two folders to get started.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var isReady: Bool {
        model.hasBIOSFolder && model.gamesFolderName != nil
    }
}

/// One folder to choose: what it is, and once chosen, which folder it is.
private struct FolderStep: View {
    let symbol: String
    let title: String
    let detail: String
    let chosen: String?
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if chosen != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                if let chosen {
                    Label(chosen, systemImage: "folder.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Button(chosen == nil ? "Choose…" : "Change…", action: choose)
                .buttonStyle(.glass)
        }
        .padding(16)
        .animation(.smooth(duration: 0.2), value: chosen)
    }
}
