//! The report half of `ps1-golden -- pgxp`: the two machine-checkable claims
//! about a PGXP-on run, and the per-game hit-rate floors they ratchet against.
//!
//! Separate from `main.zig` because none of it touches the run harness —
//! `runPgxp` needs `loadMachine` and the button script and stays over there,
//! while everything here is arithmetic on five counters plus a text file.
//!
//! There is no golden for PGXP-on output and there never will be: the identity
//! invariant bounds the error but does not confirm the value, and Avocado does
//! not implement PGXP, so it is not an oracle here either. This is the whole
//! automated gate for the feature, which is also why the default is off.

const std = @import("std");

pub const Report = struct {
    vertices: u64,
    resolved: u64,
    identity_fail: u64,
    disp_sum: u64,
    disp_max: u32,
    mixed_primitives: u64 = 0,
    thin_primitives: u64 = 0,
    welded: u64 = 0,
    weld_collisions: u64 = 0,
    clamped: u64 = 0,

    pub fn hitRate(self: Report) f64 {
        if (self.vertices == 0) return 0;
        return @as(f64, @floatFromInt(self.resolved)) * 100.0 /
            @as(f64, @floatFromInt(self.vertices));
    }

    /// Peak displacement in pixels. The counters accumulate 16.16 units.
    pub fn maxPx(self: Report) f64 {
        return @as(f64, @floatFromInt(self.disp_max)) / 65536.0;
    }

    pub fn meanPx(self: Report) f64 {
        if (self.resolved == 0) return 0;
        return @as(f64, @floatFromInt(self.disp_sum)) /
            @as(f64, @floatFromInt(self.resolved)) / 65536.0;
    }
};

pub const Floor = struct {
    key: []const u8,
    percent: f64,
};

/// The prefix that marks a `clamped` ceiling line rather than a hit-rate
/// floor line, so both ratchets can share one file without either parser
/// misreading the other's lines.
const clamp_prefix = "clamped ";

/// Parses `floors.txt`: blank lines, `#` comments, and `clamped ` ceiling
/// lines (see `parseClampCeilings`) are skipped, otherwise
/// `<workload key> <percent>`.
pub fn parseFloors(a: std.mem.Allocator, text: []const u8) ![]Floor {
    var out = std.ArrayList(Floor).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, clamp_prefix)) continue;
        const sep = std.mem.indexOfAny(u8, line, " \t") orelse return error.BadFloorLine;
        const value = std.mem.trim(u8, line[sep..], " \t");
        try out.append(a, .{
            .key = line[0..sep],
            .percent = try std.fmt.parseFloat(f64, value),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn floorFor(floors: []const Floor, key: []const u8) ?f64 {
    for (floors) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.percent;
    }
    return null;
}

pub const ClampCeiling = struct {
    key: []const u8,
    ceiling: u64,
};

/// Parses the SAME `floors.txt`, this time for `clamped <workload key>
/// <count>` lines — everything else (blank, `#`, and plain hit-rate lines)
/// is skipped, mirroring `parseFloors` skipping these.
pub fn parseClampCeilings(a: std.mem.Allocator, text: []const u8) ![]ClampCeiling {
    var out = std.ArrayList(ClampCeiling).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, clamp_prefix)) continue;
        const rest = std.mem.trim(u8, line[clamp_prefix.len..], " \t");
        const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return error.BadFloorLine;
        const value = std.mem.trim(u8, rest[sep..], " \t");
        try out.append(a, .{
            .key = rest[0..sep],
            .ceiling = try std.fmt.parseInt(u64, value, 10),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn ceilingFor(ceilings: []const ClampCeiling, key: []const u8) ?u64 {
    for (ceilings) |c| {
        if (std.mem.eql(u8, c.key, key)) return c.ceiling;
    }
    return null;
}

/// Groups the digits of `v` with thousands separators into `buf`, which must
/// hold at least 26 bytes (20 digits plus 6 separators).
fn commas(buf: []u8, v: u64) []const u8 {
    var digits: [20]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{v}) catch unreachable;
    var n: usize = 0;
    for (d, 0..) |c, i| {
        if (i != 0 and (d.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Prints one workload's block and returns true if it FAILED.
///
/// Three hard checks, plus one reported-only diagnostic.
///
/// `maxPx() < 1.0` follows from a resolved vertex sharing the wire word's
/// integer coordinate to within the pixel `primitive.zig`'s `toFixed` clamps
/// it into — which means it can no longer fail for any input; before that
/// clamp existed it was the check that caught this task's own defect (a
/// resolved vertex 2047 columns from its own wire word). The clamp stays;
/// what it hid is `clamped` below.
///
/// The hit-rate floor is the second: a ratchet on how much of a workload's
/// geometry PGXP actually reaches.
///
/// `clamped` is the third, and it is a RATCHET too, exactly like the hit-rate
/// floor, against a per-workload CEILING in the same `floors.txt` (`clamped
/// <key> <count>` lines, parsed by `parseClampCeilings`): it counts a
/// resolved vertex whose PRE-clamp conversion disagreed with the clamped
/// position actually used — the class of bug `maxPx()` can no longer see.
/// GATED, unlike `identity_fail`, because a ceiling can absorb a workload's
/// ambient rate (an `f32` rounding artifact half an ulp from a pixel edge is
/// not rare — Crash 2 hits it twice in every 600M-instruction run) while
/// still catching a NEW producer that starts clamping vertices a workload
/// never used to clamp. A workload with no ceiling line WARNs instead of
/// failing, same as a missing hit-rate floor.
///
/// `identity_fail` alone stays REPORTED, not enforced: it counts vertices the
/// word match correctly rejected — a leak in invalidation, which costs
/// coverage rather than correctness, and which the hit-rate floor already
/// prices in. Printing it is how you find a missing propagation idiom when
/// the rate comes back low.
///
/// A workload with no floor or ceiling line is a WARNING, not an error,
/// unlike a missing trace golden: a new rip should not fail the gate before
/// anyone has measured it.
pub fn report(key: []const u8, r: Report, floors: []const Floor, clamp_ceilings: []const ClampCeiling) bool {
    var b1: [26]u8 = undefined;
    var b2: [26]u8 = undefined;
    var b3: [26]u8 = undefined;
    var b4: [26]u8 = undefined;

    std.debug.print("{s}\n", .{key});
    std.debug.print("  GP0 vertices      {s}\n", .{commas(&b1, r.vertices)});

    var failed = false;

    const floor = floorFor(floors, key);
    const rate = r.hitRate();
    if (floor) |f| {
        const ok = rate >= f;
        if (!ok) failed = true;
        std.debug.print("  shadow resolved   {s}   ({d:.1}%)  floor {d:.1}%  {s}\n", .{
            commas(&b2, r.resolved), rate, f, if (ok) "OK" else "BELOW FLOOR",
        });
    } else {
        std.debug.print("  shadow resolved   {s}   ({d:.1}%)  no floor  WARN\n", .{
            commas(&b2, r.resolved), rate,
        });
    }

    // Strictly less than one pixel: `primitive.zig`'s `toFixed` clamps `px`/
    // `py` to stay inside the wire's own integer coordinate, so a
    // displacement of a whole pixel or more is arithmetically impossible
    // under the CLAMPED value this measures — see the doc comment above for
    // why that makes this specific check unable to fail today, and `clamped`
    // below for the signal that replaces it.
    const max_px = r.maxPx();
    const disp_ok = max_px < 1.0;
    if (!disp_ok) failed = true;
    // Five decimals: the largest displacement `toFixed`'s clamp can admit is
    // 65535/65536, which rounds to "1.0000" at four and reads as a violation
    // of the very bound printed beside it.
    std.debug.print("  displacement      max {d:.5} px, mean {d:.5} px   {s}\n", .{
        max_px, r.meanPx(), if (disp_ok) "OK" else "OVER ONE PIXEL",
    });

    std.debug.print("  mixed_primitives  {s}   (partly-resolved primitives snapped back to integers)\n", .{
        commas(&b3, r.mixed_primitives),
    });
    std.debug.print("  thin_primitives   {s}   (thinner than 1.5 px; a sub-pixel move could delete them)\n", .{
        commas(&b3, r.thin_primitives),
    });
    std.debug.print("  welded            {s}   (vertices moved onto their position's frame-wide value)\n", .{
        commas(&b3, r.welded),
    });
    std.debug.print("  weld_collisions   {s}   (table slot held by another position; crack survives)\n", .{
        commas(&b3, r.weld_collisions),
    });
    std.debug.print("  identity_fail     {s}   (stale candidates rejected; reported, not gated)\n", .{
        commas(&b3, r.identity_fail),
    });

    const ceiling = ceilingFor(clamp_ceilings, key);
    if (ceiling) |c| {
        const clamp_ok = r.clamped <= c;
        if (!clamp_ok) failed = true;
        std.debug.print("  clamped           {s}   ceiling {s}  {s}\n", .{
            commas(&b3, r.clamped), commas(&b4, c), if (clamp_ok) "OK" else "OVER CEILING",
        });
    } else {
        std.debug.print("  clamped           {s}   no ceiling  WARN\n", .{
            commas(&b3, r.clamped),
        });
    }

    return failed;
}

test "parseFloors skips comments, blank lines, and clamped ceiling lines" {
    const a = std.testing.allocator;
    const floors = try parseFloors(a,
        \\# a comment
        \\
        \\croc 90.0
        \\spyro  12
        \\clamped croc 4
        \\
    );
    defer a.free(floors);

    try std.testing.expectEqual(@as(usize, 2), floors.len);
    try std.testing.expectEqualStrings("croc", floors[0].key);
    try std.testing.expectEqual(@as(f64, 90.0), floors[0].percent);
    try std.testing.expectEqual(@as(f64, 12.0), floors[1].percent);
    try std.testing.expect(floorFor(floors, "spyro") != null);
    try std.testing.expect(floorFor(floors, "absent") == null);
}

test "parseClampCeilings reads only clamped lines, ignoring hit-rate floors" {
    const a = std.testing.allocator;
    const ceilings = try parseClampCeilings(a,
        \\# a comment
        \\
        \\croc 90.0
        \\clamped croc 4
        \\clamped spyro 0
        \\
    );
    defer a.free(ceilings);

    try std.testing.expectEqual(@as(usize, 2), ceilings.len);
    try std.testing.expectEqualStrings("croc", ceilings[0].key);
    try std.testing.expectEqual(@as(u64, 4), ceilings[0].ceiling);
    try std.testing.expectEqual(@as(u64, 0), ceilings[1].ceiling);
    try std.testing.expect(ceilingFor(ceilings, "spyro") != null);
    try std.testing.expect(ceilingFor(ceilings, "absent") == null);
}

test "the report's hard checks fire, and a missing floor or ceiling does not" {
    const clean = Report{ .vertices = 100, .resolved = 95, .identity_fail = 3, .disp_sum = 0, .disp_max = 65535, .clamped = 2 };
    const floors = [_]Floor{.{ .key = "w", .percent = 90.0 }};
    const ceilings = [_]ClampCeiling{.{ .key = "w", .ceiling = 2 }};

    try std.testing.expect(!report("w", clean, &floors, &ceilings));

    var low = clean;
    low.resolved = 80;
    try std.testing.expect(report("w", low, &floors, &ceilings));

    var far = clean;
    far.disp_max = 65536; // exactly one pixel: impossible under toFixed's clamp
    try std.testing.expect(report("w", far, &floors, &ceilings));

    // A ceiling exceeded fails the sweep, same as a hit-rate floor missed.
    var over = clean;
    over.clamped = 3;
    try std.testing.expect(report("w", over, &floors, &ceilings));

    // No floor or ceiling line: a warning, never a failure.
    try std.testing.expect(!report("unmeasured", low, &floors, &ceilings));
}

test "commas groups digits from the right" {
    var buf: [26]u8 = undefined;
    try std.testing.expectEqualStrings("0", commas(&buf, 0));
    try std.testing.expectEqualStrings("999", commas(&buf, 999));
    try std.testing.expectEqualStrings("1,000", commas(&buf, 1000));
    try std.testing.expectEqualStrings("1,284,551", commas(&buf, 1_284_551));
}
