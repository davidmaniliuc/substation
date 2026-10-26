//! Whole-VRAM captures gathered without a GPU round trip on the emulator
//! thread: what a rewind capture fills its VRAM section from.
//!
//! The emulator thread asks for the native VRAM as it stands after a seq
//! (`request`) and collects it later (`poll`, `release`). The render thread
//! encodes the gather right after that seq executes (`serve`), on its own
//! command buffer, and a completion block marks the slot ready. A seq that
//! is discarded rather than executed (a resync adopted past it) fails, and a
//! speculative frame never serves one: only the real timeline is captured.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const enums = @import("mtl_enums.zig");
const pi = @import("prim_instance.zig");
const gather = @import("gather.zig");

const native_pixels = pi.native_pixels;

pub const CaptureRing = struct {
    pub const slots = 3;

    slot: [slots]Slot,

    pub const Poll = union(enum) {
        pending,
        ready: *const [native_pixels]u16,
        failed,
    };

    /// What `serve` gathers from: the renderer's queue, texture and scale.
    pub const Source = struct {
        queue: mtl.CommandQueue,
        pipeline: mtl.ComputePipelineState,
        texture: mtl.Texture,
        scale: u32,
    };

    const State = enum(u8) { free, requested, encoded, ready, failed };

    const Slot = struct {
        /// The one field both threads touch. The completion block's store
        /// to it is the block's last touch of the slot.
        state: std.atomic.Value(State) = .init(.free),
        seq: u64 = 0,
        buffer: mtl.Buffer,

        fn completed(self: *Slot, cmd: objc.Id) void {
            const ok = (mtl.CommandBuffer{ .id = cmd }).status() == .completed;
            self.state.store(if (ok) .ready else .failed, .release);
        }
    };

    pub fn init(device: mtl.Device) !CaptureRing {
        var self: CaptureRing = undefined;
        var made: usize = 0;
        errdefer for (self.slot[0..made]) |s| s.buffer.release();
        for (&self.slot) |*s| {
            const b = device.newBuffer(native_pixels * 2, enums.resourceOptions(.shared)) orelse return error.MetalAllocation;
            s.* = .{ .buffer = b };
            made += 1;
        }
        return self;
    }

    /// Waits for every gather still on the GPU: its block writes the slot.
    pub fn deinit(self: *CaptureRing) void {
        for (&self.slot) |*s| {
            while (s.state.load(.acquire) == .encoded) std.Thread.yield() catch {};
            s.buffer.release();
        }
        self.* = undefined;
    }

    // MARK: The emulator thread

    /// A free slot now waiting for `seq`, or null while all are busy.
    pub fn request(self: *CaptureRing, seq: u64) ?u32 {
        for (&self.slot, 0..) |*s, i| {
            if (s.state.load(.acquire) != .free) continue;
            s.seq = seq;
            s.state.store(.requested, .release);
            return @intCast(i);
        }
        return null;
    }

    pub fn poll(self: *CaptureRing, i: u32) Poll {
        const s = &self.slot[i];
        return switch (s.state.load(.acquire)) {
            .requested, .encoded => .pending,
            .ready => .{ .ready = @ptrCast(@alignCast(s.buffer.contents())) },
            .failed => .failed,
            .free => @panic("CaptureRing.poll: the slot was never requested"),
        };
    }

    /// Gives the slot back. Not while its gather is on the GPU.
    pub fn release(self: *CaptureRing, i: u32) void {
        const s = &self.slot[i];
        while (s.state.load(.acquire) == .encoded) std.Thread.yield() catch {};
        s.state.store(.free, .release);
    }

    // MARK: The render thread

    /// `executed_seq` is what the texture now holds, executed or adopted: a
    /// slot waiting for it is gathered, one waiting for an older seq can
    /// never be and fails.
    pub fn serve(self: *CaptureRing, executed_seq: u64, src: Source) void {
        for (&self.slot) |*s| {
            if (s.state.load(.acquire) != .requested) continue;
            if (s.seq < executed_seq) {
                s.state.store(.failed, .release);
            } else if (s.seq == executed_seq) {
                encode(s, src);
            }
        }
    }

    /// Frames through `seq` left the queue without the texture ever holding
    /// them: a capture waiting for one of them fails.
    pub fn discardThrough(self: *CaptureRing, seq: u64) void {
        for (&self.slot) |*s| {
            if (s.state.load(.acquire) == .requested and s.seq <= seq) s.state.store(.failed, .release);
        }
    }

    fn encode(s: *Slot, src: Source) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd = src.queue.commandBuffer() orelse {
            s.state.store(.failed, .release);
            return;
        };
        const full: pi.VramRect = .{ .x0 = 0, .y0 = 0, .x1 = pi.native_width - 1, .y1 = pi.native_height - 1 };
        gather.encode(cmd, src.pipeline, src.texture, s.buffer, 0, full, src.scale);
        s.state.store(.encoded, .release);
        // The literal lives for this call only; the command buffer copies it.
        var block = objc.Block(Slot, Slot.completed).init(s);
        cmd.addCompletedHandler(block.ptr());
        cmd.commit();
    }
};
