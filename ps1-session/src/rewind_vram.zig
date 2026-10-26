//! A GPU-only machine's rewind captures, given their VRAM from the renderer.
//!
//! The machine takes each capture at its frame with the VRAM bytes still to
//! come (`Rewind.defer_vram`). This asks the renderer's `CaptureRing` for the
//! texture as it stands after that frame's seq, and hands each gather back to
//! the machine as it lands, oldest first: the order is what lets the machine
//! diff it exactly. A capture whose VRAM cannot come (no free slot, or a seq
//! the renderer discarded) is dropped with every newer one, since the
//! history's entries chain.
//!
//! Emulator thread only, except the counters.

const std = @import("std");

pub fn RewindVram(comptime Ring: type) type {
    return struct {
        const Self = @This();

        const Tracked = struct { slot: u32, id: u64 };

        /// Oldest first; every entry holds one ring slot.
        fifo: [Ring.slots]Tracked = undefined,
        len: usize = 0,

        /// Captures filled and dropped, and slots held: for the tests and
        /// the stats log, which read them from other threads.
        filled: std.atomic.Value(u64) = .init(0),
        dropped: std.atomic.Value(u64) = .init(0),
        held: std.atomic.Value(u32) = .init(0),

        /// After the frame whose seq `publishFrame` just started, and before
        /// its final stream is published or staged: the renderer serves a
        /// capture when its seq executes, so a request made later waits for
        /// a seq that has gone and holds its slot until it fails.
        pub fn afterFrame(self: *Self, m: anytype, ring: *Ring, seq: u64) void {
            self.releaseForgotten(m, ring);
            const p = m.rewindPendingVram() orelse return;
            if (self.len > 0 and self.fifo[self.len - 1].id >= p.last) return;
            const slot = ring.request(seq) orelse {
                m.rewindDropVramFrom(p.last);
                _ = self.dropped.fetchAdd(1, .monotonic);
                return;
            };
            self.fifo[self.len] = .{ .slot = slot, .id = p.last };
            self.setLen(self.len + 1);
        }

        /// Fills every capture whose gather has landed, oldest first, and
        /// stops at the first still on its way. A failed one is dropped
        /// with every newer one.
        pub fn collect(self: *Self, m: anytype, ring: *Ring) void {
            while (true) {
                self.releaseForgotten(m, ring);
                if (self.len == 0) return;
                const t = self.fifo[0];
                switch (ring.poll(t.slot)) {
                    .pending => return,
                    .ready => |pixels| {
                        // A refusal (out of memory) cleared the history, so
                        // the next pass releases what is left.
                        if (m.rewindFillVram(t.id, pixels)) _ = self.filled.fetchAdd(1, .monotonic);
                        ring.release(t.slot);
                        std.mem.copyForwards(Tracked, self.fifo[0 .. self.len - 1], self.fifo[1..self.len]);
                        self.setLen(self.len - 1);
                    },
                    .failed => {
                        m.rewindDropVramFrom(t.id);
                        _ = self.dropped.fetchAdd(self.len, .monotonic);
                        return self.abandon(ring);
                    },
                }
            }
        }

        /// Gives every slot back: the session is going, or the history is.
        pub fn abandon(self: *Self, ring: *Ring) void {
            for (self.fifo[0..self.len]) |t| ring.release(t.slot);
            self.setLen(0);
        }

        /// Releases every slot whose capture the machine no longer waits
        /// for: a load, a reset, a swap, a budget change or a rewind step
        /// forgot it. The machine reuses a dropped id for its next capture,
        /// so this runs before anything is matched by id.
        fn releaseForgotten(self: *Self, m: anytype, ring: *Ring) void {
            const p = m.rewindPendingVram();
            var kept: usize = 0;
            for (self.fifo[0..self.len]) |t| {
                const waiting = if (p) |w| t.id >= w.first and t.id <= w.last else false;
                if (waiting) {
                    self.fifo[kept] = t;
                    kept += 1;
                } else ring.release(t.slot);
            }
            self.setLen(kept);
        }

        fn setLen(self: *Self, n: usize) void {
            self.len = n;
            self.held.store(@intCast(n), .release);
        }
    };
}
