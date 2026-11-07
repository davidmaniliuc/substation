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
    @Bindable var game: OpenGame
    let isFullScreen: Bool
    /// A short window: a smaller cover and no serial line.
    @State private var compact = false

    static let width: CGFloat = 300

    /// Room for the traffic lights, which sit inside the panel windowed.
    private var topClearance: CGFloat { isFullScreen ? Design.Spacing.xxl : 52 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PauseMenuHeader(model: model, game: game, compact: compact)
                    .padding(.horizontal, Design.Spacing.l)
                PauseMenuList(model: model, game: game, compact: compact)
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
            Divider()
            KeyHints([("↑↓", "Move"), ("←→", "Change"), ("⎋", "Resume")])
                .padding(.horizontal, Design.Spacing.l)
        }
    }
}

// MARK: - Header

/// Cover, title, serial and region, how long this sitting ran before the
/// pause, and
/// Resume as the one prominent button.
private struct PauseMenuHeader: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame
    let compact: Bool
    @State private var cover: NSImage?

    /// The cover is read here, not only in the `.task`: a task runs after the
    /// panel is inserted, so the cover landed outside the slide's transaction
    /// and popped in on its own.
    init(model: EmulatorViewModel, game: OpenGame, compact: Bool) {
        self.model = model
        self.game = game
        self.compact = compact
        _cover = State(initialValue: game.currentCoverURL.flatMap { NSImage(contentsOf: $0) })
    }

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            if let cover {
                Image(nsImage: cover).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: coverSide, maxHeight: coverSide)
                    .clipShape(Design.cardShape(Design.Radius.cover(coverSide)))
                    .overlay(Design.cardShape(Design.Radius.cover(coverSide)).strokeBorder(.separator, lineWidth: Design.hairline))
                    .designShadow(.thumbnail)
            }
            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                Marquee(text: game.discTitle, font: .title3.weight(.semibold))
                if !compact, let disc = game.currentDisc {
                    Text(verbatim: "\(disc.serial ?? "Unknown") · \(GameInfo.region(disc.identity.region))")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Every 30 s, as the title strip: it counts minutes.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let played = game.sessionPlayed(at: ProcessInfo.processInfo.systemUptime)
                    Text(PlayingFor.pausedAfter(played))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { game.setSurface(.pauseMenu, open: false) } label: {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Resume (esc)")
            .accessibilityLabel("Resume")
        }
        .padding(.bottom, compact ? Design.Spacing.m : Design.Spacing.l)
        .task(id: game.currentCoverURL) {
            cover = game.currentCoverURL.flatMap { NSImage(contentsOf: $0) }
        }
    }

    private var coverSide: CGFloat { compact ? 44 : 64 }
}

// MARK: - List

/// Save States, Quick Settings, Machine and About This Game, as one scroll
/// view with no scroller: with a mouse attached macOS draws the legacy one, an
/// opaque track down the blur, and the soft edge effect already shows there
/// is more below.
private struct PauseMenuList: View {
    @Bindable var model: EmulatorViewModel
    @Bindable var game: OpenGame
    /// The header has dropped the serial line, so About This Game carries it.
    let compact: Bool

    private var nav: PauseMenuNavigation { game.menu }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    action(.quitGame, icon: "eject", title: "Quit Game")

                    heading("About This Game")
                    about
                }
                .padding(.top, Design.Spacing.xs)
                .padding(.bottom, Design.Spacing.m)
                .padding(.horizontal, RowMetrics.inset)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollIndicators(.never)
            // The keys' and the controller's highlight stays on screen; the
            // pointer's never scrolls.
            .onChange(of: nav.focus) { _, focus in
                guard let focus, nav.focusFromKeys else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(focus) }
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
                Titled("Save States", subtitle: game.saveStatesSummary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(FillPressStyle(hovers: false))
        .popover(isPresented: panelShown, arrowEdge: .trailing) { SaveStatesPanel(model: model, game: game) }
    }

    private var panelShown: Binding<Bool> {
        Binding(get: { game.isOpen(.saveStates) && game.saveStatesOrigin == .menu },
                set: { if !$0 { game.setSurface(.saveStates, open: false) } })
    }

    /// For a multi-disc game only. ←→ picks a disc and Return inserts it; a
    /// click on a segment inserts at once.
    private var disc: some View {
        row(.disc) {
            RowIcon(name: "opticaldisc")
            Text("Disc").font(.body)
            Spacer(minLength: Design.Spacing.s)
            Picker("Disc", selection: Binding(
                get: { nav.discChoice },
                set: { game.perform(.insertDisc($0)) })) {
                ForEach(0..<nav.discCount, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: Design.Size.trailingControl)
        }
    }

    private var speed: some View {
        row(.speed) {
            RowIcon(name: "gauge.with.dots.needle.67percent")
            Text("Speed").font(.body)
            Spacer(minLength: Design.Spacing.s)
            Picker("Speed", selection: $model.speed) {
                ForEach(SpeedSetting.choices, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: Design.Size.trailingControl)
        }
    }

    private var resolution: some View {
        row(.resolution) {
            RowIcon(name: "square.resize")
            Titled("Resolution", subtitle: game.outputSize.map { "\($0.width)×\($0.height)" })
            Spacer(minLength: Design.Spacing.s)
            Text("\(model.internalScale)×").font(.body).monospacedDigit()
            Stepper("Resolution", value: $model.internalScale, in: InternalResolution.range)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// The speaker mutes; moving the slider unmutes, as the bar's does.
    private var volume: some View {
        row(.volume) {
            Button { model.toggleMute() } label: {
                RowIcon(name: model.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .frame(width: RowMetrics.target, height: RowMetrics.target)
            }
            .buttonStyle(FillPressStyle(cornerRadius: Design.concentric(
                Design.Radius.row, inset: (RowMetrics.height - RowMetrics.target) / 2), hovers: false))
            // The target is wider than the icon column; the overhang keeps
            // the title where the other rows put theirs.
            .padding(.horizontal, -(RowMetrics.target - RowMetrics.icon) / 2)
            .help(model.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
            Text("Volume").font(.body)
            Spacer(minLength: Design.Spacing.s)
            // The level in words too: the small slider's knob covers the
            // accent fill near either end.
            Text(model.isMuted ? "Muted" : "\(Int((model.volume * 100).rounded()))%")
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.isMuted ? 0 : model.volume },
                                  set: { model.volume = $0 }),
                   in: VolumeSetting.range)
                .controlSize(.small)
                .frame(width: Design.Size.trailingControl)
                .accessibilityLabel("Volume")
        }
    }

    /// Greyed, with the reason, while the game's preset decides it.
    private var pgxp: some View {
        let locked = !nav.isEnabled(.pgxp)
        return row(.pgxp) {
            RowIcon(name: "cube.transparent")
            Titled("PGXP", subtitle: locked ? "Set by this game's preset" : "Steadier 3D geometry")
            Spacer(minLength: Design.Spacing.s)
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
            Spacer(minLength: Design.Spacing.s)
            Toggle("Analog", isOn: Binding(
                get: { game.analogShown },
                set: { game.perform(.adjust(.analog, $0 ? 1 : -1)) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    /// Reset and Quit Game: a click is a hover, then the confirm a key sends.
    /// Neither is red: quitting asks to save first, so it loses nothing.
    private func action(_ item: PauseMenuItem, icon: String, title: String) -> some View {
        Button { confirm(item) } label: {
            row(item) {
                RowIcon(name: icon)
                Text(title).font(.body)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(FillPressStyle(hovers: false))
    }

    /// Read-only, so nothing here takes the highlight.
    private var about: some View {
        VStack(spacing: 0) {
            ForEach(game.gameInfo(identityInHeader: !compact), id: \.label) { info in
                // System Settings' About: the label primary and the value
                // secondary, so the grey heading above stays the only heading.
                HStack {
                    Text(info.label)
                    Spacer()
                    Text(info.value).monospacedDigit().lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                // The rows' height, so the section keeps the list's rhythm.
                .frame(minHeight: RowMetrics.height)
            }
        }
        // Labels in the rows' title column, so the section reads as part of
        // the list above rather than a second heading level.
        .padding(.leading, RowMetrics.inset + RowMetrics.icon + RowMetrics.gap)
        .padding(.trailing, RowMetrics.inset)
    }

    // MARK: Pieces

    private func confirm(_ item: PauseMenuItem) {
        game.pointMenu(at: item)
        game.surfaceMove(.confirm)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, RowMetrics.inset)
            .padding(.top, Design.Spacing.l)
            .padding(.bottom, Design.Spacing.xs)
    }

    /// A row the pointer and the keys both highlight, with a soft tint rather
    /// than a solid fill, since most rows carry a control.
    private func row(_ item: PauseMenuItem, @ViewBuilder content: () -> some View) -> some View {
        let highlighted = nav.focus == item
        return HStack(spacing: RowMetrics.gap) { content() }
            .padding(.horizontal, RowMetrics.inset)
            .frame(minHeight: RowMetrics.height)
            .background {
                if highlighted { Design.cardShape(Design.Radius.row).fill(.fill.tertiary) }
            }
            .contentShape(.rect)
            .id(item)
            .onHover { inside in
                if inside { game.pointMenu(at: item) } else { game.leaveMenu(item) }
            }
    }
}

/// The list's one geometry, shared by the rows and the About section.
private enum RowMetrics {
    /// The icon column, so the titles line up.
    static let icon: CGFloat = 18
    /// From the icon to the row's title.
    static let gap = Design.Spacing.s
    /// Inside a row and round the list: header, headings, rows and footer
    /// all start 16 pt from the panel.
    static let inset = Design.Spacing.s
    /// The mute button's hit area, wider than the icon it holds.
    static let target: CGFloat = 28
    /// Every row's height, a title and subtitle included.
    static let height: CGFloat = 34
}

/// A secondary body-size symbol in a fixed column, so the titles line up. Not
/// the accent: in this app the accent marks what a click acts on, and here
/// that is the controls and the Resume button.
private struct RowIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: RowMetrics.icon)
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
        VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
            Text(title).font(.body)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A plain row's press feedback. The hover tint is the list's own highlight
/// (the pointer moves it), so this adds only the firmer fill under a press.
