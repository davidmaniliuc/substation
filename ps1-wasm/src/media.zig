//! Getting bytes in: the host's buffers, the BIOS, and (Task 2) discs.
//! Results richer than a code come back as JSON in `result_buf`: a struct
//! layout mirrored by hand in TypeScript would drift silently.

const std = @import("std");
const ps1 = @import("ps1_core");
const machine = @import("machine.zig");
const codes = @import("codes.zig");

const DiscImage = ps1.disc_image;

/// Sized for the worst identify result, every string at its longest with each
/// byte JSON-escaped to six (`\u00XX`): the image title (`max_title`) and the
/// ISO volume id (32 bytes) as control characters are 768 and 192 bytes, the
/// catalogue's two titles and the keys fit in what is left.
var result_buf: [2048]u8 = undefined;

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
/// discs to open; every other format wants 0. A running executable is
/// dropped for the disc.
export fn loadDisc(bin: [*]u8, bin_len: usize, cue: ?[*]const u8, cue_len: usize, sbi: ?[*]const u8, sbi_len: usize, ppf: ?[*]const u8, ppf_len: usize, disc: u32) i32 {
    const p = switch (prepareDisc(bin[0..bin_len], cue, cue_len, sbi, sbi_len, ppf, ppf_len, disc)) {
        .err => |code| return code,
        .ok => |p| p,
    };
    machine.replaceDisc(p.disc, bin[0..bin_len], p.decoder, p.sbi, p.patch);
    return codes.ok;
}

/// `loadDisc` through the tray, for the next disc of a running game: the
/// shell opens and closes an emulated second later, which is how the game
/// learns to re-read the TOC. Same inputs, ownership and codes; a machine
/// running an executable has no tray to open and answers `busy`.
export fn swapDisc(bin: [*]u8, bin_len: usize, cue: ?[*]const u8, cue_len: usize, sbi: ?[*]const u8, sbi_len: usize, ppf: ?[*]const u8, ppf_len: usize, disc: u32) i32 {
    if (machine.exe != null) return codes.busy;
    const p = switch (prepareDisc(bin[0..bin_len], cue, cue_len, sbi, sbi_len, ppf, ppf_len, disc)) {
        .err => |code| return code,
        .ok => |p| p,
    };
    machine.swapDisc(p.disc, bin[0..bin_len], p.decoder, p.sbi, p.patch);
    return codes.ok;
}

const Prepared = struct {
    disc: ps1.disc.Disc,
    decoder: DiscImage.Decoder,
    sbi: []u8,
    patch: ps1.ppf.Overlay,
};

/// Opens the image and builds its patch, touching nothing installed: every
/// refusal frees what it opened on the way.
fn prepareDisc(data: []const u8, cue: ?[*]const u8, cue_len: usize, sbi: ?[*]const u8, sbi_len: usize, ppf: ?[*]const u8, ppf_len: usize, disc: u32) union(enum) { ok: Prepared, err: i32 } {
    const cue_text: []const u8 = if (cue_len > 0) (cue orelse return .{ .err = codes.bad_cue })[0..cue_len] else &.{};
    const side: []const u8 = if (sbi_len > 0) (sbi orelse return .{ .err = codes.bad_sbi })[0..sbi_len] else &.{};
    const opened = DiscImage.open(machine.allocator, data, cue_text, side, disc) catch |err| return .{ .err = codes.ofOpen(err) };
    var d = opened.disc;

    const patch: ps1.ppf.Overlay = if (ppf_len > 0) blk: {
        const bytes = (ppf orelse {
            closeOpened(opened);
            return .{ .err = codes.bad_ppf };
        })[0..ppf_len];
        break :blk ps1.ppf.build(machine.allocator, d, bytes) catch |err| {
            closeOpened(opened);
            return .{ .err = switch (err) {
                error.OutOfMemory => codes.oom,
                error.PpfBadFormat => codes.bad_ppf,
                error.PpfMismatch => codes.ppf_mismatch,
            } };
        };
    } else .{};

    d.setSbi(opened.sbi);
    d.patch = patch;
    return .{ .ok = .{ .disc = d, .decoder = opened.decoder, .sbi = opened.sbi, .patch = patch } };
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
    /// An eboot's own TITLE; empty for any other image. Not a library title.
    imageTitle: []const u8,
};

const max_title = 128;

/// A title is the image's own text and `result_buf` is fixed: at most
/// `max_title` bytes, cut on a character boundary so the JSON stays valid UTF-8.
fn clipTitle(text: []const u8) []const u8 {
    var n = @min(text.len, max_title);
    while (n < text.len and n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
    return text[0..n];
}

/// What a disc says about itself, with no BIOS and no machine: licence
/// region, SYSTEM.CNF serial, ISO volume id, and the catalogued title and
/// multi-disc set. `bin` must be the WHOLE image: SYSTEM.CNF can sit hundreds
/// of megabytes in. The caller frees `bin`. `sheet` is the image's sheet (an
/// Alcohol `.mds`), `disc` the disc of an eboot to read; `discs` is the eboot's disc count (1 for any
/// other image) and `imageTitle` its own TITLE (never a library title).
export fn identifyDisc(bin: [*]const u8, bin_len: usize, sheet: ?[*]const u8, sheet_len: usize, disc: u32) i32 {
    const sheet_text: []const u8 = if (sheet_len > 0) (sheet orelse return codes.bad_cue)[0..sheet_len] else &.{};
    const image = DiscImage.identifyImage(machine.allocator, bin[0..bin_len], sheet_text, disc) catch |err| return codes.ofOpen(err);
    const id = image.id;
    const serial = id.serial.slice();
    return writeResult(DiscInfo{
        .region = if (id.region) |r| @tagName(r) else null,
        .serial = serial,
        .volumeId = id.volumeId(),
        .title = if (ps1.game_titles.lookup(serial)) |e| e.title else null,
        .imageTitle = clipTitle(image.title),
        .set = if (ps1.discdb.lookup(serial)) |e| DiscSet{ .title = e.game_title, .disc = e.disc_number } else null,
        .discs = image.discs,
    });
}

fn exeCode(err: ps1.exe.Error) i32 {
    return if (err == error.OutOfMemory) codes.oom else codes.bad_exe;
}

/// Boots an executable in place of a disc: a PS-X EXE, a CPE or an ELF, told
/// apart by content. `libps` is a `libps.exe` placed in RAM first (a PS-X
/// EXE only), or empty. Both are COPIED, so the caller frees them. Any disc
/// is taken out and the machine cold-boots the BIOS, which hands over to the
/// program once the kernel is up; `reset` and `loadState` re-arm it and
/// `loadDisc` drops it. A file it cannot boot is `bad_exe` and changes nothing.
export fn loadExe(exe: [*]const u8, exe_len: usize, libps: ?[*]const u8, libps_len: usize) i32 {
    const lib_in: []const u8 = if (libps_len > 0) (libps orelse return codes.bad_exe)[0..libps_len] else &.{};
    var program = parseExe(exe[0..exe_len], lib_in) catch |err| return exeCode(err);
    machine.bootExe(program) catch {
        program.deinit();
        return codes.oom;
    };
    return codes.ok;
}

fn parseExe(exe: []const u8, libps: []const u8) ps1.exe.Error!machine.Exe {
    const a = machine.allocator;
    const bytes = try a.dupe(u8, exe);
    errdefer a.free(bytes);
    const lib_bytes = try a.dupe(u8, libps);
    errdefer a.free(lib_bytes);
    var main = try ps1.exe.parse(a, bytes);
    errdefer main.deinit(a);
    var lib: ?ps1.exe.Program = null;
    if (lib_bytes.len > 0) {
        var p = try ps1.exe.parse(a, lib_bytes);
        // Loaded for its code and data alone; only a PS-X EXE is one.
        if (p.format != .psexe) {
            p.deinit(a);
            return error.BadFormat;
        }
        lib = p;
    }
    return .{
        .bytes = bytes,
        .libps = lib_bytes,
        .boot = .{ .main = main, .libps = lib, .fingerprint = ps1.exe.fingerprint(bytes, lib_bytes) },
    };
}

const ExeInfo = struct {
    format: []const u8,
    region: ?[]const u8,
    /// `exe.fingerprint` of the file alone, as 16 hex digits: a u64 does not
    /// survive a JavaScript number.
    fingerprint: []const u8,
};

/// Whether `exe` is an executable `loadExe` would boot, with no machine: a
/// Windows `.exe` is `bad_exe`. The caller frees `exe`.
export fn identifyExe(exe: [*]const u8, exe_len: usize) i32 {
    const bytes = exe[0..exe_len];
    var p = ps1.exe.parse(machine.allocator, bytes) catch |err| return exeCode(err);
    defer p.deinit(machine.allocator);
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{ps1.exe.fingerprint(bytes, "")}) catch unreachable;
    return writeResult(ExeInfo{
        .format = @tagName(p.format),
        .region = if (p.region) |r| @tagName(r) else null,
        .fingerprint = &hex,
    });
}
