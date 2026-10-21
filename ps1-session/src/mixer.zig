//! What the CoreAudio callbacks do, without CoreAudio: pull from the ring,
//! deinterleave, apply the gain, and above 1x drive the time-pitch unit at
//! the rate the core sustains.
//!
//! **Real-time code.** Everything reachable from `render` and `pull` is the
//! ring, atomics and one wake: no lock, no allocation, no wait. The type
//! holds no allocator (a test pins that), and the deinterleave scratch is an
//! array inside it.
//!
//! **Speed is paced from here, not from the emulator thread.** At Nx the
//! time-pitch unit pulls up to N times as many samples as it plays, at the
//! original pitch, so the ring drains that much faster and the producer
//! (which only ever fills the ring back to its high-water mark) runs that
//! many more frames. No second clock exists to keep in step with this one.
//! At 1x the stretch unit is not in the chain at all, rather than running at
//! a rate of one: normal play stays bit-identical to the samples the core
//! wrote, with none of the unit's latency or phase smearing.

const std = @import("std");
const pacing = @import("pacing.zig");
const AudioRing = @import("audio_ring.zig").AudioRing;
const Tempo = @import("tempo.zig").Tempo;
const Waker = @import("ps1_metal").waker.Waker;

/// The time-pitch unit, as the output callback drives it. `render` pulls its
/// input back through `Mixer.pull` and returns false on failure, which the
/// mixer answers with silence.
pub const Stretch = struct {
    ctx: *anyopaque,
    reset: *const fn (*anyopaque) void,
    set_rate: *const fn (*anyopaque, f32) void,
    render: *const fn (*anyopaque, left: []f32, right: []f32) bool,
};

/// The most a default output asks for in one callback (it rises from ~512 to
/// 4096 frames while the screen is locked).
pub const scratch_frames = 4096;

pub const Mixer = struct {
    ring: *AudioRing,
    /// Any thread writes these; the render thread reads them.
    gain_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1))),
    speed: std.atomic.Value(u32) = .init(1),
    /// Render thread only: the speed the last callback rendered at, so a
    /// stretch re-entered from 1x starts from a reset unit instead of the
    /// tail of the last fast-forward.
    rendered_speed: u32 = 1,
    /// Render thread only.
    tempo: Tempo = .{},
    /// The ring is interleaved and both units take planar audio, so every
    /// pull is deinterleaved through this.
    scratch: [scratch_frames * 2]f32 = undefined,
    /// Wakes the producer once a pull leaves the ring below the low-water
    /// mark. Null while nothing waits (the tests, a session not yet started).
    drained: ?Waker = null,

    pub fn init(ring: *AudioRing) Mixer {
        return .{ .ring = ring };
    }

    /// Any thread, before or after the output starts: the callback reads it
    /// every time, it is never latched.
    pub fn setGain(self: *Mixer, g: f32) void {
        self.gain_bits.store(@bitCast(g), .monotonic);
    }

    pub fn gain(self: *const Mixer) f32 {
        return @bitCast(self.gain_bits.load(.monotonic));
    }

    /// Any thread, for `setGain`'s reason.
    pub fn setSpeed(self: *Mixer, n: u32) void {
        self.speed.store(n, .monotonic);
    }

    /// One multiply per sample; unity, the shipped default, skips the loop.
    pub fn applyGain(self: *const Mixer, samples: []f32) void {
        const g = self.gain();
        if (g == 1) return;
        for (samples) |*s| s.* *= g;
    }

    /// The output callback. With no stretch unit (a null sink) every speed
    /// pulls straight from the ring.
    pub fn render(self: *Mixer, left: []f32, right: []f32, stretch: ?Stretch) void {
        const n = self.speed.load(.monotonic);
        if (n == 1 or stretch == null) {
            self.pull(left, right);
        } else {
            const st = stretch.?;
            if (self.rendered_speed == 1) {
                st.reset(st.ctx);
                self.tempo.reset(1);
            }
            // "Up to Nx": the rate the core can actually feed, not the one
            // asked for; see `Tempo`.
            st.set_rate(st.ctx, self.tempo.step(Tempo.rate(n, self.ring.filled())));
            if (!st.render(st.ctx, left, right)) {
                @memset(left, 0);
                @memset(right, 0);
            }
        }
        self.rendered_speed = n;
        self.applyGain(left);
        self.applyGain(right);
    }

    /// Takes `left.len` stereo frames out of the ring and deinterleaves them.
    /// On underrun the remainder is silence, for this pull only: waiting for
    /// the emulator would glitch the whole device.
    pub fn pull(self: *Mixer, left: []f32, right: []f32) void {
        const frames = left.len;
        var done: usize = 0;
        while (done < frames) {
            const chunk = @min(frames - done, scratch_frames);
            const got = self.ring.read(self.scratch[0 .. chunk * 2]) / 2;
            for (0..got) |i| {
                left[done + i] = self.scratch[2 * i];
                right[done + i] = self.scratch[2 * i + 1];
            }
            done += got;
            if (got < chunk) {
                @memset(left[done..frames], 0);
                @memset(right[done..frames], 0);
                break;
            }
        }
        if (self.drained) |w| {
            if (self.ring.filled() < pacing.waterMarks(self.speed.load(.monotonic)).low) w.call();
        }
    }
};
