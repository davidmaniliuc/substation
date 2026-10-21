//! The real output unit and its time-pitch stage behind the mixer. Needs an
//! audio device: a machine with none skips, saying so.

const std = @import("std");
const session = @import("ps1_session");

const coreaudio = session.coreaudio;
const pacing = session.pacing;
const AudioRing = session.audio_ring.AudioRing;
const Mixer = session.mixer.Mixer;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;

/// An output that built and started, or a skip naming why it could not.
fn started(out: *coreaudio.Output, mixer: *Mixer) !void {
    out.init(mixer) catch |err| switch (err) {
        error.NoComponent => {
            std.debug.print("no default output device\n", .{});
            return error.SkipZigTest;
        },
        error.OsStatus => return err,
    };
    out.start() catch {
        std.debug.print("no default output device (start failed, OSStatus {d})\n", .{out.last_status});
        out.stop();
        return error.SkipZigTest;
    };
}

test "CoreAudio: theOutputUnitBuildsStartsAndStops" {
    var ring = try AudioRing.init(alloc, pacing.ring_capacity);
    defer ring.deinit();
    var mixer = Mixer.init(&ring);
    var out: coreaudio.Output = .{};
    try started(&out, &mixer);
    out.stop();
}

test "CoreAudio: aStoppedOutputStopsAgainHarmlessly" {
    var ring = try AudioRing.init(alloc, pacing.ring_capacity);
    defer ring.deinit();
    var mixer = Mixer.init(&ring);
    var out: coreaudio.Output = .{};
    try started(&out, &mixer);
    out.stop();
    out.stop();
    // And one that never started.
    var never: coreaudio.Output = .{};
    never.stop();
}

test "CoreAudio: theRealCallbackPullsFromTheRing" {
    var ring = try AudioRing.init(alloc, pacing.ring_capacity);
    defer ring.deinit();
    var mixer = Mixer.init(&ring);
    // Silent: the test fills the ring with samples nobody needs to hear.
    mixer.setGain(0);
    var block: [1024]f32 = @splat(0);
    while (ring.freeSpace() >= block.len) _ = ring.write(&block);
    const full = ring.filled();
    var out: coreaudio.Output = .{};
    try started(&out, &mixer);
    defer out.stop();
    const t0 = std.Io.Clock.awake.now(io);
    while (ring.filled() >= full) {
        if (t0.untilNow(io, .awake).nanoseconds > std.time.ns_per_s) {
            std.debug.print("the output callback never pulled from the ring\n", .{});
            return error.TestUnexpectedResult;
        }
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(5), .clock = .awake }, io);
    }
}

test "CoreAudio: theNullOutputDrainsNothing" {
    var ring = try AudioRing.init(alloc, pacing.ring_capacity);
    defer ring.deinit();
    var mixer = Mixer.init(&ring);
    _ = ring.write(&.{ 1, 2 });
    var out: coreaudio.NullOutput = .{};
    try out.init(&mixer);
    try out.start();
    out.stop();
    try std.testing.expectEqual(2, ring.filled());
}
