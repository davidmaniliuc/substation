//! The report half of `ps1-golden -- pgxp`: the four machine-checkable claims
//! about a PGXP-on run, and the per-game hit-rate floors they ratchet against.
//!
//! Separate from `main.zig` because none of it touches the run harness —
//! `runPgxp` needs `loadMachine` and the button script and stays over there,
//! while everything here is arithmetic on seven counters plus a text file.
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
    drift_far: u64 = 0,
    drift_max: f32 = 0,
    /// Textured triangles sampled perspective-correctly — all three vertices
    /// carrying a depth, with the setting on. It is how much of the hit rate
    /// reaches a TEXEL rather than only a position, which is a different
    /// question from `resolved` and the one this phase moves.
    perspective_primitives: u64 = 0,
    /// Every textured triangle drawn, the denominator the count above is read
    /// against — see `Gp0Engine.PgxpStats.textured_triangles`.
    textured_triangles: u64 = 0,
    /// Triangles whose vertex COLOUR was interpolated through the depths —
    /// all three vertices carrying one, with the setting on.
    color_perspective_primitives: u64 = 0,
    /// Every triangle drawn whose three colours can differ: the untextured
    /// Gouraud opcodes and the Gouraud-textured ones. The denominator the count
    /// above is read against — see `Gp0Engine.PgxpStats.shaded_triangles` for
    /// why a flat-shaded primitive is not in it.
    shaded_triangles: u64 = 0,
    /// Polygons that took the depth test — see `Gp0Engine.PgxpStats.depth_tested`.
    depth_tested: u64 = 0,
    /// `clear_depth` records `gp0` decided to emit — area changes and depth
    /// jumps, never a setting toggle. See `Gp0Engine.PgxpStats.depth_clears`.
    depth_clears: u64 = 0,
    /// Resolved primitives lacking a depth, drawn at integers by
    /// `disable_2d` — see `Gp0Engine.PgxpStats.flat_2d_primitives`. Reported
    /// only; there is no ratchet on it.
    flat_2d_primitives: u64 = 0,

    pub fn hitRate(self: Report) f64 {
        if (self.vertices == 0) return 0;
        return @as(f64, @floatFromInt(self.resolved)) * 100.0 /
            @as(f64, @floatFromInt(self.vertices));
    }

    /// Peak displacement in pixels. The counters accumulate 16.16 units.
    pub fn maxPx(self: Report) f64 {
        return @as(f64, @floatFromInt(self.disp_max)) / 65536.0;
    }

    /// What share of the textured triangles drawn reached a texel through a
    /// depth. Reported beside the count because the two readings of a low
    /// count — geometry that cannot resolve, versus a workload that draws
    /// almost no textured triangle — call for opposite responses.
    pub fn perspectiveRate(self: Report) f64 {
        if (self.textured_triangles == 0) return 0;
        return @as(f64, @floatFromInt(self.perspective_primitives)) * 100.0 /
            @as(f64, @floatFromInt(self.textured_triangles));
    }

    /// What share of the triangles that COULD be colour-corrected were. Read
    /// exactly as `perspectiveRate` is, and not as the hit rate: `resolved`
    /// counts vertices that got a sub-pixel POSITION, this counts triangles
    /// that got all three DEPTHS.
    pub fn colorPerspectiveRate(self: Report) f64 {
        if (self.shaded_triangles == 0) return 0;
        return @as(f64, @floatFromInt(self.color_perspective_primitives)) * 100.0 /
            @as(f64, @floatFromInt(self.shaded_triangles));
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

/// The prefixes that mark the three keyed-count ratchets. Four kinds share one
/// `floors.txt`, so every parser has to know the others' prefixes or it reads
/// their key as its own.
const clamp_prefix = "clamped ";
const perspective_prefix = "perspective ";
const color_prefix = "color ";
const depth_prefix = "depth ";
const depth_clears_prefix = "depth_clears ";

/// Parses `floors.txt`: blank lines, `#` comments, and the other ratchets'
/// prefixed lines are skipped, otherwise `<workload key> <percent>`. This is
/// the only UNPREFIXED kind, which is why it is the only parser that has to
/// name the others — a prefixed one excludes them by requiring its own.
/// `depth_clears ` does not start with `depth ` (the underscore), so the two
/// depth prefixes cannot take each other's lines.
pub fn parseFloors(a: std.mem.Allocator, text: []const u8) ![]Floor {
    var out = std.ArrayList(Floor).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, clamp_prefix)) continue;
        if (std.mem.startsWith(u8, line, perspective_prefix)) continue;
        if (std.mem.startsWith(u8, line, color_prefix)) continue;
        if (std.mem.startsWith(u8, line, depth_prefix)) continue;
        if (std.mem.startsWith(u8, line, depth_clears_prefix)) continue;
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

/// One `<prefix><key> <count>` line. The three keyed ratchets differ only in
/// their prefix and in which direction `report` reads the number, so they are
/// one type here and the ceiling-versus-floor meaning lives where it is
/// decided — in `report`, and nowhere else.
pub const KeyedCount = struct {
    key: []const u8,
    count: u64,
};

pub const ClampCeiling = KeyedCount;
pub const PerspectiveFloor = KeyedCount;
pub const ColorFloor = KeyedCount;
pub const DepthFloor = KeyedCount;
pub const DepthClearFloor = KeyedCount;

/// `<prefix><key> <count>` lines, for the three ratchets that are keyed counts.
/// Requiring the prefix is the whole skip rule: a line belonging to any other
/// kind fails it, including the unprefixed hit-rate lines.
fn parsePrefixedCounts(a: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]KeyedCount {
    var out = std.ArrayList(KeyedCount).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = std.mem.trim(u8, line[prefix.len..], " \t");
        const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return error.BadFloorLine;
        const value = std.mem.trim(u8, rest[sep..], " \t");
        try out.append(a, .{
            .key = rest[0..sep],
            .count = try std.fmt.parseInt(u64, value, 10),
        });
    }
    return out.toOwnedSlice(a);
}

/// `clamped <workload key> <count>` — a CEILING on how often `toFixed`'s clamp
/// had to intervene.
pub fn parseClampCeilings(a: std.mem.Allocator, text: []const u8) ![]ClampCeiling {
    return parsePrefixedCounts(a, text, clamp_prefix);
}

/// `perspective <key> <count>` — a FLOOR, not a ceiling, because more textured
/// triangles sampled through their depths is the improvement here where more
/// clamps is the regression.
pub fn parsePerspectiveFloors(a: std.mem.Allocator, text: []const u8) ![]PerspectiveFloor {
    return parsePrefixedCounts(a, text, perspective_prefix);
}

/// `color <key> <count>` — a FLOOR for the same reason `perspective ` is one.
pub fn parseColorFloors(a: std.mem.Allocator, text: []const u8) ![]ColorFloor {
    return parsePrefixedCounts(a, text, color_prefix);
}

/// `depth <key> <count>` — a FLOOR on how many polygons took the depth test:
/// fewer means the feature reaches less geometry, the same reading as
/// `perspective` and `color`.
pub fn parseDepthFloors(a: std.mem.Allocator, text: []const u8) ![]DepthFloor {
    return parsePrefixedCounts(a, text, depth_prefix);
}

/// `depth_clears <key> <count>` — a FLOOR on how many `clear_depth` records
/// `gp0` emitted: a count that collapses means the clear rules (area change,
/// depth jump) stopped firing and the plane is accumulating stale depths.
pub fn parseDepthClearFloors(a: std.mem.Allocator, text: []const u8) ![]DepthClearFloor {
    return parsePrefixedCounts(a, text, depth_clears_prefix);
}

pub fn countFor(counts: []const KeyedCount, key: []const u8) ?u64 {
    for (counts) |c| {
        if (std.mem.eql(u8, c.key, key)) return c.count;
    }
    return null;
}

/// The six ratchets `floors.txt` carries, read together because a workload's
/// numbers are read together. Grouped rather than passed as six slices: a
/// seventh positional `[]const T` of nearly identical type is a call waiting
/// to be made in the wrong order.
pub const Ratchets = struct {
    floors: []const Floor = &.{},
    clamp_ceilings: []const ClampCeiling = &.{},
    perspective: []const PerspectiveFloor = &.{},
    color: []const ColorFloor = &.{},
    depth: []const DepthFloor = &.{},
    depth_clears: []const DepthClearFloor = &.{},
};

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

/// The one check the four keyed-count FLOOR ratchets share (`perspective`,
/// `color`, `depth`, `depth_clears` — never `clamped`, which is a CEILING and
/// reads the other way): `value >= floor` is OK, below it FAILS the
/// workload, and no floor line at all is a WARN, never a failure. `label` is
/// the column's padded name and `mid` is the already-formatted, ratchet-
/// specific middle of the line — the count alone for `depth`/`depth_clears`,
/// the count plus its rate over a denominator for `perspective`/`color` —
/// built by the caller because that shape is the one thing the four still
/// don't share. Prints the line and returns whether `report`'s `failed`
/// flag should be set.
fn keyedFloor(label: []const u8, mid: []const u8, counts: []const KeyedCount, key: []const u8, value: u64, buf: []u8) bool {
    if (countFor(counts, key)) |floor| {
        const ok = value >= floor;
        std.debug.print("{s}{s}   floor {s}  {s}\n", .{
            label, mid, commas(buf, floor), if (ok) "OK" else "BELOW FLOOR",
        });
        return !ok;
    }
    std.debug.print("{s}{s}   no floor  WARN\n", .{ label, mid });
    return false;
}

/// Prints one workload's block and returns true if it FAILED.
///
/// Five hard checks, plus one reported-only diagnostic.
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
/// `perspective_primitives` is the fourth, and it is a FLOOR rather than a
/// ceiling — more textured triangles reaching a texel perspective-correctly is
/// the improvement here, where more `clamped` is the regression. It answers a
/// different question from the hit rate: `resolved` counts vertices that got a
/// sub-pixel POSITION, this counts triangles that got all three depths and so
/// sampled their texture through them.
///
/// `color_perspective_primitives` is the fifth, and it is a FLOOR for the same
/// reason the fourth is. Its denominator is not every triangle but every
/// SHADED one — the untextured Gouraud opcodes plus the Gouraud-textured ones
/// — because a flat-shaded primitive reproduces its colour exactly whichever
/// interpolant runs, so counting it would dilute the rate with triangles the
/// setting cannot move.
///
/// `depth_tested` is the sixth, and it is a FLOOR: fewer polygons taking the
/// depth test means the feature reaches less geometry, the same reading as
/// `perspective` and `color`.
///
/// `depth_clears` is the seventh, and it is also a FLOOR, not a ceiling: a
/// clear count that COLLAPSES is the regression here, because it means the
/// area-change/depth-jump rules stopped firing and the plane accumulates
/// stale depths across frames instead of resetting — the opposite failure
/// mode from `clamped`, where more is worse.
///
/// A workload with no floor or ceiling line is a WARNING, not an error,
/// unlike a missing trace golden: a new rip should not fail the gate before
/// anyone has measured it.
pub fn report(key: []const u8, r: Report, ratchets: Ratchets) bool {
    var b1: [26]u8 = undefined;
    var b2: [26]u8 = undefined;
    var b3: [26]u8 = undefined;
    var b4: [26]u8 = undefined;

    std.debug.print("{s}\n", .{key});
    std.debug.print("  GP0 vertices      {s}\n", .{commas(&b1, r.vertices)});

    var failed = false;

    const floor = floorFor(ratchets.floors, key);
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

    const ceiling = countFor(ratchets.clamp_ceilings, key);
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

    var mid_buf: [80]u8 = undefined;

    const persp_mid = std.fmt.bufPrint(&mid_buf, "{s} of {s} textured tris ({d:.1}%)", .{
        commas(&b2, r.perspective_primitives), commas(&b3, r.textured_triangles), r.perspectiveRate(),
    }) catch unreachable;
    if (keyedFloor("  perspective       ", persp_mid, ratchets.perspective, key, r.perspective_primitives, &b4)) failed = true;

    const color_mid = std.fmt.bufPrint(&mid_buf, "{s} of {s} shaded tris ({d:.1}%)", .{
        commas(&b2, r.color_perspective_primitives), commas(&b3, r.shaded_triangles), r.colorPerspectiveRate(),
    }) catch unreachable;
    if (keyedFloor("  color             ", color_mid, ratchets.color, key, r.color_perspective_primitives, &b4)) failed = true;

    const depth_mid = std.fmt.bufPrint(&mid_buf, "{s} polygons tested", .{commas(&b2, r.depth_tested)}) catch unreachable;
    if (keyedFloor("  depth             ", depth_mid, ratchets.depth, key, r.depth_tested, &b4)) failed = true;

    const depth_clears_mid = std.fmt.bufPrint(&mid_buf, "{s}", .{commas(&b2, r.depth_clears)}) catch unreachable;
    if (keyedFloor("  depth_clears      ", depth_clears_mid, ratchets.depth_clears, key, r.depth_clears, &b4)) failed = true;

    std.debug.print("  flat_2d           {s}   (resolved, no depth: drawn at integers by disable_2d)\n", .{commas(&b3, r.flat_2d_primitives)});

    // The composition of `clamped` above, which the count alone cannot give:
    // a candidate a whole pixel or more from its own vertex is one the clamp
    // conceals rather than repairs, and one `pgxp_tolerance` would refuse.
    // Reported, never gated — the ratchet is `clamped`.
    std.debug.print("  drift_far         {s}   (of those, >= 1 px from the vertex; peak {d:.3} px)\n", .{
        commas(&b3, r.drift_far), r.drift_max,
    });

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
    try std.testing.expectEqual(@as(u64, 4), ceilings[0].count);
    try std.testing.expectEqual(@as(u64, 0), ceilings[1].count);
    try std.testing.expect(countFor(ceilings, "spyro") != null);
    try std.testing.expect(countFor(ceilings, "absent") == null);
}

test "the report's hard checks fire, and a missing floor or ceiling does not" {
    const clean = Report{ .vertices = 100, .resolved = 95, .identity_fail = 3, .disp_sum = 0, .disp_max = 65535, .clamped = 2, .perspective_primitives = 7, .textured_triangles = 20 };
    const ratchets: Ratchets = .{
        .floors = &[_]Floor{.{ .key = "w", .percent = 90.0 }},
        .clamp_ceilings = &[_]ClampCeiling{.{ .key = "w", .count = 2 }},
        .perspective = &[_]PerspectiveFloor{.{ .key = "w", .count = 7 }},
    };

    try std.testing.expect(!report("w", clean, ratchets));

    var low = clean;
    low.resolved = 80;
    try std.testing.expect(report("w", low, ratchets));

    var far = clean;
    far.disp_max = 65536; // exactly one pixel: impossible under toFixed's clamp
    try std.testing.expect(report("w", far, ratchets));

    // A ceiling exceeded fails the sweep, same as a hit-rate floor missed.
    var over = clean;
    over.clamped = 3;
    try std.testing.expect(report("w", over, ratchets));

    // The perspective ratchet runs the other way: BELOW its floor fails.
    var fewer = clean;
    fewer.perspective_primitives = 6;
    try std.testing.expect(report("w", fewer, ratchets));

    // No floor or ceiling line: a warning, never a failure.
    try std.testing.expect(!report("unmeasured", low, ratchets));
}

test "commas groups digits from the right" {
    var buf: [26]u8 = undefined;
    try std.testing.expectEqualStrings("0", commas(&buf, 0));
    try std.testing.expectEqualStrings("999", commas(&buf, 999));
    try std.testing.expectEqualStrings("1,000", commas(&buf, 1000));
    try std.testing.expectEqualStrings("1,284,551", commas(&buf, 1_284_551));
}

test "the four ratchet line kinds do not read each other's lines" {
    const a = std.testing.allocator;
    const text =
        \\# a comment
        \\croc 99
        \\clamped croc 81466
        \\perspective croc 47200
        \\color croc 12300
        \\
    ;
    const floors = try parseFloors(a, text);
    defer a.free(floors);
    const ceilings = try parseClampCeilings(a, text);
    defer a.free(ceilings);
    const persp = try parsePerspectiveFloors(a, text);
    defer a.free(persp);
    const color = try parseColorFloors(a, text);
    defer a.free(color);

    // One line each, and each reading ITS line rather than a neighbour's — the
    // mistake a fourth kind makes easy is a parser that takes `color croc` for
    // a hit-rate line keyed `color`.
    try std.testing.expectEqual(@as(usize, 1), floors.len);
    try std.testing.expectEqualStrings("croc", floors[0].key);
    try std.testing.expectEqual(@as(usize, 1), ceilings.len);
    try std.testing.expectEqual(@as(u64, 81466), ceilings[0].count);
    try std.testing.expectEqual(@as(usize, 1), persp.len);
    try std.testing.expectEqual(@as(u64, 47200), persp[0].count);
    try std.testing.expectEqualStrings("croc", persp[0].key);
    try std.testing.expect(countFor(persp, "croc") != null);
    try std.testing.expect(countFor(persp, "absent") == null);
    try std.testing.expectEqual(@as(usize, 1), color.len);
    try std.testing.expectEqualStrings("croc", color[0].key);
    try std.testing.expectEqual(@as(u64, 12300), color[0].count);
}

test "the colour floor gates, and a missing one does not" {
    const r: Report = .{
        .vertices = 100,
        .resolved = 100,
        .identity_fail = 0,
        .disp_sum = 0,
        .disp_max = 0,
        .shaded_triangles = 1000,
        .color_perspective_primitives = 400,
    };
    const ratchets: Ratchets = .{
        .color = &[_]ColorFloor{.{ .key = "k", .count = 500 }},
    };
    try std.testing.expect(report("k", r, ratchets)); // 400 < 500: FAIL
    try std.testing.expect(!report("k", r, .{})); // no line: WARN, not fail
}

test "Phase5: depth and depth_clears floors parse, and no other parser takes them" {
    const a = std.testing.allocator;
    const text =
        \\croc 90.0
        \\depth croc 1000
        \\depth_clears croc 50
        \\color croc 12300
    ;
    const floors = try parseFloors(a, text);
    defer a.free(floors);
    try std.testing.expectEqual(@as(usize, 1), floors.len);
    const d = try parseDepthFloors(a, text);
    defer a.free(d);
    try std.testing.expectEqual(@as(usize, 1), d.len);
    try std.testing.expectEqual(@as(u64, 1000), d[0].count);
    const c = try parseDepthClearFloors(a, text);
    defer a.free(c);
    try std.testing.expectEqual(@as(u64, 50), c[0].count);
}
