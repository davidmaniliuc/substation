//! The C ABI for ps1-core.
//!
//! This is a frontend, not part of the core: the core stays free of host
//! assumptions and `include/ps1.h` stays a reviewable artifact that a rename
//! cannot silently break. Nothing here may trap across the boundary — every
//! failure is a negative return code, and `panic` aborts rather than unwinding
//! into Swift, where there is no unwinder to catch it.

const std = @import("std");
const ps1 = @import("ps1_core");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const Disc = ps1.disc.Disc;

const allocator = std.heap.smp_allocator;

pub const PS1_OK: i32 = 0;
pub const PS1_ERR_BAD_BIOS_SIZE: i32 = -1;
pub const PS1_ERR_BAD_CUE: i32 = -2;
pub const PS1_ERR_MULTI_FILE_CUE: i32 = -3;
pub const PS1_ERR_OOM: i32 = -4;

const bios_bytes = 512 * 1024;

pub const Handle = struct {
    bus: *Bus,
    cpu: Cpu,
    /// Retained so `ps1_reset` can re-copy it: `Bus.init` memsets the struct,
    /// which clears `bus.bios` along with everything else.
    bios: [bios_bytes]u8 = [_]u8{0} ** bios_bytes,
    bios_loaded: bool = false,
    /// Borrowed, never owned — `Disc` holds a slice into the caller's bytes.
    disc: ?Disc = null,
};

fn buildMachine(h: *Handle) void {
    h.cpu = Cpu.init(h.bus);
    if (h.bios_loaded) @memcpy(h.bus.bios[0..], h.bios[0..]);
    if (h.disc) |d| h.bus.cdrom.setDisc(d);
}

pub export fn ps1_create() ?*Handle {
    const h = allocator.create(Handle) catch return null;
    h.* = .{
        .bus = Bus.init(allocator) catch {
            allocator.destroy(h);
            return null;
        },
        .cpu = undefined,
    };
    buildMachine(h);
    return h;
}

pub export fn ps1_destroy(handle: ?*Handle) void {
    const h = handle orelse return;
    h.bus.deinit(allocator);
    allocator.destroy(h);
}

/// The front-panel reset button: rebuilds the machine but keeps the BIOS and
/// the disc. Running with no disc is valid — it boots to the BIOS shell.
pub export fn ps1_reset(h: *Handle) void {
    h.bus.deinit(allocator);
    h.bus = Bus.init(allocator) catch {
        // Re-allocating 2MB+ immediately after freeing it should not fail; if
        // it does there is no valid state to return to and no way to report it.
        @panic("ps1_reset: out of memory rebuilding Bus");
    };
    buildMachine(h);
}

pub export fn ps1_load_bios(h: *Handle, bytes: [*]const u8, len: usize) i32 {
    if (len != bios_bytes) return PS1_ERR_BAD_BIOS_SIZE;
    @memcpy(h.bios[0..], bytes[0..bios_bytes]);
    h.bios_loaded = true;
    @memcpy(h.bus.bios[0..], h.bios[0..]);
    return PS1_OK;
}
