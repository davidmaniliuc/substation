//! One fixed-stride record per VRAM-visible GP0/GP1 effect, and the single
//! function that turns a record back into that effect.
//!
//! The live path and the replay path both call `execute`. That is deliberate:
//! a second transcription of "what a textured triangle means" is exactly the
//! kind of thing that drifts out of step, and a stream that has drifted is a
//! Metal backend rendering the wrong thing for reasons no shader test finds.
//!
//! `extern struct` throughout, because Phase A2 serializes these to a fixture
//! file and Phase B hands them across the C ABI.

const std = @import("std");
const Vram = @import("vram.zig").Vram;
const VramMask = @import("vram.zig").Mask;
const DrawingEnv = @import("registers.zig").DrawingEnv;
const Renderer = @import("renderer.zig").Renderer;
const Primitive = @import("primitive.zig");

pub const Kind = enum(u8) {
    draw_triangle,
    draw_shaded_triangle,
    draw_textured_triangle,
    draw_rectangle,
    draw_textured_rectangle,
    draw_line,
    draw_shaded_line,
    set_draw_env,
    latch_texpage,
    set_texture_disable_allowed,
    reset_draw_env,
    fill_rect,
    copy_rect,
    vram_write_setup,
    vram_write_data,
    vram_write_abort,
    vram_read_setup,
};

pub const Vertex = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    u: u8 = 0,
    v: u8 = 0,
    _pad: u16 = 0,
    /// 24-bit BGR as it arrives on the wire — the Gouraud paths only.
    color: u32 = 0,
    /// Screen position in 16.16, the exact value the GTE's projection
    /// produced. Equals `x << 16` unless PGXP resolved a sub-pixel — and a
    /// resolved value still satisfies `px >> 16 == x`, which is what
    /// `Precise.resolves` checks before it is admitted.
    ///
    /// Archival, not the rasterizer's working format: the edge functions run
    /// in 1/16 px taken relative to the primitive's bounding box, because a
    /// 1/16-px coordinate is then bounded by the span the oversized-primitive
    /// rule already caps — see `renderer.zig`'s `toQ`.
    px: i32 = 0,
    py: i32 = 0,
};

/// Field meanings per kind. One flat layout rather than a union, so the buffer
/// is a plain array a C caller can walk with a fixed stride:
///
///   draw_triangle                v[0..2].x/.y, value = ABGR1555 colour, transparent
///   draw_shaded_triangle         v[0..2].x/.y/.color, transparent
///   draw_textured_triangle       v[0..2].x/.y/.u/.v, value = colour, clut, tpage, opcode, transparent
///   draw_rectangle               x, y, w, h, value = colour, transparent
///   draw_textured_rectangle      x, y, w, h, v[0].u/.v = texcoord, value = colour,
///                                clut, tpage, opcode, transparent
///   draw_line                    v[0..1].x/.y, value = colour, transparent
///   draw_shaded_line             v[0..1].x/.y/.color, transparent
///   set_draw_env                 opcode = 0xE1..0xE6, value = the register word
///   latch_texpage                tpage
///   set_texture_disable_allowed  value = 0 or 1
///   reset_draw_env               (no fields)
///   fill_rect                    x, y, w, h, value = ABGR1555 colour
///   copy_rect                    x, y = source, x2, y2 = destination, w, h
///   vram_write_setup             x, y, w, h
///   vram_write_data              x = offset into the payload buffer, y = word count
///   vram_write_abort             (no fields)
///   vram_read_setup              x, y, w, h
///
/// x/y are i32 rather than i16 because a transfer's coordinates come off the
/// wire as a full 16-bit field (`gp0.zig:186-189`) and are legal up to 65535 —
/// they simply clip everything out. Screen-space vertices really are i16.
pub const Command = extern struct {
    kind: Kind,
    opcode: u8 = 0,
    transparent: u8 = 0,
    _pad0: u8 = 0,
    value: u32 = 0,
    clut: u16 = 0,
    tpage: u16 = 0,
    x: i32 = 0,
    y: i32 = 0,
    x2: i32 = 0,
    y2: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    v: [3]Vertex = .{ .{}, .{}, .{} },
};

/// One frame's worth of stream. `complete` is false when the frame overran
/// `recorder.max_records` or `recorder.max_payload_words`: the records present
/// are then a PREFIX, and applying a prefix leaves a shadow VRAM permanently
/// out of step with the rasterizer, so an incomplete stream must be discarded
/// rather than replayed.
pub const Stream = struct {
    records: []const Command,
    payload: []const u32,
    complete: bool,
};

comptime {
    // The whole point of the flat layout is that a C caller can walk the
    // buffer with a fixed stride, and Phase A2 writes it to a fixture file.
    // Pin both here so a field added later is a compile error, not a silently
    // reshaped file format.
    if (@sizeOf(Vertex) != 20) @compileError("Vertex layout changed");
    if (@sizeOf(Command) != 96) @compileError("Command layout changed");
}

/// The record's screen-space half, in the shape the renderer takes. The
/// texcoord and colour halves stay loose because only some kinds carry them.
fn vertexPoint(v: Vertex) Primitive.Point {
    return .{ .x = v.x, .y = v.y, .px = v.px, .py = v.py };
}

fn vertexTexturedPoint(v: Vertex) Primitive.TexturedPoint {
    return .{ .point = vertexPoint(v), .texcoord = .{ .u = v.u, .v = v.v } };
}

pub fn execute(cmd: Command, payload: []const u32, vram: *Vram, env: *DrawingEnv) void {
    const transp = cmd.transparent != 0;
    const color16: u16 = @truncate(cmd.value);

    switch (cmd.kind) {
        .draw_triangle => Renderer.drawTriangle(
            vram,
            env,
            vertexPoint(cmd.v[0]),
            vertexPoint(cmd.v[1]),
            vertexPoint(cmd.v[2]),
            color16,
            transp,
        ),
        .draw_shaded_triangle => Renderer.drawShadedTriangle(
            vram,
            env,
            vertexPoint(cmd.v[0]),
            cmd.v[0].color,
            vertexPoint(cmd.v[1]),
            cmd.v[1].color,
            vertexPoint(cmd.v[2]),
            cmd.v[2].color,
            transp,
        ),
        .draw_textured_triangle => Renderer.drawTexturedTriangle(
            vram,
            env,
            vertexTexturedPoint(cmd.v[0]),
            vertexTexturedPoint(cmd.v[1]),
            vertexTexturedPoint(cmd.v[2]),
            color16,
            cmd.clut,
            cmd.tpage,
            transp,
            cmd.opcode,
        ),
        .draw_rectangle => Renderer.drawRectangle(
            vram,
            env,
            @intCast(cmd.x),
            @intCast(cmd.y),
            cmd.w,
            cmd.h,
            color16,
            transp,
        ),
        .draw_textured_rectangle => Renderer.drawTexturedRectangle(
            vram,
            env,
            @intCast(cmd.x),
            @intCast(cmd.y),
            cmd.w,
            cmd.h,
            cmd.v[0].u,
            cmd.v[0].v,
            color16,
            cmd.clut,
            cmd.tpage,
            transp,
            cmd.opcode,
        ),
        .draw_line => Renderer.drawLine(
            vram,
            env,
            cmd.v[0].x,
            cmd.v[0].y,
            cmd.v[1].x,
            cmd.v[1].y,
            color16,
            transp,
        ),
        .draw_shaded_line => Renderer.drawShadedLine(
            vram,
            env,
            cmd.v[0].x,
            cmd.v[0].y,
            cmd.v[0].color,
            cmd.v[1].x,
            cmd.v[1].y,
            cmd.v[1].color,
            transp,
        ),

        .set_draw_env => env.update(cmd.opcode, cmd.value),
        .latch_texpage => env.latchPolygonTexpage(cmd.tpage),
        .set_texture_disable_allowed => env.texture_disable_allowed = cmd.value != 0,
        .reset_draw_env => env.* = .{},

        .fill_rect => vram.fillRectangle(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.w),
            @intCast(cmd.h),
            color16,
        ),
        // The E6 mask is not recorded: it is read from the replayed env, which
        // carries the same value at this point in the stream by construction.
        .copy_rect => vram.copyRect(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.x2),
            @intCast(cmd.y2),
            @intCast(cmd.w),
            @intCast(cmd.h),
            VramMask.fromE6(env.mask_bit),
        ),
        .vram_write_setup => vram.setupWrite(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.w),
            @intCast(cmd.h),
        ),
        .vram_write_data => {
            const off: usize = @intCast(cmd.x);
            const len: usize = @intCast(cmd.y);
            for (payload[off .. off + len]) |word| {
                vram.writeData(word, VramMask.fromE6(env.mask_bit));
            }
        },
        .vram_write_abort => vram.write_active = false,
        .vram_read_setup => vram.setupRead(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.w),
            @intCast(cmd.h),
        ),
    }
}

pub fn replay(s: Stream, vram: *Vram, env: *DrawingEnv) void {
    std.debug.assert(s.complete);
    for (s.records) |cmd| execute(cmd, s.payload, vram, env);
}
