//! Root of the ps1-metal tests that need no Metal framework, and so run
//! under `zig build test` on any host.

const std = @import("std");
const enums = @import("ps1_metal").mtl_enums;

// MTLResource.h: MTLResourceStorageModeShift = 4, so a storage mode's
// resource option is the mode moved up four bits and the cache mode
// (MTLCPUCacheModeDefaultCache = 0) stays in the low nibble.
test "aResourceOptionCarriesItsStorageModeInTheSecondNibble" {
    try std.testing.expectEqual(@as(usize, 0x00), enums.resourceOptions(.shared));
    try std.testing.expectEqual(@as(usize, 0x10), enums.resourceOptions(.managed));
    try std.testing.expectEqual(@as(usize, 0x20), enums.resourceOptions(.private));
    try std.testing.expectEqual(@as(usize, 0x30), enums.resourceOptions(.memoryless));
}
