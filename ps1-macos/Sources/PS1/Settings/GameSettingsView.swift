import AppKit
import SwiftUI

/// Per-game settings override sheet, presented from the Library context menu,
/// Library menu, Machine menu or Pause Menu.
///
/// Uses a native macOS `.sheet` and grouped `Form`, matching `SettingsView`.
/// Every control shows "Global (<current value>)" when inheriting the global
/// setting; choosing any explicit value saves an override for this game alone
/// and pushes it immediately to the game's session if it is running.
struct GameSettingsView: View {
    @Bindable var model: EmulatorViewModel
    let target: GameSettingsTarget
    let close: () -> Void

    @State private var tab: Tab = .video
    @State private var coverImage: NSImage?

    private enum Tab: String, CaseIterable, Identifiable {
        case video = "Video"
        case enhancements = "Enhancements"
        case emulation = "Emulation"

        var id: Self { self }
    }

    private var overrides: GameOverrides {
        model.gameOverrides.overrides(for: target.key) ?? GameOverrides()
    }

    private var resolved: ResolvedGameSettings {
        model.resolvedSettings(forKey: target.key, serial: target.serial)
    }

    private var overrideCount: Int {
        model.activeOverrideCount(for: target)
    }

    private var discPreset: PgxpPreset? {
        PgxpPreset.lookup(serial: target.serial)
    }

    private var activePreset: PgxpPreset? {
        resolved.pgxpUsePresets ? discPreset : nil
    }

    private func presetDecides<T>(_ field: KeyPath<PgxpPreset, T?>) -> Bool {
        activePreset?[keyPath: field] != nil
    }

    private var effectivePgxp: Bool {
        activePreset?.enabled ?? resolved.pgxpEnabled
    }

    private var effectiveDepthBuffer: Bool {
        (activePreset?.depthBuffer ?? resolved.pgxpDepthBuffer) && effectivePgxp
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pane
            Divider()
            footer
        }
        .frame(width: 540, height: 520)
        .background { escapeCloses }
        .background(GameSettingsWindowMarker())
        .preferredColorScheme(model.libraryTheme.colorScheme)
        .task(id: target.coverURL) {
            coverImage = target.coverURL.flatMap(ImageCache.image(at:))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                coverThumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(target.title)
                    if !target.subtitle.isEmpty {
                        Text(verbatim: target.subtitle)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(overrideSummary)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Picker("Category", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var coverThumbnail: some View {
        Group {
            if let coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.thumbnail)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "opticaldisc")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.thumbnail)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .accessibilityHidden(true)
    }

    private var overrideSummary: String {
        switch overrideCount {
        case 0: "Using global settings"
        case 1: "1 custom setting"
        default: "\(overrideCount) custom settings"
        }
    }

    // MARK: - Panes

    @ViewBuilder private var pane: some View {
        switch tab {
        case .video: videoForm
        case .enhancements: enhancementsForm
        case .emulation: emulationForm
        }
    }

    private var videoForm: some View {
        Form {
            Section {
                optionalPicker(
                    SettingsCopy.internalResolution,
                    keyPath: \.internalScale,
                    globalLabel: VideoSettingsPane.resolutionTitle(model.internalScale),
                    options: Array(InternalResolution.range),
                    optionLabel: VideoSettingsPane.resolutionTitle
                )
            }

            Section {
                optionalPicker(
                    SettingsCopy.dithering,
                    keyPath: \.ditherMode,
                    globalLabel: model.ditherMode.title,
                    options: DitherMode.allCases,
                    optionLabel: SettingsCopy.ditherOptionTitle
                )
            }

            Section {
                optionalPicker(
                    SettingsCopy.textureFiltering,
                    keyPath: \.textureFilter,
                    globalLabel: model.textureFilter.title,
                    options: TextureFilter.allCases,
                    optionLabel: \.title
                )
                optionalPicker(
                    SettingsCopy.spriteTextureFiltering,
                    keyPath: \.spriteFilter,
                    globalLabel: model.spriteFilter.title,
                    options: TextureFilter.allCases,
                    optionLabel: \.title
                )
            }

            Section {
                optionalPicker(
                    SettingsCopy.widescreen,
                    keyPath: \.widescreen,
                    globalLabel: model.widescreen.title,
                    options: Widescreen.allCases,
                    optionLabel: \.title
                )
                optionalPicker(
                    SettingsCopy.deinterlacing,
                    keyPath: \.deinterlacing,
                    globalLabel: model.deinterlacing.title,
                    options: Deinterlacing.allCases,
                    optionLabel: \.title
                )
                optionalPicker(
                    SettingsCopy.displayEffect,
                    keyPath: \.displayEffect,
                    globalLabel: model.displayEffect.title,
                    options: DisplayEffect.allCases,
                    optionLabel: \.title
                )
            }

            Section {
                SettingRow(SettingsCopy.vramReadbacks) {
                    Picker(SettingsCopy.vramReadbacks.title, selection: vramReadbacksBinding) {
                        ForEach(VramReadbacks.allCases) { choice in
                            Text(model.vramReadbacksTitle(choice, serial: target.serial)).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var enhancementsForm: some View {
        let on = effectivePgxp

        return Form {
            Section {
                optionalBoolPicker(
                    SettingsCopy.pgxp,
                    keyPath: \.pgxpEnabled,
                    globalValue: model.pgxpEnabled,
                    isEnabled: !presetDecides(\.enabled)
                )
                optionalBoolPicker(
                    SettingsCopy.usePresets,
                    keyPath: \.pgxpUsePresets,
                    globalValue: model.pgxpUsePresets
                )
            } header: {
                Text("Geometry")
            } footer: {
                if resolved.pgxpEnabled, let changes = activePreset?.changes, !changes.isEmpty {
                    Text(SettingsCopy.presetFooter(changes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !on {
                    Text(SettingsCopy.pgxpOffFooter)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Picture") {
                optionalBoolPicker(
                    SettingsCopy.textureCorrection,
                    keyPath: \.pgxpTextureCorrection,
                    globalValue: model.pgxpTextureCorrection,
                    isEnabled: on && !presetDecides(\.textureCorrection)
                )
                optionalBoolPicker(
                    SettingsCopy.colorCorrection,
                    keyPath: \.pgxpColorCorrection,
                    globalValue: model.pgxpColorCorrection,
                    isEnabled: on && !presetDecides(\.colorCorrection)
                )
                optionalBoolPicker(
                    SettingsCopy.culling,
                    keyPath: \.pgxpCulling,
                    globalValue: model.pgxpCulling,
                    isEnabled: on && !presetDecides(\.culling)
                )
                optionalBoolPicker(
                    SettingsCopy.disable2d,
                    keyPath: \.pgxpDisable2d,
                    globalValue: model.pgxpDisable2d,
                    isEnabled: on && !presetDecides(\.disable2d)
                )
            }

            Section("Depth Buffer (Experimental)") {
                optionalBoolPicker(
                    SettingsCopy.depthBuffer,
                    keyPath: \.pgxpDepthBuffer,
                    globalValue: model.pgxpDepthBuffer,
                    isEnabled: on && !presetDecides(\.depthBuffer)
                )
                optionalBoolPicker(
                    SettingsCopy.transparentDepth,
                    keyPath: \.pgxpTransparentDepth,
                    globalValue: model.pgxpTransparentDepth,
                    isEnabled: effectiveDepthBuffer
                )
            }

            Section("Advanced") {
                optionalBoolPicker(
                    SettingsCopy.cpuMode,
                    keyPath: \.pgxpCpuMode,
                    globalValue: model.pgxpCpu,
                    isEnabled: on && !presetDecides(\.cpu)
                )
                optionalBoolPicker(
                    SettingsCopy.preserveProjection,
                    keyPath: \.pgxpPreserveProjection,
                    globalValue: model.pgxpPreserveProjection,
                    isEnabled: on && !presetDecides(\.preserveProjection)
                )
                optionalBoolPicker(
                    SettingsCopy.vertexCache,
                    keyPath: \.pgxpVertexCache,
                    globalValue: model.pgxpVertexCache,
                    isEnabled: on && !presetDecides(\.vertexCache)
                )
                optionalPicker(
                    SettingsCopy.tolerance,
                    keyPath: \.pgxpTolerance,
                    globalLabel: PgxpTolerance(floatValue: model.pgxpTolerance).title,
                    options: PgxpTolerance.allCases,
                    optionLabel: \.title,
                    isEnabled: on && !presetDecides(\.tolerance)
                )
            }
        }
        .formStyle(.grouped)
    }

    private var emulationForm: some View {
        Form {
            Section("Processor") {
                optionalPicker(
                    SettingsCopy.cpuEngine,
                    keyPath: \.cpuEngine,
                    globalLabel: model.cpuEngine.title,
                    options: CpuEngine.menuOrder.filter(\.isAvailable),
                    optionLabel: \.title
                )
                optionalBoolPicker(
                    SettingsCopy.cpuOverclock,
                    keyPath: \.cpuOverclockEnabled,
                    globalValue: model.cpuOverclockEnabled
                )
                SettingRow(SettingsCopy.cpuOverclockPercent, isEnabled: resolved.cpuOverclockEnabled) {
                    HStack(spacing: 10) {
                        if overrides.cpuOverclockPercent == nil {
                            Text("Global (\(model.cpuOverclockPercent)%)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Custom Clock Speed", isOn: clockSpeedOverrideEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("Custom Clock Speed")
                    }
                }
                if overrides.cpuOverclockPercent != nil {
                    ClockSpeedControl(percent: clockSpeedPercentBinding)
                        .disabled(!resolved.cpuOverclockEnabled)
                }
            }

            Section("CD Drive") {
                optionalPicker(
                    SettingsCopy.cdReadSpeed,
                    keyPath: \.cdReadSpeedup,
                    globalLabel: CdSpeedupSetting.title(model.cdReadSpeedup),
                    options: CdSpeedupSetting.choices,
                    optionLabel: CdSpeedupSetting.title
                )
                optionalPicker(
                    SettingsCopy.cdSeekSpeed,
                    keyPath: \.cdSeekSpeedup,
                    globalLabel: CdSpeedupSetting.title(model.cdSeekSpeedup),
                    options: CdSpeedupSetting.choices,
                    optionLabel: CdSpeedupSetting.title
                )
            }

            Section("Input Lag") {
                optionalPicker(
                    SettingsCopy.runahead,
                    keyPath: \.runaheadFrames,
                    globalLabel: RunaheadSetting.title(model.runaheadFrames),
                    options: RunaheadSetting.choices,
                    optionLabel: RunaheadSetting.title
                )
            }

            Section {
                optionalBoolPicker(
                    SettingsCopy.fastBoot,
                    keyPath: \.fastBoot,
                    globalValue: model.fastBoot
                )
            } header: {
                Text("Startup")
            } footer: {
                Text(SettingsCopy.fastBootPerGameFooter)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Reset to Defaults") {
                model.resetGameOverrides(for: target)
            }
            .buttonStyle(.bordered)
            .disabled(overrideCount == 0)
            .accessibilityHint("Clears all custom settings for this game.")

            Spacer()

            Button("Done", action: close)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Escape dismisses the sheet cleanly alongside Done.
    private var escapeCloses: some View {
        Button("") { close() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Reusable Controls & Bindings

    private func optionalPicker<T: Hashable>(
        _ info: SettingInfo,
        keyPath: WritableKeyPath<GameOverrides, T?>,
        globalLabel: String,
        options: [T],
        optionLabel: @escaping (T) -> String,
        isEnabled: Bool = true
    ) -> some View {
        SettingRow(info, isEnabled: isEnabled) {
            Picker(info.title, selection: overrideBinding(keyPath)) {
                Text("Global (\(globalLabel))").tag(Optional<T>.none)
                Divider()
                ForEach(options, id: \.self) { option in
                    Text(optionLabel(option)).tag(Optional<T>.some(option))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func optionalBoolPicker(
        _ info: SettingInfo,
        keyPath: WritableKeyPath<GameOverrides, Bool?>,
        globalValue: Bool,
        isEnabled: Bool = true
    ) -> some View {
        SettingRow(info, isEnabled: isEnabled) {
            Picker(info.title, selection: overrideBinding(keyPath)) {
                Text("Global (\(globalValue ? "On" : "Off"))").tag(Optional<Bool>.none)
                Divider()
                Text("On").tag(Optional<Bool>.some(true))
                Text("Off").tag(Optional<Bool>.some(false))
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func overrideBinding<T>(_ keyPath: WritableKeyPath<GameOverrides, T?>) -> Binding<T?> {
        Binding(
            get: { model.gameOverrides.overrides(for: target.key)?[keyPath: keyPath] },
            set: { newValue in
                model.updateGameOverrides(forKey: target.key) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var vramReadbacksBinding: Binding<VramReadbacks> {
        Binding(
            get: { model.vramReadbacksChoice(for: target) },
            set: { model.setGameVramReadbacks($0, for: target) }
        )
    }

    private var clockSpeedOverrideEnabledBinding: Binding<Bool> {
        Binding(
            get: { overrides.cpuOverclockPercent != nil },
            set: { enabled in
                model.updateGameOverrides(forKey: target.key) {
                    $0.cpuOverclockPercent = enabled ? model.cpuOverclockPercent : nil
                }
            }
        )
    }

    private var clockSpeedPercentBinding: Binding<Int> {
        Binding(
            get: { overrides.cpuOverclockPercent ?? model.cpuOverclockPercent },
            set: { percent in
                model.updateGameOverrides(forKey: target.key) { $0.cpuOverclockPercent = percent }
            }
        )
    }
}

/// Tracks open Game Settings sheet `NSWindow`s so the app-wide keyboard monitor
/// never routes key-downs inside a Game Settings sheet to a running game's pad
/// or pause menu. Mirrors `SettingsWindow` and `AboutWindow`.
@MainActor
enum GameSettingsWindow {
    private final class Weak {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private static var windows: [ObjectIdentifier: Weak] = [:]

    static func record(_ window: NSWindow) {
        windows[ObjectIdentifier(window)] = Weak(window)
        windows = windows.filter { $0.value.window != nil }
    }

    static func forget(_ window: NSWindow) {
        windows[ObjectIdentifier(window)] = nil
    }

    static func owns(windowNumber: Int) -> Bool {
        windows.values.contains { $0.window?.windowNumber == windowNumber }
    }
}

private struct GameSettingsWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { GameSettingsWindow.record(window) }
    }

    private final class Probe: NSView {
        private weak var tracked: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let old = tracked, old !== window { GameSettingsWindow.forget(old) }
            tracked = window
            if let window { GameSettingsWindow.record(window) }
        }

        isolated deinit {
            if let tracked { GameSettingsWindow.forget(tracked) }
        }
    }
}
