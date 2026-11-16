import AppKit
import Foundation
import Testing
@testable import PS1

private func png(side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@MainActor @Test func aFileReplacedInPlaceIsReadAgain() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    try png(side: 4).write(to: url)
    let first = try #require(ImageCache.image(at: url))
    #expect(ImageCache.image(at: url) === first)

    try png(side: 8).write(to: url)
    // A date of its own: two writes can land on one timestamp.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
                                          ofItemAtPath: url.path)
    let second = try #require(ImageCache.image(at: url))
    #expect(second !== first)
    #expect(second.representations.first?.pixelsWide == 8)
}

@MainActor @Test func aFileThatIsGoneReadsAsNothing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try png(side: 4).write(to: url)
    #expect(ImageCache.image(at: url) != nil)
    try FileManager.default.removeItem(at: url)
    #expect(ImageCache.image(at: url) == nil)
}
