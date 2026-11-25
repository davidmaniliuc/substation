//! The deinterlacing display modes against a CPU reference, on a hand-built
//! VRAM whose even native rows are one field and odd rows the other, at 1x
//! and 3x. Every texel differs from its neighbours, so a mode that picks the
//! wrong line, or the wrong sub-row of a scaled one, cannot pass.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const dh = @import("display_harness.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const display = ps1_metal.display;
const deinterlace = ps1_metal.deinterlace;
const Rows = @import("ps1_core").gpu.Rows;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const check = harness.check;

/// The display: tall enough to be two fields, narrow enough to stay cheap.
const width = 64;
const height = 480;

/// Field colour by native row parity, green counting texels with `shift`, so
/// two pictures with different shifts differ everywhere by far more than
/// the motion threshold.
const Picture = struct {
    scale: u32,
    shift: usize = 0,

    fn word(self: Picture, x: usize, y: usize) u16 {
        const field: u16 = if ((y / self.scale) & 1 == 0) 0x001F else 0x7C00;
        const g: u16 = @intCast((x + 3 * y + self.shift) % 32);
        return field | g << 5;
    }

    fn rgb(self: Picture, x: usize, y: usize) [3]u8 {
        const w = self.word(x, y);
        return .{ expand(w & 31), expand((w >> 5) & 31), expand((w >> 10) & 31) };
    }

    /// Display line `line` at native column `nx`, subtexel (`sx`, `sy`).
    fn fetch(self: Picture, p: display.Params, nx: usize, line: usize, sx: usize, sy: usize) [3]u8 {
        const s = self.scale;
        const col = (p.vram_x + nx) & 1023;
        const row = (p.vram_y + line) & 511;
        return self.rgb(col * s + sx, row * s + sy);
    }

    fn texture(self: Picture, device: mtl.Device) !mtl.Texture {
        const w = dh.native_width * self.scale;
        const h = dh.native_height * self.scale;
        const words = try alloc.alloc(u16, w * h);
        defer alloc.free(words);
        for (words, 0..) |*o, i| o.* = self.word(i % w, i / w);
        return managed(device, .r16Uint, 2, w, h, std.mem.sliceAsBytes(words));
    }

    /// What the deinterlacer keeps of this picture: each native pixel at its
    /// top-left subtexel.
    fn woven(self: Picture, p: display.Params) ![][3]u8 {
        const out = try alloc.alloc([3]u8, width * height);
        for (out, 0..) |*o, i| o.* = self.fetch(p, i % width, i / width, 0, 0);
        return out;
    }
};

fn expand(c: u16) u8 {
    const v: u8 = @intCast(c);
    return v << 3 | v >> 2;
}

fn managed(device: mtl.Device, format: ps1_metal.mtl_enums.PixelFormat, bpp: usize, w: usize, h: usize, bytes: []const u8) !mtl.Texture {
    const t = try device.newTexture2D(.{ .format = format, .width = w, .height = h, .storage = .managed, .usage = .{ .shaderRead = true } });
    t.replaceRegion(.{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = w, .height = h, .depth = 1 },
    }, bytes, w * bpp);
    return t;
}

/// A native reference picture, as the deinterlacer's history holds one.
fn referenceTexture(device: mtl.Device, rgb: []const [3]u8) !mtl.Texture {
    const bgra = try alloc.alloc([4]u8, rgb.len);
    defer alloc.free(bgra);
    for (bgra, rgb) |*o, c| o.* = .{ c[2], c[1], c[0], 255 };
    return managed(device, .bgra8Unorm, 4, width, height, std.mem.sliceAsBytes(bgra));
}

fn average(a: [3]u8, b: [3]u8) [3]u8 {
    var o: [3]u8 = undefined;
    for (&o, a, b) |*c, x, y| c.* = @intCast((@as(u16, x) + y + 1) / 2);
    return o;
}

/// Whether a channel moved by more than 0.08 between two pictures.
fn moved(a: [3]u8, b: [3]u8) bool {
    for (a, b) |x, y| if (@abs(@as(i16, x) - y) > 20) return true;
    return false;
}

/// The picture at output pixel (`px`, `py`) of a `width * s` x `height * s`
/// target, by the rule each mode states.
fn expected(pic: Picture, p: display.Params, ref: ?[]const [3]u8, px: usize, py: usize) [3]u8 {
    const s = pic.scale;
    const nx = px / s;
    const sx = px % s;
    const ny = py / s;
    const sy = py % s;
    const last = p.height - 1;
    switch (p.deint) {
        @backingInt(deinterlace.Mode.single_field) => return pic.fetch(p, nx, @min((ny & ~@as(usize, 1)) | p.newest, last), sx, sy),
        @backingInt(deinterlace.Mode.blend) => {
            const a = ny & ~@as(usize, 1);
            return average(pic.fetch(p, nx, a, sx, sy), pic.fetch(p, nx, @min(a + 1, last), sx, sy));
        },
        @backingInt(deinterlace.Mode.adaptive) => {
            const here = pic.fetch(p, nx, ny, sx, sy);
            if (ny & 1 == p.newest or p.has_reference == 0 or ny == 0 or ny + 1 >= p.height) return here;
            const r = ref.?;
            const motion = moved(pic.fetch(p, nx, ny - 1, 0, 0), r[(ny - 1) * width + nx]) or
                moved(pic.fetch(p, nx, ny + 1, 0, 0), r[(ny + 1) * width + nx]) or
                moved(pic.fetch(p, nx, ny, 0, 0), r[ny * width + nx]);
            if (!motion) return here;
            return average(pic.fetch(p, nx, ny - 1, sx, sy), pic.fetch(p, nx, ny + 1, sx, sy));
        },
        else => return pic.fetch(p, nx, ny, sx, sy),
    }
}

fn base(scale: u32, vram_y: u32) display.Params {
    return .{ .vram_x = 0, .vram_y = vram_y, .width = width, .height = height, .depth24 = 0, .enabled = 1, .scale = scale };
}

const Rig = struct {
    m: harness.Metal,
    pass: display.DisplayPass,
    sidecar: mtl.Texture,

    fn init(scale: u32) !Rig {
        const m = try harness.metal();
        errdefer m.deinit();
        var pass = try display.DisplayPass.init(m.device, m.lib);
        errdefer pass.deinit();
        const n = dh.native_pixels * scale * scale;
        const zero = try alloc.alloc([4]u8, n);
        defer alloc.free(zero);
        @memset(zero, .{ 0, 0, 0, 0 });
        const sidecar = try managed(m.device, .rgba8Uint, 4, dh.native_width * scale, dh.native_height * scale, std.mem.sliceAsBytes(zero));
        return .{ .m = m, .pass = pass, .sidecar = sidecar };
    }

    fn deinit(self: *Rig) void {
        self.sidecar.release();
        self.pass.deinit();
        self.m.deinit();
    }

    fn render(self: *Rig, src: display.Source, p: display.Params) ![]u8 {
        return dh.renderSource(alloc, self.m, &self.pass, src, p, width * p.scale, height * p.scale);
    }
};

/// How many output pixels the rule took from a line other than their own,
/// so a case that reconstructs nothing cannot pass for one that does.
fn expectPicture(bgra: []const u8, pic: Picture, p: display.Params, ref: ?[]const [3]u8, name: []const u8) !usize {
    const w = width * pic.scale;
    var rebuilt: usize = 0;
    for (0..height * pic.scale) |py| for (0..w) |px| {
        const want = expected(pic, p, ref, px, py);
        const got = dh.pixel(bgra, w, px, py);
        const rgb = [3]u8{ got[2], got[1], got[0] };
        for (rgb, want) |g, e| if (@abs(@as(i16, g) - e) > 1) {
            try check(false, "{s} at {d}x: ({d}, {d}) is {any}, want {any}", .{ name, pic.scale, px, py, rgb, want });
        };
        if (!std.meta.eql(want, pic.fetch(p, px / pic.scale, py / pic.scale, px % pic.scale, py % pic.scale))) rebuilt += 1;
    };
    return rebuilt;
}

test "Deinterlace: singleFieldShowsTheNewestFieldLineDoubled" {
    for ([_]u32{ 1, 3 }) |scale| {
        var rig = try Rig.init(scale);
        defer rig.deinit();
        const pic: Picture = .{ .scale = scale };
        const vram = try pic.texture(rig.m.device);
        defer vram.release();
        for ([_]u32{ 0, 1 }) |vram_y| for ([_]Rows{ .even, .odd }) |rows| {
            const pool = objc.Pool.push();
            defer pool.pop();
            const p = deinterlace.picture(.single_field, base(scale, vram_y), rows);
            const bgra = try rig.render(.{ .vram = vram, .sidecar = rig.sidecar }, p);
            defer alloc.free(bgra);
            try expect(try expectPicture(bgra, pic, p, null, "single field") > 0);
        };
    }
}

test "Deinterlace: blendAveragesEachPairOfLines" {
    for ([_]u32{ 1, 3 }) |scale| {
        var rig = try Rig.init(scale);
        defer rig.deinit();
        const pic: Picture = .{ .scale = scale };
        const vram = try pic.texture(rig.m.device);
        defer vram.release();
        for ([_]u32{ 0, 1 }) |vram_y| {
            const pool = objc.Pool.push();
            defer pool.pop();
            const p = deinterlace.picture(.blend, base(scale, vram_y), .odd);
            const bgra = try rig.render(.{ .vram = vram, .sidecar = rig.sidecar }, p);
            defer alloc.free(bgra);
            try expect(try expectPicture(bgra, pic, p, null, "blend") > 0);
        }
    }
}

test "Deinterlace: weaveAndProgressiveShowThePictureAsDrawn" {
    for ([_]u32{ 1, 3 }) |scale| {
        var rig = try Rig.init(scale);
        defer rig.deinit();
        const pic: Picture = .{ .scale = scale };
        const vram = try pic.texture(rig.m.device);
        defer vram.release();
        const src: display.Source = .{ .vram = vram, .sidecar = rig.sidecar };
        const plain = try rig.render(src, base(scale, 0));
        defer alloc.free(plain);
        for ([_]deinterlace.Mode{ .progressive, .weave }) |mode| {
            const bgra = try rig.render(src, deinterlace.picture(mode, base(scale, 0), .odd));
            defer alloc.free(bgra);
            try check(std.mem.eql(u8, plain, bgra), "{s} at {d}x is not the picture as drawn", .{ @tagName(mode), scale });
        }
    }
}

test "Deinterlace: adaptiveWeavesWhatHoldsStillAndInterpolatesWhatMoved [validate]" {
    for ([_]u32{ 1, 3 }) |scale| {
        var rig = try Rig.init(scale);
        defer rig.deinit();
        const pic: Picture = .{ .scale = scale };
        const vram = try pic.texture(rig.m.device);
        defer vram.release();
        var p = deinterlace.picture(.adaptive, base(scale, 0), .odd);
        p.has_reference = 1;
        const still = try pic.woven(p);
        defer alloc.free(still);

        // One channel moved by `by` levels on every fifth line's left half:
        // 20 is under 0.08, 21 over it.
        for ([_]u8{ 0, 20, 21 }) |by| {
            const pool = objc.Pool.push();
            defer pool.pop();
            const ref = try alloc.dupe([3]u8, still);
            defer alloc.free(ref);
            for (ref, 0..) |*c, i| if ((i / width) % 5 == 0 and i % width < width / 2) {
                c[0] = if (c[0] >= 128) c[0] - by else c[0] + by;
            };
            const t = try referenceTexture(rig.m.device, ref);
            defer t.release();
            const bgra = try rig.render(.{ .vram = vram, .sidecar = rig.sidecar, .reference = t }, p);
            defer alloc.free(bgra);
            const rebuilt = try expectPicture(bgra, pic, p, ref, "adaptive");
            try check((rebuilt > 0) == (by > 20), "adaptive at {d}x moved by {d}: {d} pixels interpolated", .{ scale, by, rebuilt });

            // Nothing to compare against: woven.
            var none = p;
            none.has_reference = 0;
            const woven = try rig.render(.{ .vram = vram, .sidecar = rig.sidecar, .reference = t }, none);
            defer alloc.free(woven);
            try expectEqual(0, try expectPicture(woven, pic, none, null, "adaptive without a reference"));
        }
    }
}

/// One present's preparation, committed and waited for.
fn prepare(rig: *Rig, d: *deinterlace.Deinterlacer, mode: deinterlace.Mode, vram: mtl.Texture, id: u64, rows: Rows) !struct { display.Params, display.Source } {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cmd = rig.m.queue.commandBuffer() orelse return error.NoCommandBuffer;
    var p = base(1, 0);
    const src = d.prepare(cmd, &rig.pass, mode, .{ .vram = vram, .sidecar = rig.sidecar }, &p, .{ .id = id, .rows = rows });
    cmd.commit();
    cmd.waitUntilCompleted();
    return .{ p, src };
}

test "Deinterlace: adaptiveComparesWithThePictureShownTwoBefore [validate]" {
    var rig = try Rig.init(1);
    defer rig.deinit();
    const a: Picture = .{ .scale = 1 };
    const b: Picture = .{ .scale = 1, .shift = 7 };
    const ta = try a.texture(rig.m.device);
    defer ta.release();
    const tb = try b.texture(rig.m.device);
    defer tb.release();
    var d: deinterlace.Deinterlacer = .{};
    defer d.release();

    try expectEqual(0, (try prepare(&rig, &d, .adaptive, ta, 1, .odd))[0].has_reference);
    try expectEqual(0, (try prepare(&rig, &d, .adaptive, ta, 2, .even))[0].has_reference);
    const third = try prepare(&rig, &d, .adaptive, ta, 3, .odd);
    try expectEqual(1, third[0].has_reference);
    {
        const bgra = try rig.render(third[1], third[0]);
        defer alloc.free(bgra);
        const ref = try a.woven(third[0]);
        defer alloc.free(ref);
        try expectEqual(0, try expectPicture(bgra, a, third[0], ref, "a still picture"));
    }

    // The same picture again, with VRAM that has moved on: nothing is
    // drawn, so picture 3 stays what it was when it was shown.
    _ = try prepare(&rig, &d, .adaptive, tb, 3, .odd);
    _ = try prepare(&rig, &d, .adaptive, ta, 4, .even);
    const fifth = try prepare(&rig, &d, .adaptive, ta, 5, .odd);
    {
        const bgra = try rig.render(fifth[1], fifth[0]);
        defer alloc.free(bgra);
        const ref = try a.woven(fifth[0]);
        defer alloc.free(ref);
        try expectEqual(0, try expectPicture(bgra, a, fifth[0], ref, "a repeat"));
    }

    // Picture 6 against picture 4: everything moved.
    const sixth = try prepare(&rig, &d, .adaptive, tb, 6, .even);
    try expectEqual(1, sixth[0].has_reference);
    {
        const bgra = try rig.render(sixth[1], sixth[0]);
        defer alloc.free(bgra);
        const ref = try a.woven(sixth[0]);
        defer alloc.free(ref);
        try expect(try expectPicture(bgra, b, sixth[0], ref, "a moving picture") > 0);
    }

    // Any other mode holds no history.
    _ = try prepare(&rig, &d, .blend, ta, 7, .odd);
    for (d.woven) |t| try expectEqual(null, t);
}
