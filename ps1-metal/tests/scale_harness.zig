//! The scaled path's harness. Where
//! `harness.replay` holds one rasterizer to the software one, these compare
//! the backend against ITSELF at two internal resolutions, which is a
//! different question and needs both views of the result: the scaled
//! texture and its native (top-left subtexel) view.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const pi = ps1_metal.prim_instance;
const Rasterizer = ps1_metal.rasterizer.Rasterizer;
const command = ps1_core.gpu.command;
const Command = command.Command;
const PrimInstance = pi.PrimInstance;
const Allocator = std.mem.Allocator;
const Metal = harness.Metal;
const Rig = harness.Rig;
const ReplayOptions = harness.ReplayOptions;
const Difference = harness.Difference;
const loadFixture = harness.loadFixture;

const io = std.testing.io;
const native_pixels = pi.native_pixels;

/// One frame's result at `scale`. Free with `deinit`.
pub const Frame = struct {
    scaled: []u16,
    native: []u16,
    /// The SCALED sidecar, RGBA, four bytes per pixel; null unless the
    /// caller asked for it. At scale 8 it is 134 MB to materialise, and
    /// every Gate 2 comparison is about VRAM.
    sidecar: ?[]u8,
    /// The instances the encoder built, snapshotted BEFORE `endFrame`
    /// clears them. Gate 2b reads the boxes back out of these.
    instances: []PrimInstance,
    width: usize,
    height: usize,
    scale: u32,

    pub fn deinit(self: Frame, alloc: Allocator) void {
        alloc.free(self.scaled);
        alloc.free(self.native);
        if (self.sidecar) |s| alloc.free(s);
        alloc.free(self.instances);
    }

    pub fn nativeView(self: Frame) *const [native_pixels]u16 {
        return self.native[0..native_pixels];
    }
};

/// Dithering is off by default: every caller here is checking exactness and
/// `.off` is the mode that takes it out of the question entirely. Gate 1 is
/// what checks the dithered 1x output, per frame, per fixture.
///
/// `sprite_filter` null follows `filter`, so a test that draws a
/// screen-aligned triangle (a sprite) keeps meaning what it meant before the
/// sprite/3D split existed.
pub const FrameOptions = struct {
    payload: []const u32 = &.{},
    /// A NATIVE image, replicated N x N: the state a 1x replay would have
    /// reached, expressed at this scale. Uploading it any other way would
    /// seed a difference the comparison would then attribute to the shader.
    preload: ?*const [native_pixels]u16 = null,
    dither: pi.DitherMode = .off,
    filter: pi.TextureFilter = .nearest,
    sprite_filter: ?pi.TextureFilter = null,
    want_sidecar: bool = false,
};

/// One frame, from a blank (or preloaded) VRAM, at `scale`.
pub fn frame(alloc: Allocator, m: Metal, scale: u32, o: FrameOptions, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Rasterizer) void) !Frame {
    const pool = objc.Pool.push();
    defer pool.pop();
    const rig = try Rig.create(alloc, m, .{ .scale = scale });
    defer rig.destroy();
    if (o.preload) |p| rig.vram.uploadNative(p);
    rig.r.dither_mode = o.dither;
    rig.r.texture_filter = o.filter;
    rig.r.sprite_filter = o.sprite_filter orelse o.filter;

    rig.r.beginFrame(o.payload);
    body(ctx, &rig.r);
    const instances = try alloc.dupe(PrimInstance, rig.r.instances.items);
    errdefer alloc.free(instances);
    rig.r.endFrame();
    return capture(alloc, rig, instances, o.want_sidecar);
}

fn applyAll(records: []const Command, r: *Rasterizer) void {
    for (records) |c| r.apply(c);
}

/// `frame` over a fixed list of records, which is what almost every caller
/// draws.
pub fn frameOf(alloc: Allocator, m: Metal, scale: u32, o: FrameOptions, records: []const Command) !Frame {
    return frame(alloc, m, scale, o, records, applyAll);
}

/// The returned frame owns `instances`; on an error the caller still does.
fn capture(alloc: Allocator, rig: *Rig, instances: []PrimInstance, want_sidecar: bool) !Frame {
    const scaled = try rig.readback(alloc);
    errdefer alloc.free(scaled);
    const native = try alloc.alloc(u16, native_pixels);
    errdefer alloc.free(native);
    rig.vram.readbackNative(native[0..native_pixels]);
    const sidecar = if (want_sidecar) try rig.readbackSidecar(alloc) else null;
    return .{
        .scaled = scaled,
        .native = native,
        .sidecar = sidecar,
        .instances = instances,
        .width = rig.vram.width(),
        .height = rig.vram.height(),
        .scale = rig.vram.scale,
    };
}

/// One fixture frame, replayed from a BLANK VRAM.
///
/// Not equivalent to the cumulative replay `compare` runs: a frame that
/// depends on an earlier frame's VRAM or drawing environment will differ.
/// It is used only on frames that open with their own E3/E4/E5 and sample
/// nothing, which is what lets Gate 2b index into the middle of a fixture
/// without dragging the upload frames along.
pub fn fixtureFrame(alloc: Allocator, m: Metal, name: []const u8, i: usize, scale: u32) !Frame {
    const parsed = try loadFixture(alloc, name);
    defer parsed.deinit(alloc);
    const s = parsed.frameStream(i);
    return frameOf(alloc, m, scale, .{ .payload = s.payload }, s.records);
}

/// Whether `loadFixture` would find `name`: a generated fixture is absent on
/// a fresh clone, and a sweep over several skips the missing ones by name.
pub fn fixtureExists(alloc: Allocator, name: []const u8) bool {
    const path = harness.fixturePath(alloc, name) catch return false;
    defer alloc.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The whole fixture, cumulatively, at `scale`, handing `each.frame(i,
/// stream, native)` the NATIVE view after every frame: Gate 2's currency.
/// `each.frame` returns false to stop. Returns the frames replayed.
pub fn replayNative(alloc: Allocator, m: Metal, name: []const u8, scale: u32, o: ReplayOptions, each: anytype) !usize {
    const parsed = try loadFixture(alloc, name);
    defer parsed.deinit(alloc);
    const rig = try Rig.create(alloc, m, .{ .scale = scale, .depth_buffer = o.depth_buffer });
    defer rig.destroy();
    rig.r.dither_mode = o.dither;
    rig.r.texture_filter = o.filter;
    rig.r.sprite_filter = o.sprite_filter;
    const native = try alloc.create([native_pixels]u16);
    defer alloc.destroy(native);

    const count = @min(o.up_to orelse parsed.frames.len, parsed.frames.len);
    for (0..count) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = parsed.frameStream(i);
        rig.frame(s.payload, s.records);
        rig.vram.readbackNative(native);
        if (!try each.frame(i, s, native)) return i + 1;
    }
    return count;
}

/// Gate 2's first disagreeing frame. Owns `message`.
pub const Divergence = struct {
    frame: usize,
    message: []const u8,

    pub fn deinit(self: Divergence, alloc: Allocator) void {
        alloc.free(self.message);
    }
};

/// `dither` defaults to `.off`, which is what the gate has always run at.
/// `.native` is the one other mode it can hold: it hands every subtexel its
/// native pixel's 1x offset, so the top-left subtexel the comparison reads
/// gets exactly the 1x answer. `.scaled` cannot hold and is not meant to;
/// that is the property it trades for the smoother picture.
pub const CompareOptions = struct {
    up_to: ?usize = null,
    dither: pi.DitherMode = .off,
    depth_buffer: bool = false,
};

/// GATE 2. The same fixture replayed cumulatively at 1x and at `scale`,
/// compared per frame on the NATIVE view. Returns the first frame that
/// disagrees, or null if every frame agreed.
///
/// The reference side is the backend's own 1x output, NOT the fixture's Zig
/// hash: that comparison is Gate 1's job and it runs with dithering on,
/// where it belongs.
pub fn compare(alloc: Allocator, m: Metal, name: []const u8, scale: u32, o: CompareOptions) !?Divergence {
    const Lockstep = struct {
        alloc: Allocator,
        one: *Rig,
        want: []u16,
        scale: u32,
        out: ?Divergence = null,

        pub fn frame(self: *@This(), i: usize, s: command.Stream, got: *const [native_pixels]u16) !bool {
            self.one.frame(s.payload, s.records);
            self.one.vram.readback(self.want);
            if (std.mem.eql(u16, self.want, got)) return true;

            var total: usize = 0;
            for (self.want, got) |w, g| total += @intFromBool(w != g);
            var buf: [6]Difference = undefined;
            var text: std.Io.Writer.Allocating = .init(self.alloc);
            errdefer text.deinit();
            try text.writer.print("frame {d}: {d} native px differ", .{ i, total });
            for (harness.firstDifferences(self.want, got, &buf)) |d| {
                try text.writer.print("\n  ({d:>4},{d:>4}) 1x {X:0>4} {d}x {X:0>4}", .{ d.x, d.y, d.want, self.scale, d.got });
            }
            self.out = .{ .frame = i, .message = try text.toOwnedSlice() };
            return false;
        }
    };
    const replay_options: ReplayOptions = .{ .up_to = o.up_to, .dither = o.dither, .depth_buffer = o.depth_buffer };
    const one = try Rig.create(alloc, m, .{ .depth_buffer = o.depth_buffer });
    defer one.destroy();
    one.r.dither_mode = o.dither;
    one.r.texture_filter = replay_options.filter;
    one.r.sprite_filter = replay_options.sprite_filter;
    const want = try alloc.alloc(u16, native_pixels);
    defer alloc.free(want);

    var step: Lockstep = .{ .alloc = alloc, .one = one, .want = want, .scale = scale };
    _ = try replayNative(alloc, m, name, scale, replay_options, &step);
    return step.out;
}

/// Cumulative replay through frame `last`, returning that frame's result.
/// `dither` is the caller's to choose: Gate 3 is about how the picture
/// looks, and that includes the dither pattern.
pub fn replayTo(alloc: Allocator, m: Metal, name: []const u8, last: usize, scale: u32, dither: pi.DitherMode, want_sidecar: bool) !Frame {
    const parsed = try loadFixture(alloc, name);
    defer parsed.deinit(alloc);
    const rig = try Rig.create(alloc, m, .{ .scale = scale });
    defer rig.destroy();
    rig.r.dither_mode = dither;

    var instances: []PrimInstance = &.{};
    errdefer alloc.free(instances);
    for (0..@min(last + 1, parsed.frames.len)) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = parsed.frameStream(i);
        rig.r.beginFrame(s.payload);
        for (s.records) |c| rig.r.apply(c);
        alloc.free(instances);
        instances = try alloc.dupe(PrimInstance, rig.r.instances.items);
        rig.r.endFrame();
    }
    return capture(alloc, rig, instances, want_sidecar);
}

/// Replays a whole fixture at one scale and returns the frame count: no
/// comparison and no readback, so what Gate 4 times is render cost and not
/// the cost of moving 67 MB back over the bus per frame.
pub fn replayForTiming(alloc: Allocator, m: Metal, name: []const u8, scale: u32, filter: pi.TextureFilter, sprite_filter: pi.TextureFilter) !usize {
    const parsed = try loadFixture(alloc, name);
    defer parsed.deinit(alloc);
    const rig = try Rig.create(alloc, m, .{ .scale = scale });
    defer rig.destroy();
    rig.r.texture_filter = filter;
    rig.r.sprite_filter = sprite_filter;
    for (0..parsed.frames.len) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = parsed.frameStream(i);
        rig.frame(s.payload, s.records);
    }
    return parsed.frames.len;
}

/// Opt-in switch for the two gates a machine cannot judge: the variable's
/// trimmed value, or null when it is unset. The Swift suite read a marker
/// file instead, because the hosted test process there sees no environment;
/// this binary is launched by `zig build` and sees an ordinary one.
///
///     PS1_DUMP_SCALED=4 zig build test-metal ...    # Gate 3, at 4x
///     PS1_SCALE_TIMING=1 zig build test-metal ...   # Gate 4
pub fn gateSwitch(name: []const u8) ?[]const u8 {
    const raw = std.testing.environ.getPosix(name) orelse return null;
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// The scales every sweep runs. 3 is in the list on purpose: `px / s` and
/// `px % s` compile to shifts and masks at every power of two, so a bug
/// written as `>> log2(s)`, or an assumption that `s` divides some extent, is
/// invisible at 2, 4 and 8 and fires at 3.
///
/// Measured 2026-08-30 (Gate 4, render cost only, no readback): the scale-8
/// pass over the two 100-frame geometry fixtures costs 2.22 s
/// (silent-hill-usa) plus 0.65 s (tr1-usa-v1-1); 2.9 s against the 120 s the
/// plan set as the point where scale 8 would have to narrow. It does not, so
/// every call site stays on the full ladder.
pub const scale_ladder = [_]u32{ 2, 3, 4, 8 };

/// The three PL ROMs that draw without sampling: 18 flat + 6 Gouraud
/// triangles, 18 rectangles, and 60 mono + 20 shaded lines. `pl-hello-world`
/// and `pl-cpu-add` are NOT here: measured, they carry zero draw records and
/// are pure GP0(A0) upload fixtures, so they are movers.
pub const untextured_pl_fixtures = [_][]const u8{ "pl-render-polygon", "pl-render-rectangle", "pl-render-line" };

/// The four generated fixtures whose content is movers: 26 and 432 uploads
/// with zero draw records, and 1,014 uploads at real FMV payload sizes.
/// `pl-render-texture-polygon` is here rather than with the textured tests
/// because its texture ARRIVES by upload, in the same frame as the 48
/// triangles that sample it.
pub const mover_fixtures = [_][]const u8{ "pl-hello-world", "pl-cpu-add", "pl-render-texture-polygon", "croc-legend-of-the-gobbos" };

/// How many pixels are non-zero: "did this draw anything", and Gate 2b's
/// coverage count.
pub fn painted(pixels: []const u16) usize {
    var n: usize = 0;
    for (pixels) |p| n += @intFromBool(p != 0);
    return n;
}

/// `expect(ok)`, carrying the reason a bare boolean cannot.
pub fn check(ok: bool, comptime fmt: []const u8, args: anytype) !void {
    if (ok) return;
    std.debug.print(fmt ++ "\n", args);
    return error.TestUnexpectedResult;
}

// MARK: Assertions shared by the scale tests

const test_alloc = std.testing.allocator;

/// Gate 2 over a fixture at every scale of the ladder. Every scale runs and
/// says what it found before the test fails.
pub fn expectInvariant(m: Metal, name: []const u8, o: CompareOptions) !void {
    var failed = false;
    for (scale_ladder) |scale| {
        const d = try compare(test_alloc, m, name, scale, o) orelse continue;
        defer d.deinit(test_alloc);
        std.debug.print("{s} @{d}x: {s}\n", .{ name, scale, d.message });
        failed = true;
    }
    try std.testing.expect(!failed);
}

/// Gate 2 over each of `names` that has been generated; a sweep that found
/// none at all is a skip, never a pass.
pub fn expectInvariantWherePresent(m: Metal, names: []const []const u8) !void {
    var checked: usize = 0;
    var failed = false;
    for (names) |name| {
        if (!fixtureExists(test_alloc, name)) continue;
        checked += 1;
        expectInvariant(m, name, .{}) catch |err| switch (err) {
            error.TestUnexpectedResult => failed = true,
            else => return err,
        };
    }
    if (checked == 0) {
        std.debug.print("generated fixtures are absent; run `zig build fixtures -Doptimize=ReleaseFast`\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(!failed);
}

/// Two frames' native views agree; on a failure, says where.
pub fn expectSameNative(want: Frame, got: Frame, label: []const u8) !void {
    if (std.mem.eql(u16, want.native, got.native)) return;
    var buf: [6]Difference = undefined;
    std.debug.print("{s}: native views differ\n", .{label});
    for (harness.firstDifferences(want.native, got.native, &buf)) |d| {
        std.debug.print("  ({d:>4},{d:>4}) 1x {X:0>4} {d}x {X:0>4}\n", .{ d.x, d.y, d.want, got.scale, d.got });
    }
    return error.TestUnexpectedResult;
}

/// The same records at 1x and at every scale of `scales`, native views equal.
pub fn expectRecordsInvariant(m: Metal, o: FrameOptions, records: []const Command, scales: []const u32) !void {
    const one = try frameOf(test_alloc, m, 1, o, records);
    defer one.deinit(test_alloc);
    for (scales) |scale| {
        const many = try frameOf(test_alloc, m, scale, o, records);
        defer many.deinit(test_alloc);
        var label: [32]u8 = undefined;
        try expectSameNative(one, many, try std.fmt.bufPrint(&label, "scale {d}", .{scale}));
    }
}
