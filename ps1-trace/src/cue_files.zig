const std = @import("std");

pub const LoadedCue = struct { cue: []const u8, data: []const u8, files: usize };

/// Reads a CUE plus every .bin it references, concatenated in cue order, and
/// hands back the sheet with a `REM FILESIZE` synthesized ahead of each FILE.
///
/// `Disc.initFromCue` takes one flat data slice and uses those FILESIZE lines
/// to work out where each FILE's base LBA falls; without them every FILE stacks
/// at LBA 0 and the audio tracks land on top of the data track. Rips split per
/// track (Tekken 3: one MODE2 data track plus two Red Book audio tracks) carry
/// no FILESIZE of their own, so it is derived from the files on disk. This
/// mirrors what ps1-wasm/www/index.html does with an uploaded folder, so the
/// two frontends see byte-identical discs.
pub fn loadCue(io: std.Io, a: std.mem.Allocator, cue_path: []const u8) !LoadedCue {
    const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1024 * 1024));
    const dir = std.fs.path.dirname(cue_path) orelse ".";

    // Pass 1: resolve every FILE and total up the image.
    var paths = std.ArrayList([]const u8).empty;
    var sizes = std.ArrayList(u64).empty;
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        const name = cueFileName(raw) orelse continue;
        const path = try std.fs.path.join(a, &.{ dir, name });
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        try paths.append(a, path);
        try sizes.append(a, st.size);
        total += st.size;
    }
    if (paths.items.len == 0) return error.CueHasNoFiles;

    // Pass 2: read them back to back into one exactly-sized image.
    const data = try a.alloc(u8, @intCast(total));
    var off: usize = 0;
    for (paths.items, sizes.items) |path, size| {
        const n = try std.Io.Dir.cwd().readFile(io, path, data[off..][0..@intCast(size)]);
        off += n.len;
    }

    // Pass 3: re-emit the sheet with the sizes attached.
    var cue = std.ArrayList(u8).empty;
    var i: usize = 0;
    lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        if (cueFileName(raw) != null) {
            try cue.print(a, "REM FILESIZE {d}\n", .{sizes.items[i]});
            i += 1;
        }
        try cue.appendSlice(a, raw);
        try cue.append(a, '\n');
    }

    return .{ .cue = cue.items, .data = data, .files = paths.items.len };
}

/// The quoted name out of a `FILE "foo.bin" BINARY` line, or null.
fn cueFileName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "FILE")) return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '"') orelse return null;
    const rest = trimmed[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..close];
}
