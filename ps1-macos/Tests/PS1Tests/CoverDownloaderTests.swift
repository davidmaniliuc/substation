import Testing
import Foundation
import AppKit
@testable import PS1

/// Answers from a table instead of the network. A test that reached GitHub
/// would pass or fail on the connection rather than on the rules, and would
/// pass silently when offline in the one way that matters — by downloading
/// nothing and calling it a clean sweep.
private struct FakeFetcher: CoverFetching {
    /// serial -> bytes. A serial that is absent is a 404; one listed in
    /// `failing` throws.
    let available: [String: Data]
    var failing: Set<String> = []

    func fetch(_ url: URL) async throws -> Data? {
        let serial = url.deletingPathExtension().lastPathComponent
        if failing.contains(serial) { throw URLError(.notConnectedToInternet) }
        return available[serial]
    }
}

private func entry(_ path: String, serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), isCue: true,
              identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

private func pngData(_ colour: NSColor = .red, size: Int = 8) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let pixels = rep.bitmapData!
    for i in 0..<(size * rep.bytesPerRow) { pixels[i] = UInt8(i % 251) }
    return rep.representation(using: .png, properties: [:])!
}

@Test func theTemplateSubstitutesTheSerial() {
    let source = CoverSource(template: "https://example.test/covers/${serial}.jpg")
    #expect(source.url(forSerial: "SLUS-00530")?.absoluteString
            == "https://example.test/covers/SLUS-00530.jpg")
}

/// Both shipped templates have to name the same serial in the same place —
/// they differ only in folder and extension.
@Test func bothPresetsAreSerialKeyed() {
    #expect(CoverSource(template: CoverSource.flat).url(forSerial: "SCUS-94163")?
        .absoluteString.hasSuffix("/covers/default/SCUS-94163.jpg") == true)
    #expect(CoverSource(template: CoverSource.threeD).url(forSerial: "SCUS-94163")?
        .absoluteString.hasSuffix("/covers/3d/SCUS-94163.png") == true)
}

@Test func aDiscWithNoSerialIsSkippedRatherThanGuessedAt() async {
    let downloader = CoverDownloader(
        fetcher: FakeFetcher(available: ["SLUS-00530": pngData()]),
        source: CoverSource(template: "https://example.test/${serial}.jpg"))

    let (covers, summary) = await downloader.fetchCovers(
        for: [entry("/games/Mystery.cue", serial: nil)])

    #expect(covers.isEmpty)
    #expect(summary.skipped == 1)
    #expect(summary.downloaded == 0)
}

/// The collection covers about two thirds of the PS1 library, so "no cover for
/// this serial" is the ordinary case and must not read as a failure — the
/// summary the player sees would otherwise be alarming on every sweep.
@Test func aSerialTheCollectionLacksIsMissingNotFailed() async {
    let downloader = CoverDownloader(
        fetcher: FakeFetcher(available: [:]),
        source: CoverSource(template: "https://example.test/${serial}.jpg"))

    let (covers, summary) = await downloader.fetchCovers(
        for: [entry("/games/A.cue", serial: "SLUS-00001")])

    #expect(covers.isEmpty)
    #expect(summary.missing == 1)
    #expect(summary.failed == 0)
}

@Test func aFetchThatThrowsIsCountedAsAFailure() async {
    let downloader = CoverDownloader(
        fetcher: FakeFetcher(available: [:], failing: ["SLUS-00002"]),
        source: CoverSource(template: "https://example.test/${serial}.jpg"))

    let (_, summary) = await downloader.fetchCovers(
        for: [entry("/games/B.cue", serial: "SLUS-00002")])

    #expect(summary.failed == 1)
    #expect(summary.missing == 0)
}

/// The whole point of the concurrency window is that it does not lose or
/// duplicate work when there are more discs than slots.
@Test func everyDiscIsFetchedExactlyOnceAcrossTheConcurrencyWindow() async {
    let serials = (0..<25).map { String(format: "SLUS-%05d", $0) }
    let available = Dictionary(uniqueKeysWithValues: serials.map { ($0, pngData()) })
    let downloader = CoverDownloader(
        fetcher: FakeFetcher(available: available),
        source: CoverSource(template: "https://example.test/${serial}.jpg"))

    let entries = serials.map { entry("/games/\($0).cue", serial: $0) }
    let (covers, summary) = await downloader.fetchCovers(for: entries)

    #expect(summary.downloaded == 25)
    #expect(Set(covers.map { $0.entry.serial }) == Set(serials))
    #expect(covers.count == 25)
}

/// End to end through the store: a downloaded image lands under the SERIAL
/// key, which is the same place `coverURL(for:)` looks — the two halves were
/// built a session apart and have to agree.
@Test func aDownloadedCoverIsStoredUnderTheSerialKey() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("covers-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CoverStore(directory: directory)

    let disc = entry("/games/Croc/Croc.cue", serial: "SLUS-00530")
    let downloader = CoverDownloader(
        fetcher: FakeFetcher(available: ["SLUS-00530": pngData()]),
        source: CoverSource(template: "https://example.test/${serial}.jpg"))

    let (covers, _) = await downloader.fetchCovers(for: [disc])
    try store.setCover(from: #require(covers.first).data, for: disc)

    #expect(store.coverURL(for: disc)?.lastPathComponent == "SLUS-00530.png")
    // And it is found again from a different path, which is what keying on the
    // serial bought in the first place.
    #expect(store.coverURL(for: entry("/moved/whatever.cue", serial: "SLUS-00530")) != nil)
}

@Test func bytesThatAreNotAnImageAreRefusedRatherThanStored() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("covers-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CoverStore(directory: directory)

    #expect(throws: CoverError.undecodable) {
        try store.setCover(from: Data("404: Not Found".utf8),
                           for: entry("/games/C.cue", serial: "SLUS-00003"))
    }
}

@Test func theCoverSourceSettingRoundTripsAndDefaultsToTheJewelCase() {
    let defaults = UserDefaults(suiteName: "cover-source-\(UUID().uuidString)")!
    var setting = CoverSourceSetting(defaults: defaults)
    #expect(setting.source.template == CoverSource.flat)

    setting.set(CoverSource(template: CoverSource.threeD))
    #expect(CoverSourceSetting(defaults: defaults).source.template == CoverSource.threeD)
}
