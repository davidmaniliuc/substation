import Testing
import Foundation
import AppKit
@testable import PS1

private func makeStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("covers-\(UUID().uuidString)")
}

/// A real, decodable image on disk — `setCover` re-encodes through NSImage, so
/// a file of random bytes would (correctly) be rejected.
///
/// Colours pixels directly on the `NSBitmapImageRep` rather than drawing
/// through `NSGraphicsContext.current`: that property is process-global, and
/// Swift Testing runs this suite's tests concurrently, so two tests setting
/// and restoring it at once could interleave and corrupt each other's pixels.
private func writeTestImage(_ colour: NSColor, size: Int = 8) throws -> URL {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Written through bitmapData rather than setColor(_:atX:y:): setColor
    // routes through AppKit's colour-conversion machinery, which logged a
    // spurious "Unrecognized colorspace" warning for these NSColor literals
    // even after converting to deviceRGB. Raw bytes sidestep it entirely.
    let deviceColour = colour.usingColorSpace(.deviceRGB) ?? colour
    let component = { (c: CGFloat) in UInt8((c * 255).rounded()) }
    let r = component(deviceColour.redComponent)
    let g = component(deviceColour.greenComponent)
    let b = component(deviceColour.blueComponent)
    let a = component(deviceColour.alphaComponent)
    let pixels = rep.bitmapData!
    let bytesPerRow = rep.bytesPerRow
    for y in 0..<size {
        for x in 0..<size {
            let offset = y * bytesPerRow + x * 4
            pixels[offset] = r
            pixels[offset + 1] = g
            pixels[offset + 2] = b
            pixels[offset + 3] = a
        }
    }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cover-source-\(UUID().uuidString).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

private func makeEntry(_ path: String) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), isCue: true)
}

@Test func coverStoreHasNoCoverBeforeOneIsSet() {
    let store = CoverStore(directory: makeStoreDirectory())
    #expect(store.coverURL(for: makeEntry("/games/Croc/Croc.cue")) == nil)
}

@Test func coverStoreReadsBackWhatItWasGiven() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: entry)

    let cover = try #require(store.coverURL(for: entry))
    #expect(FileManager.default.fileExists(atPath: cover.path))
    #expect(NSImage(contentsOf: cover) != nil)
}

/// The cover must be a COPY: the library cannot break because the user moved
/// the image they picked out of their Downloads folder.
@Test func coverStoreSurvivesTheSourceImageBeingDeleted() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.blue)

    try store.setCover(from: source, for: entry)
    try FileManager.default.removeItem(at: source)

    #expect(store.coverURL(for: entry) != nil)
}

/// Both sizes are well under `CoverStore`'s downscale bound (540x720), so
/// this pins the replace behaviour itself rather than the clamp exercised by
/// `coverStoreDownscalesALargeSourceImage` below.
@Test func coverStoreReplacesAnExistingCover() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let first = try writeTestImage(.red, size: 8)
    let second = try writeTestImage(.green, size: 16)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    try store.setCover(from: first, for: entry)
    try store.setCover(from: second, for: entry)

    let cover = try #require(store.coverURL(for: entry))
    let image = try #require(NSImage(contentsOf: cover))
    #expect(image.size.width == 16)
}

/// `setCover` re-encodes at a fixed bound so a huge cover is decoded once, at
/// store time, rather than at full resolution on every `GameTile` body
/// evaluation. A source well past the bound must come back capped, not
/// full-resolution, and still in proportion (the source here is square, so
/// the stored image must be too).
@Test func coverStoreDownscalesALargeSourceImage() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.red, size: 2000)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: entry)

    let cover = try #require(store.coverURL(for: entry))
    let image = try #require(NSImage(contentsOf: cover))
    #expect(image.size.width < 2000)
    #expect(image.size.width <= 540)
    #expect(image.size.height <= 720)
    #expect(image.size.width == image.size.height)
}

@Test func coverStoreRemovesACover() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let entry = makeEntry("/games/Croc/Croc.cue")
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: entry)
    try store.removeCover(for: entry)

    #expect(store.coverURL(for: entry) == nil)
}

@Test func coverStoreRemoveIsHarmlessWhenThereIsNoCover() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    try store.removeCover(for: makeEntry("/games/Croc/Croc.cue"))
}

/// The key is derived from the path, so a rescan — which rebuilds every
/// GameEntry from scratch — finds the same cover again.
@Test func coverStoreKeepsTheCoverAcrossAFreshlyBuiltEntry() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: makeEntry("/games/Croc/Croc.cue"))

    let rescanned = makeEntry("/games/Croc/Croc.cue")
    #expect(store.coverURL(for: rescanned) != nil)
}

@Test func coverStoreKeepsTwoGamesApart() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let source = try writeTestImage(.red)
    defer { try? FileManager.default.removeItem(at: source) }

    try store.setCover(from: source, for: makeEntry("/games/Croc/Croc.cue"))

    #expect(store.coverURL(for: makeEntry("/games/Spyro/Spyro.cue")) == nil)
}

@Test func coverStoreRejectsAFileThatIsNotAnImage() throws {
    let dir = makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CoverStore(directory: dir)
    let junk = FileManager.default.temporaryDirectory
        .appendingPathComponent("junk-\(UUID().uuidString).png")
    try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: junk)
    defer { try? FileManager.default.removeItem(at: junk) }

    #expect(throws: CoverError.undecodable) {
        try store.setCover(from: junk, for: makeEntry("/games/Croc/Croc.cue"))
    }
}
