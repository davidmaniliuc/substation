import SwiftUI

public struct ContentView: View {
    @Bindable var model: EmulatorViewModel

    public init(model: EmulatorViewModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if model.stage == .playing, let runner = model.runner {
                MetalDisplayView(runner: runner)
                    .ignoresSafeArea()

                GameHUD(model: model, isVisible: model.hudVisible)
                    .padding(.bottom, 28)
            } else {
                EmptyStateView(model: model)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Zero-sized, so it cannot affect layout: it only reaches the NSWindow.
        // The traffic lights stay put on the empty state — there is no HUD
        // there to bring them back with.
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
