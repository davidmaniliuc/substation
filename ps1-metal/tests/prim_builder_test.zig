//! PrimBuilder: the refusals, the box and the flag translation. No Metal.

const std = @import("std");
const ps1_core = @import("ps1_core");
const metal = @import("ps1_metal");
const prim_builder = metal.prim_builder;
const pi = metal.prim_instance;
const Command = ps1_core.gpu.command.Command;
const command = ps1_core.gpu.command;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;

/// A full-VRAM drawing area, no offset.
fn wideEnv() DrawingEnv {
    var env: DrawingEnv = .{};
    env.update(0xE3, 0);
    env.update(0xE4, 1023 | (511 << 10));
    return env;
}

fn tri(pts: [3][2]i16) Command {
    var cmd: Command = .{ .kind = .draw_triangle };
    for (pts, 0..) |p, i| {
        cmd.v[i].x = p[0];
        cmd.v[i].y = p[1];
        cmd.v[i].px = @as(i32, p[0]) << 16;
        cmd.v[i].py = @as(i32, p[1]) << 16;
    }
    return cmd;
}

test "PrimBuilder: an oversized triangle is dropped" {
    const cmd = tri(.{ .{ 0, 0 }, .{ 1024, 0 }, .{ 0, 10 } });
    try std.testing.expect(prim_builder.triangle(cmd, wideEnv(), pi.Kind.flat_tri) == null);
    // One pixel narrower is kept.
    const ok = tri(.{ .{ 0, 0 }, .{ 1023, 0 }, .{ 0, 10 } });
    try std.testing.expect(prim_builder.triangle(ok, wideEnv(), pi.Kind.flat_tri) != null);
}

test "PrimBuilder: an oversized rectangle is dropped" {
    var cmd: Command = .{ .kind = .draw_rectangle, .w = 1024, .h = 8 };
    try std.testing.expect(prim_builder.rectangle(cmd, wideEnv(), pi.Kind.rect) == null);
    cmd.w = 1023;
    try std.testing.expect(prim_builder.rectangle(cmd, wideEnv(), pi.Kind.rect) != null);
    cmd.h = 512;
    try std.testing.expect(prim_builder.rectangle(cmd, wideEnv(), pi.Kind.rect) == null);
}

test "PrimBuilder: a degenerate triangle is dropped" {
    const cmd = tri(.{ .{ 5, 5 }, .{ 5, 5 }, .{ 5, 5 } });
    try std.testing.expect(prim_builder.triangle(cmd, wideEnv(), pi.Kind.flat_tri) == null);
}

test "PrimBuilder: the triangle box is one pixel wider and clipped" {
    const cmd = tri(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 10, 40 } });
    const inst = prim_builder.triangle(cmd, wideEnv(), pi.Kind.flat_tri).?;
    try std.testing.expectEqual(9, inst.box_x0);
    try std.testing.expectEqual(19, inst.box_y0);
    try std.testing.expectEqual(31, inst.box_x1);
    try std.testing.expectEqual(41, inst.box_y1);

    // Clipped by the drawing area.
    var env = wideEnv();
    env.update(0xE3, 12 | (22 << 10));
    env.update(0xE4, 25 | (35 << 10));
    const clipped = prim_builder.triangle(cmd, env, pi.Kind.flat_tri).?;
    try std.testing.expectEqual(12, clipped.box_x0);
    try std.testing.expectEqual(22, clipped.box_y0);
    try std.testing.expectEqual(25, clipped.box_x1);
    try std.testing.expectEqual(35, clipped.box_y1);

    // Clamped to VRAM at the corner.
    const corner = tri(.{ .{ 0, 0 }, .{ 20, 0 }, .{ 0, 20 } });
    const c = prim_builder.triangle(corner, wideEnv(), pi.Kind.flat_tri).?;
    try std.testing.expectEqual(0, c.box_x0);
    try std.testing.expectEqual(0, c.box_y0);
}

test "PrimBuilder: the record's flags translate to instance flags" {
    var cmd = tri(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 10, 40 } });
    const cases = [_]struct { bit: u8, flag: u32 }{
        .{ .bit = command.flag_texture_perspective, .flag = pi.Flag.texture_perspective },
        .{ .bit = command.flag_color_perspective, .flag = pi.Flag.color_perspective },
        .{ .bit = command.flag_depth_test, .flag = pi.Flag.depth_test },
        .{ .bit = command.flag_depth_write, .flag = pi.Flag.depth_write },
    };
    for (cases) |case| {
        cmd.flags = case.bit;
        const inst = prim_builder.triangle(cmd, wideEnv(), pi.Kind.flat_tri).?;
        try std.testing.expectEqual(case.flag, inst.flags);
    }
    cmd.flags = 0;
    cmd.transparent = 1;
    const t = prim_builder.triangle(cmd, wideEnv(), pi.Kind.flat_tri).?;
    try std.testing.expectEqual(pi.Flag.transparent, t.flags);
}

test "PrimBuilder: the environment becomes clip, blend, dither and mask" {
    var env = wideEnv();
    env.update(0xE1, (2 << 5) | (1 << 9));
    env.update(0xE6, 3);
    const inst = prim_builder.base(env);
    try std.testing.expectEqual(2, inst.blend_mode);
    try std.testing.expectEqual(pi.Flag.dither | pi.Flag.set_mask | pi.Flag.check_mask, inst.flags);
    try std.testing.expectEqual(1023, inst.clip_x1);
    try std.testing.expectEqual(511, inst.clip_y1);
}

test "PrimBuilder: applyTexture decodes tpage and clut as renderer.zig does" {
    var cmd: Command = .{ .kind = .draw_textured_triangle, .tpage = 0x0B5, .clut = 0x7FC1, .opcode = 0x24 };
    var inst = prim_builder.base(wideEnv());
    prim_builder.applyTexture(cmd, &inst);
    try std.testing.expectEqual(1, inst.tex_depth);
    try std.testing.expectEqual(320, inst.tpage_x);
    try std.testing.expectEqual(256, inst.tpage_y);
    try std.testing.expectEqual(16, inst.clut_x);
    try std.testing.expectEqual(511, inst.clut_y);
    try std.testing.expect(inst.flags & pi.Flag.modulate != 0);

    cmd.opcode = 0x25;
    inst = prim_builder.base(wideEnv());
    prim_builder.applyTexture(cmd, &inst);
    try std.testing.expect(inst.flags & pi.Flag.modulate == 0);
}
