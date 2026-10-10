import SwiftUI

/// The pause menu: a glass panel from the leading edge, opened by the bar's
/// `…`, Esc or a controller's Home, with the game paused under it. Its page,
/// highlight and disc flyout are `PauseMenuNavigation`'s, kept on the model,
/// so the arrows, the D-pad and the pointer all move the same highlight; a
/// click is a hover then a confirm.
struct PauseMenu: View {
    @Bindable var model: EmulatorViewModel

    static let width: CGFloat = 330
    private let flyoutWidth: CGFloat = 220

    private var nav: PauseMenuNavigation { model.menu }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            switch nav.page {
            case .root: root
            case .quickSettings: quickSettings
            case .gameInfo: gameInfo
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.snappy(duration: 0.25), value: nav.page)
        .animation(.snappy(duration: 0.2), value: nav.flyout)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            if nav.page != .root {
                Button { model.surfaceMove(.back) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .buttonStyle(HoverStyle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                if nav.page == .root {
                    Text("Paused").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    private var title: String {
        switch nav.page {
        case .root: model.discTitle
        case .quickSettings: "Quick Settings"
        case .gameInfo: "Game Info"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if nav.page != .gameInfo { hint("arrow.up.arrow.down", "Move") }
            if nav.page == .quickSettings { hint("arrow.left.arrow.right", "Change") }
            if nav.page == .root { hint("return", "Select") }
            hint("escape", nav.page == .root ? "Resume" : "Back")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) { Image(systemName: symbol); Text(text) }
    }

    // MARK: Root

    private var root: some View {
        VStack(spacing: 2) {
            ForEach(Array(PauseMenuRow.allCases.enumerated()), id: \.offset) { i, row in
                if row == .saveState || row == .reset {
                    Divider().padding(.vertical, 4).padding(.horizontal, 8)
                }
                rootRow(row, index: i)
            }
        }
    }

    @ViewBuilder
    private func rootRow(_ row: PauseMenuRow, index: Int) -> some View {
        let disabled = nav.isDisabled(row)
        let line = MenuRowLabel(icon: icon(row), title: rowTitle(row), detail: detail(row),
                                drills: drills(row), destructive: row == .quitGame,
                                selected: index == nav.selection && !disabled && nav.flyout == nil)
        Button {
            model.pointMenu(at: index)
            model.surfaceMove(.confirm)
        } label: { line }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
            .onHover { if $0 { model.pointMenu(at: index) } }
            .overlay(alignment: .topTrailing) {
                if row == .changeDisc, nav.flyout != nil {
                    discFlyout
                        .offset(x: flyoutWidth + 26, y: -6)
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
            }
            .popover(isPresented: panelShown(for: row), arrowEdge: .trailing) {
                SaveStatesPanel(model: model)
            }
    }

    /// The Save State and Load State rows anchor the same panel the bar
    /// opens, so the mouse and a controller share one surface.
    private func panelShown(for row: PauseMenuRow) -> Binding<Bool> {
        let origin: SaveStatesOrigin? = switch row {
        case .saveState: .menuSave
        case .loadState: .menuLoad
        default: nil
        }
        return Binding(
            get: { origin != nil && model.isOpen(.saveStates) && model.saveStatesOrigin == origin },
            set: { if !$0 { model.setSurface(.saveStates, open: false) } })
    }

    private func icon(_ row: PauseMenuRow) -> String {
        switch row {
        case .resume: "play.fill"
        case .saveState: "square.and.arrow.down"
        case .loadState: "clock.arrow.circlepath"
        case .changeDisc: "circle.circle"
        case .quickSettings: "slider.horizontal.3"
        case .gameInfo: "info.circle"
        case .reset: "arrow.counterclockwise"
        case .quitGame: "eject.fill"
        }
    }

    private func rowTitle(_ row: PauseMenuRow) -> String {
        switch row {
        case .resume: "Resume"
        case .saveState: "Save State"
        case .loadState: "Load State"
        case .changeDisc: "Change Disc"
        case .quickSettings: "Quick Settings"
        case .gameInfo: "Game Info"
        case .reset: "Reset"
        case .quitGame: "Quit Game"
        }
    }

    private func detail(_ row: PauseMenuRow) -> String? {
        switch row {
        case .resume: "Esc"
        case .changeDisc where nav.discCount > 1: "Disc \(nav.insertedDisc + 1) of \(nav.discCount)"
        default: nil
        }
    }

    private func drills(_ row: PauseMenuRow) -> Bool {
        switch row {
        case .saveState, .loadState, .quickSettings, .gameInfo: true
        case .changeDisc: nav.discCount > 1
        default: false
        }
    }

    // MARK: Change Disc

    /// Beside its row rather than a page of its own: the menu stays put.
    private var discFlyout: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<nav.discCount, id: \.self) { i in
                let inserted = i == nav.insertedDisc
                Button {
                    model.pointDisc(at: i)
                    model.surfaceMove(.confirm)
                } label: {
                    MenuRowLabel(icon: inserted ? "circle.circle.fill" : "circle.circle",
                                 title: "Disc \(i + 1)", detail: inserted ? "Inserted" : nil,
                                 drills: false, destructive: false, selected: i == nav.flyout)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { model.pointDisc(at: i) } }
            }
        }
        .padding(6)
        .frame(width: flyoutWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: Quick Settings

    private var quickSettings: some View {
        VStack(spacing: 2) {
            ForEach(Array(QuickSetting.allCases.enumerated()), id: \.offset) { i, setting in
                let s = settingLine(setting)
                StepperRow(icon: s.icon, title: s.title, value: s.value,
                           selected: i == nav.selection) { delta in
                    model.pointMenu(at: i)
                    model.perform(.adjust(setting, delta))
                }
                .onHover { if $0 { model.pointMenu(at: i) } }
            }
        }
    }

    private func settingLine(_ setting: QuickSetting) -> (icon: String, title: String, value: String) {
        switch setting {
        case .speed: ("forward", "Speed", "\(model.speed)×")
        case .resolution: ("square.resize", "Resolution", "\(model.internalScale)×")
        case .pgxp: ("cube.transparent", "PGXP", model.pgxpEnabled ? "On" : "Off")
        case .analog: ("gamecontroller", "Analog", model.analogShown ? "On" : "Off")
        case .volume: ("speaker.wave.2", "Volume",
                       model.isMuted ? "Muted" : "\(Int((model.volume * 100).rounded()))%")
        }
    }

    // MARK: Game Info

    /// Read-only: nothing here is in the arrow keys' order.
    private var gameInfo: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.gameInfo, id: \.label) { info in
                HStack(spacing: 12) {
                    Image(systemName: info.icon).frame(width: 20).foregroundStyle(.secondary)
                    Text(info.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(info.value).monospacedDigit().lineLimit(1)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

/// One row: icon, title, an optional detail, a › for a row that leads on.
/// The highlight is the accent, red for Quit Game.
private struct MenuRowLabel: View {
    let icon: String
    let title: String
    let detail: String?
    let drills: Bool
    let destructive: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20)
            Text(title)
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
            if drills {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.6)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? (destructive ? Color.red : .accentColor).opacity(0.85) : .clear,
                    in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }

    private var foreground: Color {
        if selected { return .white }
        return destructive ? .red : .primary
    }
}

/// A Quick Settings row: `‹ value ›`, the chevrons stepping it down and up.
private struct StepperRow: View {
    let icon: String
    let title: String
    let value: String
    let selected: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20)
            Text(title)
            Spacer()
            HStack(spacing: 2) {
                chevron("chevron.left", -1)
                Text(value).monospacedDigit().frame(minWidth: 44)
                chevron("chevron.right", 1)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.85) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }

    private func chevron(_ symbol: String, _ delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(HoverStyle())
    }
}
