import AppKit
import SwiftUI

/// What the bundle says about the build it came from.
///
/// `build.sh` stamps all three: the version from `MARKETING_VERSION` (a
/// release tag overrides it), the build number as the commit count, and the
/// commit into `SubstationCommit`. A build that skipped `build.sh` (Xcode's
/// Run button) expands the commit to an empty string, read here as no commit
/// at all.
struct BuildInfo: Equatable {
    static let repository = URL(string: "https://github.com/davidmaniliuc/substation")!

    let version: String
    let build: String
    /// Short hash, with `-dirty` when the working tree had changes.
    let commit: String?

    init(version: String, build: String, commit: String?) {
        self.version = version
        self.build = build
        self.commit = commit.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(infoDictionary info: [String: Any]?) {
        self.init(
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            commit: info?["SubstationCommit"] as? String)
    }

    static var current: BuildInfo { BuildInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// The commit's page on GitHub. A dirty build still links its base
    /// commit: the closest thing GitHub has to what was built.
    var commitURL: URL? {
        guard let commit else { return nil }
        let hash = commit.split(separator: "-").first.map(String.init) ?? commit
        guard !hash.isEmpty, hash.allSatisfy(\.isHexDigit) else { return nil }
        return Self.repository.appendingPathComponent("commit").appendingPathComponent(hash)
    }
}

/// Substation ▸ About Substation: the icon, the name, the three build lines
/// and the repository. A window of our own rather than the standard panel,
/// which has no place for a linked commit beside the version.
@MainActor
enum AboutWindow {
    static let id = "about"

    static weak var current: NSWindow?

    /// By window NUMBER, as `SettingsWindow.owns`: the key monitor may only
    /// carry Sendable values into the main actor.
    static func owns(windowNumber: Int) -> Bool {
        guard let current else { return false }
        return current.windowNumber == windowNumber
    }
}

struct AboutView: View {
    let info: BuildInfo

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Substation")
                .font(.title2)
                .bold()
                .padding(.top, 8)
            Text("A native PlayStation emulator for the Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            details
                .padding(.top, 16)
            Button("GitHub") { openURL(BuildInfo.repository) }
                .padding(.top, 20)
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(width: 260)
        // The desktop shows through, as in Finder's About window.
        .background {
            BehindWindowBlur()
                .ignoresSafeArea()
        }
        .background(AboutWindowMarker())
        // Escape closes it, as it does a panel.
        .background {
            Button("Close") { AboutWindow.current?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            row("Version") { Text(info.version).foregroundStyle(.secondary) }
            row("Build") { Text(info.build).foregroundStyle(.secondary) }
            if let commit = info.commit {
                row("Commit") {
                    if let url = info.commitURL {
                        Link(commit, destination: url)
                    } else {
                        Text(commit).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            value()
                .monospaced()
                .textSelection(.enabled)
        }
    }
}

/// Finds the window for `AboutWindow.current`.
private struct AboutWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { AboutWindow.current = window }
        }
    }
}
