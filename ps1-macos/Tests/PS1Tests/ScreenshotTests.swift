import Testing
import ImageIO
import Metal
import Foundation
@testable import PS1

/// A screenshot is what is on screen: the picture at the internal
/// resolution, in the 4:3 shape the player sees, with no letterbox.
@Suite struct ScreenshotTests {
    @Test func theHeightIsTheDisplayedLinesAtTheScale() {
        #expect(Screenshot.size(displayHeight: 240, scale: 4, enabled: true) == .init(width: 1280, height: 960))
        #expect(Screenshot.size(displayHeight: 480, scale: 2, enabled: true) == .init(width: 1280, height: 960))
        #expect(Screenshot.size(displayHeight: 224, scale: 3, enabled: true) == .init(width: 896, height: 672))
    }

    @Test func aDisabledDisplayIsAPlainBlackFrame() {
        #expect(Screenshot.size(displayHeight: 0, scale: 4, enabled: false) == .init(width: 640, height: 480))
        #expect(Screenshot.size(displayHeight: 0, scale: 4, enabled: true) == .init(width: 640, height: 480))
    }

    @Test func theFileIsNamedForTheGameAndTheMoment() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 10
        parts.hour = 14; parts.minute = 3; parts.second = 22
        let date = Calendar.current.date(from: parts)!
        #expect(Screenshot.fileName(title: "Crash: Warped", at: date)
                == "Crash Warped 2026-10-10 at 14.03.22.png")
        #expect(Screenshot.fileName(title: "AC/DC", at: date) == "AC-DC 2026-10-10 at 14.03.22.png")
    }

    @Test func aPngRoundTripsItsPixels() throws {
        // BGRA: pure red, opaque.
        let bytes: [UInt8] = Array(repeating: [0, 0, 255, 255], count: 4).flatMap { $0 }
        let data = try #require(bytes.withUnsafeBytes {
            Screenshot.png(bgra: $0, width: 2, height: 2, bytesPerRow: 8)
        })
        // Decoded with ImageIO and read straight off its provider:
        // `NSBitmapImageRep` colour-matches on load, which would measure the
        // conversion, not the file.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2 && image.height == 2)
        let px = try #require(image.dataProvider?.data as Data?)
        let o = image.bytesPerRow + image.bitsPerPixel / 8      // pixel (1, 1)
        #expect((px[o], px[o + 1], px[o + 2]) == (255, 0, 0))
    }

    @Test func theOffscreenPassDrawsThePicture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try Shaders.makeLibrary(device)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "display_vertex")
        desc.fragmentFunction = library.makeFunction(name: "display_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let vram = try #require(texture(device, .r16Uint, bytesPerPixel: 2, fill: 0x7FFF))
        let shadow = try #require(texture(device, .r16Uint, bytesPerPixel: 2, fill: 0))
        let sidecar = try #require(texture(device, .rgba8Uint, bytesPerPixel: 4, fill: 0))
        var params = DisplayParams()
        params.width = 320
        params.height = 240
        params.enabled = 1
        params.scale = 1
        // A letterbox the screenshot must ignore.
        params.scaleX = 0.5
        params.scaleY = 0.5

        let cmd = try #require(queue.makeCommandBuffer())
        let target = try #require(Screenshot.encode(
            into: cmd, pipeline: pipeline, vram: vram, shadow: shadow, sidecar: sidecar,
            params: params, size: .init(width: 320, height: 240)))
        cmd.commit()
        cmd.waitUntilCompleted()

        let bgra = Screenshot.bytes(of: target)
        #expect(bgra.count == 320 * 240 * 4)
        for (x, y) in [(1, 1), (160, 120), (318, 238)] {
            let o = (y * 320 + x) * 4
            #expect(bgra[o + 2] > 200, "pixel \(x),\(y) is not the white picture")
        }
    }

    private func texture(_ device: MTLDevice, _ format: MTLPixelFormat,
                         bytesPerPixel: Int, fill: UInt16) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 1024, height: 512, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var words = [UInt16](repeating: fill, count: 1024 * 512 * bytesPerPixel / 2)
        words.withUnsafeMutableBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: 1024 * bytesPerPixel)
        }
        return tex
    }
}

/// The request crosses from the main actor to whichever display view draws
/// the runner's next frame, and is taken exactly once.
@Suite struct ScreenshotRequestTests {
    @Test func aRequestIsTakenOnce() throws {
        let core = try Ps1Core()
        let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                    cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("shot-cards-\(UUID().uuidString)")))
        #expect(runner.takeScreenshotRequests().isEmpty)
        runner.requestScreenshot { _ in }
        runner.requestScreenshot { _ in }
        #expect(runner.takeScreenshotRequests().count == 2)
        #expect(runner.takeScreenshotRequests().isEmpty)
    }
}
