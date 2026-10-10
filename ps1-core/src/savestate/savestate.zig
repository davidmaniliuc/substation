//! Savestates: the whole emulated machine as a versioned, sectioned blob.
//!
//! Each device's section is written by hand in this directory and carries its
//! OWN version. When a device's state changes, bump that section's version in
//! `sections` and teach its `load` to read the old layout too, supplying the
//! new field's power-on value — that is what lets a state survive an update.
//! A tag or a section version this build does not know is refused outright:
//! a newer build's state is never half-read.
//!
//! `load` writes straight into the machine it is given. Atomicity is the
//! caller's: hand it a scratch `Bus`, and swap that in only on success.
//! `loadTrusted` is the one in-place exception, for bytes `saveTrusted`
//! produced in this process: a runahead `Mark` and the `Rewind` ring.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Bus = @import("../memory.zig").Bus;
const discid = @import("../discid.zig");
const bios = @import("../bios.zig");
const scheduler = @import("../cpu/scheduler.zig");

pub const stream = @import("stream.zig");
pub const crc32 = @import("crc32.zig");
pub const Mark = @import("mark.zig").Mark;
pub const rewind = @import("rewind.zig");
pub const Rewind = rewind.Rewind;
pub const cpu_state = @import("cpu_state.zig");
pub const io_state = @import("io_state.zig");
pub const gpu_state = @import("gpu_state.zig");
pub const spu_state = @import("spu_state.zig");
pub const cdrom_state = @import("cdrom_state.zig");

const Writer = stream.Writer;
const Reader = stream.Reader;
pub const Error = stream.Error;

pub const header_len: usize = 72;
pub const format_version: u32 = 2;
/// Version 1 had no patch fingerprint; it reads as an unpatched disc.
const v1_header_len: usize = 64;
const magic = "SBST";

/// What a state must be resumed against: the BIOS image it ran (by hash —
/// the bytes are the user's file and never travel) and the disc in the tray.
/// The hash is of the ORIGINAL image: a fast-boot patch is host
/// configuration, so a state resumes with the setting either way. A `.ppf`
/// is not: a translation keeps the disc's serial, and resuming across it
/// would mix two programs in RAM, so its fingerprint is part of the disc.
pub const Identity = struct {
    bios_sha256: [32]u8,
    serial: [16]u8,
    /// `ppf.Overlay.fingerprint`; 0 for an unpatched disc.
    patch: u64 = 0,
};

pub fn identityOf(bus: *const Bus) Identity {
    var id = Identity{ .bios_sha256 = bios.originalSha256(&bus.bios, bus.bios_patch), .serial = @splat(0) };
    if (bus.cdrom.disc) |d| {
        id.serial = discid.identify(d).serial.buf;
        id.patch = d.patch.fingerprint;
    }
    return id;
}

const Section = struct {
    tag: [4]u8,
    version: u32,
    save: *const fn (*const Cpu, *Writer) Error!void,
    load: *const fn (*Cpu, *Reader, u32) Error!void,
};

const sections = [_]Section{
    .{ .tag = "BUS ".*, .version = 1, .save = io_state.saveBus, .load = io_state.loadBus },
    .{ .tag = "CPU ".*, .version = 1, .save = cpu_state.saveCpu, .load = cpu_state.loadCpu },
    .{ .tag = "IRQ ".*, .version = 1, .save = io_state.saveIrq, .load = io_state.loadIrq },
    .{ .tag = "TMR ".*, .version = 1, .save = io_state.saveTimers, .load = io_state.loadTimers },
    .{ .tag = "DMA ".*, .version = 1, .save = io_state.saveDma, .load = io_state.loadDma },
    .{ .tag = "GPU ".*, .version = 1, .save = gpu_state.saveGpu, .load = gpu_state.loadGpu },
    .{ .tag = "SPU ".*, .version = 1, .save = spu_state.saveSpu, .load = spu_state.loadSpu },
    .{ .tag = "CDR ".*, .version = 1, .save = cdrom_state.saveCdrom, .load = cdrom_state.loadCdrom },
    .{ .tag = "MDEC".*, .version = 1, .save = io_state.saveMdec, .load = io_state.loadMdec },
    .{ .tag = "SIO ".*, .version = 2, .save = io_state.saveSio, .load = io_state.loadSio },
};

/// The version this build writes for `tag`. For tests that drive one
/// section's save and load directly.
pub fn sectionVersion(tag: [4]u8) u32 {
    return sections[indexOfTag(tag).?].version;
}

/// With `dst == null`, returns the exact size without writing anything.
pub fn save(cpu: *const Cpu, dst: ?[]u8) Error!usize {
    return write(cpu, dst, identityOf(cpu.bus), true);
}

/// `save` for bytes that never leave this process: a runahead mark or a
/// rewind snapshot, restored a few frames later by `loadTrusted`. It skips
/// the two costs only a file needs, the checksum and the identity (the BIOS
/// hash alone is ~250 us), and writes both as zero. It drains the raster
/// worker itself, because the GPU section reads VRAM.
pub fn saveTrusted(cpu: *const Cpu, dst: ?[]u8) Error!usize {
    cpu.bus.gpu.syncRaster();
    return write(cpu, dst, .{ .bios_sha256 = @splat(0), .serial = @splat(0) }, false);
}

fn write(cpu: *const Cpu, dst: ?[]u8, id: Identity, checksum: bool) Error!usize {
    // Every device must hold what a per-step tick would have left it; the
    // scheduler's backlog is not part of a state.
    scheduler.sync(cpu.bus);
    var w = Writer{ .buf = dst };
    try w.bytes(magic);
    try w.int(format_version);
    try w.int(@as(u32, 0)); // crc32, patched below
    try w.int(@as(u32, 0)); // body_len, patched below
    try w.bytes(&id.bios_sha256);
    try w.bytes(&id.serial);
    try w.int(id.patch);
    std.debug.assert(w.len == header_len);

    for (sections) |s| {
        try w.bytes(&s.tag);
        try w.int(s.version);
        const len_at = w.len;
        try w.int(@as(u32, 0));
        const start = w.len;
        try s.save(cpu, &w);
        w.patchU32(len_at, @intCast(w.len - start));
    }

    if (w.buf) |buf| {
        w.patchU32(12, @intCast(w.len - header_len));
        if (checksum) w.patchU32(8, crc32.hash(buf[header_len..w.len]));
    }
    return w.len;
}

const Header = struct { crc: u32, id: Identity, len: usize };

/// Everything a header promises except the checksum: magic, container
/// version and body length.
fn header(src: []const u8) Error!Header {
    if (src.len < v1_header_len or !std.mem.eql(u8, src[0..4], magic)) return error.StateBadMagic;
    const version = std.mem.readInt(u32, src[4..8], .little);
    if (version == 0 or version > format_version) return error.StateVersion;
    const len = if (version == 1) v1_header_len else header_len;
    if (src.len < len) return error.StateCorrupt;
    var r = Reader{ .buf = src[8..len] };
    const crc = try r.int(u32);
    const body_len = try r.int(u32);
    if (body_len != src.len - len) return error.StateCorrupt;
    var h = Header{ .crc = crc, .id = undefined, .len = len };
    @memcpy(&h.id.bios_sha256, try r.bytes(32));
    @memcpy(&h.id.serial, try r.bytes(16));
    h.id.patch = if (version == 1) 0 else try r.int(u64);
    return h;
}

/// Validates the header and the checksum and returns what the state must be
/// resumed against. Needs no machine — the app reads it for its launch prompt.
pub fn peek(src: []const u8) Error!Identity {
    return (try checked(src)).id;
}

fn checked(src: []const u8) Error!Header {
    const h = try header(src);
    if (crc32.hash(src[h.len..]) != h.crc) return error.StateCorrupt;
    return h;
}

pub fn load(cpu: *Cpu, src: []const u8) Error!void {
    const h = try checked(src);
    const want = identityOf(cpu.bus);
    if (!std.mem.eql(u8, &h.id.bios_sha256, &want.bios_sha256)) return error.StateBios;
    if (!std.mem.eql(u8, &h.id.serial, &want.serial)) return error.StateDisc;
    if (h.id.patch != want.patch) return error.StatePatch;
    try readSections(cpu, src[h.len..]);
}

/// `load` for `saveTrusted`'s bytes, into the RUNNING machine: no scratch
/// `Bus`, so the block cache, the raster worker and every PGXP shadow
/// survive. A shadow left over from frames the load undid is judged by the
/// word it was recorded against, like any other.
///
/// Only for bytes this process produced moments ago. It skips the checksum
/// and the identity, and a refusal part-way leaves the machine half-written;
/// a file goes through `load` into a scratch `Bus`, always.
pub fn loadTrusted(cpu: *Cpu, src: []const u8) Error!void {
    const h = try header(src);
    cpu.bus.gpu.syncRaster();
    try readSections(cpu, src[h.len..]);
    cpu.bus.gpu.reseatRasterWorker();
}

fn readSections(cpu: *Cpu, body: []const u8) Error!void {
    // Every section below writes the machine directly, behind the bus's
    // invalidation hook, so the blocks are reconciled here instead: the BUS
    // section drops exactly the code pages whose RAM the state changes, and
    // the BIOS never changes. The CPU section restores the state's I-cache
    // lines, which a block engine never snoops, so the dispatcher flushes
    // them before its next block. The load moves the PC, so a link pending
    // from the block that ran before it is forgotten.
    if (cpu.bus.blocks) |c| {
        c.icache_dirty = true;
        c.pins.link_site = null;
        c.pins.running = null;
    }

    var r = Reader{ .buf = body };
    var seen: [sections.len]bool = @splat(false);
    while (r.pos < r.buf.len) {
        const tag = (try r.bytes(4))[0..4].*;
        const version = try r.int(u32);
        const len = try r.int(u32);
        var sub = Reader{ .buf = try r.bytes(len) };
        const i = indexOfTag(tag) orelse return error.StateVersion;
        if (seen[i]) return error.StateCorrupt;
        if (version == 0 or version > sections[i].version) return error.StateVersion;
        try sections[i].load(cpu, &sub, version);
        try sub.end();
        seen[i] = true;
    }
    for (seen) |s| if (!s) return error.StateCorrupt;
}

fn indexOfTag(tag: [4]u8) ?usize {
    for (sections, 0..) |s, i| {
        if (std.mem.eql(u8, &s.tag, &tag)) return i;
    }
    return null;
}
