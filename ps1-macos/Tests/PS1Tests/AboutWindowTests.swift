import Testing
@testable import PS1

@Test func theBuildLinesAreReadFromTheInfoDictionary() {
    let info = BuildInfo(infoDictionary: [
        "CFBundleShortVersionString": "0.9.0",
        "CFBundleVersion": "1000",
        "SubstationCommit": "a3f91c2",
    ])
    #expect(info == BuildInfo(version: "0.9.0", build: "1000", commit: "a3f91c2"))
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
    let info = BuildInfo(version: "0.9.0", build: "1000", commit: "a3f91c2-dirty")
    #expect(info.commitURL?.lastPathComponent == "a3f91c2")
}
