//! Draining the SPU's output ring. The ring's indices belong to the core;
//! handing them to JavaScript made every caller redo the modular arithmetic.

const machine = @import("machine.zig");

var samples: [8192]f32 = undefined;

export fn audioPtr() [*]const f32 {
    return &samples;
}

/// Moves up to `max_floats` interleaved stereo samples (44100 Hz) into the
/// buffer `audioPtr` names and returns how many. An odd count truncates to
/// whole pairs, so a pair is never split across two calls.
export fn readAudio(max_floats: usize) usize {
    const spu = &machine.bus.spu;
    const len = spu.output_buffer.len;
    const available = (spu.write_idx + len - spu.read_idx) % len;
    var n = @min(available, max_floats, samples.len);
    n -= n % 2;
    for (0..n) |i| samples[i] = spu.output_buffer[(spu.read_idx + i) % len];
    spu.read_idx = (spu.read_idx + n) % len;
    return n;
}
