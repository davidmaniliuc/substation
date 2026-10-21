//! The stretch rate above 1x, and the sound of a held rewind.

const pacing = @import("pacing.zig");

/// The stretch rate above 1x: the target speed when the core keeps up, and
/// the speed it actually sustains when it does not.
///
/// A fixed rate of N pulls N seconds of game audio per second; a core that
/// manages less drains the ring, and the time-pitch unit then stretches
/// silence into the gaps: audio that stutters while the picture runs at
/// whatever the core reached anyway. Reading the rate off the ring's fill
/// instead settles where consumption equals production: a ring the core
/// keeps above the target's low-water mark plays at the full target, a ring
/// drained to 1x's low-water mark plays at real time, which the core always
/// sustains and so is where the fill recovers from.
///
/// A plain value the render thread owns: no lock.
pub const Tempo = struct {
    /// The fraction of the gap closed per render callback (~10 ms). Slow
    /// enough that the producer's high/low-water sawtooth does not reach the
    /// ear as a warble, fast enough to settle within a second.
    pub const smoothing: f32 = 0.02;

    current: f32 = 1,

    pub fn rate(target: u32, fill: usize) f32 {
        const floor = pacing.waterMarks(1).low;
        const ceiling = pacing.waterMarks(target).low;
        if (target <= 1 or ceiling <= floor) return 1;
        const t = (@as(f32, @floatFromInt(fill)) - @as(f32, @floatFromInt(floor))) /
            @as(f32, @floatFromInt(ceiling - floor));
        return 1 + @as(f32, @floatFromInt(target - 1)) * @min(@max(t, 0), 1);
    }

    pub fn reset(self: *Tempo, r: f32) void {
        self.current = r;
    }

    pub fn step(self: *Tempo, toward: f32) f32 {
        self.current += (toward - self.current) * smoothing;
        return self.current;
    }
};

/// The audio of the stretch a rewind step went back over, played backwards,
/// so a run of steps plays the game's audio in reverse. Reverses interleaved
/// stereo by FRAME, never by sample: a plain reverse would also swap the left
/// and right channels.
pub fn reverseFrames(samples: []f32) void {
    const frames = samples.len / 2;
    if (frames < 2) return;
    var front: usize = 0;
    var back: usize = frames - 1;
    while (front < back) : ({
        front += 1;
        back -= 1;
    }) {
        std.mem.swap(f32, &samples[2 * front], &samples[2 * back]);
        std.mem.swap(f32, &samples[2 * front + 1], &samples[2 * back + 1]);
    }
}

const std = @import("std");
