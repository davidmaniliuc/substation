import Foundation

/// The Bresenham walk from `renderer.zig:286-313`, transcribed.
///
/// No GPU triangle setup reproduces an error accumulator, and no closed form
/// for the step->coordinate mapping is worth deriving and proving. So the CPU
/// walks the same loop and the GPU gets one 1x1 instance per step — at most
/// 1024 of them, since an oversized line is dropped outright.
///
/// Coordinates arriving here must ALREADY have GP0(E5)'s offset applied: the
/// oversized check in the Zig source is on the offset-applied deltas.
enum LineExpander {
    struct Step {
        let x: Int
        let y: Int
        /// The step index. `drawShadedLine`'s channel at step k is
        /// `c0 + floor((c1 - c0) * k / steps)` — evaluable from k alone rather
        /// than from an accumulator, which is exactly what Phase 0 rewrote
        /// that function into so a shader could do it.
        let k: Int
    }

    /// Returns nil for a line the hardware refuses to draw at all.
    static func walk(x0: Int, y0: Int, x1: Int, y1: Int) -> (steps: [Step], total: Int)? {
        let dx = abs(x1 - x0), dy = abs(y1 - y0)
        guard dx < 1024, dy < 512 else { return nil }

        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx - dy
        var cx = x0, cy = y0
        var k = 0
        var out: [Step] = []
        out.reserveCapacity(max(dx, dy) + 1)

        while true {
            out.append(Step(x: cx, y: cy, k: k))
            if cx == x1 && cy == y1 { break }
            let e2 = 2 * err
            if e2 > -dy { err -= dy; cx += sx }
            if e2 < dx { err += dx; cy += sy }
            k += 1
        }
        return (out, max(dx, dy))
    }
}
