//! Getting bytes in: the host's buffers, the BIOS, and (Task 2) discs.
//! Results richer than a code come back as JSON in `result_buf`: a struct
//! layout mirrored by hand in TypeScript would drift silently.

const std = @import("std");
const ps1 = @import("ps1_core");
const machine = @import("machine.zig");
const codes = @import("codes.zig");

const Disc = ps1.disc.Disc;

/// The magic every `.sbi` opens with. Checked here because `Disc.setSbi`
/// ignores a file without it, and a silently dropped sidecar is a game that
/// loops on its copy check with nothing to say why.
const sbi_magic = "SBI\x00";

var result_buf: [1024]u8 = undefined;

export fn resultPtr() [*]const u8 {
    return &result_buf;
}

/// Writes `value` as JSON into `result_buf` and returns its length.
pub fn writeResult(value: anytype) i32 {
    var w: std.Io.Writer = .fixed(&result_buf);
    w.print("{f}", .{std.json.fmt(value, .{})}) catch return codes.oom;
    return @intCast(w.buffered().len);
}

/// A buffer for the host to copy an input into. Null when memory cannot grow.
export fn alloc(len: usize) ?[*]u8 {
    const bytes = machine.allocator.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    machine.allocator.free(ptr[0..len]);
}

const BiosInfo = struct {
    known: bool,
    region: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Copies the image (a reset rebuilds `Bus`, which clears its ROM) and
/// identifies it. An image missing from the table is UNIDENTIFIED, not
/// invalid: it still boots. The caller frees `ptr`.
export fn loadBios(ptr: [*]const u8, len: usize) i32 {
    if (len != ps1.bios.image_bytes) return codes.bad_bios_size;
    @memcpy(&machine.bios, ptr[0..ps1.bios.image_bytes]);
    machine.bios_loaded = true;
    machine.installBios(machine.bus);
    const row = ps1.bios.identify(&machine.bios) orelse return writeResult(BiosInfo{ .known = false });
    return writeResult(BiosInfo{
        .known = true,
        .region = @tagName(row.region),
        .version = row.version,
        .description = row.description,
    });
}

/// Installs a disc. On success the module OWNS `bin`: the drive reads from
/// it until the next disc replaces it, so the caller must not free it. On
/// failure the caller still owns it, and the previous disc is still in.
/// `cue`, `sbi` and `ppf` stay the caller's either way: the cue is parsed
/// here, the sidecar copied and the patch applied into memory this module
/// owns. A patch it cannot read is `bad_ppf`; one made for another rip is
/// `ppf_mismatch`.
///
/// A CHD is recognised by content and takes no cue. A cue with several FILEs
/// needs its images concatenated with a `REM FILESIZE` line before each,
/// which is how the seams survive the concatenation.
export fn loadDisc(bin: [*]u8, bin_len: usize, cue: ?[*]const u8, cue_len: usize, sbi: ?[*]const u8, sbi_len: usize, ppf: ?[*]const u8, ppf_len: usize) i32 {
    if (bin_len < ps1.constants.sector_bytes) return codes.bad_cue;
    const sbi_bytes: []const u8 = if (sbi_len > 0) (sbi orelse return codes.bad_sbi)[0..sbi_len] else &.{};
    if (sbi_len > 0 and !std.mem.startsWith(u8, sbi_bytes, sbi_magic)) return codes.bad_sbi;

    const data = bin[0..bin_len];
    var reader: ?*ps1.chd.Reader = null;
    var d: Disc = undefined;
    if (ps1.chd.isChd(data)) {
        if (cue_len > 0) return codes.bad_chd;
        reader = ps1.chd.Reader.open(machine.allocator, data) catch |err|
            return if (err == error.OutOfMemory) codes.oom else codes.bad_chd;
        d = Disc.initFromChd(reader.?);
    } else if (cue_len > 0) {
        const text = (cue orelse return codes.bad_cue)[0..cue_len];
        const files = ps1.disc.countCueFiles(text);
        if (files == 0) return codes.bad_cue;
        // Without the seams `initFromCue` stacks every FILE at the same base
        // LBA rather than failing, so it has to be caught here.
        if (files > 1 and !ps1.disc.cueFilesAreLaidOut(text)) return codes.multi_file_cue;
        // `initFromCue` falls back to a single data track on a cue it cannot
        // parse, which would boot the wrong layout without a word.
        if (std.mem.indexOf(u8, text, "TRACK ") == null) return codes.bad_cue;
        d = Disc.initFromCue(text, data);
    } else {
        d = Disc.init(data);
    }

    const patch: ps1.ppf.Overlay = if (ppf_len > 0) blk: {
        const bytes = (ppf orelse {
            if (reader) |r| r.close();
            return codes.bad_ppf;
        })[0..ppf_len];
        break :blk ps1.ppf.build(machine.allocator, d, bytes) catch |err| {
            if (reader) |r| r.close();
            return switch (err) {
                error.OutOfMemory => codes.oom,
                error.PpfBadFormat => codes.bad_ppf,
                error.PpfMismatch => codes.ppf_mismatch,
            };
        };
    } else .{};

    const owned_sbi = machine.allocator.dupe(u8, sbi_bytes) catch {
        patch.deinit(machine.allocator);
        if (reader) |r| r.close();
        return codes.oom;
    };
    d.setSbi(owned_sbi);
    d.patch = patch;
    machine.replaceDisc(d, data, reader, owned_sbi, patch);
    return codes.ok;
}

const DiscSet = struct { title: []const u8, disc: u8 };

const DiscInfo = struct {
    region: ?[]const u8,
    serial: []const u8,
    volumeId: []const u8,
    title: ?[]const u8,
    set: ?DiscSet,
};

/// What a disc says about itself, with no BIOS and no machine: licence
/// region, SYSTEM.CNF serial, ISO volume id, and the catalogued title and
/// multi-disc set. `bin` must be the WHOLE image: SYSTEM.CNF can sit hundreds
/// of megabytes in. The caller frees `bin`.
export fn identifyDisc(bin: [*]const u8, bin_len: usize) i32 {
    if (bin_len < ps1.constants.sector_bytes) return codes.bad_cue;
    const data = bin[0..bin_len];
    const reader: ?*ps1.chd.Reader = if (ps1.chd.isChd(data))
        ps1.chd.Reader.open(machine.allocator, data) catch return codes.bad_chd
    else
        null;
    defer if (reader) |r| r.close();

    const id = ps1.discid.identify(if (reader) |r| Disc.initFromChd(r) else Disc.init(data));
    const serial = id.serial.slice();
    return writeResult(DiscInfo{
        .region = if (id.region) |r| @tagName(r) else null,
        .serial = serial,
        .volumeId = id.volumeId(),
        .title = if (ps1.game_titles.lookup(serial)) |e| e.title else null,
        .set = if (ps1.discdb.lookup(serial)) |e| DiscSet{ .title = e.game_title, .disc = e.disc_number } else null,
    });
}
