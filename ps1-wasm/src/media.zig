//! Getting bytes in: the host's buffers, the BIOS, and (Task 2) discs.
//! Results richer than a code come back as JSON in `result_buf`: a struct
//! layout mirrored by hand in TypeScript would drift silently.

const std = @import("std");
const ps1 = @import("ps1_core");
const machine = @import("machine.zig");
const codes = @import("codes.zig");

var result_buf: [1024]u8 = undefined;

export fn resultPtr() [*]const u8 {
    return &result_buf;
}

/// Writes `value` as JSON into `result_buf` and returns its length.
pub fn writeResult(value: anytype) i32 {
    var w: std.Io.Writer = .fixed(&result_buf);
    w.print("{f}", .{std.json.fmt(value, .{})}) catch return codes.oom;
    return @intCast(w.buffered().len);
}

/// A buffer for the host to copy an input into. Null when memory cannot grow.
export fn alloc(len: usize) ?[*]u8 {
    const bytes = machine.allocator.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    machine.allocator.free(ptr[0..len]);
}

const BiosInfo = struct {
    known: bool,
    region: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Copies the image (a reset rebuilds `Bus`, which clears its ROM) and
/// identifies it. An image missing from the table is UNIDENTIFIED, not
/// invalid: it still boots. The caller frees `ptr`.
export fn loadBios(ptr: [*]const u8, len: usize) i32 {
    if (len != ps1.bios.image_bytes) return codes.bad_bios_size;
    @memcpy(&machine.bios, ptr[0..ps1.bios.image_bytes]);
    machine.bios_loaded = true;
    machine.installBios(machine.bus);
    const row = ps1.bios.identify(&machine.bios) orelse return writeResult(BiosInfo{ .known = false });
    return writeResult(BiosInfo{
        .known = true,
        .region = @tagName(row.region),
        .version = row.version,
        .description = row.description,
    });
}
