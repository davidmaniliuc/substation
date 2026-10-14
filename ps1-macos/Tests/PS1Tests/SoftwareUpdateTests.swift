import Testing
@testable import PS1

private let feed = "https://raw.githubusercontent.com/davidmaniliuc/substation/appcast/appcast.xml"

@Test func aReleaseBuildWithBothKeysUpdates() {
    #expect(SoftwareUpdate.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": "c2lnbmVkCg=="]))
}

/// A local build: the plist's `$(SPARKLE_PUBLIC_ED_KEY)` expands to nothing,
/// and that must read as "no updater", or a dev build would offer to replace
/// itself with the latest release.
@Test func anEmptyKeyIsNoUpdater() {
    #expect(!SoftwareUpdate.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": ""]))
    #expect(!SoftwareUpdate.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": "  "]))
    #expect(!SoftwareUpdate.isConfigured(["SUFeedURL": feed]))
    #expect(!SoftwareUpdate.isConfigured(["SUPublicEDKey": "c2lnbmVkCg=="]))
    #expect(!SoftwareUpdate.isConfigured(nil))
}

@MainActor
@Test func anUnconfiguredBuildNeverStartsSparkle() {
    let updates = SoftwareUpdate(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": ""])
    #expect(!updates.isAvailable)
    #expect(!updates.canCheckForUpdates)
    updates.checkForUpdates() // a no-op, not a crash
}
