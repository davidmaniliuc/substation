//! Byte offsets the emitted code addresses: `Cpu` through x19, `Pins`
//! through x22. The checks below fail the build when one outgrows the
//! unsigned-offset form that reaches it.

const std = @import("std");
const Pins = @import("../cache.zig").Pins;

/// `ram` and `scratchpad`: the prologue loads both with one `ldp`.
pub const pins_ram = @offsetOf(Pins, "ram");

comptime {
    std.debug.assert(@offsetOf(Pins, "scratchpad") == pins_ram + 8);
    std.debug.assert(pins_ram % 8 == 0 and pins_ram <= 504);
}
