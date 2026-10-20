//! Where `.p1fx` fixtures live and how one is opened by name: shared by the
//! test harness and `ps1-bench-gpu`, which both replay the same corpus.
//!
//! Paths are relative to the process CWD, the repo root, as for every other
//! harness that reads `zig-out/` or `ps1-core/tests/`.

const std = @import("std");
const fixture = @import("fixture");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const committed_dir = "ps1-core/tests/goldens/fixtures";
pub const generated_dir = "zig-out/fixtures";

/// The committed fixtures first, then the generated ones. Owned by the caller.
pub fn path(alloc: Allocator, io: Io, name: []const u8) ![]u8 {
    const committed = try std.fmt.allocPrint(alloc, "{s}/{s}.p1fx", .{ committed_dir, name });
    if (Io.Dir.cwd().access(io, committed, .{})) |_| return committed else |_| {}
    alloc.free(committed);
    return std.fmt.allocPrint(alloc, "{s}/{s}.p1fx", .{ generated_dir, name });
}

/// `error.FixtureNotFound` when neither directory holds `name`: generated
/// fixtures are build artifacts, absent on a fresh clone and, for the real
/// games, on any machine without `games/`. Each caller says so its own way.
pub fn load(alloc: Allocator, io: Io, name: []const u8) !fixture.Parsed {
    const p = try path(alloc, io, name);
    defer alloc.free(p);
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(256 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.FixtureNotFound,
        else => return err,
    };
    defer alloc.free(bytes);
    return fixture.parse(alloc, bytes);
}

/// Every name `load` can open, sorted, each once. A file another format
/// version wrote (an ad-hoc capture `zig build fixtures` does not regenerate)
/// cannot be opened, and is named on stderr rather than dropped in silence.
/// Free with `freeCorpus`.
pub fn corpus(alloc: Allocator, io: Io) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer freeCorpus(alloc, names.items);
    for ([_][]const u8{ committed_dir, generated_dir }) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        next: while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".p1fx")) continue;
            const name = entry.name[0 .. entry.name.len - ".p1fx".len];
            for (names.items) |have| if (std.mem.eql(u8, have, name)) continue :next;
            const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
            defer alloc.free(p);
            if (!currentFormat(io, p)) {
                std.debug.print("[corpus] {s} is not a version-{d} fixture; regenerate it to gate it\n", .{ p, fixture.version });
                continue;
            }
            try names.append(alloc, try alloc.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(alloc);
}

pub fn freeCorpus(alloc: Allocator, names: []const []const u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

/// Whether the header at `p` is one this build's `fixture.parse` accepts.
/// The body is still checked by the parse itself when the fixture loads.
pub fn currentFormat(io: Io, p: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, p, .{}) catch return false;
    defer file.close(io);
    var header: [fixture.header_bytes]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return false;
    return n == header.len and
        std.mem.eql(u8, header[0..8], &fixture.magic) and
        std.mem.readInt(u32, header[8..12], .little) == fixture.version and
        std.mem.readInt(u32, header[12..16], .little) == fixture.record_stride and
        std.mem.readInt(u32, header[16..20], .little) == fixture.kind_count;
}
