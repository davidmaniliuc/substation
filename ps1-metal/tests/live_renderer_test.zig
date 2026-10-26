//! The live renderer's resync rules and its divergence oracle, offscreen,
//! plus the long-session leak check (Review Focus 1) over the live path.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const StreamQueue = ps1_metal.stream_queue.StreamQueue;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const native_pixels = lh.native_pixels;

test "LiveRenderer: drainExecutesEveryQueuedFrameInOrder" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    // Two fills at the SAME place with different colours: only the later one
    // survives, so the final pixel proves the ORDER, not merely that both ran.
    lh.fill(q, 1, 0, 0, 0x001F);
    lh.fill(q, 2, 0, 0, 0x7C00);

    var shadow: lh.Shadow = .{};
    live.drain(q, &shadow);

    try expectEqual(0x7C00, try lh.pixelAt(live, 0));
    try expectEqual(2, live.last_executed_seq);
}

test "LiveRenderer: drainSkippedFramesAreExecutedNotDropped" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    // Distinct places: if drain took only the newest, the first fill's pixels
    // would never appear. A command stream is incremental, so execution may
    // never skip; only presentation may.
    lh.fill(q, 1, 0, 0, 0x001F);
    lh.fill(q, 2, 64, 0, 0x7C00);

    var shadow: lh.Shadow = .{};
    live.drain(q, &shadow);

    const back = try lh.readback(live);
    defer alloc.destroy(back);
    try expectEqual(0x001F, back[0]);
    try expectEqual(0x7C00, back[64]);
}

test "LiveRenderer: aFrameAlreadyFoldedIntoTheShadowIsDiscardedNotReplayed" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    lh.fill(q, 1, 0, 0, 0x001F);
    q.requestResync();

    const img = try lh.image(0);
    defer alloc.destroy(img);
    img[0] = 0x03E0;
    img[native_pixels - 1] = 0x7FFF;
    var shadow: lh.Shadow = .{ .pixels = img, .seq = 1 };
    live.drain(q, &shadow);

    const back = try lh.readback(live);
    defer alloc.destroy(back);
    // The upload happens BEFORE the drain, so this pixel separates the two
    // cases outright: discarded leaves the shadow's green, replayed paints
    // the fill's blue on top of it. Replaying is not a cosmetic waste:
    // VRAM->VRAM copies, semi-transparent blends and mask-bit draws are not
    // idempotent, so a second application is permanent corruption.
    try expectEqual(0x03E0, back[0]);
    try expectEqual(0x7FFF, back[native_pixels - 1]);
    try expectEqual(0, q.pendingCount());
    try expect(!q.needsResync());
}

test "LiveRenderer: aFrameNEWERThanTheShadowSurvivesTheResyncAndExecutes" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    // The producer publishes VRAM before the stream, so a stream can be newer
    // than the newest shadow. Discarding the whole backlog loses its mutations
    // for good: a command stream is incremental, and nothing replays it.
    lh.fill(q, 1, 0, 0, 0x001F);
    lh.fill(q, 2, 64, 0, 0x7C00);
    q.requestResync();

    const img = try lh.image(0);
    defer alloc.destroy(img);
    img[0] = 0x03E0;
    var shadow: lh.Shadow = .{ .pixels = img, .seq = 1 };
    live.drain(q, &shadow);

    const back = try lh.readback(live);
    defer alloc.destroy(back);
    try expectEqual(0x03E0, back[0]);
    try expectEqual(0x7C00, back[64]);
    try expectEqual(2, live.last_executed_seq);
    try expect(!q.needsResync());
}

test "LiveRenderer: theTextureAdoptsTheSampledFramesSeq" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    q.requestResync();

    // After an upload the texture IS that frame, so the oracle must be able to
    // compare against it. Leaving the seq behind makes every post-resync frame
    // an unexplained skip.
    var shadow: lh.Shadow = .{ .seq = 7 };
    live.drain(q, &shadow);
    try expectEqual(7, live.last_executed_seq);
}

test "LiveRenderer: aHoleBetweenTheShadowAndTheQueueLeavesTheResyncRaised" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    // Frame 2 never reached the queue (a full ring drops it at the producer),
    // so what survives cannot be replayed onto a matching base. Execute it to
    // keep moving, but leave the flag up so the next draw adopts a shadow that
    // covers the hole.
    lh.fill(q, 3, 64, 0, 0x7C00);
    q.requestResync();

    var shadow: lh.Shadow = .{ .seq = 1 };
    live.drain(q, &shadow);

    try expectEqual(0x7C00, try lh.pixelAt(live, 64));
    try expect(q.needsResync());
}

test "LiveRenderer: aResyncRaisedWhileTheShadowIsSampledIsNotSwallowed" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    q.requestResync();

    // clearResync is a store, not a compare-and-clear. Clearing AFTER the
    // sample drops a request the producer raised in between, and the frame
    // that raised it was never enqueued, so its mutations are lost for good.
    var shadow: lh.Shadow = .{ .seq = 1, .raise_on = q };
    live.drain(q, &shadow);
    try expect(q.needsResync());
}

// The producer publishes a shadow only when something reads it, so the newest
// can predate frames the texture already executed. Those frames have left the
// queue: adopting that shadow would lose them for good.
test "LiveRenderer: aRepairWaitsForAShadowNewerThanWhatItExecuted" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    lh.fill(q, 1, 0, 0, 0x001F);
    lh.fill(q, 2, 64, 0, 0x7C00);
    var unused: lh.Shadow = .{};
    live.drain(q, &unused);
    _ = q.wantsShadow();

    const stale = try lh.image(0);
    defer alloc.destroy(stale);
    stale[0] = 0x03E0;
    q.noteDroppedFrame();
    lh.fill(q, 4, 128, 0, 0x03E0);
    var old: lh.Shadow = .{ .pixels = stale, .seq = 1 };
    live.drain(q, &old);

    // Refused: the texture keeps frame 2, executes frame 4 and asks for more.
    const back = try lh.readback(live);
    defer alloc.destroy(back);
    try expectEqual(0x001F, back[0]);
    try expectEqual(0x7C00, back[64]);
    try expectEqual(0x03E0, back[128]);
    try expect(q.wantsShadow());

    // The debt is still owed, and a shadow from the next frame settles it.
    const fresh = try lh.image(0);
    defer alloc.destroy(fresh);
    fresh[0] = 0x7FFF;
    var newer: lh.Shadow = .{ .pixels = fresh, .seq = 5 };
    live.drain(q, &newer);
    try expectEqual(0x7FFF, try lh.pixelAt(live, 0));
    try expectEqual(5, live.last_executed_seq);
}

// The resync form of the same rule. The texture is not a picture of anything,
// so the queue is dropped rather than replayed onto it; the producer's next
// shadow folds it in, because it publishes one with every frame while the
// flag is up.
test "LiveRenderer: aResyncWaitsForAShadowNewerThanWhatItExecuted" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    lh.fill(q, 1, 0, 0, 0x001F);
    var unused: lh.Shadow = .{};
    live.drain(q, &unused);

    q.requestResync();
    lh.fill(q, 2, 64, 0, 0x7C00);
    const green = try lh.image(0x03E0);
    defer alloc.destroy(green);
    var old: lh.Shadow = .{ .pixels = green, .seq = 0 };
    live.drain(q, &old);

    const back = try lh.readback(live);
    defer alloc.destroy(back);
    try expectEqual(0x001F, back[0]);
    try expect(back[64] != 0x7C00);
    try expect(q.needsResync());
    try expectEqual(0, q.pendingCount());

    const fresh = try lh.image(0);
    defer alloc.destroy(fresh);
    fresh[64] = 0x7FFF;
    var newer: lh.Shadow = .{ .pixels = fresh, .seq = 3 };
    live.drain(q, &newer);
    try expectEqual(0x7FFF, try lh.pixelAt(live, 64));
    try expect(!q.needsResync());
}

test "LiveRenderer: theProducerIsAskedForAShadowOnlyWhenOneIsNeeded" {
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    // A fresh queue resyncs, and a resync asks for a shadow every frame.
    try expect(q.wantsShadow());
    try expect(q.wantsShadow());
    q.clearResync();
    try expect(!q.wantsShadow());

    // A request is answered by one shadow.
    q.requestShadow();
    try expect(q.wantsShadow());
    try expect(!q.wantsShadow());

    // A drop stays wanted until the consumer takes it.
    q.noteDroppedFrame();
    try expect(q.wantsShadow());
    try expect(q.wantsShadow());
    _ = q.takeDroppedFrames();
    try expect(!q.wantsShadow());
}

test "LiveRenderer: theShadowClosureIsNotCalledOnTheOrdinaryPath" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();
    lh.fill(q, 1, 0, 0, 0x001F);

    // Building the shadow array is a 1 MB copy. It belongs behind a call the
    // common path never makes.
    var shadow: lh.Shadow = .{ .seq = 1 };
    live.drain(q, &shadow);
    try expectEqual(0, shadow.calls);
}

/// A live renderer that has executed one 16x16 fill of `color` as frame `seq`.
fn oneFill(m: harness.Metal, seq: u64, color: u32) !*ps1_metal.live_renderer.LiveRenderer {
    const live = try lh.make(m, 1, false);
    errdefer live.deinit();
    const q = try lh.queue();
    defer q.deinit();
    lh.fill(q, seq, 0, 0, color);
    var unused: lh.Shadow = .{};
    live.drain(q, &unused);
    return live;
}

/// A native image holding a 16x16 box of `color` at the origin.
fn boxImage(color: u16) !*[native_pixels]u16 {
    const img = try lh.image(0);
    for (0..16) |y| for (0..16) |x| {
        img[y * lh.native_width + x] = color;
    };
    return img;
}

test "LiveRenderer: theDiffIsSilentWhenTheTextureMatchesTheShadow" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try oneFill(m, 1, 0x001F);
    defer live.deinit();

    const img = try boxImage(0x001F);
    defer alloc.destroy(img);
    var shadow: lh.DiffShadow = .{ .image = img };
    try expectEqual(null, live.diff(1, &shadow));
}

test "LiveRenderer: theDiffNamesTheFrameAndTheFirstDifferingPixel" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try oneFill(m, 3, 0x001F);
    defer live.deinit();

    // Right shape, wrong colour: 256 pixels differ, the first at (0, 0).
    const img = try boxImage(0x7C00);
    defer alloc.destroy(img);
    var shadow: lh.DiffShadow = .{ .image = img };
    const report = live.diff(3, &shadow) orelse return error.TestExpectedReport;
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{report});
    try expect(std.mem.indexOf(u8, text, "seq 3") != null);
    try expect(std.mem.indexOf(u8, text, "256") != null);
    try expect(std.mem.indexOf(u8, text, "(0, 0)") != null);
    try std.testing.expectEqualStrings(
        "PS1_LIVE_DIFF: seq 3 diverged; 256 pixels, first at (0, 0) gpu=0x1F shadow=0x7C00",
        text,
    );
}

test "LiveRenderer: theDiffRefusesToCompareTwoDifferentInstants" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try oneFill(m, 1, 0x001F);
    defer live.deinit();

    // The shadow is from frame 9; the texture holds frame 1. Comparing them
    // would report a divergence on every frame the emulator runs ahead, which
    // is exactly the noise that would make the oracle useless.
    var shadow: lh.DiffShadow = .{ .image = &lh.blank };
    try expectEqual(null, live.diff(9, &shadow));
}

test "LiveRenderer: theDiffCountsWhatItComparedAndWhatItDeclinedTo" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try oneFill(m, 1, 0x001F);
    defer live.deinit();

    const img = try boxImage(0x001F);
    defer alloc.destroy(img);
    var shadow: lh.DiffShadow = .{ .image = img };
    _ = live.diff(1, &shadow); // the texture holds frame 1
    _ = live.diff(9, &shadow); // the emulator has run ahead

    // Without this, a run that skipped every frame is indistinguishable from a
    // run in which every frame matched: both print nothing. Only the second
    // is evidence, and the play-through gate rests entirely on the difference.
    try expectEqual(1, live.diff_checked);
    try expectEqual(1, live.diff_skipped);
    var buf: [128]u8 = undefined;
    const summary = try live.diffSummary(&buf);
    try expect(std.mem.indexOf(u8, summary, "checked 1") != null);
    try expect(std.mem.indexOf(u8, summary, "skipped 1") != null);
}

test "LiveRenderer: theShadowIsNotBuiltForAFrameTheOracleWillSkip" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try oneFill(m, 1, 0x001F);
    defer live.deinit();

    // Most frames ARE skipped: the diff runs after a drain that blocks on the
    // GPU, so the emulator routinely publishes past the texture in that window.
    // Paying a 1 MB copy for each of those is a cost the seq check can decide
    // its way out of first.
    var shadow: lh.DiffShadow = .{ .image = &lh.blank };
    _ = live.diff(9, &shadow);
    try expectEqual(0, shadow.calls);
    try expectEqual(1, live.diff_skipped);
}

// Review Focus 1: a long session leaks GPU memory if the live path forgets a
// `release` or creates autoreleased objects outside a pool. Three passes of
// the corpus through StreamQueue publish and drain, a pool per frame as the
// render thread will push, must leave the device's allocation where the
// first pass left it.
test "LiveRenderer: drainingTheCorpusThreeTimesDoesNotGrowTheDevicesAllocation" {
    const m = try harness.metal();
    defer m.deinit();
    const names = try harness.corpus(alloc);
    defer harness.freeCorpus(alloc, names);

    var drained: usize = 0;
    var after: [3]usize = undefined;
    for (&after) |*slot| {
        for (names) |name| {
            const parsed = harness.loadFixture(alloc, name) catch |err| switch (err) {
                error.SkipZigTest => continue,
                else => return err,
            };
            defer parsed.deinit(alloc);
            const live = try lh.make(m, 1, harness.carriesDepth(parsed));
            defer live.deinit();
            const q = try lh.queue();
            defer q.deinit();
            for (0..parsed.frames.len) |i| {
                const pool = objc.Pool.push();
                defer pool.pop();
                q.publish(i + 1, parsed.frameStream(i));
                var shadow: lh.Shadow = .{};
                live.drain(q, &shadow);
                drained += 1;
            }
        }
        slot.* = m.device.currentAllocatedSize();
    }
    if (drained == 0) {
        std.debug.print("no fixture in the corpus; run `zig build fixtures -Doptimize=ReleaseFast`\n", .{});
        return error.SkipZigTest;
    }
    std.debug.print("[leak] live drain, device allocation after each pass: {d} / {d} / {d} bytes ({d} frames)\n", .{ after[0], after[1], after[2], drained });
    try expect(after[2] <= after[0] + (1 << 20));
}

test "LiveRenderer: aReadbackMidChunkSeesTheChunksOwnEarlierDraws" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();
    var shadow: lh.Shadow = .{};

    q.publishChunk(1, .{ .records = &.{lh.fillRect(0, 0, 16, 16, 0x001F)}, .payload = &.{}, .complete = true });
    live.drain(q, &shadow);
    try expectEqual(0x001F, try lh.pixelAt(live, 0));
    try expect(live.mid_frame);
    try expectEqual(0, live.last_executed_seq);

    lh.fill(q, 1, 0, 0, 0x7C00);
    live.drain(q, &shadow);
    try expect(!live.mid_frame);
    try expectEqual(1, live.last_executed_seq);
}

test "LiveRenderer: aSeqIsConsumedOnlyByItsFinalChunk" {
    const m = try harness.metal();
    defer m.deinit();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();
    var shadow: lh.Shadow = .{};

    q.publishChunk(1, .{ .records = &.{lh.fillRect(0, 0, 16, 16, 0x001F)}, .payload = &.{}, .complete = true });
    live.drain(q, &shadow);
    try expectEqual(0, live.consumed_seq);
    lh.fill(q, 1, 0, 0, 0x7C00);
    live.drain(q, &shadow);
    try expectEqual(1, live.consumed_seq);
}
