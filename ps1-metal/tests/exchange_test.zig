//! The exchange between the emulator thread and the render thread: the
//! triple-buffered shadow and the newest display mode. No Metal.

const std = @import("std");
const metal = @import("ps1_metal");

const Exchange = metal.frame_exchange.Exchange;
const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn publish(x: *Exchange, seq: u64, pixel: u16, depth: bool) void {
    const slot = x.shadowBack();
    @memset(&slot.pixels, pixel);
    slot.depth_valid = depth;
    slot.seq = seq;
    x.publishShadow();
}

test "Exchange: theReaderSeesTheNewestPublishedShadow" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    publish(x, 1, 0x1111, false);
    publish(x, 2, 0x2222, false);
    const s = x.acquireShadow().?;
    try expectEqual(2, s.seq);
    try expectEqual(0x2222, s.pixels[0]);
}

test "Exchange: theProducerNeverWritesTheSlotTheReaderHolds" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    publish(x, 1, 0x1111, false);
    const held = x.acquireShadow().?;
    publish(x, 2, 0xFFFF, false);
    publish(x, 3, 0xFFFF, false);
    try expectEqual(0x1111, held.pixels[0]);
    try expectEqual(1, held.seq);
    try expectEqual(1, x.heldShadow().?.seq);
}

test "Exchange: aReaderThatAcquiresTwiceWithoutAPublishKeepsItsSlot" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    publish(x, 1, 0x1111, false);
    const a = x.acquireShadow().?;
    const b = x.acquireShadow().?;
    try expect(a.pixels == b.pixels);
    try expectEqual(1, b.seq);
}

test "Exchange: nothingIsAcquiredBeforeTheFirstPublish" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    try expectEqual(null, x.acquireShadow());
    try expectEqual(null, x.heldShadow());
}

test "Exchange: theDepthPlaneTravelsWithItsSlot" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    publish(x, 1, 0, false);
    try expectEqual(null, x.acquireShadow().?.depth);
    publish(x, 2, 0, true);
    const s = x.acquireShadow().?;
    try expect(s.depth != null);
    try expectEqual(2, s.seq);
}

test "Exchange: theNewestDisplayIsWhatWasLastPublished" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    try expectEqual(false, x.newestDisplay().enabled);
    x.publishDisplay(.{ .vram_x = 320, .width = 256, .height = 240, .enabled = true });
    try expectEqual(320, x.newestDisplay().vram_x);
}

const Torn = struct {
    x: *Exchange,
    done: std.atomic.Value(bool) = .init(false),

    fn produce(self: *Torn) void {
        for (1..10_001) |i| publish(self.x, i, @truncate(i), false);
        self.done.store(true, .release);
    }
};

test "Exchange: aThreadedPublisherAndReaderNeverTear" {
    const x = try Exchange.init(alloc);
    defer x.deinit();
    var t: Torn = .{ .x = x };
    const th = try std.Thread.spawn(.{}, Torn.produce, .{&t});
    var checked: usize = 0;
    var last: u64 = 0;
    while (true) {
        const finished = t.done.load(.acquire);
        if (x.acquireShadow()) |s| {
            const want: u16 = @truncate(s.seq);
            try expect(std.mem.allEqual(u16, s.pixels, want));
            try expect(s.seq >= last);
            last = s.seq;
            checked += 1;
        }
        if (finished) break;
    }
    th.join();
    try expectEqual(10_000, x.acquireShadow().?.seq);
    try expect(checked > 0);
}
