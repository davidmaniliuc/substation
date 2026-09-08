import SwiftUI

/// What makes SwiftUI rebuild the display view. A new disc is a new runner and
/// a new queue; a new internal resolution is a new `MetalVram` and therefore a
/// new render texture, new pipelines and a new coordinator. Both are identity
/// changes, and there is deliberately no reconfiguration path for either.
private struct DisplayIdentity: Hashable {
    let runner: ObjectIdentifier
    let scale: Int
}

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel

    public init(model: EmulatorViewModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .bottom) {
            switch model.stage {
            case .playing:
                if let runner = model.runner {
                    MetalDisplayView(runner: runner, scale: model.internalScale)
                        // SwiftUI may otherwise keep this view's identity
                        // across a disc swap and leave the coordinator holding
                        // the PREVIOUS runner. Harmless when it only read
                        // frames; wrong now that it drains a stream. The scale
                        // is in the key for the same reason: the coordinator
                        // owns a texture sized by it.
                        .id(DisplayIdentity(runner: ObjectIdentifier(runner),
                                            scale: model.internalScale))
                        .ignoresSafeArea()
                        // On the picture only, so it sits BELOW the HUD in
                        // this ZStack and a click on an OSD button presses
                        // the button rather than dismissing the OSD.
                        .onTapGesture { model.hideHUDNow() }

                    GameHUD(model: model, isVisible: model.hudVisible)
                        .padding(.bottom, 28)
                }
            case .library:
                LibraryView(
                    library: model.library,
                    groups: model.groups,
                    coverURL: { model.coverURL(for: $0) },
                    play: { model.play($0) },
                    chooseCover: { model.chooseCover(for: $0) },
                    downloadCover: { model.downloadCover(for: $0) },
                    removeCover: { model.removeCover(for: $0) },
                    chooseFolder: { model.chooseGamesFolder() },
                    downloadStatus: model.coverDownloadSummary,
                    isDownloading: model.isDownloadingCovers)
            case .onboarding:
                OnboardingView(model: model)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Zero-sized, so it cannot affect layout: it only reaches the NSWindow.
        // The traffic lights stay put outside play — there is no HUD there to
        // bring them back with.
        .background(WindowConfigurator(
            lockAspect: model.stage == .playing,
            chromeVisible: model.stage != .playing || model.hudVisible
        ))
        // The point, not just the phase: this callback also fires for a click,
        // and re-showing on it would undo `hideHUDNow` in the same runloop
        // turn. `hoverMoved` re-shows only when the pointer has actually moved.
        .onContinuousHover { phase in
            if case .active(let point) = phase { model.hoverMoved(to: point) }
        }
        .onAppear { model.showHUDThenHide() }
        .alert("Could not load", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Opened as a raw .bin", isPresented: $model.showRawBinWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A raw .bin is a single data track at LBA 0 and cannot represent audio tracks. If this game has CD-DA music, it will be silent. Open the .cue instead.")
        }
    }
}
