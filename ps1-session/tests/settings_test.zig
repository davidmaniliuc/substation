//! The fold of the per-game tables into the player's settings: a preset
//! field replaces the player's wherever the row names one, and the VRAM mode
//! follows the readbacks choice.

const std = @import("std");
const ps1_core = @import("ps1_core");
const session = @import("ps1_session");
const fixtures = @import("image_fixtures");

const settings = session.settings;
const Settings = settings.Settings;
const Preset = ps1_core.pgxp_presets.Preset;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const switches = [_][]const u8{
    "enabled",
    "cpu",
    "culling",
    "vertex_cache",
    "texture_correction",
    "color_correction",
    "depth_buffer",
    "disable_2d",
    "preserve_projection",
};

/// Every folded switch by name, `vertex_cache` included.
fn folded(f: settings.Folded, comptime name: []const u8) bool {
    return if (comptime std.mem.eql(u8, name, "vertex_cache")) f.vertex_cache else @field(f.pgxp, name);
}

test "aPresetFieldOverridesThePlayers" {
    inline for (switches) |name| {
        var preset: Preset = .{ .serial = "TEST-00000" };
        @field(preset, name) = true;
        const f = settings.fold(.{ .use_presets = true }, .on, preset, false, null, .{});
        inline for (switches) |other| {
            try expectEqual(comptime std.mem.eql(u8, name, other), folded(f, other));
        }
    }
}

test "aPresetToleranceReplacesThePlayers" {
    const player: Settings = .{ .use_presets = true, .pgxp = .{ .tolerance = -1 } };
    const with = settings.fold(player, .on, .{ .serial = "T", .tolerance = 2.0 }, false, null, .{});
    try expectEqual(@as(f32, 2.0), with.pgxp.tolerance);
    const without = settings.fold(player, .on, .{ .serial = "T" }, false, null, .{});
    try expectEqual(@as(f32, -1), without.pgxp.tolerance);
}

test "transparentDepthIsAlwaysThePlayers" {
    const player: Settings = .{ .use_presets = true, .pgxp = .{ .transparent_depth = true } };
    const f = settings.fold(player, .on, .{ .serial = "T", .enabled = false }, false, null, .{});
    try expect(f.pgxp.transparent_depth);
    try expect(!f.pgxp.enabled);
}

test "presetsOffIgnoresTheRow" {
    const player: Settings = .{ .use_presets = false };
    const f = settings.fold(player, .on, .{ .serial = "T", .cpu = true, .disable_2d = true }, false, null, .{});
    try expect(std.meta.eql(f.pgxp, player.pgxp));
    try expect(!f.vertex_cache);
}

test "eachReadbacksChoiceResolvesTheMode" {
    const Mode = @TypeOf(settings.fold(.{}, .on, null, false, null, .{}).vram);
    const cases = [_]struct { settings.VramReadbacks, bool, Mode }{
        .{ .automatic, false, .gpu },
        .{ .automatic, true, .dual },
        .{ .on, false, .dual },
        .{ .on, true, .dual },
        .{ .off, false, .gpu },
        .{ .off, true, .gpu },
    };
    for (cases) |c| {
        try expectEqual(c[2], settings.fold(.{}, c[0], null, c[1], null, .{}).vram);
    }
}

test "forSerialReadsBothTables" {
    const a = settings.forSerial(.{ .use_presets = true }, .automatic, "SCES-00010");
    try expect(a.pgxp.cpu);
    try expect(a.pgxp.disable_2d);
    try expectEqual(@as(@TypeOf(a.vram), .gpu), a.vram);
    const b = settings.forSerial(.{}, .automatic, "SLES-02089");
    try expectEqual(@as(@TypeOf(b.vram), .dual), b.vram);
}

test "noSerialIsAutomaticOverAnUnlistedGame" {
    const player: Settings = .{ .use_presets = true };
    const f = settings.forSerial(player, .automatic, "");
    try expectEqual(@as(@TypeOf(f.vram), .gpu), f.vram);
    try expect(std.meta.eql(f.pgxp, player.pgxp));
}

test "aZeroImageHasNoSerial" {
    const image: [2352 * 32]u8 = @splat(0);
    const serial = settings.serialOf(&image, null, 0);
    try expectEqual(@as(usize, 0), settings.serialSlice(&serial).len);
}

const raw_bytes = 2352 * fixtures.iso_sectors;

/// An ISO 9660 disc whose SYSTEM.CNF boots `exe`.
fn isoImage(image: *[raw_bytes]u8, comptime exe: []const u8) void {
    fixtures.writeIso(image, .{ .system_cnf = "BOOT = cdrom:\\" ++ exe ++ ";1\r\nTCB = 4\r\n" });
}

test "serialOfReadsADiscNamedByItsSheet" {
    var raw: [raw_bytes]u8 = undefined;
    isoImage(&raw, "SLUS_005.30");
    const d = ps1_core.disc.Disc.init(&raw);
    const img = try fixtures.encodeMds(std.testing.allocator, d, &raw, true);
    defer std.testing.allocator.free(img.mds);
    defer std.testing.allocator.free(img.mdf);

    // The 2448-byte stride is the sheet's to say: read as a lone image the
    // same bytes name nothing.
    const sheeted = settings.serialOf(img.mdf, img.mds, 0);
    try std.testing.expectEqualStrings("SLUS-00530", settings.serialSlice(&sheeted));
    const bare = settings.serialOf(img.mdf, null, 0);
    try expectEqual(@as(usize, 0), settings.serialSlice(&bare).len);

    // A cue is a sheet too.
    const cue = "FILE \"disc.bin\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n";
    const cued = settings.serialOf(&raw, cue, 0);
    try std.testing.expectEqualStrings("SLUS-00530", settings.serialSlice(&cued));
}

test "serialOfReadsTheEbootDiscItIsAsked" {
    const a = std.testing.allocator;
    var first: [raw_bytes]u8 = undefined;
    var second: [raw_bytes]u8 = undefined;
    isoImage(&first, "SLUS_005.30");
    isoImage(&second, "SLUS_006.71");
    const file = try fixtures.encodePbp(a, &.{
        .{ .raw = &first, .d = ps1_core.disc.Disc.init(&first) },
        .{ .raw = &second, .d = ps1_core.disc.Disc.init(&second) },
    }, "Two", false);
    defer a.free(file);

    const one = settings.serialOf(file, null, 0);
    const two = settings.serialOf(file, null, 1);
    try std.testing.expectEqualStrings("SLUS-00530", settings.serialSlice(&one));
    try std.testing.expectEqualStrings("SLUS-00671", settings.serialSlice(&two));
    // Past the last disc the core refuses, and that is no serial.
    const past = settings.serialOf(file, null, 2);
    try expectEqual(@as(usize, 0), settings.serialSlice(&past).len);
}

test "the overclock table applies only while the player's is off" {
    try expectEqual(95, settings.fold(.{}, .on, null, false, 95, .{}).cpu_overclock);
    try expectEqual(150, settings.fold(.{ .cpu_overclock = 150 }, .on, null, false, 95, .{}).cpu_overclock);
    try expectEqual(100, settings.fold(.{}, .on, null, false, null, .{}).cpu_overclock);
    // Not gated on the presets switch, as the PGXP rows are.
    try expectEqual(95, settings.fold(.{ .use_presets = false }, .on, null, false, 95, .{}).cpu_overclock);
    try expectEqual(95, settings.forSerial(.{}, .automatic, "SLES-00275").cpu_overclock);
    try expectEqual(100, settings.forSerial(.{}, .automatic, "").cpu_overclock);
}

test "a listed game's disabled CD direction is 1x and the other keeps the player's" {
    const Speedup = ps1_core.speedup.Speedup;
    const player: Settings = .{ .cd_speedup = .{ .read = .x4, .seek = .x6 } };
    // Read only (SCES-02080), both (SLUS-00952), neither (SLUS-00707), and no serial.
    try expectEqual(Speedup{ .read = .x1, .seek = .x6 }, settings.forSerial(player, .automatic, "SCES-02080").cd_speedup);
    try expectEqual(Speedup{ .read = .x1, .seek = .x1 }, settings.forSerial(player, .automatic, "SLUS-00952").cd_speedup);
    try expectEqual(player.cd_speedup, settings.forSerial(player, .automatic, "SLUS-00707").cd_speedup);
    try expectEqual(player.cd_speedup, settings.forSerial(player, .automatic, "").cd_speedup);
    // Not gated on the presets switch, and the default is the identity.
    try expectEqual(Speedup{ .read = .x1, .seek = .x6 }, settings.forSerial(.{ .use_presets = true, .cd_speedup = player.cd_speedup }, .automatic, "SCES-02080").cd_speedup);
    try expectEqual(Speedup{}, settings.forSerial(.{}, .automatic, "SCES-02080").cd_speedup);
}

/// The value `#define <name>` carries in `ps1_session.h`.
fn headerValue(header: []const u8, name: []const u8) !u32 {
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, words.next() orelse continue, "#define")) continue;
        if (!std.mem.eql(u8, words.next() orelse continue, name)) continue;
        return std.fmt.parseInt(u32, words.next() orelse return error.NoValue, 10);
    }
    return error.NotInTheHeader;
}

test "theEffectsKeepTheNumbersTheHeaderGives" {
    const header = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "ps1-capi/include/ps1_session.h", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(header);
    const Effect = @FieldType(Settings, "display_effect");
    inline for (.{
        .{ "PS1_EFFECT_NONE", Effect.none },
        .{ "PS1_EFFECT_SHARP_BILINEAR", Effect.sharp_bilinear },
        .{ "PS1_EFFECT_SCANLINES", Effect.scanlines },
        .{ "PS1_EFFECT_CRT", Effect.crt },
        .{ "PS1_EFFECT_COMPOSITE", Effect.composite },
    }) |pair| {
        try expectEqual(@backingInt(pair[1]), try headerValue(header, pair[0]));
    }
    try expectEqual(5, @typeInfo(Effect).@"enum".field_names.len);
}

test "aNewSettingsValueShowsNoEffect" {
    const s: Settings = .{};
    try expectEqual(.none, s.display_effect);
}
