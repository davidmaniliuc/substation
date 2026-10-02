import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PS1

private let vramWidth = 1024
private let vramHeight = 512

/// Decodes the PNG and returns the RGB of one pixel.
private func pixel(_ png: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let ctx = CGContext(data: &buf, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let i = ((image.height - 1 - y) * image.width + x) * 4
    return (buf[i], buf[i + 1], buf[i + 2])
}

private func display(x: UInt32, y: UInt32, w: UInt32, h: UInt32, depth24: Bool) -> Ps1Display {
    var d = Ps1Display()
    d.vram_x = x; d.vram_y = y; d.width = w; d.height = h
    d.depth24 = depth24 ? 1 : 0
    d.enabled = 1
    return d
}

@Test func a15bppDisplayIsCroppedAndExpanded() throws {
    // Blue everywhere, pure red inside the 320x240 display area at (64, 32).
    var vram = [UInt16](repeating: 0x1F << 10, count: vramWidth * vramHeight)
    for y in 32..<(32 + 240) { for x in 64..<(64 + 320) { vram[y * vramWidth + x] = 0x1F } }
    let png = try #require(vram.withUnsafeBufferPointer {
        ResumeThumbnail.png(vram: $0, display: display(x: 64, y: 32, w: 320, h: 240, depth24: false))
    })
    let p = try #require(pixel(png, x: 160, y: 120))
    #expect(p.r == 255 && p.g == 0 && p.b == 0)
    let corner = try #require(pixel(png, x: 2, y: 2))
    #expect(corner.b < 32) // the blue outside the crop never reaches the picture
}

@Test func a24bppDisplayIsUnpackedAcrossWords() throws {
    // R=10, G=200, B=30 packed three bytes per pixel across 16-bit words.
    var vram = [UInt16](repeating: 0, count: vramWidth * vramHeight)
    let rgb: [UInt8] = [10, 200, 30]
    for y in 0..<240 {
        for byte in 0..<(320 * 3) {
            let word = y * vramWidth + byte / 2
            let value = UInt16(rgb[byte % 3])
            vram[word] |= byte % 2 == 0 ? value : value << 8
        }
    }
    let png = try #require(vram.withUnsafeBufferPointer {
        ResumeThumbnail.png(vram: $0, display: display(x: 0, y: 0, w: 320, h: 240, depth24: true))
    })
    let p = try #require(pixel(png, x: 160, y: 120))
    #expect(p.r == 10 && p.g == 200 && p.b == 30)
    let odd = try #require(pixel(png, x: 161, y: 120))
    #expect(odd.r == 10 && odd.g == 200 && odd.b == 30)
}

@Test func theThumbnailIsAlways320By240() throws {
    let vram = [UInt16](repeating: 0x7FFF, count: vramWidth * vramHeight)
    let png = try #require(vram.withUnsafeBufferPointer {
        ResumeThumbnail.png(vram: $0, display: display(x: 0, y: 0, w: 640, h: 480, depth24: false))
    })
    let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(image.width == 320 && image.height == 240)
}

@Test func aDisabledDisplayHasNoThumbnail() {
    let vram = [UInt16](repeating: 0, count: vramWidth * vramHeight)
    var d = display(x: 0, y: 0, w: 320, h: 240, depth24: false)
    d.enabled = 0
    #expect(vram.withUnsafeBufferPointer { ResumeThumbnail.png(vram: $0, display: d) } == nil)
}
