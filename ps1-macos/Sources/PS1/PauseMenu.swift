import AppKit
import SwiftUI

/// The pause menu: a blurred sidebar flush to the window's leading edge,
/// opened by the bar's `…`, Esc or a controller's Home, with the game paused
/// under it. The header and the key hints stay put; everything
/// between them is one scrolling list whose settings are real controls, so
/// nothing sits behind a page. The highlight is `PauseMenuNavigation`'s,
/// kept on the model, so the arrows, the D-pad and the pointer move the same
/// one.
struct PauseMenu: View {
    @Bindable var model: EmulatorViewModel
    let isFullScreen: Bool
    /// A short window: a smaller cover and no serial line.
    @State private var compact = false

    static let width: CGFloat = 300
    /// The footer's rule.
    static let rule = Color.white.opacity(0.16)

    /// Room for the traffic lights, which sit inside the panel windowed.
    private var topClearance: CGFloat { isFullScreen ? 24 : 52 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PauseMenuHeader(model: model, compact: compact)
                    .padding(.horizontal, 16)
                PauseMenuList(model: model, compact: compact)
            }
            .padding(.top, topClearance)
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < 640 } action: { compact = $0 }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // A plain blur, as Music's lyrics pane: Liquid Glass rims its whole
        // shape, and on a rectangle flush to the window that rim and an
        // edge hairline read as a box drawn round the panel.
        .background(.regularMaterial)
    }

    /// A rule across the whole panel, then the keys as one quiet line, in a
    /// strip of its own so the list never scrolls under it.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Self.rule).frame(height: 1)
            HStack(spacing: 8) {
                KeyHint(key: "↑↓", text: "Move")
                separator
                KeyHint(key: "←→", text: "Change")
                separator
                KeyHint(key: "esc", text: "Resume")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private var separator: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 12)
    }
}

/// A key cap and what it does.
private struct KeyHint: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            Text(text)
        }
        .fixedSize()
    }
}

// MARK: - Header

/// Cover, title, serial and region, how long this sitting has been, and
/// Resume as the one prominent button.
private struct PauseMenuHeader: View {
    @Bindable var model: EmulatorViewModel
    let compact: Bool
    @State private var cover: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if let cover {
                Image(nsImage: cover).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: coverSide, maxHeight: coverSide)
                    .clipShape(.rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Marquee(text: model.discTitle, font: .system(size: 15, weight: .semibold))
                if !compact, let disc = model.currentDisc {
                    Text(verbatim: "\(disc.serial ?? "Unknown") · \(GameInfo.region(disc.identity.region))")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Every 30 s, as the title strip: it counts minutes.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let played = model.sessionPlayed(at: ProcessInfo.processInfo.systemUptime)
                    Label("Playing for \(PlayingFor.format(played))", systemImage: "pause.fill")
                        .labelStyle(PausedLabel())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { model.setSurface(.pauseMenu, open: false) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Resume (esc)")
            .accessibilityLabel("Resume")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, compact ? 10 : 16)
        .task(id: model.currentCoverURL) {
            cover = model.currentCoverURL.flatMap { NSImage(contentsOf: $0) }
        }
    }

    private var coverSide: CGFloat { compact ? 44 : 64 }
}

/// The paused glyph small and a step lighter than the words.
private struct PausedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 8)).opacity(0.8)
            configuration.title
        }
    }
}

// MARK: - List

/// Save States, Quick Settings, Machine and About This Game, as one scroll
/// view with no scroller: with a mouse attached macOS draws the legacy one, an
/// opaque track down the blur, and the soft edge effect already shows there
/// is more below.
private struct PauseMenuList: View {
    @Bindable var model: EmulatorViewModel
    /// The header has dropped the serial line, so About This Game carries it.
    let compact: Bool

    private var nav: PauseMenuNavigation { model.menu }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    saveStates
                    if nav.isShown(.disc) { disc }

                    heading("Quick Settings")
                    speed
                    resolution
                    volume
                    pgxp
                    analog

                    heading("Machine")
                    action(.reset, icon: "arrow.counterclockwise", title: "Reset")
                    action(.quitGame, icon: "eject.fill", title: "Quit Game")

                    heading("About This Game")
                    about
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
                .padding(.horizontal, 10)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollIndicators(.never)
            // The keys' and the controller's highlight stays on screen; the
            // pointer's never scrolls.
            .onChange(of: nav.focus) { _, focus in
                guard let focus, nav.focusFromKeys else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(focus) }
            }
        }
    }

    // MARK: Rows

    /// The panel the bar opens, anchored here: the menu is the controller's
    /// only route to it.
    private var saveStates: some View {
        Button { confirm(.saveStates) } label: {
            row(.saveStates) {
                RowIcon(name: "rectangle.stack")
                Titled("Save States", subtitle: model.saveStatesSummary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: panelShown, arrowEdge: .trailing) { SaveStatesPanel(model: model) }
    }

    private var panelShown: Binding<Bool> {
        Binding(get: { model.isOpen(.saveStates) && model.saveStatesOrigin == .menu },
                set: { if !$0 { model.setSurface(.saveStates, open: false) } })
    }

    /// For a multi-disc game only. ←→ picks a disc and Return inserts it; a
    /// click on a segment inserts at once.
    private var disc: some View {
        row(.disc) {
            RowIcon(name: "opticaldisc")
            Text("Disc").font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("Disc", selection: Binding(
                get: { nav.discChoice },
                set: { model.perform(.insertDisc($0)) })) {
                ForEach(0..<nav.discCount, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 132)
        }
    }

    private var speed: some View {
        row(.speed) {
            RowIcon(name: "gauge.with.dots.needle.67percent")
            Text("Speed").font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("Speed", selection: $model.speed) {
                ForEach(SpeedSetting.choices, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 132)
        }
    }

    private var resolution: some View {
        row(.resolution) {
            RowIcon(name: "square.resize")
            Titled("Resolution", subtitle: model.outputSize.map { "\($0.width)×\($0.height)" })
            Spacer(minLength: 8)
            Text("\(model.internalScale)×").font(.system(size: 13)).monospacedDigit()
            Stepper("Resolution", value: $model.internalScale, in: InternalResolution.range)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// The speaker mutes; moving the slider unmutes, as the bar's does.
    private var volume: some View {
        row(.volume) {
            Button { model.toggleMute() } label: {
                RowIcon(name: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .help(model.isMuted ? "Unmute" : "Mute")
            Text("Volume").font(.system(size: 13))
            Spacer(minLength: 8)
            Slider(value: Binding(get: { model.isMuted ? 0 : model.volume },
                                  set: { model.volume = $0 }),
                   in: VolumeSetting.range)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel("Volume")
        }
    }

    /// Greyed, with the reason, while the game's preset decides it.
    private var pgxp: some View {
        let locked = !nav.isEnabled(.pgxp)
        return row(.pgxp) {
            RowIcon(name: "cube.transparent")
            Titled("PGXP", subtitle: locked ? "Set by this game's preset" : "Steadier 3D geometry")
            Spacer(minLength: 8)
            Toggle("PGXP", isOn: $model.pgxpEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(locked)
        }
    }

    /// The mode asked for; the button is pressed when the menu closes.
    private var analog: some View {
        row(.analog) {
            RowIcon(name: "gamecontroller")
            Titled("Analog", subtitle: "DualShock sticks")
            Spacer(minLength: 8)
            Toggle("Analog", isOn: Binding(
                get: { model.analogShown },
                set: { model.perform(.adjust(.analog, $0 ? 1 : -1)) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    /// Reset and Quit Game: a click is a hover, then the confirm a key sends.
    private func action(_ item: PauseMenuItem, icon: String, title: String) -> some View {
        let destructive = item == .quitGame
        return Button { confirm(item) } label: {
            row(item) {
                RowIcon(name: icon, tint: destructive ? .red : .accentColor)
                Text(title).font(.system(size: 13))
                    .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    /// Read-only, so nothing here takes the highlight.
    private var about: some View {
        VStack(spacing: 6) {
            ForEach(model.gameInfo(identityInHeader: !compact), id: \.label) { info in
                // System Settings' About: the label primary and the value
                // secondary, so the grey heading above stays the only heading.
                HStack {
                    Text(info.label)
                    Spacer()
                    Text(info.value).monospacedDigit().lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Pieces

    private func confirm(_ item: PauseMenuItem) {
        model.pointMenu(at: item)
        model.surfaceMove(.confirm)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    /// A row the pointer and the keys both highlight, with a soft tint rather
    /// than a solid fill, since most rows carry a control.
    private func row(_ item: PauseMenuItem, @ViewBuilder content: () -> some View) -> some View {
        let highlighted = nav.focus == item
        return HStack(spacing: 9) { content() }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .padding(.vertical, 2)
            .background(highlighted ? (item == .quitGame ? Color.red.opacity(0.18) : .white.opacity(0.09))
                                    : .clear,
                        in: .rect(cornerRadius: 8))
            .contentShape(.rect)
            .id(item)
            .onHover { inside in
                if inside { model.pointMenu(at: item) } else { model.leaveMenu(item) }
            }
    }
}

/// An accent 13 pt symbol in a fixed column, so the titles line up.
private struct RowIcon: View {
    let name: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(width: 18)
    }
}

/// A row's title, with a one-line subtitle under it when there is one.
private struct Titled: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13))
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
