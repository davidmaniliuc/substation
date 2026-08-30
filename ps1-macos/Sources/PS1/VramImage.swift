import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ABGR1555 -> PNG, for the one Phase C gate a machine cannot run: seams along
/// quad diagonals, texture bleeding, and gaps between adjacent primitives are
/// all things you see in an image and none of them move a hash.
///
/// A sibling of `VramDump`, not a replacement: a `.vram` blob is the exact
/// bytes and is what a diff is taken against; a PNG is lossy about the mask bit
/// and is for looking at.
enum VramImage {
    /// Sits next to the fixtures, which are already build artifacts.
    static func url(fixture: String, frame: Int, scale: Int) -> URL {
        FixtureFile.repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(fixture)-frame\(frame)-\(scale)x.png")
    }

    /// Bit 15 (mask/STP) is DROPPED, not rendered as alpha: an image whose
    /// alpha varied with the mask bit would show masked regions as holes and
    /// invite exactly the wrong conclusion about a picture that is correct.
    static func write(_ pixels: [UInt16], width: Int, height: Int, to url: URL) -> Bool {
        precondition(pixels.count == width * height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let p = pixels[i]
            let r = Int(p & 0x1F), g = Int((p >> 5) & 0x1F), b = Int((p >> 10) & 0x1F)
            // 5 -> 8 bits by replicating the high bits, so 31 maps to 255.
            // A plain << 3 tops out at 248 and darkens every dump.
            rgba[i * 4 + 0] = UInt8((r << 3) | (r >> 2))
            rgba[i * 4 + 1] = UInt8((g << 3) | (g >> 2))
            rgba[i * 4 + 2] = UInt8((b << 3) | (b >> 2))
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
