//! `image-write`: a disc read from its cue, written out again as a CloneCD set,
//! an ECM or an ISO, so each format the core reads can be checked against the
//! rip it was made from. The encoders take a raw image in memory and touch no
//! file, which is what lets the core's tests build their fixtures with them.
const std = @import("std");
const ps1 = @import("ps1_core");

const Disc = ps1.disc.Disc;
const MSF = ps1.disc.MSF;
const sector = ps1.sector;
const sector_bytes = ps1.constants.sector_bytes;
const iso_bytes = 2048;
const sub_bytes = 96;
const q_offset = 12;
const lead_in = ps1.constants.lead_in_frames;

pub const Format = enum {
    ccd,
    ecm,
    iso,
    pbp,
    mds,
    @"mds-sub",
};

/// What a write did: `refused` is a disc the format cannot hold, which is
/// not a failure of the disc or of the writer.
pub const Outcome = enum { written, refused };

/// Writes `d`, a disc over a flat raw image, as `format` beside `stem`:
/// `<stem>.ccd/.img/.sub`, `<stem>.ecm` with the `<stem>.cue` that lays its
/// tracks out, `<stem>.iso`, `<stem>.mds/.mdf` (`mds-sub` with subchannel), or
/// `<stem>.pbp`, the one format that takes several discs, in order, titled
/// `title`. Every other format takes exactly one.
pub fn write(gpa: std.mem.Allocator, io: std.Io, discs: []const Disc, format: Format, stem: []const u8, title: []const u8) !Outcome {
    const d = discs[0];
    if (discs.len > 1 and format != .pbp) return error.BadArguments;
    const raw = d.source.flat;
    switch (format) {
        .pbp => {
            if (discs.len > 5) return error.BadArguments;
            const list = try gpa.alloc(PbpDisc, discs.len);
            defer gpa.free(list);
            for (discs, list) |disc, *item| item.* = .{ .raw = disc.source.flat, .d = disc };
            const encoded = try encodePbp(gpa, list, title, false);
            defer gpa.free(encoded);
            try put(gpa, io, stem, ".pbp", encoded);
        },
        .mds, .@"mds-sub" => {
            const pair = try encodeMds(gpa, d, raw, format == .@"mds-sub");
            defer gpa.free(pair.mds);
            defer gpa.free(pair.mdf);
            try put(gpa, io, stem, ".mdf", pair.mdf);
            try put(gpa, io, stem, ".mds", pair.mds);
        },
        .ccd => {
            try put(gpa, io, stem, ".img", raw);
            const sheet = try ccdSheet(gpa, d);
            defer gpa.free(sheet);
            try put(gpa, io, stem, ".ccd", sheet);
            const sub = try subchannel(gpa, d);
            defer gpa.free(sub);
            try put(gpa, io, stem, ".sub", sub);
        },
        .ecm => {
            const encoded = try encodeEcm(gpa, raw);
            defer gpa.free(encoded);
            try put(gpa, io, stem, ".ecm", encoded);
            const name = try std.fmt.allocPrint(gpa, "{s}.ecm", .{std.fs.path.basename(stem)});
            defer gpa.free(name);
            const cue = try singleFileCue(gpa, d, name);
            defer gpa.free(cue);
            try put(gpa, io, stem, ".cue", cue);
        },
        .iso => {
            if (d.track_count != 1 or d.tracks[0].type != .data) return .refused;
            const cooked = try cook(gpa, raw);
            defer gpa.free(cooked);
            try put(gpa, io, stem, ".iso", cooked);
        },
    }
    return .written;
}

fn put(gpa: std.mem.Allocator, io: std.Io, stem: []const u8, ext: []const u8, data: []const u8) !void {
    const path = try std.mem.concat(gpa, u8, &.{ stem, ext });
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// The mode byte of a data track's first sector, as a cue or CloneCD MODE
/// names it: 1 or 2, and 2 for a sector that carries neither.
fn dataMode(d: Disc, t: ps1.disc.Track) u8 {
    var raw: [sector_bytes]u8 = undefined;
    if (!d.readSector2352(t.start_lba, &raw) or raw[15] != 1) return 2;
    return 1;
}

/// A cue sheet naming `file` alone, every track at its absolute place in it:
/// a multi-FILE rip's tracks laid out as one image.
pub fn singleFileCue(gpa: std.mem.Allocator, d: Disc, file: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "FILE \"{s}\" BINARY\n", .{file});
    for (d.tracks[0..d.track_count]) |t| {
        if (t.type == .audio) {
            try out.print(gpa, "  TRACK {d:0>2} AUDIO\n", .{t.number});
        } else {
            try out.print(gpa, "  TRACK {d:0>2} MODE{d}/2352\n", .{ t.number, dataMode(d, t) });
        }
        if (t.pregap_lba) |p| try putCueIndex(gpa, &out, 0, p);
        try putCueIndex(gpa, &out, 1, t.start_lba);
    }
    return out.toOwnedSlice(gpa);
}

/// A cue's MSF is decimal and counts from the file's first sector.
fn putCueIndex(gpa: std.mem.Allocator, out: *std.ArrayList(u8), index: u8, lba: i32) !void {
    const n: u32 = @intCast(lba);
    try out.print(gpa, "    INDEX {d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{ index, n / 4500, n / 75 % 60, n % 75 });
}

/// The CloneCD control file of `d`: the TOC as the drive reads it (A0, A1,
/// the lead-out A2, then one entry per track) and a TRACK section per track.
/// The image starts at LBA 0, so no track 1 pregap is stored.
pub fn ccdSheet(gpa: std.mem.Allocator, d: Disc) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const first = d.tracks[0];
    const last = d.tracks[d.track_count - 1];
    const disc_control: u8 = if (first.type == .data) 4 else 0;
    try out.print(gpa, "[CloneCD]\nVersion=3\n[Disc]\nTocEntries={d}\nSessions=1\nDataTracksScrambled=0\nCDTextLength=0\n", .{d.track_count + 3});
    try out.appendSlice(gpa, "[Session 1]\nPreGapMode=2\nPreGapSubC=0\n");
    // A0's PSEC is the disc type: 0x20, CD-ROM XA.
    try putEntry(gpa, &out, 0, 0xA0, disc_control, .{ .m = first.number, .s = 0x20, .f = 0 });
    try putEntry(gpa, &out, 1, 0xA1, disc_control, .{ .m = last.number, .s = 0, .f = 0 });
    try putEntry(gpa, &out, 2, 0xA2, disc_control, plain(d.sectorCount()));
    for (d.tracks[0..d.track_count], 3..) |t, i| {
        try putEntry(gpa, &out, i, t.number, if (t.type == .data) 4 else 0, plain(t.start_lba));
    }
    for (d.tracks[0..d.track_count]) |t| {
        const mode: u8 = if (t.type == .audio) 0 else dataMode(d, t);
        try out.print(gpa, "[TRACK {d}]\nMODE={d}\n", .{ t.number, mode });
        if (t.pregap_lba) |p| try out.print(gpa, "INDEX 0={d}\n", .{p});
        try out.print(gpa, "INDEX 1={d}\n", .{t.start_lba});
    }
    return out.toOwnedSlice(gpa);
}

/// A TOC entry's P field: binary minutes, seconds and frames.
const Pmsf = struct { m: u8, s: u8, f: u8 };

fn plain(lba: i32) Pmsf {
    const n: u32 = @intCast(lba + lead_in);
    return .{ .m = @intCast(n / 4500), .s = @intCast(n / 75 % 60), .f = @intCast(n % 75) };
}

fn putEntry(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: usize, point: u8, control: u8, p: Pmsf) !void {
    const plba = (@as(i32, p.m) * 60 + p.s) * 75 + p.f - lead_in;
    try out.print(gpa,
        \\[Entry {d}]
        \\Session=1
        \\Point=0x{x:0>2}
        \\ADR=0x01
        \\Control=0x{x:0>2}
        \\TrackNo=0
        \\AMin=0
        \\ASec=0
        \\AFrame=0
        \\ALBA=-150
        \\Zero=0
        \\PMin={d}
        \\PSec={d}
        \\PFrame={d}
        \\PLBA={d}
        \\
    , .{ n, point, control, p.m, p.s, p.f, plba });
}

/// The `.sub` of `d`: 96 bytes per sector, P and R-W empty, a Q that is
/// valid for its address, but for the LibCrypt sectors `d`'s `.sbi` names,
/// whose CRC is inverted as the protection's own is.
pub fn subchannel(gpa: std.mem.Allocator, d: Disc) ![]u8 {
    const count: usize = @intCast(d.sectorCount());
    const sub = try gpa.alloc(u8, count * sub_bytes);
    @memset(sub, 0);
    for (0..count) |i| {
        const lba: i32 = @intCast(i);
        const s = d.getSubchannelQ(lba);
        const control_adr: u8 = if (d.trackForLba(lba).type == .data) 0x41 else 0x01;
        const q = sub[i * sub_bytes + q_offset ..][0..12];
        q[0..10].* = .{ control_adr, s.track, s.index, s.rel_m, s.rel_s, s.rel_f, 0, s.abs_m, s.abs_s, s.abs_f };
        var crc = ps1.ccd.qCrc(q[0..10]);
        if (d.isLibCryptSector(lba)) crc = ~crc;
        std.mem.writeInt(u16, q[10..12], crc, .big);
    }
    return sub;
}

const mds_header_bytes = 0x58;
const mds_session_bytes = 24;
const mds_entry_bytes = 80;
const mds_extra_bytes = 8;
const mds_type_audio = 0xA9;
const mds_type_data = 0xAC;

/// Interleaves a Q channel into 96 bytes of subchannel, P..W otherwise empty:
/// Q byte `j` bit `7 - k` lands in bit 6 of byte `j * 8 + k`.
fn interleaveQ(q: *const [12]u8, out: *[sub_bytes]u8) void {
    @memset(out, 0);
    for (out, 0..) |*byte, n| byte.* = ((q[n / 8] >> @intCast(7 - n % 8)) & 1) << 6;
}

fn putMdsEntry(out: []u8, point: u8, control: u8, with_sub: bool, msf: Pmsf, extra: u32, offset: u32) void {
    out[0] = control;
    out[1] = @intFromBool(with_sub);
    out[4] = point;
    out[9] = msf.m;
    out[10] = msf.s;
    out[11] = msf.f;
    std.mem.writeInt(u32, out[12..16], extra, .little);
    std.mem.writeInt(u32, out[40..44], offset, .little);
}

fn bcdMsf(lba: i32) Pmsf {
    const m = MSF.fromLba(lba);
    return .{ .m = m.m, .s = m.s, .f = m.f };
}

/// An Alcohol 120% image of `d`: one session, the A0/A1/A2 entries ahead of
/// the tracks, each track's entry pointing at an extra block (pregap, length).
/// The `.mdf` is the raw sectors back to back, each followed by 96 bytes of
/// interleaved subchannel when `with_sub` is set (the LibCrypt sectors'
/// Q CRC inverted, as `subchannel` writes it).
pub fn encodeMds(gpa: std.mem.Allocator, d: Disc, raw: []const u8, with_sub: bool) !struct { mds: []u8, mdf: []u8 } {
    const count: usize = @intCast(d.sectorCount());
    std.debug.assert(raw.len == count * sector_bytes);
    const stride: usize = if (with_sub) sector_bytes + sub_bytes else sector_bytes;
    const mdf = try gpa.alloc(u8, count * stride);
    errdefer gpa.free(mdf);
    const sub = try subchannel(gpa, d);
    defer gpa.free(sub);
    for (0..count) |i| {
        @memcpy(mdf[i * stride ..][0..sector_bytes], raw[i * sector_bytes ..][0..sector_bytes]);
        if (with_sub) {
            const q = sub[i * sub_bytes + q_offset ..][0..12];
            interleaveQ(q, mdf[i * stride + sector_bytes ..][0..sub_bytes]);
        }
    }

    const tracks = d.tracks[0..d.track_count];
    const entries = tracks.len + 3;
    const extra_at = mds_header_bytes + mds_session_bytes + entries * mds_entry_bytes;
    const mds = try gpa.alloc(u8, extra_at + tracks.len * mds_extra_bytes);
    errdefer gpa.free(mds);
    @memset(mds, 0);
    @memcpy(mds[0..16], "MEDIA DESCRIPTOR");
    std.mem.writeInt(u32, mds[0x50..][0..4], mds_header_bytes, .little);
    const session = mds[mds_header_bytes..][0..mds_session_bytes];
    std.mem.writeInt(u16, session[14..16], @intCast(tracks.len), .little);
    std.mem.writeInt(u32, session[20..24], mds_header_bytes + mds_session_bytes, .little);

    const first = tracks[0];
    const last = tracks[tracks.len - 1];
    const disc_control: u8 = if (first.type == .data) mds_type_data else mds_type_audio;
    const table = mds[mds_header_bytes + mds_session_bytes ..];
    putMdsEntry(table[0..], 0xA0, disc_control, with_sub, .{ .m = first.number, .s = 0x20, .f = 0 }, 0, 0);
    putMdsEntry(table[mds_entry_bytes..], 0xA1, disc_control, with_sub, .{ .m = last.number, .s = 0, .f = 0 }, 0, 0);
    putMdsEntry(table[2 * mds_entry_bytes ..], 0xA2, disc_control, with_sub, bcdMsf(d.sectorCount()), 0, 0);
    for (tracks, 0..) |t, i| {
        const extra = extra_at + i * mds_extra_bytes;
        const pregap: u32 = if (i == 0) 0 else @intCast(t.start_lba - (t.pregap_lba orelse t.start_lba));
        const end: i32 = if (i + 1 < tracks.len) tracks[i + 1].start_lba else d.sectorCount();
        std.mem.writeInt(u32, mds[extra..][0..4], pregap, .little);
        std.mem.writeInt(u32, mds[extra + 4 ..][0..4], @intCast(end - t.start_lba), .little);
        const on_file: usize = if (i == 0) 0 else @intCast(t.pregap_lba orelse t.start_lba);
        putMdsEntry(table[(3 + i) * mds_entry_bytes ..], ps1.disc.binaryToBcd(t.number), if (t.type == .audio) mds_type_audio else mds_type_data, with_sub, bcdMsf(t.start_lba), @intCast(extra), @intCast(on_file * stride));
    }
    return .{ .mds = mds, .mdf = mdf };
}

/// The cooked copy of `raw`: each sector's 2048 bytes of user data, from
/// wherever its own mode byte puts them. A Form 2 sector loses what it held
/// past them.
pub fn cook(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    std.debug.assert(raw.len % sector_bytes == 0);
    const count = raw.len / sector_bytes;
    const out = try gpa.alloc(u8, count * iso_bytes);
    for (0..count) |i| {
        const s = raw[i * sector_bytes ..][0..sector_bytes];
        const start: usize = if (s[15] == 1) 0x10 else 0x18;
        @memcpy(out[i * iso_bytes ..][0..iso_bytes], s[start..][0..iso_bytes]);
    }
    return out;
}

const ecm_raw = 0;
const ecm_mode1 = 1;
const ecm_form1 = 2;
const ecm_form2 = 3;
const ecm_terminator = 0xFFFFFFFF;

/// One run of records sharing a type: one chunk of the stream.
const EcmChunk = struct {
    type: u2 = ecm_raw,
    count: u32 = 0,
    records: std.ArrayList(u8) = .empty,
};

/// ECM-encodes `raw`: type 1 for a Mode 1 sector, the 16 sync/header bytes
/// raw then type 2 or 3 for a Mode 2 Form 1 or Form 2 sector, raw bytes for
/// anything else. A sector is only stripped when its rebuild matches it.
pub fn encodeEcm(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    std.debug.assert(raw.len % sector_bytes == 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "ECM\x00");

    var chunk: EcmChunk = .{};
    defer chunk.records.deinit(gpa);

    var at: usize = 0;
    while (at < raw.len) : (at += sector_bytes) {
        const s = raw[at..][0..sector_bytes];
        switch (ecmTypeOf(s)) {
            ecm_mode1 => try addRecord(gpa, &out, &chunk, ecm_mode1, &.{ s[0x0C..0x0F], s[0x10..0x810] }),
            ecm_form1 => {
                try addRecord(gpa, &out, &chunk, ecm_raw, &.{s[0..0x10]});
                try addRecord(gpa, &out, &chunk, ecm_form1, &.{s[0x14..0x818]});
            },
            ecm_form2 => {
                try addRecord(gpa, &out, &chunk, ecm_raw, &.{s[0..0x10]});
                try addRecord(gpa, &out, &chunk, ecm_form2, &.{s[0x14..0x92C]});
            },
            else => try addRecord(gpa, &out, &chunk, ecm_raw, &.{s}),
        }
    }
    try flushChunk(gpa, &out, &chunk);
    try putEcmHeader(gpa, &out, ecm_raw, ecm_terminator);
    var edc: [4]u8 = undefined;
    std.mem.writeInt(u32, &edc, sector.edc(raw), .little);
    try out.appendSlice(gpa, &edc);
    return out.toOwnedSlice(gpa);
}

fn addRecord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), chunk: *EcmChunk, kind: u2, parts: []const []const u8) !void {
    if (chunk.count != 0 and chunk.type != kind) try flushChunk(gpa, out, chunk);
    chunk.type = kind;
    for (parts) |p| try chunk.records.appendSlice(gpa, p);
    // A raw chunk is one record of `count` bytes; the others count records.
    chunk.count += if (kind == ecm_raw) @intCast(parts[0].len) else 1;
}

fn flushChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), chunk: *EcmChunk) !void {
    if (chunk.count == 0) return;
    try putEcmHeader(gpa, out, chunk.type, chunk.count - 1);
    try out.appendSlice(gpa, chunk.records.items);
    chunk.records.clearRetainingCapacity();
    chunk.count = 0;
}

fn putEcmHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: u2, count_minus_one: u32) !void {
    var n = count_minus_one >> 5;
    try out.append(gpa, @as(u8, kind) | (@as(u8, @intCast(count_minus_one & 0x1F)) << 2) | (if (n != 0) @as(u8, 0x80) else 0));
    while (n != 0) {
        const low: u8 = @intCast(n & 0x7F);
        n >>= 7;
        try out.append(gpa, low | (if (n != 0) @as(u8, 0x80) else 0));
    }
}

/// Which record a sector can be stored as: the rebuild from what that record
/// keeps must give back the sector exactly.
fn ecmTypeOf(s: *const [sector_bytes]u8) u2 {
    if (!std.mem.eql(u8, s[0..12], &sector.sync_pattern)) return ecm_raw;
    var rebuilt: [sector_bytes]u8 = @splat(0);
    rebuilt[0..12].* = sector.sync_pattern;
    rebuilt[0x0C..0x10].* = s[0x0C..0x10].*;
    switch (s[15]) {
        1 => {
            @memcpy(rebuilt[0x10..0x810], s[0x10..0x810]);
            sector.putEdc(&rebuilt, 0, 0x810);
            sector.writeEcc(&rebuilt);
            return if (std.mem.eql(u8, &rebuilt, s)) ecm_mode1 else ecm_raw;
        },
        2 => {
            if (!std.mem.eql(u8, s[0x10..0x14], s[0x14..0x18])) return ecm_raw;
            rebuilt[0x10..0x18].* = s[0x10..0x18].*;
            if (s[0x12] & 0x20 != 0) {
                @memcpy(rebuilt[0x18..0x92C], s[0x18..0x92C]);
                sector.putEdc(&rebuilt, 0x10, 0x92C);
                return if (std.mem.eql(u8, &rebuilt, s)) ecm_form2 else ecm_raw;
            }
            @memcpy(rebuilt[0x18..0x818], s[0x18..0x818]);
            sector.putEdc(&rebuilt, 0x10, 0x818);
            sector.writeEcc(&rebuilt);
            return if (std.mem.eql(u8, &rebuilt, s)) ecm_form1 else ecm_raw;
        },
        else => return ecm_raw,
    }
}

/// One disc of an eboot: its raw image and the disc whose tracks the TOC lists.
pub const PbpDisc = struct { raw: []const u8, d: Disc };

const pbp_block_sectors = 16;
const pbp_block_bytes = pbp_block_sectors * sector_bytes;
const pbp_image_offset = 0x100000;
const pbp_table_at = 0x4000;
const pbp_table_entry = 32;
const pbp_toc_at = 0x800;
const pbp_first_disc = 0x2000;

/// An eboot holding `discs`. `stored` writes every block as it is; otherwise
/// a block is deflated, unless that does not make it smaller.
pub fn encodePbp(gpa: std.mem.Allocator, discs: []const PbpDisc, title: []const u8, stored: bool) ![]u8 {
    std.debug.assert(discs.len >= 1 and discs.len <= 5);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const sfo = try encodeSfo(gpa, title);
    defer gpa.free(sfo);
    const psar = std.mem.alignForward(usize, 0x28 + sfo.len, 0x10);
    try out.resize(gpa, psar);
    @memset(out.items, 0);
    @memcpy(out.items[0..4], "\x00PBP");
    std.mem.writeInt(u32, out.items[4..8], 0x00010000, .little);
    for (0..8) |i| {
        const at: u32 = if (i == 0) 0x28 else if (i == 7) @intCast(psar) else @intCast(0x28 + sfo.len);
        std.mem.writeInt(u32, out.items[8 + 4 * i ..][0..4], at, .little);
    }
    @memcpy(out.items[0x28..][0..sfo.len], sfo);

    if (discs.len > 1) {
        try out.appendNTimes(gpa, 0, pbp_first_disc);
        @memcpy(out.items[psar..][0..16], "PSTITLEIMG000000");
    }
    const state = try gpa.create(PbpCompressor);
    defer gpa.destroy(state);
    for (discs, 0..) |disc, i| {
        if (discs.len > 1) std.mem.writeInt(u32, out.items[psar + 0x200 + 4 * i ..][0..4], @intCast(out.items.len - psar), .little);
        try writePbpDisc(gpa, &out, state, disc, stored);
        try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, out.items.len, 0x10) - out.items.len);
    }
    return out.toOwnedSlice(gpa);
}

const PbpCompressor = struct {
    window: [std.compress.flate.max_window_len]u8,
    buffer: [pbp_block_bytes + 1024]u8,
};

fn encodeSfo(gpa: std.mem.Allocator, title: []const u8) ![]u8 {
    const Item = struct { key: []const u8, text: ?[]const u8, number: u32 };
    const items = [_]Item{
        .{ .key = "BOOTABLE", .text = null, .number = 1 },
        .{ .key = "CATEGORY", .text = "ME", .number = 0 },
        .{ .key = "DISC_ID", .text = "SLUS00000", .number = 0 },
        .{ .key = "TITLE", .text = title, .number = 0 },
    };
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(gpa);
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(gpa);
    var entries: std.ArrayList(u8) = .empty;
    defer entries.deinit(gpa);
    for (items) |item| {
        var e: [16]u8 = undefined;
        std.mem.writeInt(u16, e[0..2], @intCast(keys.items.len), .little);
        std.mem.writeInt(u16, e[2..4], if (item.text != null) 0x0204 else 0x0404, .little);
        std.mem.writeInt(u32, e[12..16], @intCast(values.items.len), .little);
        try keys.appendSlice(gpa, item.key);
        try keys.append(gpa, 0);
        const len: u32 = if (item.text) |t| @intCast(t.len + 1) else 4;
        std.mem.writeInt(u32, e[4..8], len, .little);
        std.mem.writeInt(u32, e[8..12], len, .little);
        if (item.text) |t| {
            try values.appendSlice(gpa, t);
            try values.append(gpa, 0);
        } else {
            try values.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, item.number)));
        }
        try entries.appendSlice(gpa, &e);
    }
    const key_at = 0x14 + entries.items.len;
    const value_at = std.mem.alignForward(usize, key_at + keys.items.len, 4);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x00PSF\x01\x01\x00\x00");
    for ([_]usize{ key_at, value_at, items.len }) |v| {
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(v))));
    }
    try out.appendSlice(gpa, entries.items);
    try out.appendSlice(gpa, keys.items);
    try out.appendNTimes(gpa, 0, value_at - key_at - keys.items.len);
    try out.appendSlice(gpa, values.items);
    return out.toOwnedSlice(gpa);
}

fn writePbpDisc(gpa: std.mem.Allocator, out: *std.ArrayList(u8), state: *PbpCompressor, disc: PbpDisc, stored: bool) !void {
    const d = disc.d;
    const count: i32 = @intCast(disc.raw.len / sector_bytes);
    const base = out.items.len;
    try out.appendNTimes(gpa, 0, pbp_image_offset);
    const head = out.items[base..];
    @memcpy(head[0..12], "PSISOIMG0000");
    std.mem.writeInt(u32, head[0xBFC..][0..4], pbp_image_offset, .little);

    const toc = head[pbp_toc_at..][0 .. 102 * 10];
    const last = d.tracks[d.track_count - 1];
    putTocEntry(toc, 0, 0x41, 0xA0, .{ .m = 0, .s = 0, .f = 0 }, .{ .m = ps1.disc.binaryToBcd(d.tracks[0].number), .s = 0, .f = 0 });
    putTocEntry(toc, 1, 0x41, 0xA1, .{ .m = 0, .s = 0, .f = 0 }, .{ .m = ps1.disc.binaryToBcd(last.number), .s = 0, .f = 0 });
    putTocEntry(toc, 2, 0x41, 0xA2, .{ .m = 0, .s = 0, .f = 0 }, MSF.fromFrames(count));
    for (d.tracks[0..d.track_count], 3..) |t, i| {
        const user = MSF.fromLba(t.start_lba);
        // Track 1's pregap field is zero: the image begins at our LBA 0, with
        // no lead-in before it.
        const pregap = if (t.number == 1) MSF{ .m = 0, .s = 0, .f = 0 } else MSF.fromLba(t.pregap_lba orelse t.start_lba);
        putTocEntry(toc, i, if (t.type == .audio) 0x01 else 0x41, ps1.disc.binaryToBcd(t.number), pregap, user);
    }

    const blocks = std.math.divCeil(usize, @intCast(count), pbp_block_sectors) catch unreachable;
    for (0..blocks) |n| {
        var block: [pbp_block_bytes]u8 = @splat(0);
        const from = n * pbp_block_bytes;
        const have = @min(pbp_block_bytes, disc.raw.len - from);
        @memcpy(block[0..have], disc.raw[from..][0..have]);

        const at = out.items.len - base - pbp_image_offset;
        const size = try appendPbpBlock(gpa, out, state, &block, stored);
        const entry = out.items[base + pbp_table_at + n * pbp_table_entry ..][0..pbp_table_entry];
        std.mem.writeInt(u32, entry[0..4], @intCast(at), .little);
        std.mem.writeInt(u16, entry[4..6], @intCast(size), .little);
    }
}

fn putTocEntry(toc: []u8, index: usize, kind: u8, point: u8, pregap: MSF, user: MSF) void {
    const e = toc[index * 10 ..][0..10];
    e.* = .{ kind, 0, point, pregap.m, pregap.s, pregap.f, 0, user.m, user.s, user.f };
}

/// Appends `block` deflated, or as it is when `stored` or deflating does not
/// shrink it. Returns the bytes appended.
fn appendPbpBlock(gpa: std.mem.Allocator, out: *std.ArrayList(u8), state: *PbpCompressor, block: *const [pbp_block_bytes]u8, stored: bool) !usize {
    if (!stored) {
        var w = std.Io.Writer.fixed(&state.buffer);
        if (deflate(&w, &state.window, block)) {
            const packed_bytes = w.buffered();
            if (packed_bytes.len < pbp_block_bytes) {
                try out.appendSlice(gpa, packed_bytes);
                return packed_bytes.len;
            }
        } else |_| {}
    }
    try out.appendSlice(gpa, block);
    return pbp_block_bytes;
}

fn deflate(w: *std.Io.Writer, window: []u8, block: []const u8) !void {
    var c = try std.compress.flate.Compress.init(w, window, .raw, .default);
    try c.writer.writeAll(block);
    try c.finish();
}
