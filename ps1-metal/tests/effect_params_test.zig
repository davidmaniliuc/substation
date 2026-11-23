//! The effects' pure half: what the shader is told, with no device.

const std = @import("std");
const display = @import("ps1_metal").display;

const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

fn params(width: u32, height: u32, scale: u32) display.Params {
    return .{ .vram_x = 0, .vram_y = 0, .width = width, .height = height, .depth24 = 0, .enabled = 1, .scale = scale };
}

test "Effect: onlyTheEffectsHaveAShader" {
    try expectEqual(null, display.Effect.none.fragmentName());
    for ([_]display.Effect{ .sharp_bilinear, .scanlines, .crt, .composite }) |fx| {
        try std.testing.expect(std.mem.startsWith(u8, fx.fragmentName().?, "effect_"));
    }
}

test "Effect: theValuesAreTheOnesTheAbiPromises" {
    try expectEqual(0, @backingInt(display.Effect.none));
    try expectEqual(1, @backingInt(display.Effect.sharp_bilinear));
    try expectEqual(2, @backingInt(display.Effect.scanlines));
    try expectEqual(3, @backingInt(display.Effect.crt));
    try expectEqual(4, @backingInt(display.Effect.composite));
}

test "Effect: theParamsStrideMatchesTheShaderStruct" {
    try expectEqual(48, @sizeOf(display.EffectParams));
}

test "Effect: aScreenOfMoreThanTwoFiftySixLinesIsTwoFields" {
    try expectEqual(240, display.scanRows(240));
    try expectEqual(256, display.scanRows(256));
    try expectEqual(128, display.scanRows(257));
    try expectEqual(240, display.scanRows(480));
    try expectEqual(0, display.scanRows(0));
}

test "Effect: aFadeIsLinearBetweenItsFloorAndItsCeilingAndFlatOutside" {
    try expectEqual(0, display.floorFade(1, 2, 3));
    try expectEqual(0, display.floorFade(2, 2, 3));
    try expectApproxEqAbs(0.5, display.floorFade(2.5, 2, 3), 1e-6);
    try expectEqual(1, display.floorFade(3, 2, 3));
    try expectEqual(1, display.floorFade(40, 2, 3));
    try expectApproxEqAbs(0.5, display.floorFade(3.75, 3, 4.5), 1e-6);
}

test "Effect: theSharpPrescaleIsTheWholePixelsPerTexelAndNeverBelowOne" {
    try expectEqual(6, display.sharpPrescale(1920, 320));
    try expectEqual(3, display.sharpPrescale(1000, 320));
    try expectEqual(1, display.sharpPrescale(480, 320));
    try expectEqual(1, display.sharpPrescale(100, 320));
    try expectEqual(1, display.sharpPrescale(100, 0));
}

test "Effect: aLargeFourThreeDrawableTurnsEveryEffectFullyOn" {
    const e = display.effectParams(params(320, 240, 1), .{ 1920, 1440 });
    try expectEqual(320, e.picture_w);
    try expectEqual(240, e.picture_h);
    try expectEqual(1920, e.out_w);
    try expectEqual(1440, e.out_h);
    try expectEqual(0, e.origin_x);
    try expectEqual(240, e.scan_rows);
    try expectEqual(6, e.sharp_x);
    try expectEqual(6, e.sharp_y);
    try expectEqual(1, e.scan_strength);
    try expectEqual(1, e.mask_strength);
}

test "Effect: aSmallDrawableFadesTheScanRowsAndTheMaskOut" {
    // 2 drawable pixels a scan row and a native column.
    const small = display.effectParams(params(320, 240, 1), .{ 640, 480 });
    try expectEqual(0, small.scan_strength);
    try expectEqual(0, small.mask_strength);
    // 3 a row is a full scan row, and 3 a column is below the mask's room.
    const mid = display.effectParams(params(320, 240, 1), .{ 960, 720 });
    try expectEqual(1, mid.scan_strength);
    try expectEqual(0, mid.mask_strength);
}

test "Effect: theRowsFollowTheNativeLinesAtEveryInternalScale" {
    for ([_]u32{ 1, 3, 8 }) |scale| {
        const e = display.effectParams(params(320, 240, scale), .{ 1280, 960 });
        try expectEqual(240, e.scan_rows);
        try expectEqual(@as(f32, @floatFromInt(320 * scale)), e.picture_w);
        try expectEqual(4, e.out_h / e.scan_rows);
    }
}

test "Effect: anInterlacedDisplayHasHalfAsManyRowsAsLines" {
    const e = display.effectParams(params(640, 480, 1), .{ 1280, 960 });
    try expectEqual(240, e.scan_rows);
    try expectEqual(4, e.out_h / e.scan_rows);
}

test "Effect: theLetterboxShrinksThePictureAndOffsetsItsOrigin" {
    var p = params(320, 240, 1);
    const box = display.letterboxScale(1600, 900);
    p.scale_x = box.x;
    p.scale_y = box.y;
    const e = display.effectParams(p, .{ 1600, 900 });
    try expectApproxEqAbs(1200, e.out_w, 0.01);
    try expectEqual(900, e.out_h);
    try expectApproxEqAbs(200, e.origin_x, 0.01);
}

test "Effect: aDegenerateDrawableOrDisplayGivesTheSafeDefaults" {
    const safe: display.EffectParams = .{};
    try expectEqual(safe, display.effectParams(params(320, 240, 1), .{ 0, 480 }));
    try expectEqual(safe, display.effectParams(params(320, 240, 1), .{ 640, 0 }));
    try expectEqual(safe, display.effectParams(params(0, 240, 1), .{ 640, 480 }));
    try expectEqual(safe, display.effectParams(params(320, 0, 1), .{ 640, 480 }));
    try expectEqual(1, safe.sharp_x);
}
