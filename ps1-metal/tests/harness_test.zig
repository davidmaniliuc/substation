//! Gate 1 over the whole corpus, the harness's own failure modes, and the
//! VRAM and PNG dump writers a failing gate leaves behind.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");
const image_io = @import("image_io.zig");

const command = ps1_core.gpu.command;

const alloc = std.testing.allocator;
const io = std.testing.io;
const native_pixels = ps1_metal.prim_instance.native_pixels;

// Gate 1 over every fixture `loadFixture` can open, every frame. A fixture
// that depth-tests was captured with the plane persisting, so it replays
// with one. `[validate]` puts it in `test-metal-validate`.
test "theCorpusPassesGateOne: every corpus fixture, every frame [validate]" {
    const m = try harness.metal();
    defer m.deinit();
    const names = try harness.corpus(alloc);
    defer harness.freeCorpus(alloc, names);
    try std.testing.expect(names.len > 0);

    var failed = false;
    for (names) |name| {
        const depth = blk: {
            const parsed = try harness.loadFixture(alloc, name);
            defer parsed.deinit(alloc);
            break :blk harness.carriesDepth(parsed);
        };
        const r = try harness.replay(alloc, m, name, .{ .depth_buffer = depth });
        defer r.deinit(alloc);
        std.debug.print("[gate-1] {s}{s}: {d} frames, {d} passes\n", .{ name, if (depth) " (depth)" else "", r.frames_checked, r.pass_count });
        if (r.first_divergence != null) {
            std.debug.print("{s}\n", .{r.message});
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

// Review Focus 1: ported code that forgets a `release`, or creates
// autoreleased objects outside a pool, grows without bound in a long
// session. Three corpus passes, a pool per frame (`harness.replay` pushes
// one), must leave the device's allocation where the first left it.
test "replayingTheCorpusThreeTimesDoesNotGrowTheDevicesAllocation" {
    const m = try harness.metal();
    defer m.deinit();
    const names = try harness.corpus(alloc);
    defer harness.freeCorpus(alloc, names);

    var after: [3]usize = undefined;
    for (&after) |*slot| {
        for (names) |name| {
            const depth = blk: {
                const parsed = try harness.loadFixture(alloc, name);
                defer parsed.deinit(alloc);
                break :blk harness.carriesDepth(parsed);
            };
            const r = try harness.replay(alloc, m, name, .{ .depth_buffer = depth });
            r.deinit(alloc);
        }
        slot.* = m.device.currentAllocatedSize();
    }
    std.debug.print("[leak] device allocation after each pass: {d} / {d} / {d} bytes\n", .{ after[0], after[1], after[2] });
    try std.testing.expect(after[2] <= after[0] + (1 << 20));
}

// Review Focus 4: a missing fixture is a skip that names itself, never a
// crash and never a pass.
test "aMissingFixtureSkipsAndNamesItself" {
    try std.testing.expectError(error.SkipZigTest, harness.loadFixture(alloc, "no-such-fixture"));
}

fn census(parsed: ps1_metal.fixture.Parsed, frame: usize, kind: command.Kind) usize {
    var n: usize = 0;
    for (parsed.frameStream(frame).records) |r| n += @intFromBool(r.kind == kind);
    return n;
}

test "theCommittedPrimitivesFixtureHasTheDocumentedShape" {
    const f = try harness.loadFixture(alloc, "synthetic-primitives");
    defer f.deinit(alloc);
    // Seven Phase B rungs plus frame 7, the Gouraud-shaded TEXTURED polygons,
    // plus frame 8, the depth rung.
    try std.testing.expectEqual(9, f.frames.len);
    try std.testing.expect(census(f, 0, .draw_triangle) > 0);
    try std.testing.expectEqual(0, census(f, 0, .draw_shaded_triangle));
    try std.testing.expect(census(f, 1, .draw_shaded_triangle) > 0);
    try std.testing.expect(census(f, 2, .draw_textured_triangle) > 0);
    try std.testing.expect(census(f, 3, .draw_rectangle) > 0);
    try std.testing.expect(census(f, 4, .draw_textured_rectangle) > 0);
    try std.testing.expect(census(f, 5, .draw_line) > 0);
    try std.testing.expect(census(f, 5, .draw_shaded_line) > 0);
    try std.testing.expect(census(f, 6, .copy_rect) > 0);
}

// MARK: VRAM dumps

fn tmpPath(comptime name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ harness.generated_dir, name });
}

fn removeFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "vramDumpRoundTripsAndReportsTheFirstDifferences" {
    const a = try alloc.alloc(u16, native_pixels);
    defer alloc.free(a);
    @memset(a, 0);
    const b = try alloc.dupe(u16, a);
    defer alloc.free(b);
    b[5] = 0x1234;
    b[1024 + 7] = 0x8000;

    const path = try tmpPath("dump-roundtrip-3f8a1c.vram");
    defer alloc.free(path);
    defer removeFile(path);
    try harness.writeDump(path, b);
    const back = harness.readDump(alloc, path) orelse return error.TestUnexpectedNull;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u16, b, back);

    var buf: [4]harness.Difference = undefined;
    const diffs = harness.firstDifferences(a, b, &buf);
    try std.testing.expectEqual(2, diffs.len);
    try std.testing.expectEqual(harness.Difference{ .x = 5, .y = 0, .want = 0, .got = 0x1234 }, diffs[0]);
    try std.testing.expectEqual(harness.Difference{ .x = 7, .y = 1, .want = 0, .got = 0x8000 }, diffs[1]);
    a[5] = 0x1234;
    a[1024 + 7] = 0x8000;
    try std.testing.expectEqual(0, harness.firstDifferences(a, b, &buf).len);
}

// `report()` is what every gate calls on a mismatch. Fixture names here are
// unique nonce strings, since `report()` writes into zig-out/fixtures and
// must not collide with an actual build artifact.
test "reportProducesARegenerationHintWhenNoReferenceDumpExists" {
    const name = "vramdump-report-test-noref-3f8a1c";
    const mine = try harness.dumpPath(alloc, name, 0, "metal");
    defer alloc.free(mine);
    defer removeFile(mine);

    const got = try alloc.alloc(u16, native_pixels);
    defer alloc.free(got);
    @memset(got, 0);
    got[9] = 0x2222;

    const message = try harness.report(alloc, name, 0, got, null);
    defer alloc.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, name ++ " frame 0 diverged") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "stream-capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "--dump-frame=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "--filter=" ++ name) != null);
    const back = harness.readDump(alloc, mine) orelse return error.TestUnexpectedNull;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u16, got, back);
}

test "reportListsTheFirstDifferingPixelsWhenAReferenceDumpExists" {
    const name = "vramdump-report-test-withref-3f8a1c";
    const want = try alloc.alloc(u16, native_pixels);
    defer alloc.free(want);
    @memset(want, 0);
    const got = try alloc.dupe(u16, want);
    defer alloc.free(got);
    got[5] = 0x1234;
    got[1024 + 7] = 0x8000;

    const reference = try harness.dumpPath(alloc, name, 0, "");
    defer alloc.free(reference);
    defer removeFile(reference);
    const mine = try harness.dumpPath(alloc, name, 0, "metal");
    defer alloc.free(mine);
    defer removeFile(mine);
    try harness.writeDump(reference, want);

    const message = try harness.report(alloc, name, 0, got, null);
    defer alloc.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, name ++ " frame 0 diverged: 2 px") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "  (   5,   0) want 0000 got 1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "  (   7,   1) want 0000 got 8000") != null);
    const back = harness.readDump(alloc, mine) orelse return error.TestUnexpectedNull;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u16, got, back);
}

// MARK: PNG dumps

// ABGR1555 -> 8 bits per channel is `(c << 3) | (c >> 2)`, so 31 becomes 255
// and 0 becomes 0: a plain `<< 3` would top out at 248 and every dumped image
// would be subtly dark, which is exactly the kind of thing an eyeball gate
// would rationalize away.
test "vramImageWritesAPngWhoseChannelsAreTheFiveBitOnesExpanded" {
    const pixels = [_]u16{
        0x001F, // red   = 31
        0x03E0, // green = 31
        0x7C00, // blue  = 31
        0x8000, // all channels 0, mask bit set (and ignored)
    };
    const path = try tmpPath("vramimage-test-3f8a1c.png");
    defer alloc.free(path);
    defer removeFile(path);
    try std.Io.Dir.cwd().createDirPath(io, harness.generated_dir);
    try harness.writeVramPng(path, &pixels, 2, 2);

    const img = try image_io.readRgba(alloc, path);
    defer alloc.free(img.rgba);
    try std.testing.expectEqual(2, img.width);
    try std.testing.expectEqual(2, img.height);
    const b = img.rgba;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, b[0..3]); // red
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, b[4..7]); // green
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, b[8..11]); // blue
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, b[12..15]); // mask bit only
}

// Gate 3's only assertable half. The dump itself is eyeball-only, but a
// writer that silently drops a channel would make the comparison it exists
// for meaningless, and the PNG is the only place the eight-bit picture is
// ever visible outside the app.
test "theSidecarPngWriterRoundTripsItsBytes" {
    const w = 4;
    const h = 2;
    var bytes: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| {
        bytes[i * 4] = @intCast(i * 8);
        bytes[i * 4 + 1] = @intCast(i * 8 + 1);
        bytes[i * 4 + 2] = @intCast(i * 8 + 2);
        bytes[i * 4 + 3] = if (i % 2 == 0) 255 else 0;
    }
    const path = try tmpPath("sidecar-test-3f8a1c.png");
    defer alloc.free(path);
    defer removeFile(path);
    try std.Io.Dir.cwd().createDirPath(io, harness.generated_dir);
    try harness.writeSidecarPng(path, &bytes, w, h);
    try std.Io.Dir.cwd().access(io, path, .{});

    const img = try image_io.readRgba(alloc, path);
    defer alloc.free(img.rgba);
    try std.testing.expectEqual(w, img.width);
    try std.testing.expectEqual(h, img.height);
    const back = img.rgba;
    for (0..w * h) |i| {
        if (i % 2 == 0) {
            // Present: the writer must carry the exact input channels
            // through, in order; each channel's value here is distinct,
            // which is what catches a dropped or swapped one.
            try std.testing.expectEqualSlices(u8, bytes[i * 4 ..][0..3], back[i * 4 ..][0..3]);
        } else {
            // Absent: the presence byte must be honoured, not ignored; a
            // writer that copied RGB verbatim regardless of alpha would still
            // pass every other assertion here.
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, back[i * 4 ..][0..3]);
        }
    }

    // The names must differ or the two dumps overwrite each other and the
    // comparison silently becomes one image against itself.
    const a = try harness.pngPath(alloc, "x", 1, 4, false);
    defer alloc.free(a);
    const b = try harness.pngPath(alloc, "x", 1, 4, true);
    defer alloc.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
