const std = @import("std");

/// Column order of a golden row. Must stay in lockstep with
/// `state_hash.Region` — `state_hash.zig` has a comptime assertion for it.
pub const region_names = [_][]const u8{
    "ram",   "io",  "vram", "cpu",
    "cdrom", "spu", "gpu",  "dma",
    "timer", "sio", "mdec", "interrupt",
};

pub const region_count = region_names.len;

pub const Sample = struct {
    instr: u64,
    hashes: [region_count]u64,
};

pub const Golden = struct {
    workload: []const u8,
    instructions: u64,
    interval: u64,
    samples: []Sample,
};

pub const ParseError = error{MalformedGolden} || std.mem.Allocator.Error || std.fmt.ParseIntError;

/// Line-oriented text so goldens diff readably in git and a divergence can be
/// eyeballed without tooling. 240 samples is roughly 53 KB.
pub fn serialize(allocator: std.mem.Allocator, g: Golden) ![]u8 {
    // std.ArrayList in 0.16 is unmanaged and has no `writer()`; `print` takes
    // the allocator directly.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "# ps1-golden v1\n", .{});
    try out.print(allocator, "# columns: instr", .{});
    for (region_names) |n| try out.print(allocator, " {s}", .{n});
    try out.print(allocator, "\n", .{});
    try out.print(allocator, "workload {s}\n", .{g.workload});
    try out.print(allocator, "instructions {d}\n", .{g.instructions});
    try out.print(allocator, "interval {d}\n", .{g.interval});

    for (g.samples) |s| {
        try out.print(allocator, "{d}", .{s.instr});
        for (s.hashes) |h| try out.print(allocator, " {x:0>16}", .{h});
        try out.print(allocator, "\n", .{});
    }

    return out.toOwnedSlice(allocator);
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Golden {
    var workload: []const u8 = "";
    var workload_set: bool = false;
    var instructions: u64 = 0;
    var instructions_set: bool = false;
    var interval: u64 = 0;
    var interval_set: bool = false;

    var samples = std.ArrayList(Sample).empty;
    errdefer samples.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "workload ")) {
            workload = line["workload ".len..];
            workload_set = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "instructions ")) {
            instructions = try std.fmt.parseInt(u64, line["instructions ".len..], 10);
            instructions_set = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "interval ")) {
            interval = try std.fmt.parseInt(u64, line["interval ".len..], 10);
            interval_set = true;
            continue;
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const instr_text = fields.next() orelse return error.MalformedGolden;
        var s = Sample{
            .instr = try std.fmt.parseInt(u64, instr_text, 10),
            .hashes = [_]u64{0} ** region_count,
        };
        var i: usize = 0;
        while (fields.next()) |tok| : (i += 1) {
            if (i >= region_count) return error.MalformedGolden;
            s.hashes[i] = try std.fmt.parseInt(u64, tok, 16);
        }
        if (i != region_count) return error.MalformedGolden;
        try samples.append(allocator, s);
    }

    if (!workload_set or !instructions_set or !interval_set) {
        return error.MalformedGolden;
    }

    return .{
        .workload = workload,
        .instructions = instructions,
        .interval = interval,
        .samples = try samples.toOwnedSlice(allocator),
    };
}

pub const games_dir = "games";
pub const bios_eu = "SCPH-7502_BIOS_1997_EU.bin";
pub const bios_us = "SCPH-1001_BIOS_1995_US.bin";
pub const bios_jp = "SCPH-1000_BIOS_1994_JP.bin";

pub const Workload = struct {
    key: []const u8,
    /// null for the disc-less `bios-only` workload.
    cue_path: ?[]const u8,
    bios_path: []const u8,
};

/// "Crash Bandicoot (Europe) (EDC)" -> "crash-bandicoot-europe-edc".
/// Lowercase, every run of non-alphanumeric characters becomes one '-',
/// leading/trailing '-' trimmed. The result is the golden's filename, so it
/// must be stable for as long as the directory keeps its name.
pub fn sanitiseKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pending_dash = false;
    for (name) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_dash and out.items.len > 0) try out.append(allocator, '-');
            pending_dash = false;
            try out.append(allocator, lower);
        } else {
            pending_dash = true;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// A US BIOS in front of a PAL disc stops at the region-lock screen, which
/// wastes the whole workload. Infer the region from the rip's name.
pub fn biosForKey(key: []const u8) []const u8 {
    if (std.mem.indexOf(u8, key, "europe") != null) return bios_eu;
    if (std.mem.indexOf(u8, key, "japan") != null) return bios_jp;
    return bios_us;
}

/// Number of `FILE` directives in a cue sheet. More than one means a
/// per-track .bin layout, which `Disc.initFromCue` cannot load — it takes a
/// single data slice — so such a disc is skipped rather than silently
/// mis-loaded. See the multi-FILE follow-up in the spec.
pub fn countCueFiles(cue_text: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "FILE ")) n += 1;
    }
    return n;
}

/// Scans `games/*/` for exactly one `.cue` per directory. Always yields
/// `bios-only` first, so the harness is useful on a machine with no rips.
pub fn discover(allocator: std.mem.Allocator, io: std.Io) ![]Workload {
    var out = std.ArrayList(Workload).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, .{
        .key = try allocator.dupe(u8, "bios-only"),
        .cue_path = null,
        .bios_path = bios_us,
    });

    var dir = std.Io.Dir.cwd().openDir(io, games_dir, .{ .iterate = true }) catch {
        std.debug.print("[golden] no {s}/ directory — running bios-only\n", .{games_dir});
        return out.toOwnedSlice(allocator);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const key = try sanitiseKey(allocator, entry.name);
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ games_dir, entry.name });
        defer allocator.free(sub_path);

        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch {
            std.debug.print("[golden] skip {s}: cannot open directory\n", .{key});
            allocator.free(key);
            continue;
        };
        defer sub.close(io);

        var cue_name: ?[]u8 = null;
        var sub_it = sub.iterate();
        while (try sub_it.next(io)) |f| {
            if (f.kind != .file) continue;
            if (!std.ascii.endsWithIgnoreCase(f.name, ".cue")) continue;
            if (cue_name != null) {
                std.debug.print("[golden] skip {s}: more than one .cue\n", .{key});
                allocator.free(cue_name.?);
                cue_name = null;
                break;
            }
            cue_name = try allocator.dupe(u8, f.name);
        }

        const name = cue_name orelse {
            std.debug.print("[golden] skip {s}: no .cue found\n", .{key});
            allocator.free(key);
            continue;
        };
        defer allocator.free(name);

        const cue_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_path, name });

        const cue_text = std.Io.Dir.cwd().readFileAlloc(io, cue_path, allocator, .limited(1 << 20)) catch {
            std.debug.print("[golden] skip {s}: cannot read cue\n", .{key});
            allocator.free(key);
            allocator.free(cue_path);
            continue;
        };
        defer allocator.free(cue_text);

        const file_count = countCueFiles(cue_text);
        if (file_count != 1) {
            std.debug.print(
                "[golden] skip {s}: cue declares {d} FILEs; Disc.initFromCue takes one data slice\n",
                .{ key, file_count },
            );
            allocator.free(key);
            allocator.free(cue_path);
            continue;
        }

        try out.append(allocator, .{
            .key = key,
            .cue_path = cue_path,
            .bios_path = biosForKey(key),
        });
    }

    return out.toOwnedSlice(allocator);
}
