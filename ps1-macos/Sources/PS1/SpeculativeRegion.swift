import Foundation
import CPs1

/// The native VRAM rectangle a speculative group may write: what
/// `LiveRenderer` saves before replaying the group for display and puts back
/// at the next drain.
///
/// A bound, not an exact footprint. A primitive is bounded by the drawing
/// area it is clipped to, followed through the group's own environment
/// records; a fill, an upload, a copy and a depth clear by their explicit
/// rectangle, and one that wraps an axis takes the whole axis. Too large
/// only costs a bigger blit; too small would leave the speculative picture
/// in the real timeline's VRAM, so anything unrecognised takes all of it.
enum SpeculativeRegion {
    static let full = VramRect(x0: 0, y0: 0,
                               x1: MetalVram.nativeWidth - 1, y1: MetalVram.nativeHeight - 1)

    /// `env` and `transfer` are the rasterizer's as the group starts: an
    /// upload the real frame began can be finished by the group.
    static func of<S: Sequence>(_ frames: S, env start: DrawEnv,
                                transfer: VramTransfer) -> VramRect? where S.Element == StreamSlot {
        var env = start
        var region: VramRect?
        func add(_ r: VramRect?) {
            guard let r else { return }
            if region == nil { region = r } else { region!.formUnion(r) }
        }
        if transfer.active { add(wrapped(x: transfer.x, y: transfer.y, w: transfer.w, h: transfer.h)) }

        for slot in frames {
            for i in 0..<slot.recordCount {
                let cmd = slot.records[i]
                switch cmd.commandKind {
                case PS1_GPU_SET_DRAW_ENV, PS1_GPU_LATCH_TEXPAGE,
                     PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED, PS1_GPU_RESET_DRAW_ENV:
                    env.apply(cmd)
                case PS1_GPU_DRAW_TRIANGLE, PS1_GPU_DRAW_SHADED_TRIANGLE,
                     PS1_GPU_DRAW_TEXTURED_TRIANGLE, PS1_GPU_DRAW_RECTANGLE,
                     PS1_GPU_DRAW_TEXTURED_RECTANGLE, PS1_GPU_DRAW_LINE,
                     PS1_GPU_DRAW_SHADED_LINE:
                    let c = env.clip
                    add(clamped(x0: c.x0, y0: c.y0, x1: c.x1, y1: c.y1))
                case PS1_GPU_FILL_RECT, PS1_GPU_CLEAR_DEPTH:
                    let x = Int(cmd.x), y = Int(cmd.y)
                    add(clamped(x0: x, y0: y, x1: x + Int(cmd.w) - 1, y1: y + Int(cmd.h) - 1))
                case PS1_GPU_COPY_RECT:
                    add(wrapped(x: Int(cmd.x2), y: Int(cmd.y2), w: Int(cmd.w), h: Int(cmd.h)))
                case PS1_GPU_VRAM_WRITE_SETUP:
                    add(wrapped(x: Int(cmd.x), y: Int(cmd.y), w: Int(cmd.w), h: Int(cmd.h)))
                case PS1_GPU_VRAM_WRITE_DATA, PS1_GPU_VRAM_WRITE_ABORT, PS1_GPU_VRAM_READ_SETUP:
                    break
                default:
                    return full
                }
            }
        }
        return region
    }

    private static func clamped(x0: Int, y0: Int, x1: Int, y1: Int) -> VramRect? {
        let r = VramRect(x0: max(x0, 0), y0: max(y0, 0),
                         x1: min(x1, full.x1), y1: min(y1, full.y1))
        return r.x0 <= r.x1 && r.y0 <= r.y1 ? r : nil
    }

    /// A transfer-style rectangle: the origin wraps, a size of 0 is the
    /// whole axis, and one that crosses an edge takes the whole axis.
    private static func wrapped(x: Int, y: Int, w: Int, h: Int) -> VramRect {
        let (x0, x1) = axis(x & 0x3FF, VramTransfer.axisExtent(w & 0x7FF, MetalVram.nativeWidth),
                            MetalVram.nativeWidth)
        let (y0, y1) = axis(y & 0x1FF, VramTransfer.axisExtent(h & 0x3FF, MetalVram.nativeHeight),
                            MetalVram.nativeHeight)
        return VramRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    private static func axis(_ origin: Int, _ extent: Int, _ size: Int) -> (Int, Int) {
        origin + extent > size ? (0, size - 1) : (origin, origin + extent - 1)
    }
}
