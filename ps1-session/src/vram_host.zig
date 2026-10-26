//! A GPU-only machine's VRAM host: the core's `flush` and `read` hooks,
//! answered by the stream queue and the render thread.
//!
//! Both run on the emulator thread, inside `runFrame`. A chunk goes into
//! the queue under the frame being built (`seq + 1`, the seq `publishFrame`
//! is about to start) as a NON-final slot, so the frame's final slot follows
//! it under the same seq. A read publishes the open chunk first and then
//! waits on a ticket covering every slot published, so the renderer has
//! executed every record the machine has pushed when it gathers the rect.

const std = @import("std");
const builtin = @import("builtin");
const ps1_core = @import("ps1_core");
const metal = @import("ps1_metal");

const Allocator = std.mem.Allocator;
const Host = ps1_core.gpu.Host;
const HostRect = ps1_core.gpu.HostRect;
const Sink = ps1_core.gpu.Sink;
const Vram = ps1_core.gpu.Vram;
const Stream = ps1_core.gpu.command.Stream;
const StreamQueue = metal.stream_queue.StreamQueue;
const RenderThread = metal.render_thread.RenderThread;
const Readback = metal.readback_desk.Readback;
const Pacer = metal.waker.Pacer;
const native_pixels = metal.prim_instance.native_pixels;

/// How long a full queue is waited on between checks for a stopped
/// renderer: the queue's own drain bumps the pacer sooner.
const full_queue_poll_ms = 50;
/// A Debug build panics past this, so a deadlock fails a test rather than
/// hanging it. Release waits without a bound.
const debug_bound_ns = 2 * std.time.ns_per_s;

pub const VramHost = struct {
    queue: *StreamQueue,
    render: *RenderThread,
    pacer: *Pacer,
    io: std.Io,
    /// The run loop's seq: the newest frame published.
    seq: *const u64,
    /// The readback's scratch, row-major over the rect.
    colour: *[native_pixels]u16,
    depth: *[native_pixels]u32,

    pub fn init(alloc: Allocator, queue: *StreamQueue, render: *RenderThread, pacer: *Pacer, io: std.Io, seq: *const u64) !VramHost {
        const colour = try alloc.create([native_pixels]u16);
        errdefer alloc.destroy(colour);
        return .{
            .queue = queue,
            .render = render,
            .pacer = pacer,
            .io = io,
            .seq = seq,
            .colour = colour,
            .depth = try alloc.create([native_pixels]u32),
        };
    }

    pub fn deinit(self: *VramHost, alloc: Allocator) void {
        alloc.destroy(self.colour);
        alloc.destroy(self.depth);
    }

    pub fn host(self: *VramHost) Host {
        return .{ .ctx = self, .read = read, .flush = flush };
    }

    fn flush(ctx: *anyopaque, sink: *Sink) void {
        const self: *VramHost = @ptrCast(@alignCast(ctx));
        self.publish(sink.rec.takeChunk());
    }

    fn read(ctx: *anyopaque, sink: *Sink, vram: *Vram, rect: HostRect, depth: bool) void {
        const self: *VramHost = @ptrCast(@alignCast(ctx));
        const open = sink.rec.takeChunk();
        if (open.records.len > 0 or open.payload.len > 0) self.publish(open);

        const n = @as(usize, rect.w) * rect.h;
        var req: Readback = .{
            .rect = .{ .x0 = rect.x, .y0 = rect.y, .x1 = @as(i32, rect.x) + rect.w - 1, .y1 = @as(i32, rect.y) + rect.h - 1 },
            .colour = self.colour[0..n],
            .depth = if (depth) self.depth[0..n] else null,
            .through = self.queue.ticket(),
        };
        self.render.readback(self.io, &req);
        for (0..rect.h) |row| {
            const dst = Vram.index(rect.x, rect.y + row);
            const src = row * rect.w;
            @memcpy(vram.data[dst..][0..rect.w], self.colour[src..][0..rect.w]);
            if (depth) @memcpy(vram.depth[dst..][0..rect.w], self.depth[src..][0..rect.w]);
        }
    }

    /// Waits for room (the renderer is draining, so it comes), then hands
    /// the chunk over. A renderer that has stopped will never drain: the
    /// chunk is then noted as a drop, and teardown carries on.
    fn publish(self: *VramHost, chunk: Stream) void {
        const t0 = std.Io.Clock.awake.now(self.io);
        while (true) {
            const seen = self.pacer.generation();
            if (self.queue.freeSlots() > 0) break;
            if (self.render.hasStopped()) return self.queue.noteDroppedFrame();
            if (builtin.mode == .debug and t0.untilNow(self.io, .awake).nanoseconds > debug_bound_ns)
                @panic("VramHost: the renderer did not drain in 2 s");
            self.pacer.wait(self.io, seen, .{ .duration = .{ .raw = .fromMilliseconds(full_queue_poll_ms), .clock = .awake } });
        }
        self.queue.publishChunk(self.seq.* +% 1, chunk);
        self.render.frameArrived();
    }
};
