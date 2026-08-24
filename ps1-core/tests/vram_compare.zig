//! Full-VRAM equality with a readable failure. `expectEqualSlices` over
//! 524,288 pixels prints a diff nobody can use; what a divergence needs is how
//! many pixels moved and where the first one is.

const std = @import("std");
const ps1_core = @import("ps1_core");
const Vram = ps1_core.gpu.Vram;

pub fn expectVramEqual(want: *const Vram, got: *const Vram) !void {
    var diffs: usize = 0;
    var first: usize = 0;
    for (want.data, got.data, 0..) |w, g, i| {
        if (w == g) continue;
        if (diffs == 0) first = i;
        diffs += 1;
    }
    if (diffs == 0) return;
    std.debug.print(
        "\nVRAM diverged: {d} pixels; first at ({d},{d}) want={x:0>4} got={x:0>4}\n",
        .{ diffs, first % 1024, first / 1024, want.data[first], got.data[first] },
    );
    return error.VramDiverged;
}
