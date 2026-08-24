//! The .p1fx fixture format: a recorded GP0 command stream on disk, plus the
//! per-frame VRAM hash a consumer checks it against.
//!
//! Little-endian throughout, asserted rather than assumed.

const std = @import("std");
const ps1 = @import("ps1_core");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) {
        @compileError(".p1fx is little-endian; this target is not");
    }
}

/// FNV-1a 64.
///
/// Deliberately NOT `std.hash.Wyhash`, which state_hash.zig uses. Wyhash is a
/// standard-library implementation that may change across Zig releases, so a
/// FILE FORMAT pinned to it breaks silently on a toolchain upgrade — and the
/// failure presents as "Swift disagrees with Zig", the most confusing shape a
/// bridge bug can take. This is six lines in either language and frozen by
/// definition.
pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// The full 1024x512, as little-endian u16 in row-major order — not the
/// display window.
pub fn hashVram(v: *const ps1.gpu.Vram) u64 {
    return fnv1a(std.mem.sliceAsBytes(v.data[0..]));
}
