const std = @import("std");
const ps1_core = @import("ps1_core");
const options = @import("rom_test_options");

/// The engine `-Dengine` chose. The build validates the name.
pub fn engine() ps1_core.recompiler.Engine {
    return std.meta.stringToEnum(ps1_core.recompiler.Engine, options.engine).?;
}

/// Under a block engine the run must actually have compiled blocks, or a
/// suite "passing under -Dengine=cached" proves nothing. `BlockCache` keeps
/// no compile counter, so this looks for any live slot.
pub fn expectBlocksCompiled(bus: *const ps1_core.memory.Bus) !void {
    if (engine() == .interpreter) return;
    const c = bus.blocks orelse return error.BlockEngineNotInstalled;
    for (c.ram) |slot| if (slot != null) return;
    for (c.bios) |slot| if (slot != null) return;
    return error.NoBlocksCompiled;
}

/// Read a test asset (BIOS, .exe, .log, reference image) relative to the process
/// CWD (the repo root). Panics with the path on FileNotFound so a missing asset
/// is obvious rather than a generic error.
pub fn readTestFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_size + 1)) catch |err| switch (err) {
        error.FileNotFound => std.debug.panic("File not found: {s}\n", .{path}),
        else => return err,
    };
}
