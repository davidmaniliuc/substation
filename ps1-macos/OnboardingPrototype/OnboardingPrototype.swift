// PROTOTYPE, throwaway. First-launch onboarding: C2 (C refined, the chosen
// direction), C (welcome window with a live preview), A (welcome form),
// B (two steps).
// "Current" is today's OnboardingView, for comparison. Choosing a folder is
// faked: it fills in a sample path and a sample scan result.
// Run: ps1-macos/OnboardingPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Fake setup state

struct BiosImage: Hashable { let model: String; let region: String }

@Observable final class Setup {
    var bios: URL?
    var games: URL?
    var biosFolderEmpty = false

    var biosImages: [BiosImage] {
        biosFolderEmpty ? [] : [.init(model: "SCPH-1001", region: "USA"),
                                .init(model: "SCPH-7502", region: "Europe"),
                                .init(model: "SCPH-5500", region: "Japan")]
    }
    let gameTitles = ["Castlevania: Symphony of the Night", "Crash Bandicoot", "Crash Bandicoot 2",
                      "Crash Bandicoot: Warped", "Croc: Legend of the Gobbos", "Doom",
                      "Final Fantasy VII", "Final Fantasy IX", "Gran Turismo", "Grand Theft Auto",
                      "Hot Wheels Turbo Racing", "Rayman", "Resident Evil", "Silent Hill",
                      "Spyro the Dragon", "Suikoden", "Tekken", "Tekken 3", "Tetris Plus", "Tomb Raider"]

    var biosReady: Bool { bios != nil && !biosImages.isEmpty }
    var isReady: Bool { biosReady && games != nil }

    var scanningBios = false
    var scanningGames = false

    func chooseBios() {
        bios = URL(filePath: NSHomeDirectory() + "/PlayStation/BIOS")
        scan(\.scanningBios)
    }
    func chooseGames() {
        games = URL(filePath: NSHomeDirectory() + "/PlayStation/Games")
        scan(\.scanningGames)
    }
    func reset() { bios = nil; games = nil }

    /// A real scan takes a moment on a big folder; the fake one pretends to.
    private func scan(_ flag: ReferenceWritableKeyPath<Setup, Bool>) {
        guard env("PROTO_NOSCAN") == nil else { return }
        self[keyPath: flag] = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            self[keyPath: flag] = false
        }
    }

    /// The region a title's serial says it is from, for the preview.
    func region(of title: String) -> String {
        ["Crash Bandicoot", "Crash Bandicoot 2", "Doom", "Rayman", "Final Fantasy IX", "Tekken"]
            .contains(title) ? "Europe" : "USA"
    }

    /// Screenshot hooks: PROTO_FILL=bios|both, PROTO_EMPTY=1.
    static func fromEnvironment() -> Setup {
        let setup = Setup()
        if env("PROTO_FILL") != nil { setup.chooseBios() }
        if env("PROTO_FILL") == "both" { setup.chooseGames() }
        setup.biosFolderEmpty = env("PROTO_EMPTY") != nil
        return setup
    }

    var biosSummary: String {
        biosImages.isEmpty ? "No BIOS images in this folder"
            : "\(biosImages.count) images · " + biosImages.map(\.region).formatted(.list(type: .and))
    }
    var gamesSummary: String { "\(gameTitles.count) games" }
}

let appIcon: NSImage = {
    let app = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../zig-out/Substation.app").standardized.path
    return FileManager.default.fileExists(atPath: app)
        ? NSWorkspace.shared.icon(forFile: app) : NSApp.applicationIconImage
}()

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

func tilde(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

/// The folder as Finder shows it: its own icon and a home-relative path.
struct FolderPath: View {
    let url: URL
    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 16, height: 16)
            Text(tilde(url)).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// What the scan found, or why the folder will not do.
struct ScanStatus: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(.secondary)
    }
}

// MARK: - A: welcome form

/// One centred column: icon, a welcome, and the two folders as a grouped
/// form like Settings, each row saying what was found in it.
struct VariantA: View {
    @Bindable var setup: Setup

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: appIcon).resizable().frame(width: 96, height: 96)
            Text("Welcome to Substation")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 12)
            Text("Choose where your BIOS files and games are kept.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Form {
                Section {
                    row(title: "BIOS", symbol: "cpu", url: setup.bios,
                        status: setup.bios.map { _ in ScanStatus(ok: setup.biosReady, text: setup.biosSummary) },
                        choose: setup.chooseBios)
                    row(title: "Games", symbol: "opticaldisc", url: setup.games,
                        status: setup.games.map { _ in ScanStatus(ok: true, text: setup.gamesSummary) },
                        choose: setup.chooseGames)
                } footer: {
                    Text("Each game uses the BIOS for its region. Subfolders are included. You can change both later in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: 230)
            .padding(.top, 16)

            Button("Continue") {}
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.isReady)
        }
        .frame(width: 520)
    }

    private func row(title: String, symbol: String, url: URL?, status: ScanStatus?,
                     choose: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(url == nil ? "Choose…" : "Change…", action: choose)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    if let url {
                        FolderPath(url: url).font(.callout).foregroundStyle(.secondary)
                        status?.font(.callout)
                    } else {
                        Text("Not chosen").font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - B: two steps

/// Setup Assistant: one question per page, a large symbol, a sentence on
/// why it is needed, Back on the leading side and Continue on the trailing.
struct VariantB: View {
    @Bindable var setup: Setup
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if step == 0 {
                    page(symbol: "cpu", title: "Add Your BIOS",
                         text: "A PlayStation starts from its BIOS, which Substation doesn’t include. Choose the folder holding the SCPH files dumped from your console. Each game uses the one for its region.",
                         url: setup.bios, choose: setup.chooseBios,
                         status: setup.bios.map { _ in ScanStatus(ok: setup.biosReady, text: setup.biosSummary) })
                } else {
                    page(symbol: "opticaldisc", title: "Add Your Games",
                         text: "Choose the folder holding your disc images. Subfolders are included, and .cue, .chd and .bin images are all read.",
                         url: setup.games, choose: setup.chooseGames,
                         status: setup.games.map { _ in ScanStatus(ok: true, text: setup.gamesSummary) })
                }
            }
            .id(step)
            .transition(.opacity)
            .frame(maxHeight: .infinity)

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step = 0 } }
                        .controlSize(.large)
                }
                Spacer()
                Button(step == 0 ? "Continue" : "Open Library") {
                    if step == 0 { withAnimation { step = 1 } }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(step == 0 ? !setup.biosReady : !setup.isReady)
            }
            .overlay {
                HStack(spacing: 7) {
                    ForEach(0..<2) { i in
                        Circle().fill(i == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Step \(step + 1) of 2")
            }
            .padding(.top, 20)
        }
        .frame(width: 540, height: 420)
    }

    private func page(symbol: String, title: String, text: String, url: URL?,
                      choose: @escaping () -> Void, status: ScanStatus?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .frame(height: 72)
            Text(title).font(.largeTitle.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            VStack(spacing: 8) {
                if let url {
                    FolderPath(url: url)
                    status
                    Button("Change Folder…", action: choose)
                        .controlSize(.large)
                } else {
                    Button("Choose Folder…", action: choose)
                        .controlSize(.large)
                }
            }
            .padding(.top, 10)
        }
    }
}

// MARK: - C: welcome window with a live preview

/// The Xcode welcome window's shape: the app and its two actions on the
/// left, and on the right what those choices found, filling in as they are
/// made, so the first thing the library shows is no surprise.
struct VariantC: View {
    @Bindable var setup: Setup

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer()
                Image(nsImage: appIcon).resizable().frame(width: 112, height: 112)
                Text("Welcome to Substation")
                    .font(.title.weight(.semibold))
                    .padding(.top, 14)
                Text("Version 1.0")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Spacer()
                VStack(spacing: 6) {
                    action(symbol: "cpu", title: setup.bios == nil ? "Choose BIOS Folder…" : "Change BIOS Folder…",
                           done: setup.biosReady, run: setup.chooseBios)
                    action(symbol: "opticaldisc", title: setup.games == nil ? "Choose Games Folder…" : "Change Games Folder…",
                           done: setup.games != nil, run: setup.chooseGames)
                }
                .frame(maxWidth: 300)
                Spacer()
                HStack {
                    Text("You can change these later in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue") {}
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!setup.isReady)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)

            preview
                .frame(width: 300)
                .background(.background.secondary)
        }
        .frame(width: 760, height: 460)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
    }

    private func action(symbol: String, title: String, done: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(ActionRowStyle())
    }

    @ViewBuilder private var preview: some View {
        if setup.bios == nil && setup.games == nil {
            ContentUnavailableView {
                Label("Nothing Chosen Yet", systemImage: "folder")
            } description: {
                Text("What Substation finds in your folders appears here.")
            }
        } else {
            List {
                Section("BIOS") {
                    if setup.bios == nil {
                        Text("Not chosen").foregroundStyle(.tertiary)
                    } else if setup.biosImages.isEmpty {
                        ScanStatus(ok: false, text: "No BIOS images in this folder")
                    } else {
                        ForEach(setup.biosImages, id: \.self) { image in
                            LabeledContent(image.region, value: image.model)
                        }
                    }
                }
                Section(setup.games == nil ? "Games" : "Games · \(setup.gameTitles.count)") {
                    if setup.games == nil {
                        Text("Not chosen").foregroundStyle(.tertiary)
                    } else {
                        ForEach(setup.gameTitles, id: \.self) { Text($0).lineLimit(1) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// A sidebar-like row: no border, a highlight under the pointer and a darker
/// one while pressed. Hover brightens; it never moves.
struct ActionRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.fill.opacity(configuration.isPressed ? 1 : hovering ? 0.6 : 0),
                        in: .rect(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

// MARK: - C2: refined welcome window

/// C, filling the window: the welcome and its two actions on the leading
/// side, and a full-height pane on the trailing side listing what the
/// folders hold, scanning visibly as each one is chosen.
struct VariantC2: View {
    @Bindable var setup: Setup
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            Group { if compact { plain } else { welcome } }
                .frame(maxWidth: .infinity)
            Divider()
            preview
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .background(.background.secondary)
        }
    }

    /// C3: no hero. A left-aligned title and one sentence, like a settings
    /// pane, with the two rows straight under it.
    private var plain: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            Text("Set Up Your Library")
                .font(.title2.weight(.semibold))
            Text("Substation needs a BIOS from your console and a folder of games.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            rows
                .padding(.top, 24)
                .padding(.horizontal, -12)
            Spacer(minLength: 24)
            footer
                .padding(.bottom, 24)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 40)
    }

    private var rows: some View {
        VStack(spacing: 4) {
            SetupRow(symbol: "cpu",
                     title: setup.bios == nil ? "Choose BIOS Folder…" : "Change BIOS Folder…",
                     hint: "The SCPH files dumped from your console",
                     folder: setup.bios, scanning: setup.scanningBios,
                     ok: setup.biosReady, choose: setup.chooseBios)
            SetupRow(symbol: "opticaldisc",
                     title: setup.games == nil ? "Choose Games Folder…" : "Change Games Folder…",
                     hint: "Disc images in .cue, .chd or .bin, in any subfolder",
                     folder: setup.games, scanning: setup.scanningGames,
                     ok: setup.games != nil, choose: setup.chooseGames)
        }
    }

    private var footer: some View {
        HStack {
            Text("You can change these later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Library") {}
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.isReady || setup.scanningBios || setup.scanningGames)
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: appIcon).resizable().frame(width: 128, height: 128)
            Text("Welcome to Substation")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 16)
            Text("Version 1.0 (412)")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(spacing: 4) {
                SetupRow(symbol: "cpu",
                         title: setup.bios == nil ? "Choose BIOS Folder…" : "Change BIOS Folder…",
                         hint: "The SCPH files dumped from your console",
                         folder: setup.bios, scanning: setup.scanningBios,
                         ok: setup.biosReady, choose: setup.chooseBios)
                SetupRow(symbol: "opticaldisc",
                         title: setup.games == nil ? "Choose Games Folder…" : "Change Games Folder…",
                         hint: "Disc images in .cue, .chd or .bin, in any subfolder",
                         folder: setup.games, scanning: setup.scanningGames,
                         ok: setup.games != nil, choose: setup.chooseGames)
            }
            .frame(width: 400)
            .padding(.top, 44)
            Spacer(minLength: 24)
            HStack {
                Text("You can change these later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Library") {}
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.isReady || setup.scanningBios || setup.scanningGames)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private var preview: some View {
        if setup.bios == nil && setup.games == nil {
            ContentUnavailableView {
                Label("Your Library", systemImage: "square.stack")
            } description: {
                Text("The BIOS images and games in your folders appear here.")
            }
        } else {
            List {
                Section {
                    biosRows
                } header: {
                    header("BIOS", count: setup.bios == nil || setup.scanningBios ? nil : setup.biosImages.count)
                }
                Section {
                    gameRows
                } header: {
                    header("Games", count: setup.games == nil || setup.scanningGames ? nil : setup.gameTitles.count)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var biosRows: some View {
        if setup.bios == nil {
            Text("No folder chosen").foregroundStyle(.tertiary)
        } else if setup.scanningBios {
            Scanning()
        } else if setup.biosImages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No BIOS Images Found", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Text("Substation looks for the SCPH files dumped from a PlayStation. Games can’t start without one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } else {
            ForEach(setup.biosImages, id: \.self) { image in
                Label {
                    LabeledContent(image.region) {
                        Text(image.model).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "cpu")
                }
            }
        }
    }

    @ViewBuilder private var gameRows: some View {
        if setup.games == nil {
            Text("No folder chosen").foregroundStyle(.tertiary)
        } else if setup.scanningGames {
            Scanning()
        } else {
            ForEach(setup.gameTitles, id: \.self) { title in
                Label {
                    LabeledContent {
                        Text(setup.region(of: title))
                    } label: {
                        Text(title).lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "opticaldisc")
                }
            }
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let count { Text("\(count)").monospacedDigit() }
        }
        .padding(.trailing, 10)
    }
}

private struct Scanning: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning…").foregroundStyle(.secondary)
        }
    }
}

/// One setup action: a symbol tile, the action, and under it the chosen
/// folder or what belongs there. A folder dragged from Finder onto the row
/// counts as choosing it.
private struct SetupRow: View {
    let symbol: String
    let title: String
    let hint: String
    let folder: URL?
    let scanning: Bool
    let ok: Bool
    let choose: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Group {
                        if let folder { Text(tilde(folder)).truncationMode(.middle) } else { Text(hint) }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                status
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(ActionRowStyle())
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { _, _ in choose(); return true } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var status: some View {
        if scanning {
            ProgressView().controlSize(.small)
        } else if folder != nil {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? AnyShapeStyle(.green) : AnyShapeStyle(.yellow))
                .font(.title3)
        }
    }
}

// MARK: - Current

/// Today's OnboardingView, unchanged, for comparison.
struct Current: View {
    @Bindable var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(nsImage: appIcon).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Substation").font(.title.weight(.semibold))
                    Text("Choose where your BIOS images and games are kept.").foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                row("BIOS", "Images are detected automatically. Each disc uses the BIOS for its region.",
                    setup.bios, setup.chooseBios)
                Divider().padding(.horizontal, 14)
                row("Games", "Subfolders are included. Reads .cue, .chd and .bin.", setup.games, setup.chooseGames)
            }
            .background(.quinary, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            HStack {
                Text("You can change these later in Settings.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Continue") {}
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(setup.bios == nil || setup.games == nil)
            }
        }
        .frame(maxWidth: 560)
        .padding(32)
    }

    private func row(_ title: String, _ note: String, _ folder: URL?, _ choose: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: folder == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(folder == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let folder { FolderPath(url: folder).font(.callout) }
                else { Text("Not set").font(.callout).foregroundStyle(.tertiary) }
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(folder == nil ? "Choose…" : "Change…", action: choose)
        }
        .padding(14)
    }
}

// MARK: - Shell

enum Variant: String, CaseIterable, Identifiable {
    case c3 = "C3", c2 = "C2", c = "C", a = "A", b = "B", old = "Current"
    var id: String { rawValue }
}

enum Backdrop: String, CaseIterable, Identifiable {
    case black = "Black", system = "System"
    var id: String { rawValue }
}

struct Root: View {
    @State private var setup = Setup.fromEnvironment()
    @State private var variant = Variant.allCases.first { $0.rawValue.lowercased().hasPrefix(env("PROTO_VARIANT") ?? "c3") } ?? .c3
    @State private var backdrop = env("PROTO_THEME") == "system" ? Backdrop.system : .black

    var body: some View {
        ZStack {
            (backdrop == .black ? Color.black : Color(nsColor: .windowBackgroundColor))
            switch variant {
            case .c3: VariantC2(setup: setup, compact: true)
            case .c2: VariantC2(setup: setup)
            case .a: VariantA(setup: setup)
            case .b: VariantB(setup: setup)
            case .c: VariantC(setup: setup)
            case .old: Current(setup: setup)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, backdrop == .black ? .dark : .light)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $variant) {
                    ForEach(Variant.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                Picker("Theme", selection: $backdrop) {
                    ForEach(Backdrop.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("BIOS Folder Empty", isOn: $setup.biosFolderEmpty)
                Button("Fill Both") { setup.chooseBios(); setup.chooseGames() }
                Button("Reset") { setup.reset() }
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .animation(.default, value: setup.bios)
        .animation(.default, value: setup.games)
    }
}

@main
struct OnboardingPrototypeApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Onboarding Prototype") { Root() }
    }
}
