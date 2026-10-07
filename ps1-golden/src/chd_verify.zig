//! `chd-verify`: a CHD made from a cue must be the same disc as the cue. Every
//! sector from LBA 0 to the lead-out, the track table and the identity.
const std = @import("std");
const ps1 = @import("ps1_core");
const cue_files = @import("cue_files");

const Disc = ps1.disc.Disc;
const sector_bytes = ps1.constants.sector_bytes;

/// True when the two discs differ in any way.
pub fn run(a: std.mem.Allocator, io: std.Io, cue_path: []const u8, chd_path: []const u8) !bool {
    const loaded = try cue_files.loadCue(io, a, cue_path);
    const flat = Disc.initFromCue(loaded.cue, loaded.data);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, chd_path, a, .limited(1 << 30));
    const reader = try ps1.chd.Reader.open(a, bytes);
    defer reader.close();
    const packed_disc = Disc.initFromChd(reader);

    var failed = false;
    var tables_differ = flat.track_count != packed_disc.track_count;
    if (!tables_differ) {
        for (0..flat.track_count) |i| {
            if (!std.meta.eql(flat.tracks[i], packed_disc.tracks[i])) tables_differ = true;
        }
    }
    if (tables_differ) {
        failed = true;
        std.debug.print("  track tables differ\n", .{});
        for (0..@max(flat.track_count, packed_disc.track_count)) |i| {
            std.debug.print("    cue {any}\n    chd {any}\n", .{ flat.tracks[i], packed_disc.tracks[i] });
        }
    }
    if (flat.sectorCount() != packed_disc.sectorCount()) {
        failed = true;
        std.debug.print("  sector counts differ: cue {d}, chd {d}\n", .{ flat.sectorCount(), packed_disc.sectorCount() });
    }

    const count = @min(flat.sectorCount(), packed_disc.sectorCount());
    var want: [sector_bytes]u8 = undefined;
    var got: [sector_bytes]u8 = undefined;
    var mismatches: u32 = 0;
    var first: i32 = 0;
    var lba: i32 = 0;
    while (lba < count) : (lba += 1) {
        const ok_flat = flat.readSector2352(lba, &want);
        const ok_chd = packed_disc.readSector2352(lba, &got);
        if (ok_flat != ok_chd or !std.mem.eql(u8, &want, &got)) {
            if (mismatches == 0) first = lba;
            mismatches += 1;
        }
    }
    if (mismatches > 0) {
        failed = true;
        std.debug.print("  {d} sectors differ, the first at LBA {d} (track {d})\n", .{
            mismatches, first, flat.trackForLba(first).number,
        });
    }

    const id_flat = ps1.discid.identify(flat);
    const id_chd = ps1.discid.identify(packed_disc);
    if (!std.meta.eql(id_flat.region, id_chd.region) or !std.mem.eql(u8, id_flat.serial.slice(), id_chd.serial.slice())) {
        failed = true;
        std.debug.print("  identities differ: cue {s}, chd {s}\n", .{ id_flat.serial.slice(), id_chd.serial.slice() });
    }

    std.debug.print("  {s}: {d} sectors, {d} tracks, {s}  {s}\n", .{
        cue_path, count, flat.track_count, id_flat.serial.slice(), if (failed) "DIFFERS" else "identical",
    });
    return failed;
}
