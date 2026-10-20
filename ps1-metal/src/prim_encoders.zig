//! Record -> instance encoding for the primitives whose per-pixel geometry
//! doesn't fit the builder's one-instance-per-record shape: lines (which
//! expand into one 1x1 instance per Bresenham step) and the memory movers
//! (fill, copy, upload, depth clear). A copy brackets itself with a pass
//! break; a fill or an upload is ordered by the hazard rule (`appendWrite`).

const std = @import("std");
const ps1_core = @import("ps1_core");
const pi = @import("prim_instance.zig");
const prim_builder = @import("prim_builder.zig");
const Rasterizer = @import("rasterizer.zig").Rasterizer;

const Command = ps1_core.gpu.command.Command;
const LineWalk = ps1_core.gpu.LineWalk;
const WriteCursor = ps1_core.gpu.WriteCursor;
const axisExtent = ps1_core.gpu.Vram.axisExtent;
const PrimInstance = pi.PrimInstance;
const Kind = pi.Kind;
const Flag = pi.Flag;
const native_width = pi.native_width;
const native_height = pi.native_height;

/// One 1x1 instance per Bresenham step. The pixel itself is the box, so
/// coverage is trivially true; the drawing-area clip and the mask still run in
/// the shader's putPixel tail, exactly as `drawLine` calls `putPixel`.
pub fn encodeLine(r: *Rasterizer, cmd: Command) void {
    const shaded = cmd.kind == .draw_shaded_line;
    const ox = r.env.getOffsetX();
    const oy = r.env.getOffsetY();
    var walk = LineWalk.init(
        @as(i32, cmd.v[0].x) + ox,
        @as(i32, cmd.v[0].y) + oy,
        @as(i32, cmd.v[1].x) + ox,
        @as(i32, cmd.v[1].y) + oy,
    ) orelse return;

    var proto = prim_builder.base(r.env);
    proto.kind = if (shaded) Kind.shaded_line_pixel else Kind.line_pixel;
    proto.color = cmd.value & 0xFFFF;
    proto.c0 = cmd.v[0].color;
    proto.c1 = cmd.v[1].color;
    proto.steps = walk.steps;
    if (cmd.transparent != 0) proto.flags |= Flag.transparent;
    // A mono line never dithers; drawLine has no dither branch.
    if (!shaded) proto.flags &= ~Flag.dither;

    while (walk.next()) |step| {
        // Outside VRAM the software path's putPixel returns immediately, so
        // skipping the instance is equivalent and saves the box clamp.
        if (step.x < 0 or step.x >= native_width or step.y < 0 or step.y >= native_height) continue;
        var inst = proto;
        inst.box_x0 = step.x;
        inst.box_x1 = step.x;
        inst.box_y0 = step.y;
        inst.box_y1 = step.y;
        inst.x0 = step.x;
        inst.y0 = step.y;
        inst.k = step.k;
        r.appendPrim(inst);
    }
}

fn maskFlags(r: *const Rasterizer) u32 {
    return (if (r.env.mask_bit & 1 != 0) Flag.set_mask else 0) |
        (if (r.env.mask_bit & 2 != 0) Flag.check_mask else 0);
}

const Box = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

/// Clamps an inclusive box to VRAM. Null when nothing is left, which is the
/// encoder's equivalent of the software path's `continue`.
fn clampBox(x0: i64, y0: i64, x1: i64, y1: i64) ?Box {
    const b: Box = .{
        .x0 = @max(x0, 0),
        .y0 = @max(y0, 0),
        .x1 = @min(x1, native_width - 1),
        .y1 = @min(y1, native_height - 1),
    };
    if (b.x0 > b.x1 or b.y0 > b.y1) return null;
    return b;
}

fn setBox(inst: *PrimInstance, b: Box) void {
    inst.box_x0 = @intCast(b.x0);
    inst.box_y0 = @intCast(b.y0);
    inst.box_x1 = @intCast(b.x1);
    inst.box_y1 = @intCast(b.y1);
}

/// A wrapping run on one axis, as at most two non-wrapping inclusive ranges.
fn wrapRanges(out: *[2][2]i64, origin: i64, extent: i64, axis: i64) [][2]i64 {
    if (extent >= axis) {
        out[0] = .{ 0, axis - 1 };
        return out[0..1];
    }
    const o = @mod(origin, axis);
    if (o + extent <= axis) {
        out[0] = .{ o, o + extent - 1 };
        return out[0..1];
    }
    out[0] = .{ o, axis - 1 };
    out[1] = .{ 0, o + extent - axis - 1 };
    return out[0..2];
}

/// The box a fill or a depth clear covers, or null for an empty one.
fn rectBox(cmd: Command) ?Box {
    const x: i64 = cmd.x;
    const y: i64 = cmd.y;
    const w: i64 = cmd.w;
    const h: i64 = cmd.h;
    if (w <= 0 or h <= 0) return null;
    return clampBox(x, y, x + w - 1, y + h - 1);
}

pub fn encodeFill(r: *Rasterizer, cmd: Command) void {
    const box = rectBox(cmd) orelse return;
    var inst = std.mem.zeroes(PrimInstance);
    inst.kind = Kind.fill;
    setBox(&inst, box);
    inst.color = cmd.value & 0xFFFF;
    const first = r.instances.items.len;
    r.pushInstance(inst);
    r.appendWrite(.fill, first, r.instances.items.len);
}

/// `clear_depth`: one box, depth only. No pass break either side: it writes
/// colour back unchanged, so nothing sampling VRAM can observe it, and
/// tile-memory order is submission order at every pixel.
pub fn encodeDepthClear(r: *Rasterizer, cmd: Command) void {
    const box = rectBox(cmd) orelse return;
    var inst = std.mem.zeroes(PrimInstance);
    inst.kind = Kind.depth_clear;
    setBox(&inst, box);
    const first = r.instances.items.len;
    r.pushInstance(inst);
    r.pushStep(.{ .draw = .{ .kind = .depth_clear, .start = first, .end = r.instances.items.len } });
}

pub fn encodeCopy(r: *Rasterizer, cmd: Command) void {
    const w: i64 = axisExtent(@as(i64, cmd.w), native_width);
    const h: i64 = axisExtent(@as(i64, cmd.h), native_height);
    if (w <= 0 or h <= 0) return;

    var base = std.mem.zeroes(PrimInstance);
    base.kind = Kind.copy;
    base.x0 = cmd.x2 & 0x3FF;
    base.y0 = cmd.y2 & 0x1FF;
    base.src_x = cmd.x & 0x3FF;
    base.src_y = cmd.y & 0x1FF;
    base.w = @intCast(w);
    base.h = @intCast(h);
    base.flags = maskFlags(r);

    const first = r.instances.items.len;
    var xs: [2][2]i64 = undefined;
    var ys: [2][2]i64 = undefined;
    for (wrapRanges(&xs, base.x0, w, native_width)) |bx| {
        for (wrapRanges(&ys, base.y0, h, native_height)) |by| {
            var inst = base;
            setBox(&inst, .{ .x0 = bx[0], .y0 = by[0], .x1 = bx[1], .y1 = by[1] });
            r.pushInstance(inst);
        }
    }
    r.breakPass();
    r.pushStep(.snapshot);
    r.pushStep(.{ .draw = .{ .kind = .copy, .start = first, .end = r.instances.items.len } });
    r.breakPass();
}

pub fn encodeUpload(r: *Rasterizer, cmd: Command) void {
    // A record's off/len pair comes straight off the wire, and nothing
    // validates it against the frame's payload. Without this guard,
    // `word_base + (pix >> 1)` in the upload fragment would index past the
    // payload buffer's real allocation: an out-of-bounds device-buffer read,
    // not merely a wrong pixel.
    const off: i64 = cmd.x;
    const len: i64 = cmd.y;
    if (off < 0 or len < 0 or off + len > r.payload_count) return;
    var word: usize = @intCast(off);
    var remaining: usize = @intCast(len);
    const first = r.instances.items.len;
    while (remaining > 0 and r.transfer.active) {
        const run = r.transfer.plan(remaining) orelse break;
        appendUploadInstance(r, word, run);
        word += run.consumed;
        remaining -= run.consumed;
    }
    r.appendWrite(.upload, first, r.instances.items.len);
}

fn appendUploadInstance(r: *Rasterizer, buffer_word_offset: usize, run: WriteCursor.Run) void {
    const t = r.transfer;
    const w: i64 = @intCast(t.w);
    const row_first: i64 = @intCast(run.first / t.w);
    const row_last: i64 = @intCast(run.last / t.w);
    const box = clampBox(t.x, t.y + row_first, t.x + w - 1, t.y + row_last) orelse return;
    var inst = std.mem.zeroes(PrimInstance);
    inst.kind = Kind.upload;
    setBox(&inst, box);
    inst.x0 = t.x;
    inst.y0 = t.y;
    inst.w = @intCast(t.w);
    inst.h = @intCast(t.h);
    // A run always starts on an EVEN pixel index, so this bias is exact.
    inst.word_base = @intCast(@as(i64, @intCast(buffer_word_offset)) - @as(i64, @intCast(run.first / 2)));
    inst.pixel_first = @intCast(run.first);
    inst.pixel_last = @intCast(run.last);
    inst.flags = maskFlags(r);
    r.pushInstance(inst);
}
