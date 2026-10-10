import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A screenshot is what is on screen: the display pass the window draws,
/// rendered once more into a texture of its own at the internal resolution,
/// in the 4:3 shape the player sees and with no letterbox. Saved as a PNG in
/// `~/Pictures/Substation/`.
enum Screenshot {
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    /// The displayed lines at the internal scale, and the width that makes
    /// it 4:3, the shape the window shows whatever the horizontal resolution.
    /// A display that is off, or shows no lines, is a black VGA frame.
    static func size(displayHeight: Int, scale: Int, enabled: Bool) -> Size {
        guard enabled, displayHeight > 0 else { return Size(width: 640, height: 480) }
        let height = displayHeight * scale
        return Size(width: Int((Double(height) * 4 / 3).rounded()), height: height)
    }

    /// "Crash Warped 2026-10-10 at 14.03.22.png": the title made safe for a
    /// filename (no `/`, no `:`, which Finder shows as `/`), then the moment.
    static func fileName(title: String, at date: Date) -> String {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(safe.isEmpty ? "Substation" : safe) \(format.string(from: date)).png"
    }

    static var folder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures")
        return pictures.appending(path: "Substation", directoryHint: .isDirectory)
    }

    /// Writes into `folder`, creating it on demand. Two shots in the same
    /// second get " 2", " 3" rather than one replacing the other.
    static func write(_ png: Data, title: String, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName(title: title, at: date)
        var url = folder.appending(path: name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: name.replacingOccurrences(of: ".png", with: " \(n).png"))
            n += 1
        }
        try png.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Encodes the display pass into a new texture of `size`, with the
    /// letterbox at (1, 1). The caller commits `cmd` and reads the texture
    /// with `bytes(of:)` once it has completed.
    static func encode(into cmd: MTLCommandBuffer, pipeline: MTLRenderPipelineState,
                       vram: MTLTexture, shadow: MTLTexture, sidecar: MTLTexture,
                       params: DisplayParams, size: Size) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        guard let target = cmd.device.makeTexture(descriptor: desc) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        var p = params
        p.scaleX = 1
        p.scaleY = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(vram, index: 0)
        enc.setFragmentTexture(shadow, index: 1)
        enc.setFragmentTexture(sidecar, index: 2)
        enc.setVertexBytes(&p, length: MemoryLayout<DisplayParams>.stride, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<DisplayParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: target)
        blit.endEncoding()
        return target
    }

    /// A completed `encode` target's BGRA bytes, top row first.
    static func bytes(of texture: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return out
    }

    /// An sRGB PNG of BGRA bytes, as `.bgra8Unorm` lays them out.
    static func png(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                         | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
