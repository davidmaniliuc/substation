//! One way in for every disc image a frontend is handed: the image, its cue
//! sheet (or CloneCD control file) and its sidecar, told apart by content.
//! Both the C ABI and the browser core open discs here, so a format reaches
//! every frontend at once.

const std = @import("std");
const disc = @import("disc.zig");
const chd = @import("chd/chd.zig");
const ecm = @import("ecm.zig");
const ccd = @import("ccd.zig");
const discid = @import("discid.zig");
const constants = @import("constants.zig");

const Disc = disc.Disc;

/// The smallest image that is a disc: one cooked sector.
const min_image_bytes = 2048;
const sub_sector_bytes = 96;

/// The reader a disc's `Source` points at, owned by whoever holds the disc.
/// It is closed only once nothing reads that disc any more.
pub const Decoder = union(enum) {
    none,
    chd: *chd.Reader,
    ecm: *ecm.Reader,

    pub fn close(self: Decoder) void {
        switch (self) {
            .none => {},
            .chd => |r| r.close(),
            .ecm => |r| r.close(),
        }
    }
};

/// An opened disc. `sbi` is owned, `"SBI\x00"`-prefixed or empty, and NOT
/// attached: the caller attaches it with `Disc.setSbi` once it owns it.
pub const Opened = struct {
    disc: Disc,
    decoder: Decoder,
    sbi: []u8,
};

pub const Error = error{ OutOfMemory, BadCue, MultiFileCue, BadChd, BadEcm, BadCcd, BadSbi };

/// Opens `bin` with its `cue` (empty for none) and `side` (a `.sbi`, or a
/// CloneCD `.sub`; empty for none). `bin` and `cue` are borrowed: the disc
/// slices into `bin`. Every refusal frees what it allocated.
pub fn open(gpa: std.mem.Allocator, bin: []const u8, cue: []const u8, side: []const u8) Error!Opened {
    if (bin.len < min_image_bytes) return error.BadCue;

    var decoder: Decoder = .none;
    errdefer decoder.close();
    var is_ccd = false;
    var d: Disc = undefined;

    if (chd.isChd(bin)) {
        if (cue.len > 0) return error.BadChd;
        const r = chd.Reader.open(gpa, bin) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.BadChd;
        decoder = .{ .chd = r };
        d = Disc.initFromChd(r);
    } else if (ecm.isEcm(bin)) {
        // A `Disc` holds one source, so a cue may name the ECM alone.
        if (cue.len > 0) {
            if (disc.countCueFiles(cue) != 1) return error.BadCue;
            try checkTracks(cue);
        }
        const r = try ecm.Reader.open(gpa, bin);
        decoder = .{ .ecm = r };
        if (cue.len > 0) {
            d = Disc.initFromCue(cue, bin);
            d.source = .{ .ecm = r };
        } else {
            d = Disc.initFromEcm(r);
        }
    } else if (ccd.isCcd(cue)) {
        d = try ccd.parse(cue, bin);
        is_ccd = true;
    } else if (cue.len > 0) {
        const files = disc.countCueFiles(cue);
        if (files == 0) return error.BadCue;
        // Without the `REM FILESIZE` seams `initFromCue` stacks every FILE at
        // the same base LBA rather than failing, so it has to be caught here.
        if (files > 1 and !disc.cueFilesAreLaidOut(cue)) return error.MultiFileCue;
        try checkTracks(cue);
        const mode = disc.cueCookedMode(cue) catch return error.BadCue;
        d = if (mode) |m| Disc.initCookedCue(cue, bin, m) else Disc.initFromCue(cue, bin);
    } else {
        d = Disc.initLone(bin);
    }

    return .{ .disc = d, .decoder = decoder, .sbi = try sidecar(gpa, side, bin, cue, is_ccd) };
}

/// `initFromCue` falls back to a single data track on a cue with no TRACK,
/// which would boot the wrong layout without a word.
fn checkTracks(cue: []const u8) Error!void {
    if (std.mem.indexOf(u8, cue, "TRACK ") == null) return error.BadCue;
}

/// The owned sbi buffer for `side`. A buffer without the magic is a `.sub`
/// only beside a CloneCD sheet, and only if it covers the whole image: a
/// silently dropped sidecar is a game looping on its copy check.
fn sidecar(gpa: std.mem.Allocator, side: []const u8, bin: []const u8, cue: []const u8, is_ccd: bool) Error![]u8 {
    if (side.len == 0) return &.{};
    if (std.mem.startsWith(u8, side, disc.sbi_magic)) return gpa.dupe(u8, side);
    if (!is_ccd or side.len % sub_sector_bytes != 0) return error.BadSbi;
    if (side.len / sub_sector_bytes < bin.len / constants.sector_bytes) return error.BadSbi;
    return ccd.subRecords(gpa, side, ccd.pregapSkip(cue)) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.BadSbi;
}

/// What a lone image says about itself. A CHD or an ECM needs its index
/// built to be read at all; that is the one allocation, freed before
/// returning, and each call opens its own reader.
pub fn identify(gpa: std.mem.Allocator, bin: []const u8) Error!discid.DiscId {
    const opened = try open(gpa, bin, "", "");
    defer opened.decoder.close();
    return discid.identify(opened.disc);
}
