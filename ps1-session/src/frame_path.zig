//! The frame half of the emulator thread's pass: `iterate` and what it
//! publishes. Functions over `RunLoop(M)`, which forwards to them.

const std = @import("std");
const metal = @import("ps1_metal");
const pacing = @import("pacing.zig");
const runahead = @import("runahead.zig");
const tempo = @import("tempo.zig");
const machine = @import("machine.zig");

const picture_frames = @import("ps1_core").savestate.rewind.picture_frames;
const ms = std.time.ns_per_ms;

/// What the thread must wait for before the next pass, and for how long at
/// most. A wait with no timeout is woken by the event it names.
pub const Wait = struct {
    pub const Reason = enum { paused, audio, queue, rewind_drain, rewind_idle };
    reason: Reason,
    timeout_ns: ?u64,
};

pub const Outcome = union(enum) { ran_frame, rewound, wait: Wait };

/// While paused the cards and requests must still be serviced, so the wait
/// has a timeout even though an unpause wakes it.
const paused_timeout_ns = 50 * ms;
/// The audio callback wakes the thread below the low mark; this is the
/// backstop for a device that stopped calling back.
const audio_timeout_ns = 50 * ms;

/// One pass of the Swift runner's `while running` body, in its order,
/// returning what to wait for instead of waiting.
///
/// **A stalled renderer can no longer drop a frame.** The producer waits for
/// room in the queue before every frame and for `picture_frames` of room
/// before every rewind step, and nothing else publishes, so the full-ring
/// drop is unreachable. The drops left are an incomplete recording and an
/// oversized frame, which `stage` still notes, and the repair debt answers
/// those as before.
pub fn iterate(self: anytype, now_ns: u64) Outcome {
    const c = &self.controls;
    self.serviceRequests(now_ns);
    if (c.paused.load(.acquire)) return wait(.paused, paused_timeout_ns);

    // GPU-only has no rewind or runahead yet: both restore VRAM the
    // renderer alone holds.
    const want_budget = if (c.gpu_vram) 0 else c.rewind_budget.load(.acquire);
    if (want_budget != self.applied_rewind_budget) {
        // A refusal (out of memory) leaves rewind off; it is not retried
        // every frame.
        self.m.configureRewind(want_budget) catch self.m.configureRewind(0) catch {};
        self.applied_rewind_budget = want_budget;
        self.rewind_frames.store(self.m.rewindFramesCovered(), .release);
    }

    const speed = c.speed.load(.acquire);

    // A held rewind is paced by the audio ring as a frame is: each step
    // writes the stretch it went back over, played backwards. With no
    // history left it writes nothing, so it waits out its own interval.
    if (c.rewinding.load(.acquire) and self.applied_rewind_budget > 0) {
        const high = pacing.rewindHighWater(speed);
        const filled = self.ring.filled();
        if (filled > high) return wait(.rewind_drain, pacing.drainTime(filled - high, speed));
        // Room for EVERY frame the step publishes: a step publishes four at
        // once, and at a high scale a drop is the repair path.
        if (self.x.queue.freeSlots() < picture_frames) return wait(.queue, null);
        if (rewindStep(self)) return .rewound;
        return wait(.rewind_idle, pacing.rewind_step_interval_ns);
    }

    // Audio is the clock: stop producing once the ring is full enough.
    if (self.ring.filled() > pacing.waterMarks(speed).high) return wait(.audio, audio_timeout_ns);
    // The renderer is the second clock, and a drain wakes this wait.
    if (self.x.queue.freeSlots() < 1) return wait(.queue, null);

    self.serviceSwap();

    self.m.setButtons(@truncate(c.buttons.load(.acquire)));
    const s = c.sticks.load(.acquire);
    self.m.setAnalog(.{ @truncate(s), @truncate(s >> 8), @truncate(s >> 16), @truncate(s >> 24) });
    if (c.takeAnalogPress()) self.m.pressAnalogButton();
    // Re-applied every frame rather than on change, as the button mask is:
    // this thread owns the machine, and a latch would need a second flag to
    // say the value moved.
    self.m.applyPgxp(c.pgxp());
    const want_cache = c.vertex_cache.load(.acquire);
    if (want_cache != self.applied_vertex_cache) {
        self.m.setVertexCache(want_cache);
        self.applied_vertex_cache = want_cache;
    }
    // Recorded even when the machine refuses it, so a refusal is not retried
    // every frame; the machine then stays on the engine it had.
    const want_engine = c.engine.load(.acquire);
    if (self.applied_engine == null or self.applied_engine.? != want_engine) {
        if (std.enums.fromInt(machine.Engine, want_engine)) |e| self.m.setEngine(e) catch {};
        self.applied_engine = want_engine;
    }

    self.m.runFrame();
    self.publishPadStatus();
    const produced = self.m.readAudio(&self.audio_scratch);
    if (produced > 0) _ = self.ring.write(self.audio_scratch[0..produced]);

    // VRAM FIRST, then the stream, both under the same seq: a shadow sampled
    // at seq S accounts for every stream up to S and none above it, which is
    // what lets a resync discard exactly the frames the shadow holds.
    publishFrame(self, false);
    // Runahead only at 1x: above it the frames ahead would cost the speed
    // the player asked for, and fast-forward has no lag to hide.
    const ahead = if (c.gpu_vram) 0 else c.runahead.load(.acquire);
    if (ahead > 0 and speed == 1) {
        // The real frame is staged, not published, until its group is in.
        _ = self.x.queue.stage(self.seq, self.m.takeFrameStream());
        runahead.speculate(self.m, ahead, self.seq, self.x.queue, &self.audio_scratch);
        self.x.queue.commitStaged();
        self.x.notifyPublished();
    } else {
        publishStream(self);
    }
    self.rewind_frames.store(self.m.rewindFramesCovered(), .release);
    return .ran_frame;
}

fn wait(reason: Wait.Reason, timeout_ns: ?u64) Outcome {
    return .{ .wait = .{ .reason = reason, .timeout_ns = timeout_ns } };
}

/// Starts a new seq for the frame the machine just ran and publishes its
/// display mode, and its VRAM as the newest shadow when something reads it:
/// a debug switch, `force`, or the renderer. The copy waits for the raster
/// worker, and skipping it on every other frame lets the emulator run on
/// while the worker draws. A 24-bit display scans out of the render texture
/// and needs none. Under GPU-only the renderer never asks for one: nothing
/// it could ask about is answered by a shadow there (`machineReplaced`).
pub fn publishFrame(self: anytype, force: bool) void {
    self.seq +%= 1;
    self.x.frames_produced.store(self.seq, .release);
    const d = self.m.display();
    // Asked every frame, since it clears the renderer's request.
    // The debug seams need dual (Plan C forces it); under GPU-only their
    // readback would file this frame's records under the next seq.
    const gpu = self.controls.gpu_vram;
    const wanted = self.x.queue.wantsShadow() and !gpu;
    if (force or wanted or (self.controls.shadow_every_frame and !gpu)) publishShadow(self, .settled);
    self.x.publishDisplay(d);
}

/// Where a shadow's pixels come from: `.settled` reads VRAM as the machine
/// sees it (a readback under GPU-only), `.as_is` copies `vram.data` without
/// one, for a machine whose VRAM is complete because it was just loaded or
/// zeroed.
pub const ShadowSource = enum { settled, as_is };

pub fn publishShadow(self: anytype, comptime source: ShadowSource) void {
    const slot = self.x.shadowBack();
    switch (source) {
        .settled => self.m.copyVram(&slot.pixels),
        .as_is => self.m.copyVramAsIs(&slot.pixels),
    }
    // The depth plane is part of the shadow a resync adopts, so it is
    // published under the SAME seq as VRAM, never sampled separately.
    const with_depth = self.controls.depthBuffer();
    if (with_depth) switch (source) {
        .settled => self.m.copyDepth(&slot.depth),
        .as_is => self.m.copyDepthAsIs(&slot.depth),
    };
    slot.depth_valid = with_depth;
    slot.state = self.m.rasterState();
    slot.seq = self.seq;
    self.x.publishShadow();
}

/// The frame's stream into the queue under the current seq. Once per
/// `runFrame`, unconditionally: the recorder is a drain.
fn publishStream(self: anytype) void {
    self.x.queue.publish(self.seq, self.m.takeFrameStream());
    self.x.notifyPublished();
}

/// One step of a held rewind. The machine goes back as many frames as the
/// picture runs, so a held rewind costs what playing does and goes back at
/// the game's own speed. The machine is then published as a shadow, and the
/// `picture_frames` frames run from there as streams with no shadow of their
/// own: the resync adopts the step's shadow and replays them on top of it at
/// scale. A shadow per frame would be adopted instead and its stream
/// discarded as already applied, which puts a 1x picture on screen.
///
/// The frames from the capture to the one the step left are the stretch it
/// went back over, and their audio goes into the ring reversed; the frames
/// past them are the picture's alone and are dropped. With no history left
/// the picture holds where it is and this returns false.
fn rewindStep(self: anytype) bool {
    const before = self.m.rewindFramesCovered();
    if (!self.m.rewindStep()) return false;
    var went_back = before -| self.m.rewindFramesCovered();
    while (went_back < picture_frames and self.m.rewindStep()) went_back = before -| self.m.rewindFramesCovered();

    publishFrame(self, true);
    // Before the streams, never after: a drain landing between the two would
    // otherwise replay a stream onto the texture of the future it just left,
    // and then discard it at the resync.
    self.requestResync();
    var len: usize = 0;
    for (0..picture_frames) |frame| {
        self.m.runFrame();
        const produced = self.m.readAudio(&self.audio_scratch);
        if (frame < went_back) {
            const n = @min(produced, self.rewind_audio.len - len);
            @memcpy(self.rewind_audio[len..][0..n], self.audio_scratch[0..n]);
            len += n;
        }
        self.seq +%= 1;
        self.x.frames_produced.store(self.seq, .release);
        publishStream(self);
    }
    self.publishPadStatus();
    tempo.reverseFrames(self.rewind_audio[0..len]);
    if (len > 0) _ = self.ring.write(self.rewind_audio[0..len]);
    self.rewind_frames.store(self.m.rewindFramesCovered(), .release);
    return true;
}
