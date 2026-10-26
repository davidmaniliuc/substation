//! The live renderer above 1x: the drain keeps downsample-invariance, and a
//! dropped frame is answered by scale. The render thread's half (settings,
//! resyncs, presents) is `frame_renderer_test.zig`.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const LiveRenderer = ps1_metal.live_renderer.LiveRenderer;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const native_pixels = lh.native_pixels;
const check = harness.check;

fn drainFillsAndACopy(live: *LiveRenderer) !void {
    const q = try lh.queue();
    defer q.deinit();
    lh.publish(q, 1, &.{
        lh.fillRect(7, 11, 33, 17, 0x03E0),
        lh.fillRect(40, 11, 20, 20, 0x7C00),
    });
    lh.publish(q, 2, &.{lh.copyRect(7, 11, 200, 300, 33, 17)});
    var shadow: lh.Shadow = .{};
    live.drain(q, &shadow);
}

test "LiveRenderer: aLiveDrainAtScaleMatchesTheOneXReplayOfTheSameStream" {
    // Phase C's downsample-invariance property, re-run through the LIVE path
    // rather than the fixture harness: the queue, the resync decision and the
    // persistent buffers are all in the picture here and are not in the scale
    // harness's.
    //
    // Fills and a VRAM->VRAM copy: both are exactly scale-invariant, and the
    // copy is the one read Phase C does NOT reduce to native (it carries
    // sub_x/sub_y so a blit preserves scaled detail), so it is worth having on
    // this path. Deliberately no Gouraud shading: a dither mode sampled per
    // subtexel legitimately differs, and the native mode's invariance is
    // pinned on the fixture corpus rather than on two fills.
    const m = try harness.metal();
    defer m.deinit();

    const one = try lh.make(m, 1, false);
    defer one.deinit();
    try drainFillsAndACopy(one);
    const reference = try lh.readback(one);
    defer alloc.destroy(reference);
    try check(harness.painted(reference) > 0, "the stream painted nothing", .{});

    for (harness.scale_ladder) |scale| {
        const many = try lh.make(m, scale, false);
        defer many.deinit();
        try drainFillsAndACopy(many);
        const got = try lh.readback(many);
        defer alloc.destroy(got);
        try check(std.mem.eql(u16, got, reference), "scale {d}: native view differs from 1x", .{scale});
        try expectEqual(2, many.last_executed_seq);
    }
}

// A frame the producer could not enqueue at all is a LOST frame, not a
// texture that has come loose from reality. Those are two conditions with two
// remedies, and answering the first with the second is what put a 1x picture
// on screen at 8x: the shadow is a NATIVE image, so adopting it replicates
// each pixel N x N and the whole picture collapses to nearest-neighbour 1x
// until the game redraws it.
test "LiveRenderer: aDroppedFrameKeepsTheScaledPictureRatherThanCollapsingToOneX" {
    const m = try harness.metal();
    defer m.deinit();
    const red = try lh.image(0x7C00);
    defer alloc.destroy(red);

    for (harness.scale_ladder) |scale| {
        const live = try lh.make(m, scale, false);
        defer live.deinit();
        const q = try lh.queue();
        defer q.deinit();

        // A picture on the texture, executed the ordinary way.
        lh.fill(q, 1, 0, 0, 0x001F);
        var unused: lh.Shadow = .{};
        live.drain(q, &unused);
        try check(try lh.pixelAt(live, 0) == 0x001F, "scale {d}: the fill did not land", .{scale});

        lh.lose(q, 2);
        var shadow: lh.Shadow = .{ .pixels = red, .seq = 2 };
        live.drain(q, &shadow);

        // Still ours, not the shadow's red.
        try check(try lh.pixelAt(live, 0) == 0x001F, "scale {d}: the shadow was adopted", .{scale});
        // And the 1 MB copy was never even built: above 1x there is nothing
        // the shadow can be used for on this path.
        try check(shadow.calls == 0, "scale {d}: the shadow was built", .{scale});
    }
}

// The 1x control, and not symmetry for its own sake: at scale 1
// `uploadNative` IS `upload`, so adopting the shadow costs one upload and is
// byte-exact. That exactness is what `PS1_LIVE_DIFF` at 1x is, and the
// default scale must not opt out of the only oracle that covers real games.
test "LiveRenderer: aDroppedFrameStillAdoptsTheShadowAtOneX" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    lh.fill(q, 1, 0, 0, 0x001F);
    var unused: lh.Shadow = .{};
    live.drain(q, &unused);

    lh.lose(q, 2);
    const red = try lh.image(0x7C00);
    defer alloc.destroy(red);
    var shadow: lh.Shadow = .{ .pixels = red, .seq = 2 };
    live.drain(q, &shadow);

    try expectEqual(0x7C00, try lh.pixelAt(live, 0));
    try expectEqual(2, live.last_executed_seq);
}

// The condition the skip must NOT swallow. A rebuilt `MetalVram` is a BLANK
// texture (a scale change, a disc change, the first view), and there is no
// picture there to preserve. Skipping here leaves the window black until
// something repaints all of VRAM, which for a static backdrop is never.
test "LiveRenderer: aHardResyncStillAdoptsTheShadowAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    const img = try lh.image(0);
    defer alloc.destroy(img);
    img[0] = 0x03E0;

    for ([_]u32{ 1, 2, 3, 4, 8 }) |scale| {
        const live = try lh.make(m, scale, false);
        defer live.deinit();
        const q = try ps1_metal.stream_queue.StreamQueue.init(alloc);
        defer q.deinit();
        q.requestResync();

        var shadow: lh.Shadow = .{ .pixels = img, .seq = 9 };
        live.drain(q, &shadow);

        try check(try lh.pixelAt(live, 0) == 0x03E0, "scale {d}: the shadow was not adopted", .{scale});
        try check(live.last_executed_seq == 9, "scale {d}: seq {d}", .{ scale, live.last_executed_seq });
    }
}

// A resync while depth is on adopts the shadow's depth plane too. Without it
// the next frame depth-tests against a blank plane and a far polygon covers
// a near one the software rasterizer kept hidden.
test "LiveRenderer: aResyncAdoptsTheDepthPlane" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, true);
    defer live.deinit();
    const q = try ps1_metal.stream_queue.StreamQueue.init(alloc);
    defer q.deinit();

    const plane = try alloc.create([native_pixels]u32);
    defer alloc.destroy(plane);
    @memset(plane, 0);
    for (0..100) |y| for (0..100) |x| {
        plane[y * lh.native_width + x] = 1_000_000; // near
    };
    // A FAR depth-tested triangle over that region, published as frame 2. The
    // queue is fresh, so the drain adopts the shadow at seq 1 first and then
    // executes seq 2 against the adopted plane.
    const far = harness.depthTestedTriangle(0x7FFF, .{ 10, 90, 10 }, .{ 1000, 1000, 1001 });
    lh.publish(q, 2, &.{ harness.fullDrawingArea(), far });
    var shadow: lh.Shadow = .{ .depth = plane, .seq = 1 };
    live.drain(q, &shadow);
    // Hidden: the plane came across.
    try expectEqual(0, try lh.pixelAt(live, 50 * lh.native_width + 20));
}

// Keeping the scaled picture across a dropped frame is only half a policy:
// the frame's mutations have to be REPAIRED too. A texture page, a CLUT and a
// VRAM->VRAM copy are uploaded ONCE and sampled by every frame after; FF7's
// main menu opens with a single 256x3 palette upload at (256, 493) and every
// frame after it carries 197 textured rectangles and zero payload words, so
// losing that one frame draws the menu text through a stale CLUT for as long
// as it stays open. The repair is DEFERRED, not abandoned: skipped while
// frames are still being lost (re-adopting into a sustained deficit is the
// 8x/1x flicker coming straight back), taken on the first drain that loses
// none, and taken once.
test "LiveRenderer: aLostFramesMutationIsRepairedOnceTheDropsStop" {
    const m = try harness.metal();
    defer m.deinit();
    const img = try lh.image(0);
    defer alloc.destroy(img);
    img[0] = 0x7C00;

    for (harness.scale_ladder) |scale| {
        const live = try lh.make(m, scale, false);
        defer live.deinit();
        const q = try lh.queue();
        defer q.deinit();

        lh.fill(q, 1, 0, 0, 0x001F);
        var unused: lh.Shadow = .{};
        live.drain(q, &unused);

        // The frame that never arrived. Stands for FF7's palette upload: its
        // mutation appears in no later stream, so executing what follows can
        // never put it back.
        lh.lose(q, 2);

        // The drain that observes the drop keeps the scaled picture, exactly
        // as before: the flicker fix is not being undone here.
        var shadow: lh.Shadow = .{ .pixels = img, .seq = 2 };
        live.drain(q, &shadow);
        try check(try lh.pixelAt(live, 0) == 0x001F, "scale {d}: adopted on the drop", .{scale});
        try check(shadow.calls == 0, "scale {d}: built on the drop", .{scale});

        // The next one loses nothing, so the debt is settled.
        live.drain(q, &shadow);
        try check(shadow.calls == 1, "scale {d}: {d} samples after the drops stopped", .{ scale, shadow.calls });
        try check(try lh.pixelAt(live, 0) == 0x7C00, "scale {d}: the debt was not settled", .{scale});
        try check(live.last_executed_seq == 2, "scale {d}: seq {d}", .{ scale, live.last_executed_seq });

        // And settled ONCE: a debt that never clears re-adopts a native
        // shadow every frame, which is the collapse under another name.
        live.drain(q, &shadow);
        try check(shadow.calls == 1, "scale {d}: the debt was settled twice", .{scale});
    }
}

/// Fills and a copy as frames 3 and 4, drained after a resync against a
/// blank shadow sampled at seq 2: what the first drain after a rebuild sees.
fn drainAfterAResync(live: *LiveRenderer, q: *ps1_metal.stream_queue.StreamQueue) !void {
    q.requestResync();
    lh.publish(q, 3, &.{
        lh.fillRect(7, 11, 33, 17, 0x03E0),
        lh.fillRect(40, 11, 20, 20, 0x7C00),
    });
    lh.publish(q, 4, &.{lh.copyRect(7, 11, 200, 300, 33, 17)});
    var shadow: lh.Shadow = .{ .seq = 2 };
    live.drain(q, &shadow);
}

// A scale change rebuilds the VRAM and nothing else: the pipelines stay the
// ones the session built, and the rebuilt renderer is indistinguishable from
// one built at that scale in the first place.
test "LiveRenderer: aRebuildAtANewScaleMatchesAFreshRendererAtThatScale" {
    const m = try harness.metal();
    defer m.deinit();
    var set = try lh.pipelineSet(m);
    defer set.deinit();

    // Frames 1 and 2 paint the 1x texture, which the rebuild then throws away.
    const rebuilt = try LiveRenderer.init(alloc, m, &set, 1, false, .{});
    defer rebuilt.deinit();
    const q = try lh.queue();
    defer q.deinit();
    lh.fill(q, 1, 500, 300, 0x001F);
    lh.fill(q, 2, 600, 300, 0x001F);
    var before: lh.Shadow = .{};
    rebuilt.drain(q, &before);
    try rebuilt.rebuildVram(3, false);
    try expectEqual(3, rebuilt.vram.scale);
    try drainAfterAResync(rebuilt, q);

    const fresh = try LiveRenderer.init(alloc, m, &set, 3, false, .{});
    defer fresh.deinit();
    const q2 = try lh.queue();
    defer q2.deinit();
    try drainAfterAResync(fresh, q2);

    const a = try lh.readback(rebuilt);
    defer alloc.destroy(a);
    const b = try lh.readback(fresh);
    defer alloc.destroy(b);
    try check(harness.painted(a) > 0, "the stream painted nothing", .{});
    try check(std.mem.eql(u16, a, b), "the rebuilt renderer differs from a fresh one at 3x", .{});
    try expectEqual(4, rebuilt.last_executed_seq);
    try expect(rebuilt.rasterizer.pipelines == &set);
    try expect(fresh.rasterizer.pipelines == &set);
}

test "LiveRenderer: aRebuildBuildsNoPipelines" {
    const m = try harness.metal();
    defer m.deinit();
    var set = try lh.pipelineSet(m);
    defer set.deinit();

    const live = try LiveRenderer.init(alloc, m, &set, 1, false, .{});
    defer live.deinit();
    const count = set.variantCount();
    const first = set.prims[0][0][0].id;
    try live.rebuildVram(2, true);
    try live.rebuildVram(4, false);
    try expectEqual(count, set.variantCount());
    try expectEqual(first, set.prims[0][0][0].id);
    try expectEqual(first, live.rasterizer.pipelines.prims[0][0][0].id);
}
