//! Booting a bare executable the way a disc boots: the real BIOS runs with
//! an empty drive, and the moment its kernel is initialised the program is
//! placed in RAM and jumped to, so the shell and the logo never run.
//!
//! "Initialised" is the BIOS's own POST code 7, written to the expansion
//! port's LED latch. The store only raises `Bus.exe_due`; the injection runs
//! in `Cpu.runFor` after the unit that made it, because it rewrites RAM
//! behind `Bus.write` and moves the PC, which nothing inside a block may do.

const std = @import("std");
const exe = @import("../exe.zig");
const Cpu = @import("cpu.zig").Cpu;

/// An armed program: borrowed by `Bus.exe_boot` as host configuration and
/// never written to a savestate.
pub const Boot = struct {
    main: exe.Program,
    /// A `libps.exe` beside the program, placed first; its PC is not taken.
    libps: ?exe.Program,
    /// Stands in for a disc serial in a savestate's identity.
    fingerprint: u64,
};

/// The POST code the kernel writes once it is initialised.
const kernel_initialised = 7;

/// Whether a CPU store to `paddr` is the BIOS reporting its kernel ready:
/// either EXP2 POST latch, or EXP3's first byte, which some BIOSes use.
pub fn isKernelInitialised(paddr: u32, value: u32) bool {
    const post = paddr == 0x1F802041 or paddr == 0x1F802042 or paddr == 0x1FA00000;
    return post and value & 0xF == kernel_initialised;
}

pub fn inject(cpu: *Cpu, boot: *const Boot) void {
    const bus = cpu.bus;
    if (boot.libps) |*p| place(bus.ram[0..], p);
    place(bus.ram[0..], &boot.main);
    // Bypasses `Bus.write`, so no block over the written range knows.
    if (bus.blocks) |c| c.flush();
    cpu.icache = @splat(.{});

    const entry = boot.main.entry;
    cpu.jumpTo(entry.pc);
    if (entry.gp != 0) cpu.writeReg(.gp, entry.gp);
    if (entry.sp != 0) {
        cpu.writeReg(.sp, entry.sp);
        cpu.writeReg(.fp, entry.sp);
    }
    bus.exe_due = false;
}

/// `exe.parse` has already refused anything past the end of RAM.
fn place(ram: []u8, p: *const exe.Program) void {
    for (p.fills) |f| @memset(ram[phys(f.addr)..][0..f.len], 0);
    for (p.segments) |s| @memcpy(ram[phys(s.addr)..][0..s.bytes.len], s.bytes);
}

fn phys(addr: u32) usize {
    return addr & 0x1FFFFFFF;
}
