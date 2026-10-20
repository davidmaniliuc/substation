//! What every Metal test shares: a device, its queue and the shader library,
//! or a skip where there is no GPU to run on; the fixture corpus; Gate 1; and
//! the VRAM dumps a failing gate leaves behind.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const image_io = @import("image_io.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const fixture = ps1_metal.fixture;
const pi = ps1_metal.prim_instance;
const MetalVram = ps1_metal.metal_vram.MetalVram;
const Rasterizer = ps1_metal.rasterizer.Rasterizer;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Vertex = command.Vertex;
const Vram = ps1_core.gpu.Vram;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const Allocator = std.mem.Allocator;

const io = std.testing.io;
const native_width = pi.native_width;
const native_pixels = pi.native_pixels;

pub const committed_dir = "ps1-core/tests/goldens/fixtures";
pub const generated_dir = "zig-out/fixtures";

pub const Metal = struct {
    device: mtl.Device,
    queue: mtl.CommandQueue,
    lib: mtl.Library,

    pub fn deinit(self: Metal) void {
        self.lib.release();
        self.queue.release();
        self.device.release();
    }
};

/// A headless runner has no device, and a red suite there would be noise,
/// not a signal: the test skips and says why.
pub fn metal() !Metal {
    const device = mtl.Device.createSystemDefault() orelse {
        std.debug.print("no Metal device\n", .{});
        return error.SkipZigTest;
    };
    errdefer device.release();
    const queue = device.newCommandQueue() orelse return error.NoCommandQueue;
    errdefer queue.release();
    const lib = try ps1_metal.shaders.makeLibrary(device);
    return .{ .device = device, .queue = queue, .lib = lib };
}

/// A `MetalVram` and the rasterizer drawing into it, on the heap so the
/// rasterizer's pointer to the VRAM stays put.
pub const Rig = struct {
    alloc: Allocator,
    vram: MetalVram,
    r: Rasterizer,

    pub const Options = struct { scale: u32 = 1, depth_buffer: bool = false };

    pub fn create(alloc: Allocator, m: Metal, o: Options) !*Rig {
        const self = try alloc.create(Rig);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.vram = try MetalVram.init(alloc, m.device, m.queue, o.scale, o.depth_buffer);
        errdefer self.vram.deinit();
        self.r = try Rasterizer.init(alloc, &self.vram, m.lib);
        return self;
    }

    pub fn destroy(self: *Rig) void {
        self.r.deinit();
        self.vram.deinit();
        self.alloc.destroy(self);
    }

    /// One frame: begin, every record, end.
    pub fn frame(self: *Rig, payload: []const u32, records: []const Command) void {
        self.r.beginFrame(payload);
        for (records) |c| self.r.apply(c);
        self.r.endFrame();
    }

    /// The scaled texture, owned by the caller.
    pub fn readback(self: *Rig, alloc: Allocator) ![]u16 {
        const out = try alloc.alloc(u16, self.vram.pixelCount());
        self.vram.readback(out);
        return out;
    }

    /// The scaled sidecar, owned by the caller.
    pub fn readbackSidecar(self: *Rig, alloc: Allocator) ![]u8 {
        const out = try alloc.alloc(u8, self.vram.pixelCount() * 4);
        self.vram.readbackSidecar(out);
        return out;
    }
};

/// Records through `command.execute` into a blank software VRAM, the
/// reference every Metal draw is held to. Owned by the caller.
pub fn softwareFrame(alloc: Allocator, payload: []const u32, records: []const Command) !*Vram {
    const vram = try alloc.create(Vram);
    vram.* = .{};
    var draw_env: DrawingEnv = .{};
    for (records) |c| command.execute(c, payload, vram, &draw_env);
    return vram;
}

// MARK: The corpus

/// The committed fixtures first, then the generated ones. Owned by the caller.
pub fn fixturePath(alloc: Allocator, name: []const u8) ![]u8 {
    const committed = try std.fmt.allocPrint(alloc, "{s}/{s}.p1fx", .{ committed_dir, name });
    if (std.Io.Dir.cwd().access(io, committed, .{})) |_| return committed else |_| {}
    alloc.free(committed);
    return std.fmt.allocPrint(alloc, "{s}/{s}.p1fx", .{ generated_dir, name });
}

/// Generated fixtures are build artifacts: absent on a fresh clone, and the
/// real-game ones absent on any machine without `games/`. A missing one is a
/// skip that names itself, never a silent pass.
pub fn loadFixture(alloc: Allocator, name: []const u8) !fixture.Parsed {
    const path = try fixturePath(alloc, name);
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("fixture {s} not generated; run `zig build fixtures -Doptimize=ReleaseFast`\n", .{name});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(bytes);
    return fixture.parse(alloc, bytes);
}

/// Every name `loadFixture` can open, sorted, each once. A file another
/// format version wrote (an ad-hoc capture `zig build fixtures` does not
/// regenerate) cannot be opened, and is named on stderr rather than dropped
/// in silence. Free with `freeCorpus`.
pub fn corpus(alloc: Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer freeCorpus(alloc, names.items);
    for ([_][]const u8{ committed_dir, generated_dir }) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        next: while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".p1fx")) continue;
            const name = entry.name[0 .. entry.name.len - ".p1fx".len];
            for (names.items) |have| if (std.mem.eql(u8, have, name)) continue :next;
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
            defer alloc.free(path);
            if (!currentFormat(path)) {
                std.debug.print("[corpus] {s} is not a version-{d} fixture; regenerate it to gate it\n", .{ path, fixture.version });
                continue;
            }
            try names.append(alloc, try alloc.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(alloc);
}

/// Whether the header at `path` is one this build's `fixture.parse` accepts.
/// The body is still checked by the parse itself when the fixture loads.
fn currentFormat(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var header: [fixture.header_bytes]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return false;
    return n == header.len and
        std.mem.eql(u8, header[0..8], &fixture.magic) and
        std.mem.readInt(u32, header[8..12], .little) == fixture.version and
        std.mem.readInt(u32, header[12..16], .little) == fixture.record_stride and
        std.mem.readInt(u32, header[16..20], .little) == fixture.kind_count;
}

pub fn freeCorpus(alloc: Allocator, names: []const []const u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

/// Whether any record depth-tests. Such a fixture was captured with the depth
/// plane persisting, and a memoryless plane (wiped at every pass break)
/// cannot reproduce it.
pub fn carriesDepth(parsed: fixture.Parsed) bool {
    for (parsed.records) |c| if (c.flags & command.flag_depth_test != 0) return true;
    return false;
}

// MARK: Gate 1

/// `dither`, `filter` and `sprite_filter` are PINNED rather than inherited
/// from the shipped default, and the default here is `.native`. This gate's
/// reference is the software rasterizer, which dithers whenever GP0(E1) bit 9
/// is set, so a mode is part of the gate; `.scaled` is the same expression at
/// 1x and `.true_color` deliberately is not. Inheriting the player's setting
/// once made the shipped default decide what every fixture was compared to.
///
/// `up_to` bounds the replay to the first N frames: VRAM is cumulative, and a
/// later frame's mismatch would otherwise mask an earlier feature that works.
pub const ReplayOptions = struct {
    up_to: ?usize = null,
    dither: pi.DitherMode = .native,
    filter: pi.TextureFilter = .nearest,
    sprite_filter: pi.TextureFilter = .nearest,
    depth_buffer: bool = false,
};

pub const ReplayResult = struct {
    frames_checked: usize,
    first_divergence: ?usize,
    pass_count: usize,
    /// Owned by the allocator `replay` was given.
    message: []const u8,

    pub fn deinit(self: ReplayResult, alloc: Allocator) void {
        alloc.free(self.message);
    }
};

/// GATE 1. Each frame is replayed through `command.replay` into a software
/// VRAM AND through Metal at 1x; the full VRAM is compared after EVERY frame,
/// and the software side is held to the fixture's recorded hash as well, so a
/// fixture the core no longer reproduces is named as that rather than blamed
/// on the port.
pub fn replay(alloc: Allocator, m: Metal, name: []const u8, o: ReplayOptions) !ReplayResult {
    const parsed = try loadFixture(alloc, name);
    defer parsed.deinit(alloc);

    const rig = try Rig.create(alloc, m, .{ .depth_buffer = o.depth_buffer });
    defer rig.destroy();
    rig.r.dither_mode = o.dither;
    rig.r.texture_filter = o.filter;
    rig.r.sprite_filter = o.sprite_filter;

    const soft = try alloc.create(Vram);
    defer alloc.destroy(soft);
    soft.* = .{};
    var draw_env: DrawingEnv = .{};
    const got = try alloc.alloc(u16, native_pixels);
    defer alloc.free(got);

    const count = @min(o.up_to orelse parsed.frames.len, parsed.frames.len);
    for (0..count) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = parsed.frameStream(i);
        command.replay(s, soft, &draw_env);
        rig.frame(s.payload, s.records);
        rig.vram.readback(got);

        const fail: ?[]const u8 = if (rig.r.saw_unmodelled_kind)
            try std.fmt.allocPrint(alloc, "{s} frame {d}: a record of a kind the rasterizer does not model", .{ name, i })
        else if (!std.mem.eql(u16, got, &soft.data))
            try report(alloc, name, i, got, &soft.data)
        else if (fixture.hashVram(soft) != parsed.frames[i].vram_hash)
            try std.fmt.allocPrint(alloc, "{s} frame {d}: Metal agrees with the software rasterizer, but both hash {x:0>16} and the fixture recorded {x:0>16}", .{ name, i, fixture.hashVram(soft), parsed.frames[i].vram_hash })
        else
            null;
        if (fail) |message| return .{
            .frames_checked = i + 1,
            .first_divergence = i,
            .pass_count = rig.r.pass_count,
            .message = message,
        };
    }
    return .{
        .frames_checked = count,
        .first_divergence = null,
        .pass_count = rig.r.pass_count,
        .message = try std.fmt.allocPrint(alloc, "{s}: {d} frames, {d} passes", .{ name, count, rig.r.pass_count }),
    };
}

// MARK: VRAM dumps
//
// Raw 1 MB VRAM blobs, and the pixel-wise diff that turns "frame 137
// diverged" into an address. Built BEFORE there is anything to debug,
// deliberately: it is worthless to write while staring at a red frame.

/// Sits next to the generated fixtures, which are already build artifacts.
/// Owned by the caller.
pub fn dumpPath(alloc: Allocator, fixture_name: []const u8, frame_index: usize, side: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}-frame{d}{s}{s}.vram", .{
        generated_dir, fixture_name, frame_index, if (side.len == 0) "" else "-", side,
    });
}

pub fn writeDump(path: []const u8, pixels: []const u16) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(pixels) });
}

/// Null for a missing file or one that is not exactly one native VRAM.
pub fn readDump(alloc: Allocator, path: []const u8) ?[]u16 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(native_pixels * 2 + 1)) catch return null;
    defer alloc.free(bytes);
    if (bytes.len != native_pixels * 2) return null;
    const out = alloc.alloc(u16, native_pixels) catch return null;
    @memcpy(std.mem.sliceAsBytes(out), bytes);
    return out;
}

pub const Difference = struct { x: usize, y: usize, want: u16, got: u16 };

/// Up to `out.len` differing pixels, in address order.
pub fn firstDifferences(want: []const u16, got: []const u16, out: []Difference) []Difference {
    var n: usize = 0;
    for (0..@min(want.len, got.len)) |i| {
        if (n == out.len) break;
        if (want[i] == got[i]) continue;
        out[n] = .{ .x = i % native_width, .y = i / native_width, .want = want[i], .got = got[i] };
        n += 1;
    }
    return out[0..n];
}

/// The failure message. Writes this side's VRAM unconditionally. `want` is
/// the in-process reference when there is one; without it the message lists
/// differences against the `stream-capture --dump-frame` dump for that frame
/// if one is on disk, or says how to produce it.
pub fn report(alloc: Allocator, fixture_name: []const u8, frame_index: usize, got: []const u16, want: ?[]const u16) ![]const u8 {
    const mine = try dumpPath(alloc, fixture_name, frame_index, "metal");
    defer alloc.free(mine);
    writeDump(mine, got) catch {};

    var loaded: ?[]u16 = null;
    defer if (loaded) |l| alloc.free(l);
    const reference = want orelse blk: {
        const theirs = try dumpPath(alloc, fixture_name, frame_index, "");
        defer alloc.free(theirs);
        loaded = readDump(alloc, theirs);
        break :blk loaded orelse return std.fmt.allocPrint(alloc,
            \\{s} frame {d} diverged. Metal VRAM written to {s}.
            \\No reference dump: produce one with:
            \\  zig build trace-golden -Doptimize=ReleaseFast -- stream-capture \
            \\    --filter={s} --dump-frame={d}
        , .{ fixture_name, frame_index, mine, fixture_name, frame_index });
    };
    if (want != null) {
        const soft = try dumpPath(alloc, fixture_name, frame_index, "software");
        defer alloc.free(soft);
        writeDump(soft, reference) catch {};
    }

    var total: usize = 0;
    for (0..@min(reference.len, got.len)) |i| total += @intFromBool(reference[i] != got[i]);
    var buf: [10]Difference = undefined;
    var text: std.Io.Writer.Allocating = .init(alloc);
    errdefer text.deinit();
    try text.writer.print("{s} frame {d} diverged: {d} px", .{ fixture_name, frame_index, total });
    for (firstDifferences(reference, got, &buf)) |d| {
        try text.writer.print("\n  ({d:>4},{d:>4}) want {X:0>4} got {X:0>4}", .{ d.x, d.y, d.want, d.got });
    }
    return text.toOwnedSlice();
}

// MARK: PNG dumps
//
// ABGR1555 -> PNG, for what a machine cannot judge: seams along quad
// diagonals, texture bleeding and gaps between adjacent primitives are all
// things you see in an image and none of them move a hash. A sibling of the
// `.vram` dump, not a replacement: the blob is the exact bytes, the PNG is
// lossy about the mask bit and is for looking at.

/// `sidecar` names the eight-bit dump rather than the VRAM one; the two must
/// not collide, or the side-by-side comparison becomes one image against
/// itself. Owned by the caller.
pub fn pngPath(alloc: Allocator, fixture_name: []const u8, frame_index: usize, scale: u32, sidecar: bool) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}-frame{d}-{d}x{s}.png", .{
        generated_dir, fixture_name, frame_index, scale, if (sidecar) "-sidecar" else "",
    });
}

fn expand5(c: u16) u8 {
    // 5 -> 8 bits by replicating the high bits, so 31 maps to 255. A plain
    // << 3 tops out at 248 and darkens every dump.
    return @intCast((c << 3) | (c >> 2));
}

/// Bit 15 (mask/STP) is DROPPED, not rendered as alpha: an image whose alpha
/// varied with the mask bit would show masked regions as holes and invite
/// exactly the wrong conclusion about a picture that is correct.
pub fn writeVramPng(path: []const u8, pixels: []const u16, w: usize, h: usize) !void {
    std.debug.assert(pixels.len == w * h);
    const rgba = try std.heap.page_allocator.alloc(u8, w * h * 4);
    defer std.heap.page_allocator.free(rgba);
    for (pixels, 0..) |p, i| {
        rgba[i * 4 + 0] = expand5(p & 0x1F);
        rgba[i * 4 + 1] = expand5((p >> 5) & 0x1F);
        rgba[i * 4 + 2] = expand5((p >> 10) & 0x1F);
        rgba[i * 4 + 3] = 255;
    }
    try image_io.writeRgba(path, rgba, w, h);
}

/// The true-colour sidecar: RGB where alpha says the pixel is present, BLACK
/// where it does not. This dump is for reading the sidecar's own coverage,
/// and expanding VRAM into the gaps would produce a plausible-looking picture
/// that answers a different question.
pub fn writeSidecarPng(path: []const u8, rgba: []const u8, w: usize, h: usize) !void {
    std.debug.assert(rgba.len == w * h * 4);
    const out = try std.heap.page_allocator.alloc(u8, w * h * 4);
    defer std.heap.page_allocator.free(out);
    for (0..w * h) |i| {
        const present = rgba[i * 4 + 3] != 0;
        for (0..3) |c| out[i * 4 + c] = if (present) rgba[i * 4 + c] else 0;
        out[i * 4 + 3] = 255;
    }
    try image_io.writeRgba(path, out, w, h);
}

// MARK: Hand-built records

/// A vertex with no sub-pixel, which is what GP0 decode produces whenever
/// PGXP has nothing to say about it: `px == x << 16`, `py == y << 16`.
pub fn vtx(x: i16, y: i16, u: u8, v: u8, color: u32) Vertex {
    return .{ .x = x, .y = y, .u = u, .v = v, .color = color, .px = @as(i32, x) << 16, .py = @as(i32, y) << 16 };
}

pub fn env(opcode: u8, value: u32) Command {
    return .{ .kind = .set_draw_env, .opcode = opcode, .value = value };
}

/// GP0(E4) = (1023, 511): with E3's default of (0, 0), the whole of VRAM.
pub fn fullDrawingArea() Command {
    return env(0xE4, (511 << 10) | 1023);
}

// MARK: The scaled path
//
// Lives in `scale_harness.zig` to keep this file in bounds; re-exported here
// so every test reaches the whole harness through one import.

const scale_harness = @import("scale_harness.zig");
pub const Frame = scale_harness.Frame;
pub const FrameOptions = scale_harness.FrameOptions;
pub const frame = scale_harness.frame;
pub const frameOf = scale_harness.frameOf;
pub const fixtureFrame = scale_harness.fixtureFrame;
pub const fixtureExists = scale_harness.fixtureExists;
pub const replayNative = scale_harness.replayNative;
pub const Divergence = scale_harness.Divergence;
pub const CompareOptions = scale_harness.CompareOptions;
pub const compare = scale_harness.compare;
pub const replayTo = scale_harness.replayTo;
pub const replayForTiming = scale_harness.replayForTiming;
pub const gateSwitch = scale_harness.gateSwitch;
pub const scale_ladder = scale_harness.scale_ladder;
pub const untextured_pl_fixtures = scale_harness.untextured_pl_fixtures;
pub const mover_fixtures = scale_harness.mover_fixtures;
pub const painted = scale_harness.painted;
pub const check = scale_harness.check;
pub const expectInvariant = scale_harness.expectInvariant;
pub const expectInvariantWherePresent = scale_harness.expectInvariantWherePresent;
pub const expectSameNative = scale_harness.expectSameNative;
pub const expectRecordsInvariant = scale_harness.expectRecordsInvariant;
