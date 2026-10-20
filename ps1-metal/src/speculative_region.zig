//! The native VRAM rectangle a speculative group may write: what
//! `LiveRenderer` saves before replaying the group for display and puts back
//! before the next real frame.
//!
//! A bound, not an exact footprint. A primitive is bounded by the drawing
//! area it is clipped to, followed through the group's own environment
//! records; a fill, an upload, a copy and a depth clear by their explicit
//! rectangle, and one that wraps an axis takes the whole axis. Too large only
//! costs a bigger blit; too small would leave the speculative picture in the
//! real timeline's VRAM. The switch below is exhaustive, so a record kind
//! added to the core fails to compile here until it is given a bound.

const ps1_core = @import("ps1_core");
const pi = @import("prim_instance.zig");
const StreamSlot = @import("stream_queue.zig").StreamSlot;

const command = ps1_core.gpu.command;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const WriteCursor = ps1_core.gpu.WriteCursor;
const Vram = ps1_core.gpu.Vram;
const VramRect = pi.VramRect;

pub const full: VramRect = .{ .x0 = 0, .y0 = 0, .x1 = pi.native_width - 1, .y1 = pi.native_height - 1 };

/// `start_env` and `transfer` are the rasterizer's as the group starts: an
/// upload the real frame began can be finished by the group.
pub fn of(frames: []const StreamSlot, start_env: DrawingEnv, transfer: WriteCursor) ?VramRect {
    var env = start_env;
    var region: ?VramRect = null;
    if (transfer.active) {
        add(&region, wrapped(transfer.x, transfer.y, @intCast(transfer.w), @intCast(transfer.h)));
    }

    for (frames) |*slot| {
        for (slot.records[0..slot.record_count]) |cmd| switch (cmd.kind) {
            .set_draw_env, .latch_texpage, .set_texture_disable_allowed, .reset_draw_env => {
                command.applyEnv(cmd, &env);
            },
            .draw_triangle,
            .draw_shaded_triangle,
            .draw_textured_triangle,
            .draw_rectangle,
            .draw_textured_rectangle,
            .draw_line,
            .draw_shaded_line,
            => {
                const c = env.area();
                add(&region, clamped(c.x0, c.y0, c.x1, c.y1));
            },
            .fill_rect, .clear_depth => add(&region, clamped(cmd.x, cmd.y, cmd.x + cmd.w - 1, cmd.y + cmd.h - 1)),
            .copy_rect => add(&region, wrapped(cmd.x2, cmd.y2, cmd.w, cmd.h)),
            .vram_write_setup => add(&region, wrapped(cmd.x, cmd.y, cmd.w, cmd.h)),
            .vram_write_data, .vram_write_abort, .vram_read_setup => {},
        };
    }
    return region;
}

fn add(region: *?VramRect, r: ?VramRect) void {
    const rect = r orelse return;
    region.* = if (region.*) |cur| cur.unionWith(rect) else rect;
}

fn clamped(x0: i32, y0: i32, x1: i32, y1: i32) ?VramRect {
    const r: VramRect = .{ .x0 = @max(x0, 0), .y0 = @max(y0, 0), .x1 = @min(x1, full.x1), .y1 = @min(y1, full.y1) };
    return if (r.x0 <= r.x1 and r.y0 <= r.y1) r else null;
}

/// A transfer-style rectangle: the origin wraps, a size of 0 is the whole
/// axis, and one that crosses an edge takes the whole axis.
fn wrapped(x: i32, y: i32, w: i32, h: i32) VramRect {
    const xs = axis(x & 0x3FF, Vram.axisExtent(w & 0x7FF, pi.native_width), pi.native_width);
    const ys = axis(y & 0x1FF, Vram.axisExtent(h & 0x3FF, pi.native_height), pi.native_height);
    return .{ .x0 = xs[0], .y0 = ys[0], .x1 = xs[1], .y1 = ys[1] };
}

fn axis(origin: i32, extent: i32, size: i32) [2]i32 {
    return if (origin + extent > size) .{ 0, size - 1 } else .{ origin, origin + extent - 1 };
}
