//! The audio path's arithmetic: the ring, the gain, the tempo, reversed
//! rewind audio, the water marks and the mixer the CoreAudio callbacks call.
//! Ported from AudioRingTests, AudioGainTests, TempoControlTests,
//! RewindAudioTests and the water-mark cases of SpeedSettingTests.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");

const pacing = session.pacing;
const AudioRing = session.audio_ring.AudioRing;
const Tempo = session.tempo.Tempo;
const Mixer = session.mixer.Mixer;
const Stretch = session.mixer.Stretch;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

fn ring(capacity: usize) !AudioRing {
    return AudioRing.init(alloc, capacity);
}

fn read(r: *AudioRing, comptime n: usize) struct { buf: [n]f32, len: usize } {
    var out: [n]f32 = @splat(std.math.nan(f32));
    const got = r.read(&out);
    return .{ .buf = out, .len = got };
}

// AudioRingTests

test "AudioRing: startsEmpty" {
    var r = try ring(8);
    defer r.deinit();
    try expectEqual(0, r.filled());
    try expectEqual(8, r.freeSpace());
}

test "AudioRing: writeThenReadRoundTrips" {
    var r = try ring(8);
    defer r.deinit();
    try expectEqual(4, r.write(&.{ 1, 2, 3, 4 }));
    try expectEqual(4, r.filled());
    const got = read(&r, 4);
    try expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, got.buf[0..got.len]);
    try expectEqual(0, r.filled());
}

test "AudioRing: readOfAnEmptyRingReturnsNothing" {
    var r = try ring(8);
    defer r.deinit();
    try expectEqual(0, read(&r, 4).len);
}

test "AudioRing: partialReadLeavesTheRemainder" {
    var r = try ring(8);
    defer r.deinit();
    _ = r.write(&.{ 1, 2, 3, 4 });
    const a = read(&r, 2);
    try expectEqualSlices(f32, &.{ 1, 2 }, a.buf[0..a.len]);
    try expectEqual(2, r.filled());
    const b = read(&r, 2);
    try expectEqualSlices(f32, &.{ 3, 4 }, b.buf[0..b.len]);
}

test "AudioRing: writeIsCappedByFreeSpaceAndNeverOverwrites" {
    var r = try ring(8);
    defer r.deinit();
    try expectEqual(8, r.write(&.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    try expectEqual(0, r.freeSpace());
    try expectEqual(0, r.write(&.{ 9, 10 }));
    const got = read(&r, 8);
    try expectEqualSlices(f32, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, got.buf[0..got.len]);
}

test "AudioRing: wrapsAroundWithoutLosingSamples" {
    var r = try ring(8);
    defer r.deinit();
    _ = r.write(&.{ 1, 2, 3, 4, 5, 6 });
    const a = read(&r, 4);
    try expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, a.buf[0..a.len]);
    try expectEqual(4, r.write(&.{ 7, 8, 9, 10 }));
    const b = read(&r, 6);
    try expectEqualSlices(f32, &.{ 5, 6, 7, 8, 9, 10 }, b.buf[0..b.len]);
    try expectEqual(0, r.filled());
}

test "AudioRing: underrunReadReturnsOnlyWhatIsThere" {
    var r = try ring(8);
    defer r.deinit();
    _ = r.write(&.{ 1, 2 });
    const got = read(&r, 6);
    try expectEqualSlices(f32, &.{ 1, 2 }, got.buf[0..got.len]);
}

test "AudioRing: theCapacityIsRoundedUpToAPowerOfTwo" {
    var r = try ring(5);
    defer r.deinit();
    try expectEqual(8, r.capacity);
}

// AudioGainTests, against the mixer's gain.

fn mixer(r: *AudioRing) Mixer {
    return Mixer.init(r);
}

test "Mixer: aGainSetOnOneSideIsReadBackOnTheOther" {
    var r = try ring(8);
    defer r.deinit();
    var m = mixer(&r);
    m.setGain(0.375);
    try expectEqual(@as(f32, 0.375), m.gain());
}

test "Mixer: aGainOfZeroSilencesTheBuffer" {
    var r = try ring(8);
    defer r.deinit();
    var m = mixer(&r);
    m.setGain(0);
    var samples = [_]f32{ 1, -1, 0.5, -0.25 };
    m.applyGain(&samples);
    try expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &samples);
}

test "Mixer: aFractionalGainScalesEverySample" {
    var r = try ring(8);
    defer r.deinit();
    var m = mixer(&r);
    m.setGain(0.5);
    var samples = [_]f32{ 1, -1, 0.5, -0.25 };
    m.applyGain(&samples);
    try expectEqualSlices(f32, &.{ 0.5, -0.5, 0.25, -0.125 }, &samples);
}

test "Mixer: unityGainLeavesTheSamplesUntouched" {
    var r = try ring(8);
    defer r.deinit();
    var m = mixer(&r);
    m.setGain(1);
    var samples = [_]f32{ 1, -1, 0.5, -0.25 };
    m.applyGain(&samples);
    try expectEqualSlices(f32, &.{ 1, -1, 0.5, -0.25 }, &samples);
}

// TempoControlTests

const full = pacing.waterMarks(4).low;
const empty = pacing.waterMarks(1).low;

test "Tempo: aRingTheCoreKeepsFullStretchesAtTheTarget" {
    try expectEqual(@as(f32, 4), Tempo.rate(4, full));
    try expectEqual(@as(f32, 4), Tempo.rate(4, full * 2));
}

test "Tempo: aDrainedRingFallsBackToRealTime" {
    try expectEqual(@as(f32, 1), Tempo.rate(4, empty));
    try expectEqual(@as(f32, 1), Tempo.rate(4, 0));
}

test "Tempo: theRateRisesWithTheFillBetweenTheTwo" {
    var last: f32 = 0;
    for (0..11) |step| {
        const fill = empty + (full - empty) * step / 10;
        const r = Tempo.rate(4, fill);
        try expect(r >= last);
        try expect(r >= 1 and r <= 4);
        last = r;
    }
}

test "Tempo: smoothingGlidesTowardTheRateRatherThanJumping" {
    var t: Tempo = .{};
    t.reset(1);
    const first = t.step(4);
    try expect(first > 1 and first < 4);
    for (0..500) |_| _ = t.step(4);
    try expect(@abs(t.step(4) - 4) < 0.01);
}

// RewindAudioTests

test "Tempo: rewindAudioReversesStereoFramesAndKeepsEachChannelOnItsSide" {
    var samples = [_]f32{ 1, -1, 2, -2, 3, -3 };
    session.tempo.reverseFrames(&samples);
    try expectEqualSlices(f32, &.{ 3, -3, 2, -2, 1, -1 }, &samples);

    var even = [_]f32{ 1, -1, 2, -2 };
    session.tempo.reverseFrames(&even);
    try expectEqualSlices(f32, &.{ 2, -2, 1, -1 }, &even);

    var none: [0]f32 = .{};
    session.tempo.reverseFrames(&none);
}

// SpeedSettingTests: the water marks.

test "Pacing: theRingBuffersTheSameTimeOfAudioAtEverySpeed" {
    const one = pacing.waterMarks(1);
    for (1..pacing.max_speed + 1) |n| {
        const marks = pacing.waterMarks(@intCast(n));
        try expectEqual(one.high * n, marks.high);
        try expectEqual(one.low * n, marks.low);
    }
}

test "Pacing: theRingHoldsTheHighWaterMarkAtTheFastestSpeed" {
    try expect(pacing.waterMarks(pacing.max_speed).high < pacing.ring_capacity);
}

test "Pacing: aRewindStepStartsWithAWholeStepQueuedAndAlwaysFitsTheRing" {
    const step = @import("ps1_core").savestate.rewind.picture_frames * pacing.floats_per_frame;
    for (1..pacing.max_speed + 1) |n| {
        const mark = pacing.rewindHighWater(@intCast(n));
        try expect(mark >= step);
        try expect(mark + step <= pacing.ring_capacity);
    }
}

test "Pacing: theRewindSleepsUntilTheRingDrainsToItsMark" {
    try expectEqual(1_000_000_000, pacing.drainTime(88_200, 1));
    try expectEqual(500_000_000, pacing.drainTime(88_200, 2));
    try expectEqual(1_000_000, pacing.drainTime(1, 1));
}

// The mixer: what both CoreAudio callbacks call.

/// A stretch unit that renders a constant and counts what it was asked.
const FakeStretch = struct {
    resets: usize = 0,
    renders: usize = 0,
    rate: f32 = 0,

    fn reset(ctx: *anyopaque) void {
        const self: *FakeStretch = @ptrCast(@alignCast(ctx));
        self.resets += 1;
    }

    fn setRate(ctx: *anyopaque, r: f32) void {
        const self: *FakeStretch = @ptrCast(@alignCast(ctx));
        self.rate = r;
    }

    fn render(ctx: *anyopaque, left: []f32, right: []f32) bool {
        const self: *FakeStretch = @ptrCast(@alignCast(ctx));
        self.renders += 1;
        @memset(left, 0.25);
        @memset(right, 0.25);
        return true;
    }

    fn stretch(self: *FakeStretch) Stretch {
        return .{ .ctx = self, .reset = reset, .set_rate = setRate, .render = render };
    }
};

test "Mixer: atOneXTheMixerIsBitIdenticalToTheRing" {
    var r = try ring(pacing.ring_capacity);
    defer r.deinit();
    var m = mixer(&r);
    _ = r.write(&.{ 0.1, -0.1, 0.2, -0.2, 0.3, -0.3 });
    var fake: FakeStretch = .{};
    var left: [4]f32 = undefined;
    var right: [4]f32 = undefined;
    m.render(&left, &right, fake.stretch());
    try expectEqual(0, fake.renders);
    try expectEqual(0, fake.resets);
    try expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0 }, &left);
    try expectEqualSlices(f32, &.{ -0.1, -0.2, -0.3, 0 }, &right);
}

test "Mixer: aStretchReenteredFromOneXStartsFromAResetUnit" {
    var r = try ring(pacing.ring_capacity);
    defer r.deinit();
    var m = mixer(&r);
    var fake: FakeStretch = .{};
    var left: [16]f32 = undefined;
    var right: [16]f32 = undefined;
    for ([_]u32{ 1, 2, 2, 1, 3 }) |speed| {
        m.setSpeed(speed);
        m.render(&left, &right, fake.stretch());
    }
    try expectEqual(2, fake.resets);
    try expectEqual(3, fake.renders);
    try expect(fake.rate >= 1);
}

const Wakes = struct {
    n: usize = 0,

    fn wake(ctx: *anyopaque) void {
        const self: *Wakes = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }
};

test "Mixer: theMixerWakesTheProducerOnlyBelowTheLowMark" {
    var r = try ring(pacing.ring_capacity);
    defer r.deinit();
    var m = mixer(&r);
    var wakes: Wakes = .{};
    m.drained = .{ .ctx = &wakes, .wake = Wakes.wake };
    const low = pacing.waterMarks(1).low;
    var block: [512]f32 = @splat(0.5);
    while (r.filled() < low + 256) _ = r.write(&block);
    var left: [64]f32 = undefined;
    var right: [64]f32 = undefined;
    m.pull(&left, &right);
    try expectEqual(0, wakes.n);
    while (r.filled() >= low) m.pull(&left, &right);
    try expectEqual(1, wakes.n);
    m.pull(&left, &right);
    try expectEqual(2, wakes.n);
}

fn holdsAllocator(comptime T: type) bool {
    if (T == std.mem.Allocator) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.field_types) |f| {
            if (holdsAllocator(f)) break true;
        } else false,
        .optional => |o| holdsAllocator(o.child),
        .array => |a| holdsAllocator(a.child),
        else => false,
    };
}

test "Mixer: theMixerTypeHoldsNoAllocator" {
    comptime std.debug.assert(!holdsAllocator(Mixer));
    // The check itself must be able to fail.
    comptime std.debug.assert(holdsAllocator(struct { a: ?[2]std.mem.Allocator }));
}
