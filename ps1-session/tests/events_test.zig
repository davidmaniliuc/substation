//! The session's events: the frame-rate window (rule for rule what the app's
//! FPS readout used to compute itself) and the coalescing that sends a value
//! only when it changes.

const std = @import("std");
const session = @import("ps1_session");

const events = session.events;
const Ps1Event = events.Ps1Event;
const FrameRate = events.FrameRate;
const Events = events.Events;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const ms = std.time.ns_per_ms;

/// Every event the sink was handed, copied: the record is valid only during
/// the call.
const Recorder = struct {
    events: [16]Ps1Event = undefined,
    len: usize = 0,

    fn record(ctx: ?*anyopaque, ev: *const Ps1Event) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.events[self.len] = ev.*;
        self.len += 1;
    }

    fn sink(self: *Recorder) events.Sink {
        return .{ .on_event = record, .ctx = self };
    }

    fn last(self: *const Recorder) Ps1Event {
        return self.events[self.len - 1];
    }
};

test "FrameRate: theFirstSampleOnlyLatches" {
    var f: FrameRate = .{};
    try expectEqual(null, f.sample(100, 0));
}

test "FrameRate: aFullWindowReportsFramesPerSecond" {
    var f: FrameRate = .{};
    _ = f.sample(0, 0);
    try expectEqual(60.0, f.sample(30, 500 * ms));
}

test "FrameRate: aSampleInsideTheWindowIsIgnored" {
    var f: FrameRate = .{};
    _ = f.sample(0, 0);
    try expectEqual(null, f.sample(10, 200 * ms));
}

test "FrameRate: framesFromAnIgnoredSampleStillCount" {
    var f: FrameRate = .{};
    _ = f.sample(0, 0);
    _ = f.sample(10, 200 * ms);
    try expectEqual(60.0, f.sample(30, 500 * ms));
}

test "FrameRate: aCountThatGoesBackwardsReportsZero" {
    var f: FrameRate = .{};
    _ = f.sample(100, 0);
    try expectEqual(0.0, f.sample(5, 500 * ms));
}

test "FrameRate: eachWindowMeasuresOnlyItsOwnFrames" {
    var f: FrameRate = .{};
    _ = f.sample(0, 0);
    try expectEqual(60.0, f.sample(30, 500 * ms));
    try expectEqual(30.0, f.sample(45, 1000 * ms));
}

test "FrameRate: resetRelatches" {
    var f: FrameRate = .{};
    _ = f.sample(0, 0);
    f.reset();
    try expectEqual(null, f.sample(30, 10_000 * ms));
    try expectEqual(60.0, f.sample(60, 10_500 * ms));
}

test "Events: aPadStatusIsSentOnlyWhenItChanges" {
    var rec: Recorder = .{};
    var e: Events = .{ .sink = rec.sink() };
    e.pad(0);
    try expectEqual(0, rec.len);
    e.pad(1);
    try expectEqual(1, rec.len);
    try expectEqual(@backingInt(events.Kind.pad), rec.last().kind);
    try expectEqual(session.capi.Ps1PadStatus{ .analog = 1, .small = 0, .large = 0 }, rec.last().pad);
    e.pad(1);
    try expectEqual(1, rec.len);
    e.pad(1 | 255 << 8 | 0x40 << 16);
    try expectEqual(2, rec.len);
    try expectEqual(session.capi.Ps1PadStatus{ .analog = 1, .small = 255, .large = 0x40 }, rec.last().pad);
}

test "Events: everyCardWriteIsSent" {
    var rec: Recorder = .{};
    var e: Events = .{ .sink = rec.sink() };
    e.cardWrite(1);
    e.cardWrite(2);
    try expectEqual(2, rec.len);
    try expectEqual(@backingInt(events.Kind.card_write), rec.events[0].kind);
    try expectEqual(1, rec.events[0].card_writes);
    try expectEqual(2, rec.events[1].card_writes);
}

test "Events: rewindSendsSecondsOnChangeAndAlwaysTheFirst" {
    var rec: Recorder = .{};
    var e: Events = .{ .sink = rec.sink() };
    e.rewind(0);
    try expectEqual(1, rec.len);
    try expectEqual(@backingInt(events.Kind.rewind), rec.last().kind);
    try expectEqual(0.0, rec.last().value);
    e.rewind(0);
    try expectEqual(1, rec.len);
    e.rewind(120);
    try expectEqual(2, rec.len);
    try expectEqual(2.0, rec.last().value);
}

test "Events: frameSendsTheRateWhenAWindowCloses" {
    var rec: Recorder = .{};
    var e: Events = .{ .sink = rec.sink() };
    e.frame(0, 0);
    e.frame(15, 250 * ms);
    try expectEqual(0, rec.len);
    e.frame(30, 500 * ms);
    try expectEqual(1, rec.len);
    try expectEqual(@backingInt(events.Kind.frame_rate), rec.last().kind);
    try expectEqual(60.0, rec.last().value);
}

test "Events: noSinkSendsNothingAndKeepsState" {
    var rec: Recorder = .{};
    var e: Events = .{};
    e.pad(1);
    e.sink = rec.sink();
    e.pad(1);
    try expectEqual(0, rec.len);
}
