//! Audio is the master clock: the emulator thread runs a frame only while
//! the ring is below its high-water mark, and the audio device drains it.
//! These are the marks and the sleeps that rule follows.

const std = @import("std");
const picture_frames = @import("ps1_core").savestate.rewind.picture_frames;

/// The ring every session is built over. It must hold the high-water mark at
/// the fastest speed, which a test pins.
pub const ring_capacity = 1 << 15;

/// About one emulated frame of stereo audio: 44100 / 60 * 2.
pub const floats_per_frame = 1470;

/// The fastest fast-forward on offer.
pub const max_speed = 4;

/// A held rewind takes a step this often.
pub const rewind_step_interval_ns: u64 = std.time.ns_per_s / 30;

pub const Marks = struct { high: usize, low: usize };

/// About four emulated frames of stereo audio at 1x, and N times that at Nx.
/// Without the scaling, 4x would drain a one-frame margin per callback and
/// underrun.
pub fn waterMarks(speed: u32) Marks {
    return .{ .high = floats_per_frame * 4 * speed, .low = floats_per_frame * 2 * speed };
}

/// The fill below which a held rewind takes its next step: the ordinary high
/// mark plus one step's audio, short of where a step would overflow the
/// ring. A step writes four frames at once and takes 20-25 ms to compute, so
/// it must start with a whole step still queued: started at the ordinary low
/// mark (two frames, 33 ms) it ran the ring dry every cycle and rewound at
/// 0.8x, measured 2026-10-11. The low mark's wake never fires this high, so
/// the emulator thread sleeps for `drainTime` instead.
pub fn rewindHighWater(speed: u32) usize {
    const step = picture_frames * floats_per_frame;
    return @min(waterMarks(speed).high + step, ring_capacity - step);
}

/// How long the audio device takes to consume `floats` at `speed`, in
/// nanoseconds: the rewind's sleep while the ring is above its mark. Bounded
/// below so a fill just over the mark does not spin.
pub fn drainTime(floats: usize, speed: u32) u64 {
    const ns = @as(u64, floats) * std.time.ns_per_s / (88_200 * @as(u64, speed));
    return @max(std.time.ns_per_ms, ns);
}
