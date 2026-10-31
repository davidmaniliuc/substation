//! Getting bytes in: the host's buffers, the BIOS, and (Task 2) discs.
//! Results richer than a code come back as JSON in `result_buf`: a struct
//! layout mirrored by hand in TypeScript would drift silently.

const std = @import("std");
const ps1 = @import("ps1_core");
const machine = @import("machine.zig");
const codes = @import("codes.zig");

const DiscImage = ps1.disc_image;

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
/// The format is recognised by content (`disc_image.open`): a CHD takes no
/// cue, an ECM at most a one-FILE cue, a CloneCD sheet goes in `cue` and its
/// `.sub` in `sbi`. A cue with several FILEs needs its images concatenated
/// with a `REM FILESIZE` line before each, which is how the seams survive
/// the concatenation. An eboot takes no cue, and `disc` picks which of its
/// discs to open; every other format wants 0.
export fn loadDisc(bin: [*]u8, bin_len: usize, cue: ?[*]const u8, cue_len: usize, sbi: ?[*]const u8, sbi_len: usize, ppf: ?[*]const u8, ppf_len: usize, disc: u32) i32 {
    const index = std.math.cast(u8, disc) orelse return codes.bad_cue;
    const cue_text: []const u8 = if (cue_len > 0) (cue orelse return codes.bad_cue)[0..cue_len] else &.{};
    const side: []const u8 = if (sbi_len > 0) (sbi orelse return codes.bad_sbi)[0..sbi_len] else &.{};
    const data = bin[0..bin_len];
    const opened = DiscImage.open(machine.allocator, data, cue_text, side, index) catch |err| return codes.ofOpen(err);
    var d = opened.disc;

    const patch: ps1.ppf.Overlay = if (ppf_len > 0) blk: {
        const bytes = (ppf orelse {
            closeOpened(opened);
            return codes.bad_ppf;
        })[0..ppf_len];
        break :blk ps1.ppf.build(machine.allocator, d, bytes) catch |err| {
            closeOpened(opened);
            return switch (err) {
                error.OutOfMemory => codes.oom,
                error.PpfBadFormat => codes.bad_ppf,
                error.PpfMismatch => codes.ppf_mismatch,
            };
        };
    } else .{};

    d.setSbi(opened.sbi);
    d.patch = patch;
    machine.replaceDisc(d, data, opened.decoder, opened.sbi, patch);
    return codes.ok;
}

fn closeOpened(opened: DiscImage.Opened) void {
    opened.decoder.close();
    machine.allocator.free(opened.sbi);
}

const DiscSet = struct { title: []const u8, disc: u8 };

const DiscInfo = struct {
    region: ?[]const u8,
    serial: []const u8,
    volumeId: []const u8,
    title: ?[]const u8,
    set: ?DiscSet,
    discs: u8,
};

/// A title is the image's own text and `result_buf` is fixed: at most 128
/// bytes, cut on a character boundary so the JSON stays valid UTF-8.
fn clipTitle(text: []const u8) []const u8 {
    var n = @min(text.len, 128);
    while (n < text.len and n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
    return text[0..n];
}

/// What a disc says about itself, with no BIOS and no machine: licence
/// region, SYSTEM.CNF serial, ISO volume id, and the catalogued title and
/// multi-disc set. `bin` must be the WHOLE image: SYSTEM.CNF can sit hundreds
/// of megabytes in. The caller frees `bin`. `sheet` is the image's sheet (an
/// Alcohol `.mds`), `disc` the disc of an eboot to read; `discs` is the eboot's disc count (1 for any
/// other image) and its own title fills `title` where the catalogue has none.
export fn identifyDisc(bin: [*]const u8, bin_len: usize, sheet: ?[*]const u8, sheet_len: usize, disc: u32) i32 {
    const sheet_text: []const u8 = if (sheet_len > 0) (sheet orelse return codes.bad_cue)[0..sheet_len] else &.{};
    const index = std.math.cast(u8, disc) orelse return codes.bad_cue;
    const image = DiscImage.identifyImage(machine.allocator, bin[0..bin_len], sheet_text, index) catch |err| return codes.ofOpen(err);
    const id = image.id;
    const serial = id.serial.slice();
    return writeResult(DiscInfo{
        .region = if (id.region) |r| @tagName(r) else null,
        .serial = serial,
        .volumeId = id.volumeId(),
        // The catalogue's name, else an eboot's own; `title` is one field.
        .title = if (ps1.game_titles.lookup(serial)) |e| e.title else if (image.title.len > 0) clipTitle(image.title) else null,
        .set = if (ps1.discdb.lookup(serial)) |e| DiscSet{ .title = e.game_title, .disc = e.disc_number } else null,
        .discs = image.discs,
    });
}
