//! The host's half of GPU-only VRAM: when the core records without
//! rasterizing, `vram.data` is a landing area, and only the host (the
//! renderer that executes the stream) can say what a pixel is. The core
//! never imports that renderer; it calls these hooks, set by the frontend
//! and never saved.

const constants = @import("../constants.zig");
const Vram = @import("vram.zig").Vram;
const Sink = @import("sink.zig").Sink;

/// A rect inside VRAM, never empty.
pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub const all: Rect = .{ .x = 0, .y = 0, .w = constants.vram_width, .h = constants.vram_height };

    /// The part of a transfer rect `Vram` actually reads: `readPixel` returns
    /// 0 past column 1023 or row 511 and never wraps, so the rest needs no
    /// pixels. `w`/`h` have already been through `Vram.axisExtent`. Null when
    /// nothing is in bounds.
    pub fn clip(x: usize, y: usize, w: usize, h: usize) ?Rect {
        if (x >= constants.vram_width or y >= constants.vram_height or w == 0 or h == 0) return null;
        return .{
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(@min(w, constants.vram_width - x)),
            .h = @intCast(@min(h, constants.vram_height - y)),
        };
    }
};

pub const Host = struct {
    ctx: *anyopaque,
    /// Fill `vram.data` (and `vram.depth` when `depth`) over `rect` with what
    /// every record pushed so far produced, synchronously. Takes the open
    /// chunk with `sink.rec.takeChunk()` first.
    read: *const fn (ctx: *anyopaque, sink: *Sink, vram: *Vram, rect: Rect, depth: bool) void,
    /// The recorder is full: take the open chunk with `takeChunk`. May block
    /// on backpressure.
    flush: *const fn (ctx: *anyopaque, sink: *Sink) void,
};

/// What `PS1_LIVE_STATS` reports of the hooks.
pub const Stats = struct {
    reads: u64 = 0,
    /// GPUREADs re-settled because a pixel record landed mid-read.
    stale_reads: u64 = 0,
    /// Reads that found no host to ask: a bug.
    unserved_reads: u64 = 0,
    /// Reads refused because a runahead mark is held: expected, since the
    /// host's texture holds only the real timeline.
    speculative_reads: u64 = 0,
    flushes: u64 = 0,
};
