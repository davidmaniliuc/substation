const std = @import("std");

/// Read a test asset (BIOS, .exe, .log, reference image) relative to the process
/// CWD (the repo root). Panics with the path on FileNotFound so a missing asset
/// is obvious rather than a generic error.
pub fn readTestFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_size + 1)) catch |err| switch (err) {
        error.FileNotFound => std.debug.panic("File not found: {s}\n", .{path}),
        else => return err,
    };
}
