//! The fold of the per-game tables into the player's settings: a preset
//! field replaces the player's wherever the row names one, and the VRAM mode
//! follows the readbacks choice.

const std = @import("std");
const ps1_core = @import("ps1_core");
const session = @import("ps1_session");

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
        const f = settings.fold(.{ .use_presets = true }, .on, preset, false);
        inline for (switches) |other| {
            try expectEqual(comptime std.mem.eql(u8, name, other), folded(f, other));
        }
    }
}

test "aPresetToleranceReplacesThePlayers" {
    const player: Settings = .{ .use_presets = true, .pgxp = .{ .tolerance = -1 } };
    const with = settings.fold(player, .on, .{ .serial = "T", .tolerance = 2.0 }, false);
    try expectEqual(@as(f32, 2.0), with.pgxp.tolerance);
    const without = settings.fold(player, .on, .{ .serial = "T" }, false);
    try expectEqual(@as(f32, -1), without.pgxp.tolerance);
}

test "transparentDepthIsAlwaysThePlayers" {
    const player: Settings = .{ .use_presets = true, .pgxp = .{ .transparent_depth = true } };
    const f = settings.fold(player, .on, .{ .serial = "T", .enabled = false }, false);
    try expect(f.pgxp.transparent_depth);
    try expect(!f.pgxp.enabled);
}

test "presetsOffIgnoresTheRow" {
    const player: Settings = .{ .use_presets = false };
    const f = settings.fold(player, .on, .{ .serial = "T", .cpu = true, .disable_2d = true }, false);
    try expect(std.meta.eql(f.pgxp, player.pgxp));
    try expect(!f.vertex_cache);
}

test "eachReadbacksChoiceResolvesTheMode" {
    const Mode = @TypeOf(settings.fold(.{}, .on, null, false).vram);
    const cases = [_]struct { settings.VramReadbacks, bool, Mode }{
        .{ .automatic, false, .gpu },
        .{ .automatic, true, .dual },
        .{ .on, false, .dual },
        .{ .on, true, .dual },
        .{ .off, false, .gpu },
        .{ .off, true, .gpu },
    };
    for (cases) |c| {
        try expectEqual(c[2], settings.fold(.{}, c[0], null, c[1]).vram);
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
    const serial = settings.serialOf(&image);
    try expectEqual(@as(usize, 0), settings.serialSlice(&serial).len);
}
