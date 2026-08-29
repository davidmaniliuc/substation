import Foundation

/// An inclusive VRAM rectangle.
struct VramRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int

    func intersects(_ o: VramRect) -> Bool {
        x0 <= o.x1 && o.x0 <= x1 && y0 <= o.y1 && o.y0 <= y1
    }

    mutating func formUnion(_ o: VramRect) {
        x0 = min(x0, o.x0); y0 = min(y0, o.y0)
        x1 = max(x1, o.x1); y1 = max(y1, o.y1)
    }
}

/// Per-draw hazard detection with render-pass splitting.
///
/// PS1 VRAM is the render target and the texture source at once. The invariant
/// that makes that legal on a tile-based GPU is: NOTHING SAMPLED DURING A
/// RENDER PASS MAY HAVE BEEN WRITTEN DURING THAT PASS. The tile being rendered
/// lives in tile memory and the rest of the attachment stays in device memory
/// until the store action runs, so a read() sees the pre-pass contents — right
/// for a region an earlier PASS wrote, stale for one an earlier DRAW in this
/// pass wrote. This forbids the second case.
///
/// Programmable blending is unaffected: it reads the same pixel through tile
/// memory, which is a different mechanism from sampling an arbitrary address.
///
/// Ordering is preserved by construction and pathological content degrades
/// into many small passes rather than into wrong pixels. Do NOT weaken this to
/// buy speed — the pass count is reported, so the cost is visible.
struct HazardTracker {
    private var dirty: VramRect?

    mutating func reset() { dirty = nil }

    /// True when this draw must begin a new render pass. Resets the dirty rect
    /// when it returns true, because the new pass has written nothing yet.
    mutating func needsBreak(sampling rects: [VramRect]) -> Bool {
        guard let d = dirty, rects.contains(where: { $0.intersects(d) }) else { return false }
        dirty = nil
        return true
    }

    mutating func markWritten(_ rect: VramRect) {
        if dirty == nil { dirty = rect } else { dirty!.formUnion(rect) }
    }
}
