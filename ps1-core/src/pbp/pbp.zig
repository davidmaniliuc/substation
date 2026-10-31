//! PS1 eboots (`.pbp`): the PSP's container for a PS1 disc. A header points
//! at a PARAM.SFO and at the DATA.PSAR, which holds one disc or, for a
//! multi-disc title, up to five. A disc is a TOC and a table of 16-sector
//! blocks, each stored or deflated. Encrypted discs are refused. Read in
//! place over a BORROWED file, one block inflated at a time; see `Reader`.
const std = @import("std");
const disc = @import("../disc.zig");
const sfo = @import("sfo.zig");
const toc = @import("toc.zig");
const u32At = sfo.u32At;
const constants = @import("../constants.zig");

const pbp_magic = "\x00PBP";
const psar_slot = 0x24;
const sfo_slot = 0x08;
const header_bytes = 0x28;
const sector_bytes = constants.sector_bytes;
const lead_in = constants.lead_in_frames;

const multi_magic = "PSTITLEIMG000000";
const multi_table = 0x200;
const max_discs = 5;
const disc_magic = "PSISOIMG0000";
const encrypted_magic: u32 = 0x44475000;
const encrypted_at = 0x400;
const toc_at = 0x800;
const image_offset_at = 0xBFC;
const table_at = 0x4000;
const table_entries = 32256;
const table_entry_bytes = 32;

const block_sectors = 16;
pub const block_bytes = block_sectors * sector_bytes;

pub const Error = error{ OutOfMemory, BadPbp, EncryptedPbp };

pub fn isPbp(data: []const u8) bool {
    return std.mem.startsWith(u8, data, pbp_magic);
}

/// `data[at..]`, or `BadPbp` when `at` is past the end.
fn from(data: []const u8, at: u64) error{BadPbp}![]const u8 {
    if (at > data.len) return error.BadPbp;
    return data[@intCast(at)..];
}

/// The SFO and the PSAR of a well-formed eboot.
fn sections(data: []const u8) error{BadPbp}!struct { sfo: []const u8, psar: []const u8 } {
    if (!isPbp(data) or data.len < header_bytes) return error.BadPbp;
    return .{
        .sfo = try from(data, u32At(data, sfo_slot)),
        .psar = try from(data, u32At(data, psar_slot)),
    };
}

/// How many discs the eboot holds, 1 to 5.
pub fn discCount(data: []const u8) Error!u8 {
    const s = try sections(data);
    _ = try sfo.parse(s.sfo);
    return (try discOffsets(s.psar)).count;
}

/// The title the eboot's PARAM.SFO gives, borrowed; empty when it names none.
pub fn title(data: []const u8) Error![]const u8 {
    return (try sfo.parse((try sections(data)).sfo)).title;
}

const Offsets = struct { count: u8, at: [max_discs]u32 };

/// Where each disc starts, relative to the PSAR.
fn discOffsets(psar: []const u8) Error!Offsets {
    if (!std.mem.startsWith(u8, psar, multi_magic)) return .{ .count = 1, .at = .{ 0, 0, 0, 0, 0 } };
    if (psar.len < multi_table + 4 * max_discs) return error.BadPbp;
    var out: Offsets = .{ .count = 0, .at = @splat(0) };
    while (out.count < max_discs) : (out.count += 1) {
        const at = u32At(psar, multi_table + 4 * @as(usize, out.count));
        if (at == 0) break;
        out.at[out.count] = at;
    }
    if (out.count == 0) return error.BadPbp;
    if (out.at[0] == encrypted_magic) return error.EncryptedPbp;
    return out;
}

/// Reads one disc of an eboot in place. `data` is borrowed and must outlive
/// the reader. Holds the one block last inflated, so it is not thread-safe.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    /// Where the block table's offsets are relative to.
    image: u64,
    table: []const u8,
    sectors: i32,
    track1_pregap: i32,
    tracks: [99]disc.Track = undefined,
    track_count: u8 = 0,
    block: [block_bytes]u8 = undefined,
    /// How much of `block` the stream held: a final block may inflate short.
    block_len: usize = 0,
    block_index: ?u32 = null,
    window: [std.compress.flate.max_window_len]u8 = undefined,

    /// Opens disc `index` (from 0).
    pub fn open(gpa: std.mem.Allocator, data: []const u8, index: u8) Error!*Reader {
        const s = try sections(data);
        _ = try sfo.parse(s.sfo);
        const offsets = try discOffsets(s.psar);
        if (index >= offsets.count) return error.BadPbp;
        const header = try from(s.psar, offsets.at[index]);
        if (!std.mem.startsWith(u8, header, disc_magic)) return error.BadPbp;
        if (header.len < table_at + table_entries * table_entry_bytes) return error.BadPbp;
        if (u32At(header, encrypted_at) == encrypted_magic) return error.EncryptedPbp;

        const self = try gpa.create(Reader);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .data = data,
            .image = @as(u64, u32At(data, psar_slot)) + offsets.at[index] + u32At(header, image_offset_at),
            .table = header[table_at..][0 .. table_entries * table_entry_bytes],
            .sectors = 0,
            .track1_pregap = 0,
        };
        const layout = try toc.tracks(header[toc_at..][0..toc.toc_bytes], &self.tracks);
        self.track_count = layout.count;
        self.sectors = layout.sectors;
        self.track1_pregap = layout.track1_pregap;
        return self;
    }

    pub fn close(self: *Reader) void {
        self.gpa.destroy(self);
    }

    pub fn sectorCount(self: *const Reader) i32 {
        return self.sectors;
    }

    pub fn readSector(self: *Reader, lba: i32, out: *[sector_bytes]u8) bool {
        if (lba < 0 or lba >= self.sectors) return false;
        const placed = lba + lead_in - self.track1_pregap;
        if (placed < 0) return false;
        const file_sector: u32 = @intCast(placed);
        if (!self.load(file_sector / block_sectors)) return false;
        if ((file_sector % block_sectors + 1) * sector_bytes > self.block_len) return false;
        out.* = self.block[file_sector % block_sectors * sector_bytes ..][0..sector_bytes].*;
        return true;
    }

    /// Makes block `n` the cached one; false when it is absent or will not inflate.
    fn load(self: *Reader, n: u32) bool {
        if (self.block_index == n) return true;
        self.block_index = null;
        if (n >= table_entries) return false;
        const entry = self.table[n * table_entry_bytes ..][0..table_entry_bytes];
        const size = std.mem.readInt(u16, entry[4..6], .little);
        const start = self.image + u32At(entry, 0);
        if (size == 0 or start + size > self.data.len) return false;
        const stored = self.data[@intCast(start)..][0..size];
        if (size == block_bytes) {
            self.block = stored[0..block_bytes].*;
            self.block_len = block_bytes;
        } else {
            var in = std.Io.Reader.fixed(stored);
            var inflate = std.compress.flate.Decompress.init(&in, .raw, &self.window);
            // A stream that ends cleanly short is a final block with no padding;
            // a sector past what it held is refused in `readSector`.
            self.block_len = inflate.reader.readSliceShort(&self.block) catch return false;
        }
        self.block_index = n;
        return true;
    }
};
