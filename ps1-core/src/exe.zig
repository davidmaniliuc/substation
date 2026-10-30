//! Bare executables: a PS-X EXE, a Psy-Q CPE or a MIPS ELF, parsed into the
//! one shape a boot needs: the bytes to place, the ranges to zero and the
//! registers to start from.
//!
//! The format is decided by the file's CONTENT, never its extension. A
//! program renamed from `.cpe` to `.exe` is still a CPE, and a loader that
//! trusted the extension would refuse it for no reason the player can see.
//!
//! Nothing here touches a machine: segments slice the caller's bytes, and
//! every one is checked to land inside main RAM before the file is accepted,
//! so a refused file is refused when it is opened, not halfway into a boot.

const std = @import("std");
const discid = @import("discid.zig");

pub const Format = enum { psexe, cpe, elf };
pub const Segment = struct { addr: u32, bytes: []const u8 };
pub const Fill = struct { addr: u32, len: u32 };
/// A zero `gp` or `sp` leaves that register as the BIOS left it.
pub const Entry = struct { pc: u32, gp: u32 = 0, sp: u32 = 0 };

pub const Program = struct {
    format: Format,
    segments: []Segment,
    /// Zeroed BEFORE the segments are copied.
    fills: []Fill,
    entry: Entry,
    /// From the PS-X EXE header's licence marker only.
    region: ?discid.Region,

    pub fn deinit(self: *Program, a: std.mem.Allocator) void {
        a.free(self.segments);
        a.free(self.fills);
        self.* = undefined;
    }
};

pub const Error = error{ BadFormat, Truncated, OutsideRam, NoEntry, OutOfMemory };

/// Main RAM is 2 MB; every mirror (KUSEG, KSEG0, KSEG1) maps to it.
const ram_bytes = 0x200000;
const psexe_header = 0x800;
const psexe_marker = 0x4C;
/// The register number a CPE's set-register chunk uses for the PC.
const cpe_pc = 0x90;
const elf_load = 1;
const elf_mips = 8;

pub fn parse(a: std.mem.Allocator, bytes: []const u8) Error!Program {
    if (startsWith(bytes, "PS-X EXE")) return parsePsExe(a, bytes);
    if (startsWith(bytes, "CPE\x01")) return parseCpe(a, bytes);
    if (startsWith(bytes, "\x7FELF")) return parseElf(a, bytes);
    // A prefix of a magic is a cut-off file, not some other format.
    for ([_][]const u8{ "PS-X EXE", "CPE\x01", "\x7FELF" }) |magic| {
        if (bytes.len < magic.len and std.mem.startsWith(u8, magic, bytes)) return error.Truncated;
    }
    return error.BadFormat;
}

/// Names a program for a savestate's identity: the main file and the
/// `libps.exe` loaded before it, since either changes what runs.
pub fn fingerprint(main: []const u8, libps: []const u8) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(main);
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, main.len, .little);
    h.update(&len);
    h.update(libps);
    return h.final();
}

fn startsWith(bytes: []const u8, magic: []const u8) bool {
    return std.mem.startsWith(u8, bytes, magic);
}

fn inRam(addr: u32, len: u32) Error!void {
    const phys: u64 = addr & 0x1FFFFFFF;
    if (phys + len > ram_bytes) return error.OutsideRam;
}

fn read32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn read16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

const Builder = struct {
    a: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,
    fills: std.ArrayList(Fill) = .empty,

    fn segment(self: *Builder, addr: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        try inRam(addr, @intCast(bytes.len));
        try self.segments.append(self.a, .{ .addr = addr, .bytes = bytes });
    }

    fn fill(self: *Builder, addr: u32, len: u32) Error!void {
        if (len == 0) return;
        try inRam(addr, len);
        try self.fills.append(self.a, .{ .addr = addr, .len = len });
    }

    fn deinit(self: *Builder) void {
        self.segments.deinit(self.a);
        self.fills.deinit(self.a);
    }

    fn finish(self: *Builder, format: Format, entry: Entry, region: ?discid.Region) Error!Program {
        const segments = try self.segments.toOwnedSlice(self.a);
        errdefer self.a.free(segments);
        return .{
            .format = format,
            .segments = segments,
            .fills = try self.fills.toOwnedSlice(self.a),
            .entry = entry,
            .region = region,
        };
    }
};

/// Read as `Cpu.loadExe` reads it: a header `file_size` past the end of the
/// file is clamped to what is there, and zero means "the rest of the file".
fn parsePsExe(a: std.mem.Allocator, bytes: []const u8) Error!Program {
    if (bytes.len <= psexe_header) return error.Truncated;
    var b: Builder = .{ .a = a };
    defer b.deinit();

    const available: u32 = @intCast(@min(bytes.len - psexe_header, std.math.maxInt(u32)));
    const header_size = read32(bytes, 0x1C);
    const size = if (header_size == 0) available else @min(header_size, available);
    try b.fill(read32(bytes, 0x28) & ~@as(u32, 3), read32(bytes, 0x2C) & ~@as(u32, 3));
    try b.segment(read32(bytes, 0x18), bytes[psexe_header..][0..size]);

    const entry: Entry = .{
        .pc = read32(bytes, 0x10),
        .gp = read32(bytes, 0x14),
        .sp = read32(bytes, 0x30) +% read32(bytes, 0x34),
    };
    return b.finish(.psexe, entry, discid.licenseRegion(bytes[psexe_marker..psexe_header]));
}

/// The chunked Psy-Q debug executable (PSX-SPX "CDROM File Psy-Q CPE
/// Files"). Only the PC among the registers is acted on; the rest, the run
/// address, the workspace and the unit are read past.
fn parseCpe(a: std.mem.Allocator, bytes: []const u8) Error!Program {
    var b: Builder = .{ .a = a };
    defer b.deinit();
    var pc: ?u32 = null;
    var at: usize = 4;
    while (true) {
        if (at >= bytes.len) return error.Truncated;
        const chunk = bytes[at];
        at += 1;
        const body: usize = switch (chunk) {
            0 => break,
            1 => 8,
            2, 7 => 4,
            3 => 6,
            4 => 4,
            5 => 3,
            6 => 5,
            8 => 1,
            else => return error.BadFormat,
        };
        if (bytes.len - at < body) return error.Truncated;
        switch (chunk) {
            1 => {
                const len = read32(bytes, at + 4);
                if (bytes.len - at - body < len) return error.Truncated;
                try b.segment(read32(bytes, at), bytes[at + body ..][0..len]);
                at += len;
            },
            3...6 => if (read16(bytes, at) == cpe_pc) {
                pc = switch (chunk) {
                    3 => read32(bytes, at + 2),
                    4 => read16(bytes, at + 2),
                    5 => bytes[at + 2],
                    else => @as(u32, read16(bytes, at + 2)) | @as(u32, bytes[at + 4]) << 16,
                };
            },
            else => {},
        }
        at += body;
    }
    return b.finish(.cpe, .{ .pc = pc orelse return error.NoEntry }, null);
}

/// A 32-bit little-endian MIPS ELF: each `PT_LOAD` is copied and its
/// `memsz` tail past `filesz` zeroed. No `gp` or `sp` is set.
fn parseElf(a: std.mem.Allocator, bytes: []const u8) Error!Program {
    if (bytes.len < 52) return error.Truncated;
    if (bytes[4] != 1 or bytes[5] != 1 or read16(bytes, 18) != elf_mips) return error.BadFormat;
    var b: Builder = .{ .a = a };
    defer b.deinit();

    const phoff = read32(bytes, 28);
    const phentsize = read16(bytes, 42);
    const phnum = read16(bytes, 44);
    if (phentsize < 32) return error.BadFormat;
    if (@as(u64, phoff) + @as(u64, phentsize) * phnum > bytes.len) return error.Truncated;
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        if (read32(bytes, ph) != elf_load) continue;
        const offset = read32(bytes, ph + 4);
        const vaddr = read32(bytes, ph + 8);
        const filesz = read32(bytes, ph + 16);
        const memsz = read32(bytes, ph + 20);
        if (@as(u64, offset) + filesz > bytes.len) return error.Truncated;
        try b.segment(vaddr, bytes[offset..][0..filesz]);
        if (memsz > filesz) try b.fill(vaddr +% filesz, memsz - filesz);
    }
    return b.finish(.elf, .{ .pc = read32(bytes, 24) }, null);
}
