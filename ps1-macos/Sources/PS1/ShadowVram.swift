import Foundation
import CPs1

/// A 1024x512 VRAM plus the GP0 commands that move memory around inside it:
/// Fill Rectangle, VRAM->VRAM copy, and the CPU->VRAM transfer FSM.
///
/// This mirrors ps1-core/src/gpu/vram.zig:51-198 and is a SECOND TRANSCRIPTION,
/// accepted knowingly and bounded deliberately: it duplicates the memory movers
/// only, never the rasterizer. Reproducing a rasterized frame in Swift is Phase
/// B's job, and writing a second rasterizer is exactly what Phase A's one-
/// interpreter design was built to prevent.
///
/// It is also not scaffolding — these are Phase B's 02/80/A0 passes, written a
/// phase early with a hash gate on them.
struct ShadowVram {
    static let width = 1024
    static let height = 512

    var data = [UInt16](repeating: 0, count: ShadowVram.width * ShadowVram.height)

    /// GP0(E6) bit 0: OR bit 15 into every pixel written.
    var maskSet = false
    /// GP0(E6) bit 1: skip pixels whose existing bit 15 is set.
    var maskCheck = false

    // CPU -> VRAM transfer state
    private var writeActive = false
    private var writeX = 0, writeY = 0, writeW = 0, writeH = 0
    private var currX = 0, currY = 0
    private var remaining = 0

    var hash: UInt64 { Fnv1a.hash(vram: data) }

    private static func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    /// A width or height of 0 means the WHOLE AXIS, not an empty rectangle.
    private static func axisExtent(_ size: Int, _ full: Int) -> Int {
        size == 0 ? full : size
    }

    private mutating func maskedWrite(_ x: Int, _ y: Int, _ value: UInt16) {
        let i = Self.index(x, y)
        if maskCheck && (data[i] & 0x8000) != 0 { return }
        data[i] = value | (maskSet ? 0x8000 : 0)
    }

    mutating func apply(_ cmd: Ps1GpuCommand, payload: UnsafeBufferPointer<UInt32>) {
        switch cmd.commandKind {
        case PS1_GPU_SET_DRAW_ENV:
            // Only E6 moves the mask bits; the rest of the drawing environment
            // is rasterizer state this shadow does not model.
            if cmd.opcode == 0xE6 {
                maskSet = (cmd.value & 1) != 0
                maskCheck = (cmd.value & 2) != 0
            }

        case PS1_GPU_RESET_DRAW_ENV:
            maskSet = false
            maskCheck = false

        case PS1_GPU_FILL_RECT:
            fill(Int(cmd.x), Int(cmd.y), Int(cmd.w), Int(cmd.h), UInt16(truncatingIfNeeded: cmd.value))

        case PS1_GPU_COPY_RECT:
            copy(Int(cmd.x), Int(cmd.y), Int(cmd.x2), Int(cmd.y2), Int(cmd.w), Int(cmd.h))

        case PS1_GPU_VRAM_WRITE_SETUP:
            setupWrite(Int(cmd.x), Int(cmd.y), Int(cmd.w), Int(cmd.h))

        case PS1_GPU_VRAM_WRITE_DATA:
            let off = Int(cmd.x), len = Int(cmd.y)
            for k in off..<(off + len) { writeData(payload[k]) }

        case PS1_GPU_VRAM_WRITE_ABORT:
            writeActive = false

        default:
            // Rasterizing and read-setup records are not modelled. A fixture
            // containing them cannot be hash-checked here, which is why only
            // the synthetic one is.
            break
        }
    }

    /// GP0(02). DELIBERATELY unmasked — hardware ignores GP0(E6) for fills, and
    /// this is the only VRAM write in the core that does. It also CLIPS rather
    /// than wrapping, unlike copy.
    private mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt16) {
        guard h > 0, w > 0 else { return }
        for yy in 0..<h {
            for xx in 0..<w {
                let px = x + xx, py = y + yy
                if px >= 0 && px < Self.width && py >= 0 && py < Self.height {
                    data[Self.index(px, py)] = color
                }
            }
        }
    }

    /// GP0(80). Masked, and WRAPS on both axes rather than clipping. The
    /// direction matters when source and destination overlap.
    private mutating func copy(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int, _ w: Int, _ h: Int) {
        let width = Self.axisExtent(w, Self.width)
        let height = Self.axisExtent(h, Self.height)
        let backwards = (dy > sy) || (dy == sy && dx > sx)

        let ys = backwards ? Array((0..<height).reversed()) : Array(0..<height)
        let xs = backwards ? Array((0..<width).reversed()) : Array(0..<width)

        for yy in ys {
            for xx in xs {
                let srcX = (sx + xx) & 0x3FF, srcY = (sy + yy) & 0x1FF
                let dstX = (dx + xx) & 0x3FF, dstY = (dy + yy) & 0x1FF
                maskedWrite(dstX, dstY, data[Self.index(srcX, srcY)])
            }
        }
    }

    private mutating func setupWrite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        writeW = Self.axisExtent(w, Self.width)
        writeH = Self.axisExtent(h, Self.height)
        writeX = x
        writeY = y
        currX = 0
        currY = 0
        remaining = (writeW * writeH + 1) / 2
        writeActive = remaining > 0
    }

    private mutating func writePixel(_ pix: UInt16) {
        let px = writeX + currX, py = writeY + currY
        // The Zig source (vram.zig) only checks the upper bound because its
        // coordinates are usize and can't go negative. Swift's are Int, so a
        // negative writeX/writeY (an out-of-range VRAM_WRITE_SETUP) needs an
        // explicit lower-bound guard the Zig side gets for free from its type.
        if px >= 0 && px < Self.width && py >= 0 && py < Self.height {
            maskedWrite(px, py, pix)
        }
        currX += 1
        if currX >= writeW {
            currX = 0
            currY += 1
        }
    }

    /// One 32-bit word is two pixels. The second is dropped when it would fall
    /// past the end of an odd-sized transfer.
    private mutating func writeData(_ value: UInt32) {
        guard writeActive else { return }
        writePixel(UInt16(truncatingIfNeeded: value))
        if (currY * writeW + currX) < (writeW * writeH) {
            writePixel(UInt16(truncatingIfNeeded: value >> 16))
        }
        if remaining > 0 { remaining -= 1 }
        if remaining == 0 { writeActive = false }
    }
}
