//! Everything the emulator thread hands the render thread, in one value both
//! hold: the frame queue, the software shadow, and the newest display mode.
//!
//! The shadow is a real triple buffer. The producer fills the BACK slot and
//! swaps it with the MIDDLE one; the consumer swaps the middle into FRONT
//! when it is fresh and reads front for as long as it likes. Neither copies,
//! and the producer can never write the slot the reader holds, however many
//! frames it publishes while a 1 MB upload of that slot is in flight.

const std = @import("std");
const pi = @import("prim_instance.zig");
const live_renderer = @import("live_renderer.zig");
const stream_queue = @import("stream_queue.zig");
const Lock = @import("lock.zig").Lock;
const Waker = @import("waker.zig").Waker;

const Allocator = std.mem.Allocator;
const Display = stream_queue.Display;
const StreamQueue = stream_queue.StreamQueue;
const native_pixels = pi.native_pixels;

pub const ShadowSlot = struct {
    pixels: [native_pixels]u16,
    depth: [native_pixels]u32,
    /// Whether `depth` was filled for this frame: only while the depth
    /// buffer is on.
    depth_valid: bool,
    seq: u64,
};

/// `middle`'s index and whether the producer has put a slot there the
/// consumer has not yet taken.
const fresh_bit: u32 = 1 << 2;
const index_mask: u32 = 3;

pub const Exchange = struct {
    alloc: Allocator,
    queue: *StreamQueue,
    slots: *[3]ShadowSlot,

    /// Producer-only.
    back: u32 = 0,
    /// The middle slot's index and the fresh bit, the only state both sides
    /// write. Each side exchanges its own slot for it with a `swap`.
    middle: std.atomic.Value(u32) = .init(1),
    /// Consumer-only. Null until the first acquire finds a fresh slot.
    front: ?u32 = null,
    spare_front: u32 = 2,

    display_lock: Lock = .{},
    display: Display = .{},

    /// Every frame the emulator thread has run and published.
    frames_produced: std.atomic.Value(u64) = .init(0),

    /// The render thread's arrival signal: called after each stream the
    /// producer enqueues and each group it commits. Set before either thread
    /// starts.
    on_published: ?Waker = null,

    pub fn init(alloc: Allocator) !*Exchange {
        const self = try alloc.create(Exchange);
        errdefer alloc.destroy(self);
        const queue = try StreamQueue.init(alloc);
        errdefer queue.deinit();
        const slots = try alloc.create([3]ShadowSlot);
        for (slots) |*s| {
            s.depth_valid = false;
            s.seq = 0;
        }
        self.* = .{ .alloc = alloc, .queue = queue, .slots = slots };
        return self;
    }

    pub fn deinit(self: *Exchange) void {
        self.alloc.destroy(self.slots);
        self.queue.deinit();
        self.alloc.destroy(self);
    }

    // Producer: emulator thread only.

    /// The slot to fill. Never the one the consumer holds.
    pub fn shadowBack(self: *Exchange) *ShadowSlot {
        return &self.slots[self.back];
    }

    /// Hands the filled back slot over. Release: its bytes are visible before
    /// the consumer can see the index.
    pub fn publishShadow(self: *Exchange) void {
        const old = self.middle.swap(self.back | fresh_bit, .acq_rel);
        self.back = old & index_mask;
    }

    /// A stream or a group is in the queue.
    pub fn notifyPublished(self: *Exchange) void {
        if (self.on_published) |w| w.call();
    }

    pub fn publishDisplay(self: *Exchange, d: Display) void {
        self.display_lock.lock();
        defer self.display_lock.unlock();
        self.display = d;
    }

    // Consumer: render thread only.

    /// The newest published shadow, taking it if one is fresh. Null before
    /// the first publish.
    pub fn acquireShadow(self: *Exchange) ?live_renderer.Shadow {
        if (self.middle.load(.acquire) & fresh_bit != 0) {
            const mine = self.front orelse self.spare_front;
            const old = self.middle.swap(mine, .acq_rel);
            self.front = old & index_mask;
        }
        return self.heldShadow();
    }

    /// The shadow the consumer already holds, without taking a newer one.
    pub fn heldShadow(self: *const Exchange) ?live_renderer.Shadow {
        const f = self.front orelse return null;
        const s = &self.slots[f];
        return .{ .pixels = &s.pixels, .depth = if (s.depth_valid) &s.depth else null, .seq = s.seq };
    }

    /// Any thread.
    pub fn newestDisplay(self: *Exchange) Display {
        self.display_lock.lock();
        defer self.display_lock.unlock();
        return self.display;
    }
};
