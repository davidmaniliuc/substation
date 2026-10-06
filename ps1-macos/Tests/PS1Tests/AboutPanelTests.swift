import Testing
import AppKit
@testable import PS1

@Test func theCommitIsReadFromTheInfoDictionary() {
    let info = BuildInfo(infoDictionary: ["SubstationCommit": "a3f91c2"])
    #expect(info.commit == "a3f91c2")
    #expect(info.commitURL?.absoluteString
        == "https://github.com/davidmaniliuc/substation/commit/a3f91c2")
}

/// Xcode's Run button skips build.sh, so the plist's `$(SUBSTATION_COMMIT)`
/// expands to nothing: that is no commit, not an empty line.
@Test func anUnstampedBuildHasNoCommit() {
    #expect(BuildInfo(infoDictionary: ["SubstationCommit": ""]).commit == nil)
    #expect(BuildInfo(infoDictionary: [:]).commit == nil)
    #expect(BuildInfo(infoDictionary: nil).commitURL == nil)
}

@Test func aDirtyBuildLinksItsBaseCommit() {
    let info = BuildInfo(commit: "a3f91c2-dirty")
    #expect(info.commitURL?.lastPathComponent == "a3f91c2")
}

@Test func theCreditsCarryTheCommitAndTheRepository() {
    let credits = AboutPanel.credits(for: BuildInfo(commit: "a3f91c2"))
    #expect(credits.string == "Commit a3f91c2\ngithub.com/davidmaniliuc/substation")

    var links: [URL] = []
    credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
        if let url = value as? URL { links.append(url) }
    }
    #expect(links.map(\.absoluteString) == [
        "https://github.com/davidmaniliuc/substation/commit/a3f91c2",
        "https://github.com/davidmaniliuc/substation",
    ])
}

@Test func withoutACommitTheCreditsAreJustTheRepository() {
    let credits = AboutPanel.credits(for: BuildInfo(commit: nil))
    #expect(credits.string == "github.com/davidmaniliuc/substation")
}
