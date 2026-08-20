import SwiftUI

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel

    public init(model: EmulatorViewModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .bottom) {
            switch model.stage {
            case .playing:
                if let runner = model.runner {
                    MetalDisplayView(runner: runner)
                        .ignoresSafeArea()

                    GameHUD(model: model, isVisible: model.hudVisible)
                        .padding(.bottom, 28)
                }
            case .library:
                LibraryView(
                    library: model.library,
                    coverURL: { model.coverURL(for: $0) },
                    play: { model.play($0) },
                    chooseCover: { model.chooseCover(for: $0) },
                    removeCover: { model.removeCover(for: $0) },
                    chooseFolder: { model.chooseGamesFolder() })
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
        .onContinuousHover { phase in
            if case .active = phase { model.showHUDThenHide() }
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
