import AppKit

/// What the bundle says about the build it came from.
///
/// The version and build number are the standard panel's own
/// (`CFBundleShortVersionString`/`CFBundleVersion`, both numeric). The commit
/// cannot go there, so `build.sh` stamps it into `SubstationCommit` through
/// the `SUBSTATION_COMMIT` build setting; a build that skipped `build.sh`
/// (Xcode's Run button) expands that to an empty string, read here as no
/// commit at all.
struct BuildInfo: Equatable {
    static let repository = URL(string: "https://github.com/davidmaniliuc/substation")!

    /// Short hash, with `-dirty` when the working tree had changes.
    let commit: String?

    init(commit: String?) {
        self.commit = commit.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(infoDictionary: [String: Any]?) {
        self.init(commit: infoDictionary?["SubstationCommit"] as? String)
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

/// The standard About panel, with the commit and the repository as credits.
enum AboutPanel {
    static func credits(for info: BuildInfo) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        if let commit = info.commit {
            text.append(NSAttributedString(string: "Commit ", attributes: base))
            var link = base
            if let url = info.commitURL { link[.link] = url }
            text.append(NSAttributedString(string: commit, attributes: link))
            text.append(NSAttributedString(string: "\n", attributes: base))
        }
        var repo = base
        repo[.link] = BuildInfo.repository
        let shown = BuildInfo.repository.host! + BuildInfo.repository.path
        text.append(NSAttributedString(string: shown, attributes: repo))
        return text
    }

    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(for: .current)])
        NSApp.activate()
    }
}
