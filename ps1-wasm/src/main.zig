//! The browser frontend: one machine per wasm instance, driven by
//! `ps1-web`'s `Ps1Core`. Every export that can fail returns a negative code
//! from `codes.zig`. The one thing that crosses as a trap is a core panic,
//! which the worker reports instead of hanging.

const std = @import("std");
const ps1 = @import("ps1_core");
const machine = @import("machine.zig");
const codes = @import("codes.zig");

comptime {
    // Their `export fn`s are emitted only once the files are analysed.
    _ = @import("media.zig");
    _ = @import("video.zig");
    _ = @import("audio.zig");
    _ = @import("saves.zig");
}

extern "env" fn jsConsoleLog(ptr: [*]const u8, len: usize) void;

export fn init() i32 {
    machine.create() catch return codes.oom;
    return codes.ok;
}

export fn reset() i32 {
    machine.reset() catch return codes.oom;
    return codes.ok;
}

/// Vblank to vblank: spin out of any vblank already in, then run to the
/// next. `runFor`, not `run`: under a block engine `run` is one block.
export fn runFrame() void {
    if (!machine.bios_loaded) return;
    const budget = std.math.maxInt(u32);
    while (machine.cpu.bus.gpu.is_vblank) _ = machine.cpu.runFor(budget);
    while (!machine.cpu.bus.gpu.is_vblank) _ = machine.cpu.runFor(budget);
}

/// `sio.zig`'s convention: a 0 bit is PRESSED, 0xFFFF is idle.
export fn setButtons(mask: u32) void {
    machine.bus.sio.setButtons(@truncate(mask));
}

/// 0 the interpreter, 1 the cached interpreter. 2, the JIT, emits arm64 host
/// code and is ENGINE_UNAVAILABLE in every wasm build.
export fn setCpuEngine(engine: u32) i32 {
    const e: ps1.recompiler.Engine = switch (engine) {
        0 => .interpreter,
        1 => .cached,
        2 => .jit,
        else => return codes.engine_unavailable,
    };
    ps1.recompiler.setEngine(&machine.cpu, machine.allocator, e) catch |err| return switch (err) {
        error.OutOfMemory => codes.oom,
        error.EngineUnavailable => codes.engine_unavailable,
    };
    machine.engine = e;
    return codes.ok;
}

/// Read whenever the BIOS is installed: by `loadBios`, `loadDisc`, `reset`
/// and `loadState`. It changes nothing by itself.
export fn setFastBoot(on: u32) void {
    machine.fast_boot = on != 0;
}

/// Logs, then traps. Spinning here would hang the worker with nothing to
/// report; a trap reaches JavaScript as a `RuntimeError` it can surface.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    jsConsoleLog(msg.ptr, msg.len);
    @trap();
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch "Log message too long";
    jsConsoleLog(text.ptr, text.len);
}
