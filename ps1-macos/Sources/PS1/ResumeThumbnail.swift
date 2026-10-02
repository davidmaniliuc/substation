import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The picture on the resume prompt, taken from CORE VRAM at the instant of
/// the save so it shows exactly the saved frame.
///
/// Never from the Metal drawable: that may be upscaled, a frame later, or
/// under the HUD. The display area is cropped and decoded here the way
/// `DisplayShader.metal` scans it out (15 bpp, or 24 bpp packed three bytes
/// per pixel across 16-bit words) with the same `c << 3 | c >> 2` expansion,
/// then drawn at 4:3 whatever the display's pixel size, which is how the game
/// is shown.
enum ResumeThumbnail {
    static let size = CGSize(width: 320, height: 240)
    private static let vramWidth = 1024
    private static let vramHeight = 512

    static func png(vram: UnsafeBufferPointer<UInt16>, display d: Ps1Display) -> Data? {
        let w = Int(d.width), h = Int(d.height)
        guard d.enabled != 0, w > 0, h > 0,
              vram.count == vramWidth * vramHeight else { return nil }

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let row = ((Int(d.vram_y) + y) & (vramHeight - 1)) * vramWidth
            for x in 0..<w {
                let o = (y * w + x) * 4
                if d.depth24 != 0 {
                    // Byte k of the row lives in halfword (vram_x + k/2), low byte first.
                    func byte(_ k: Int) -> UInt8 {
                        let word = vram[row + ((Int(d.vram_x) + k / 2) & (vramWidth - 1))]
                        return UInt8(truncatingIfNeeded: k % 2 == 0 ? word : word >> 8)
                    }
                    rgba[o] = byte(x * 3)
                    rgba[o + 1] = byte(x * 3 + 1)
                    rgba[o + 2] = byte(x * 3 + 2)
                } else {
                    let p = vram[row + ((Int(d.vram_x) + x) & (vramWidth - 1))]
                    rgba[o] = expand(p & 0x1F)
                    rgba[o + 1] = expand((p >> 5) & 0x1F)
                    rgba[o + 2] = expand((p >> 10) & 0x1F)
                }
            }
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let source = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// 5 -> 8 bits by replicating the high bits, so 31 maps to 255: the one
    /// expansion every display path in the app uses.
    private static func expand(_ c: UInt16) -> UInt8 {
        UInt8((c << 3) | (c >> 2))
    }
}
