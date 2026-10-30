//! `image-verify`: an image made from a cue must be the same disc as the cue.
//! A raw image (CHD, ECM, CloneCD) must match every sector from LBA 0 to the
//! lead-out, the track table and the identity; a cooked one (ISO) keeps only
//! 2048 bytes a sector, so it must match those wherever a sector has no more.
const std = @import("std");
const ps1 = @import("ps1_core");
const cue_files = @import("cue_files");

const Disc = ps1.disc.Disc;
const sector_bytes = ps1.constants.sector_bytes;
const user_bytes = 2048;

/// A cue's disc as the harness boots it, with its `.sbi` attached.
pub const Reference = struct { disc: Disc, sbi: []const u8 };

pub fn reference(a: std.mem.Allocator, io: std.Io, cue_path: []const u8) !Reference {
    const loaded = try cue_files.loadCue(io, a, cue_path);
    var d = Disc.initFromCue(loaded.cue, loaded.data);
    const sbi = try sbiBeside(a, io, cue_path);
    d.setSbi(sbi);
    return .{ .disc = d, .sbi = sbi };
}

/// The `.sbi` named after `cue_path`, or empty: a LibCrypt disc without its
/// sidecar never gets past its own protection check.
pub fn sbiBeside(a: std.mem.Allocator, io: std.Io, cue_path: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}.sbi", .{stem(cue_path)});
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |err|
        if (err == error.FileNotFound) &.{} else return err;
}

fn stem(path: []const u8) []const u8 {
    return path[0 .. path.len - std.fs.path.extension(path).len];
}

/// Opens an image as a frontend would, with `side` (a `.sbi` or `.sub`, or
/// empty) attached. Its sheet is found by its stem: a `.ccd` IS the sheet and
/// reads its `.img`, a CHD carries its own, and anything else takes a `.cue`
/// beside it when there is one.
pub fn openImage(a: std.mem.Allocator, io: std.Io, path: []const u8, side: []const u8) !ps1.disc_image.Opened {
    const cwd = std.Io.Dir.cwd();
    const ext = std.fs.path.extension(path);
    var bin_path = path;
    var sheet: []const u8 = &.{};
    if (std.ascii.eqlIgnoreCase(ext, ".ccd")) {
        sheet = try cwd.readFileAlloc(io, path, a, .limited(1 << 20));
        bin_path = try std.fmt.allocPrint(a, "{s}.img", .{stem(path)});
    } else if (!std.ascii.eqlIgnoreCase(ext, ".chd")) {
        const cue_path = try std.fmt.allocPrint(a, "{s}.cue", .{stem(path)});
        sheet = cwd.readFileAlloc(io, cue_path, a, .limited(1 << 20)) catch |err|
            if (err == error.FileNotFound) &.{} else return err;
    }
    const bin = try cwd.readFileAlloc(io, bin_path, a, .limited(1 << 30));
    var opened = try ps1.disc_image.open(a, bin, sheet, side);
    opened.disc.setSbi(opened.sbi);
    return opened;
}

/// True when the two discs differ in any way. `sub_path`, a CloneCD `.sub`,
/// must also name exactly the LibCrypt sectors the cue's `.sbi` does.
pub fn run(a: std.mem.Allocator, io: std.Io, cue_path: []const u8, image_path: []const u8, sub_path: ?[]const u8) !bool {
    const ref = try reference(a, io, cue_path);
    const side = if (sub_path) |p| try std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 30)) else &.{};
    const opened = try openImage(a, io, image_path, side);
    defer opened.decoder.close();
    const image = opened.disc;

    var failed = false;
    const summary = if (image.source == .cooked)
        try compareCooked(a, ref.disc, image, &failed)
    else
        try compareRaw(a, ref.disc, image, &failed);

    const id_ref = ps1.discid.identify(ref.disc);
    const id_image = ps1.discid.identify(image);
    if (!std.meta.eql(id_ref.region, id_image.region) or !std.mem.eql(u8, id_ref.serial.slice(), id_image.serial.slice())) {
        failed = true;
        std.debug.print("  identities differ: cue {s}, image {s}\n", .{ id_ref.serial.slice(), id_image.serial.slice() });
    }

    if (sub_path != null) {
        const want = try msfSet(a, ref.disc.sbi);
        const got = try msfSet(a, image.sbi);
        if (!std.mem.eql(u32, want, got)) {
            failed = true;
            std.debug.print("  LibCrypt sectors differ: .sbi {d}, .sub {d}\n", .{ want.len, got.len });
        } else {
            std.debug.print("  .sub marks the .sbi's {d} LibCrypt sectors\n", .{want.len});
        }
    }

    std.debug.print("  {s}: {s}, {s}  {s}\n", .{
        image_path, summary, id_ref.serial.slice(), if (failed) "DIFFERS" else "identical",
    });
    return failed;
}

/// Every sector, the track table and the sector count.
fn compareRaw(a: std.mem.Allocator, ref: Disc, image: Disc, failed: *bool) ![]const u8 {
    var tables_differ = ref.track_count != image.track_count;
    if (!tables_differ) {
        for (0..ref.track_count) |i| {
            if (!std.meta.eql(ref.tracks[i], image.tracks[i])) tables_differ = true;
        }
    }
    if (tables_differ) {
        failed.* = true;
        std.debug.print("  track tables differ\n", .{});
        for (0..@max(ref.track_count, image.track_count)) |i| {
            std.debug.print("    cue   {any}\n    image {any}\n", .{ ref.tracks[i], image.tracks[i] });
        }
    }
    if (ref.sectorCount() != image.sectorCount()) {
        failed.* = true;
        std.debug.print("  sector counts differ: cue {d}, image {d}\n", .{ ref.sectorCount(), image.sectorCount() });
    }

    const count = @min(ref.sectorCount(), image.sectorCount());
    var want: [sector_bytes]u8 = undefined;
    var got: [sector_bytes]u8 = undefined;
    var mismatches: u32 = 0;
    var first: i32 = 0;
    var lba: i32 = 0;
    while (lba < count) : (lba += 1) {
        const ok_ref = ref.readSector2352(lba, &want);
        const ok_image = image.readSector2352(lba, &got);
        if (ok_ref != ok_image or !std.mem.eql(u8, &want, &got)) {
            if (mismatches == 0) first = lba;
            mismatches += 1;
        }
    }
    if (mismatches > 0) {
        failed.* = true;
        std.debug.print("  {d} sectors differ, the first at LBA {d} (track {d})\n", .{
            mismatches, first, ref.trackForLba(first).number,
        });
    }
    return std.fmt.allocPrint(a, "{d} sectors, {d} tracks", .{ count, ref.track_count });
}

/// The 2048 user bytes of every data sector that has no more than that: Mode 1
/// and Mode 2 Form 1. A Form 2 sector's payload is longer, and what a cooked
/// image keeps of it is not the sector, so it is counted rather than compared.
fn compareCooked(a: std.mem.Allocator, ref: Disc, image: Disc, failed: *bool) ![]const u8 {
    var want: [sector_bytes]u8 = undefined;
    var got: [user_bytes]u8 = undefined;
    var compared: u32 = 0;
    var form2: u32 = 0;
    var other: u32 = 0;
    var mismatches: u32 = 0;
    var first: i32 = 0;
    var lba: i32 = 0;
    while (lba < ref.sectorCount()) : (lba += 1) {
        if (ref.trackForLba(lba).type != .data) continue;
        _ = ref.readSector2352(lba, &want);
        const at: usize = switch (want[15]) {
            1 => 0x10,
            2 => if (want[0x12] & 0x20 != 0) {
                form2 += 1;
                continue;
            } else 0x18,
            else => {
                other += 1;
                continue;
            },
        };
        compared += 1;
        if (!image.readSector(lba, &got) or !std.mem.eql(u8, want[at..][0..user_bytes], &got)) {
            if (mismatches == 0) first = lba;
            mismatches += 1;
        }
    }
    if (mismatches > 0) {
        failed.* = true;
        std.debug.print("  {d} sectors differ, the first at LBA {d}\n", .{ mismatches, first });
    }
    return std.fmt.allocPrint(a, "{d} sectors compared, {d} Form 2 and {d} other skipped", .{ compared, form2, other });
}

/// The addresses of an sbi-shaped record buffer, sorted.
fn msfSet(a: std.mem.Allocator, records: []const u8) ![]u32 {
    const n = records.len / ps1.disc.sbi_record_bytes;
    const set = try a.alloc(u32, n);
    for (set, 0..) |*v, i| {
        const r = records[i * ps1.disc.sbi_record_bytes ..];
        v.* = @as(u32, r[0]) << 16 | @as(u32, r[1]) << 8 | r[2];
    }
    std.mem.sort(u32, set, {}, std.sort.asc(u32));
    return set;
}
