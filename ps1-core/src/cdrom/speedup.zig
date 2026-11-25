//! The CD speedup: how many times faster than the real drive a load runs.
//! Two settings, as DuckStation has them: READ divides the double-speed
//! sector period, SEEK divides the two invented seek times.
//!
//! Host configuration like the overclock: it lives on `CdRom` beside the
//! timers it scales, never in a state. A factor of 0 is unrepresentable on
//! purpose, so a zeroed struct cannot divide by it, and 1x is the identity:
//! every expression below returns its input.

pub const Factor = enum(u8) {
    x1 = 1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,

    /// The factor a host's integer names, if it names one: 1 to 10.
    pub fn fromInt(n: i64) ?Factor {
        if (n < 1 or n > 10) return null;
        return @fromBackingInt(@intCast(n));
    }
};

pub const Speedup = struct {
    read: Factor = .x1,
    seek: Factor = .x1,

    /// The sector period at `mode` (the Setmode byte). Only a double-speed
    /// data read is sped up: single speed, XA-ADPCM and CD-DA play in real
    /// time or the music runs fast, and so does anything the drive is
    /// playing rather than reading.
    pub fn sectorCycles(self: Speedup, mode: u8, playing: bool) i64 {
        const single: i64 = 451584; // 33868800 / 75 Hz
        const double = single / 2;
        if (mode & 0x80 == 0) return single;
        const audio = playing or mode & 0x41 != 0;
        return if (audio) double else @divTrunc(double, @backingInt(self.read));
    }

    /// A seek of `cycles` at real-drive speed. The smallest seek the table
    /// has is 500000, so at 10x it is still 50000: DuckStation's 30000-cycle
    /// floor can never bind here and is not carried.
    pub fn seekCycles(self: Speedup, cycles: i64) i64 {
        return @divTrunc(cycles, @backingInt(self.seek));
    }
};
