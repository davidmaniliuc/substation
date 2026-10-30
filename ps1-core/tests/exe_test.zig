const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const ps1_core = @import("ps1_core");
const exe = ps1_core.exe;

const gpa = std.testing.allocator;
const psexe_header = 0x800;

const PsExe = struct {
    pc: u32 = 0x80010000,
    gp: u32 = 0,
    dest: u32 = 0x80010000,
    file_size: u32 = 16,
    memfill_start: u32 = 0,
    memfill_size: u32 = 0,
    sp_base: u32 = 0,
    sp_off: u32 = 0,
    marker: []const u8 = "",
    payload: usize = 16,
};

fn put32(buf: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], v, .little);
}

fn put16(buf: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], v, .little);
}

fn makePsExe(o: PsExe) ![]u8 {
    const buf = try gpa.alloc(u8, psexe_header + o.payload);
    @memset(buf, 0);
    @memcpy(buf[0..8], "PS-X EXE");
    put32(buf, 0x10, o.pc);
    put32(buf, 0x14, o.gp);
    put32(buf, 0x18, o.dest);
    put32(buf, 0x1C, o.file_size);
    put32(buf, 0x28, o.memfill_start);
    put32(buf, 0x2C, o.memfill_size);
    put32(buf, 0x30, o.sp_base);
    put32(buf, 0x34, o.sp_off);
    @memcpy(buf[0x4C..][0..o.marker.len], o.marker);
    for (buf[psexe_header..], 0..) |*b, i| b.* = @truncate(i + 1);
    return buf;
}

test "psexeParsesHeader" {
    const bytes = try makePsExe(.{
        .gp = 0x8001F000,
        .sp_base = 0x801FFF00,
        .sp_off = 0x10,
        .memfill_start = 0x80020001,
        .memfill_size = 10,
    });
    defer gpa.free(bytes);
    var p = try exe.parse(gpa, bytes);
    defer p.deinit(gpa);

    try expectEqual(exe.Format.psexe, p.format);
    try expectEqual(@as(usize, 1), p.segments.len);
    try expectEqual(@as(u32, 0x80010000), p.segments[0].addr);
    try expectEqualSlices(u8, bytes[psexe_header..], p.segments[0].bytes);
    try expectEqual(@as(usize, 1), p.fills.len);
    try expectEqual(exe.Fill{ .addr = 0x80020000, .len = 8 }, p.fills[0]);
    try expectEqual(exe.Entry{ .pc = 0x80010000, .gp = 0x8001F000, .sp = 0x801FFF10 }, p.entry);
    try expectEqual(@as(?ps1_core.discid.Region, null), p.region);
}

test "psexeRegionMarker" {
    const cases = [_]struct { []const u8, ps1_core.discid.Region }{
        .{ "Sony Computer Entertainment Inc. for Europe area", .europe },
        .{ "Sony Computer Entertainment Inc. for North America area", .america },
        .{ "Sony Computer Entertainment Inc. for Japan area", .japan },
    };
    for (cases) |c| {
        const bytes = try makePsExe(.{ .marker = c[0] });
        defer gpa.free(bytes);
        var p = try exe.parse(gpa, bytes);
        defer p.deinit(gpa);
        try expectEqual(@as(?ps1_core.discid.Region, c[1]), p.region);
    }
}

test "psexeFileSizeClamped" {
    const bytes = try makePsExe(.{ .file_size = 0x1000 });
    defer gpa.free(bytes);
    var p = try exe.parse(gpa, bytes);
    defer p.deinit(gpa);
    try expectEqual(@as(usize, 16), p.segments[0].bytes.len);
}

const cpe_load = [_]u8{ 1, 0x00, 0x00, 0x01, 0x80, 4, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF };
const cpe_set_pc = [_]u8{ 3, 0x90, 0x00, 0x00, 0x00, 0x01, 0x80 };

test "cpeLoadsAndSetsPc" {
    const bytes = "CPE\x01" ++ [_]u8{ 8, 0 } ++ cpe_load ++ cpe_set_pc ++ [_]u8{0};
    var p = try exe.parse(gpa, bytes);
    defer p.deinit(gpa);
    try expectEqual(exe.Format.cpe, p.format);
    try expectEqual(@as(usize, 1), p.segments.len);
    try expectEqual(@as(u32, 0x80010000), p.segments[0].addr);
    try expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, p.segments[0].bytes);
    try expectEqual(@as(u32, 0x80010000), p.entry.pc);
    try expectEqual(@as(u32, 0), p.entry.gp);
}

test "cpeWithoutPcIsNoEntry" {
    const bytes = "CPE\x01" ++ [_]u8{ 8, 0 } ++ cpe_load ++ [_]u8{0};
    try expectError(error.NoEntry, exe.parse(gpa, bytes));
}

test "cpeUnknownChunkRefused" {
    const bytes = "CPE\x01" ++ [_]u8{ 9, 0 } ++ cpe_set_pc ++ [_]u8{0};
    try expectError(error.BadFormat, exe.parse(gpa, bytes));
}

test "cpeWithoutEndChunkIsTruncated" {
    const bytes = "CPE\x01" ++ cpe_load ++ cpe_set_pc;
    try expectError(error.Truncated, exe.parse(gpa, bytes));
}

const elf_header = 52;
const elf_phdr = 32;

fn makeElf(data_encoding: u8) ![]u8 {
    const payload_at = elf_header + elf_phdr;
    const buf = try gpa.alloc(u8, payload_at + 8);
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7FELF");
    buf[4] = 1; // ELFCLASS32
    buf[5] = data_encoding;
    buf[6] = 1;
    put16(buf, 16, 2); // ET_EXEC
    put16(buf, 18, 8); // EM_MIPS
    put32(buf, 20, 1);
    put32(buf, 24, 0x80010000); // e_entry
    put32(buf, 28, elf_header); // e_phoff
    put16(buf, 40, elf_header);
    put16(buf, 42, elf_phdr);
    put16(buf, 44, 1); // e_phnum
    put32(buf, elf_header + 0, 1); // PT_LOAD
    put32(buf, elf_header + 4, payload_at);
    put32(buf, elf_header + 8, 0x80010000);
    put32(buf, elf_header + 12, 0x80010000);
    put32(buf, elf_header + 16, 8); // filesz
    put32(buf, elf_header + 20, 24); // memsz
    for (buf[payload_at..], 0..) |*b, i| b.* = @truncate(0xA0 + i);
    return buf;
}

test "elfLoadsSegments" {
    const bytes = try makeElf(1);
    defer gpa.free(bytes);
    var p = try exe.parse(gpa, bytes);
    defer p.deinit(gpa);
    try expectEqual(exe.Format.elf, p.format);
    try expectEqual(@as(usize, 1), p.segments.len);
    try expectEqual(@as(u32, 0x80010000), p.segments[0].addr);
    try expectEqual(@as(usize, 8), p.segments[0].bytes.len);
    try expectEqual(@as(usize, 1), p.fills.len);
    try expectEqual(exe.Fill{ .addr = 0x80010008, .len = 16 }, p.fills[0]);
    try expectEqual(exe.Entry{ .pc = 0x80010000 }, p.entry);
}

test "elfBigEndianRefused" {
    const bytes = try makeElf(2);
    defer gpa.free(bytes);
    try expectError(error.BadFormat, exe.parse(gpa, bytes));
}

test "refusals" {
    try expectError(error.Truncated, exe.parse(gpa, "PS-X EX"));
    try expectError(error.BadFormat, exe.parse(gpa, "MZ\x90\x00"));

    const past_ram = try makePsExe(.{ .dest = 0x801FFFF8 });
    defer gpa.free(past_ram);
    try expectError(error.OutsideRam, exe.parse(gpa, past_ram));

    const header_only = try makePsExe(.{ .payload = 0 });
    defer gpa.free(header_only);
    try expectError(error.Truncated, exe.parse(gpa, header_only[0 .. psexe_header - 1]));
}

test "fingerprintDependsOnLibps" {
    try expect(exe.fingerprint("main", "") != exe.fingerprint("main", "libps"));
    try expectEqual(exe.fingerprint("main", "libps"), exe.fingerprint("main", "libps"));
}
