//! Rewind captures under GPU-only, against a scripted ring and machine:
//! filled oldest first, dropped newest first, and no ring slot left behind.

const std = @import("std");
const session = @import("ps1_session");
const FakeMachine = @import("fake_machine.zig").FakeMachine;
const native_pixels = @import("ps1_metal").prim_instance.native_pixels;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Three slots the test resolves by hand.
const FakeRing = struct {
    pub const slots = 3;
    pub const Poll = union(enum) { pending, ready: *const [native_pixels]u16, failed };
    const State = enum { free, pending, ready, failed };

    state: [slots]State = @splat(.free),
    seq: [slots]u64 = @splat(0),
    pixels: [native_pixels]u16 = @splat(0),

    pub fn request(self: *FakeRing, seq: u64) ?u32 {
        for (&self.state, 0..) |*s, i| if (s.* == .free) {
            s.* = .pending;
            self.seq[i] = seq;
            return @intCast(i);
        };
        return null;
    }

    pub fn poll(self: *FakeRing, i: u32) Poll {
        return switch (self.state[i]) {
            .pending => .pending,
            .ready => .{ .ready = &self.pixels },
            .failed => .failed,
            .free => @panic("FakeRing.poll: a free slot"),
        };
    }

    pub fn release(self: *FakeRing, i: u32) void {
        self.state[i] = .free;
    }

    /// The slot waiting for `seq`.
    fn slotOf(self: *const FakeRing, seq: u64) usize {
        for (self.state, self.seq, 0..) |s, q, i| if (s != .free and q == seq) return i;
        @panic("FakeRing: no slot for that seq");
    }

    fn resolve(self: *FakeRing, seq: u64, to: State) void {
        self.state[self.slotOf(seq)] = to;
    }

    fn free(self: *const FakeRing) usize {
        var n: usize = 0;
        for (self.state) |s| n += @intFromBool(s == .free);
        return n;
    }
};

const Rig = struct {
    m: FakeMachine,
    ring: FakeRing = .{},
    rv: session.rewind_vram.RewindVram(FakeRing) = .{},
    seq: u64 = 0,

    /// A frame whose rewind capture is now pending.
    fn capture(r: *Rig) void {
        r.seq += 1;
        r.m.captureRewind();
        r.rv.afterFrame(&r.m, &r.ring, r.seq);
    }
};

fn rig() Rig {
    return .{ .m = FakeMachine.init(alloc) };
}

test "RewindVram: aReadyCaptureIsFilledOldestFirst" {
    var r = rig();
    defer r.m.deinit();
    r.capture();
    r.capture();
    r.ring.resolve(1, .ready);
    r.ring.resolve(2, .ready);
    r.rv.collect(&r.m, &r.ring);
    try expectEqual(0, r.m.filled.items[0]);
    try expectEqual(1, r.m.filled.items[1]);
    try expect(r.m.rewindPendingVram() == null);
    try expectEqual(3, r.ring.free());
}

test "RewindVram: collectStopsAtTheFirstPendingCapture" {
    var r = rig();
    defer r.m.deinit();
    r.capture();
    r.capture();
    r.ring.resolve(2, .ready);
    r.rv.collect(&r.m, &r.ring);
    try expectEqual(0, r.m.filled.items.len);
    try expectEqual(1, r.ring.free());
    r.ring.resolve(1, .ready);
    r.rv.collect(&r.m, &r.ring);
    try expectEqual(2, r.m.filled.items.len);
    try expectEqual(3, r.ring.free());
}

test "RewindVram: aFullRingDropsOnlyTheNewestCapture" {
    var r = rig();
    defer r.m.deinit();
    for (0..4) |_| r.capture();
    const p = r.m.rewindPendingVram().?;
    try expectEqual(0, p.first);
    try expectEqual(2, p.last);
    try expectEqual(0, r.ring.free());
    try expectEqual(1, r.m.count("rewindDropVramFrom"));
}

test "RewindVram: aFailedCaptureDropsItAndEveryNewerOneAndReleasesTheirSlots" {
    var r = rig();
    defer r.m.deinit();
    for (0..3) |_| r.capture();
    r.ring.resolve(1, .ready);
    r.ring.resolve(2, .failed);
    r.rv.collect(&r.m, &r.ring);
    try expectEqual(1, r.m.filled.items.len);
    try expect(r.m.rewindPendingVram() == null);
    try expectEqual(3, r.ring.free());
    // The next capture takes a slot again.
    r.capture();
    try expectEqual(2, r.ring.free());
}

test "RewindVram: aClearedHistoryReleasesEveryRingSlot" {
    var r = rig();
    defer r.m.deinit();
    r.capture();
    r.capture();
    r.m.clearRewind();
    r.rv.collect(&r.m, &r.ring);
    try expectEqual(3, r.ring.free());
    try expectEqual(0, r.m.filled.items.len);
}

test "RewindVram: abandonReleasesEverySlot" {
    var r = rig();
    defer r.m.deinit();
    r.capture();
    r.capture();
    r.rv.abandon(&r.ring);
    try expectEqual(3, r.ring.free());
}
