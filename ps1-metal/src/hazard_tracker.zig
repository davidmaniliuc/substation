//! Per-draw hazard detection with render-pass splitting.
//!
//! PS1 VRAM is the render target and the texture source at once. The
//! invariant that makes that legal on a tile-based GPU is: NOTHING SAMPLED
//! DURING A RENDER PASS MAY HAVE BEEN WRITTEN DURING THAT PASS. The tile being
//! rendered lives in tile memory and the rest of the attachment stays in
//! device memory until the store action runs, so a read() sees the pre-pass
//! contents: right for a region an earlier PASS wrote, stale for one an
//! earlier DRAW in this pass wrote. This forbids the second case.
//!
//! Programmable blending is unaffected: it reads the same pixel through tile
//! memory, which is a different mechanism from sampling an arbitrary address.
//!
//! The rule is SYMMETRIC, and the second half is easy to miss. A read during
//! a pass resolves against device memory, which a write during that same pass
//! updates only when its tile is stored, so a draw that WRITES what an
//! earlier draw in this pass SAMPLED is just as unordered as the reverse.
//! Whether the reader sees the old contents or the new one depends on the
//! order two different tiles happen to be rendered in, which is why it
//! presents as a race rather than as a consistently wrong pixel. Tracking
//! only read-after-write left that latent.
//!
//! Ordering is preserved by construction and pathological content degrades
//! into many small passes rather than into wrong pixels. Do NOT weaken this
//! to buy speed: the pass count is reported, so the cost is visible.

const std = @import("std");
const VramRect = @import("prim_instance.zig").VramRect;

pub const HazardTracker = struct {
    alloc: std.mem.Allocator,
    dirty: ?VramRect = null,
    /// A LIST, not the union `dirty` keeps, and the difference is worth 50x.
    /// A sampled rect is a whole 256-row texture page, so unioning two pages
    /// that sit apart covers most of VRAM and then nearly every subsequent
    /// write intersects it: measured over `silent-hill-usa`, the union form
    /// costs 13,767 passes across 100 frames where the list form costs 266
    /// against a 244 baseline. Read rects are few (one page plus at most a
    /// CLUT row per textured draw, deduplicated), so the linear scan is
    /// cheaper than the passes it saves.
    reads: std.ArrayList(VramRect) = .empty,

    pub fn init(alloc: std.mem.Allocator) HazardTracker {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *HazardTracker) void {
        self.reads.deinit(self.alloc);
    }

    pub fn reset(self: *HazardTracker) void {
        self.dirty = null;
        self.reads.clearRetainingCapacity();
    }

    /// True when this draw must begin a new render pass because it SAMPLES a
    /// region an earlier draw in this pass wrote.
    ///
    /// A pure predicate: the pass break calls `reset()`, and that is the only
    /// thing that clears this state. With two predicates, self-clearing would
    /// leave the OTHER half populated with the previous pass's rects whenever
    /// the `or` short-circuits.
    pub fn needsBreakSampling(self: *const HazardTracker, rects: []const VramRect) bool {
        const d = self.dirty orelse return false;
        for (rects) |r| if (r.intersects(d)) return true;
        return false;
    }

    pub fn markWritten(self: *HazardTracker, box: VramRect) void {
        self.dirty = if (self.dirty) |d| d.unionWith(box) else box;
    }

    /// True when this draw must begin a new render pass because it WRITES a
    /// region an earlier draw in this pass SAMPLED. The mirror of
    /// `needsBreakSampling`, pure for the same reason.
    pub fn needsBreakWriting(self: *const HazardTracker, box: VramRect) bool {
        for (self.reads.items) |r| if (box.intersects(r)) return true;
        return false;
    }

    /// Deduplicated: a run of triangles off one texture page reports the same
    /// page rect every time, and a list that grew per primitive would turn the
    /// scan above into the hot loop. Allocation failure is a programmer-level
    /// event here (a handful of rects), so it panics rather than threading an
    /// error through every draw.
    pub fn markRead(self: *HazardTracker, rects: []const VramRect) void {
        outer: for (rects) |rect| {
            for (self.reads.items) |have| {
                if (std.meta.eql(have, rect)) continue :outer;
            }
            self.reads.append(self.alloc, rect) catch @panic("hazard tracker out of memory");
        }
    }
};
