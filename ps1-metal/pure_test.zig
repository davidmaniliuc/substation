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

// Rasterizer.metal: static_assert(sizeof(Ps1PrimInstance) == 4 * 54) and
// static_assert(sizeof(Ps1RasterUniforms) == 16). The record is read from
// the same header, so this pins the translate-c result, not a second copy.
test "theInstanceRecordAndUniformsKeepTheSizesTheShaderAsserts" {
    const prim = @import("ps1_metal").prim_instance;
    try std.testing.expectEqual(4 * 54, @sizeOf(prim.PrimInstance));
    try std.testing.expectEqual(16, @sizeOf(prim.Uniforms));
}

test {
    _ = @import("tests/hazard_test.zig");
    _ = @import("tests/prim_builder_test.zig");
    _ = @import("tests/queue_test.zig");
    _ = @import("tests/speculation_region_test.zig");
}
