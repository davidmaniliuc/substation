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
/// The rule is SYMMETRIC, and the second half is easy to miss. A read during
/// a pass resolves against device memory, which a write during that same pass
/// updates only when its tile is stored — so a draw that WRITES what an
/// earlier draw in this pass SAMPLED is just as unordered as the reverse.
/// Whether the reader sees the old contents or the new one depends on the
/// order two different tiles happen to be rendered in, which is why it
/// presents as a race rather than as a consistently wrong pixel: frame 6 of
/// `synthetic-primitives` hashed three different ways across three runs of the
/// same binary once a shader edit perturbed scheduling, and hashed correctly
/// and stably before it. Tracking only read-after-write left that latent.
///
/// Ordering is preserved by construction and pathological content degrades
/// into many small passes rather than into wrong pixels. Do NOT weaken this to
/// buy speed — the pass count is reported, so the cost is visible.
struct HazardTracker {
    private var dirty: VramRect?
    /// A LIST, not the union `dirty` keeps, and the difference is worth 50x.
    /// A sampled rect is a whole 256-row texture page, so unioning two pages
    /// that sit apart covers most of VRAM and then nearly every subsequent
    /// write intersects it: measured over `silent-hill-usa`, the union form
    /// costs 13,767 passes across 100 frames where the list form costs 266
    /// against a 244 baseline. Read rects are few — one page plus at most a
    /// CLUT row per textured draw, deduplicated — so the linear scan is
    /// cheaper than the passes it saves.
    private var reads: [VramRect] = []

    mutating func reset() { dirty = nil; reads.removeAll(keepingCapacity: true) }

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

    /// True when this draw must begin a new render pass because it WRITES a
    /// region an earlier draw in this pass SAMPLED. The mirror of
    /// `needsBreak(sampling:)`, and needed for the same reason.
    mutating func needsBreak(writing box: VramRect) -> Bool {
        guard reads.contains(where: { box.intersects($0) }) else { return false }
        reads.removeAll(keepingCapacity: true)
        return true
    }

    /// Deduplicated: a run of triangles off one texture page reports the same
    /// page rect every time, and a list that grew per primitive would turn the
    /// scan above into the hot loop.
    mutating func markRead(_ rects: [VramRect]) {
        for rect in rects where !reads.contains(rect) { reads.append(rect) }
    }
}
