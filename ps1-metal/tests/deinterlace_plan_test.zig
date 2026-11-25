//! The deinterlacer's decisions, without a device: which pictures a mode
//! reconstructs, and which older picture Adaptive compares against.

const std = @import("std");
const ps1_metal = @import("ps1_metal");

const deinterlace = ps1_metal.deinterlace;
const display = ps1_metal.display;
const History = deinterlace.History;
const Mode = deinterlace.Mode;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn interlaced() display.Params {
    return .{ .vram_x = 0, .vram_y = 0, .width = 640, .height = 480, .depth24 = 0, .enabled = 1 };
}

test "Deinterlace: onlyProgressiveDrawsEveryRow" {
    for (std.enums.values(Mode)) |m| try expectEqual(m != .progressive, m.drawsFields());
}

test "Deinterlace: progressiveAndWeaveShowTheTextureAsDrawn" {
    for ([_]Mode{ .progressive, .weave }) |m| {
        const q = deinterlace.picture(m, interlaced(), .odd);
        try expectEqual(0, q.deint);
    }
}

test "Deinterlace: aReconstructionNeedsAFieldOfATallDisplayThatIsOn" {
    for ([_]Mode{ .adaptive, .blend, .single_field }) |m| {
        try expectEqual(@backingInt(m), deinterlace.picture(m, interlaced(), .even).deint);
        try expectEqual(0, deinterlace.picture(m, interlaced(), .all).deint);
        var short = interlaced();
        short.height = 240;
        try expectEqual(0, deinterlace.picture(m, short, .even).deint);
        var off = interlaced();
        off.enabled = 0;
        try expectEqual(0, deinterlace.picture(m, off, .even).deint);
    }
}

test "Deinterlace: theNewestFieldIsCountedFromTheDisplaysFirstRow" {
    var p = interlaced();
    try expectEqual(0, deinterlace.picture(.blend, p, .even).newest);
    try expectEqual(1, deinterlace.picture(.blend, p, .odd).newest);
    p.vram_y = 1;
    try expectEqual(1, deinterlace.picture(.blend, p, .even).newest);
    try expectEqual(0, deinterlace.picture(.blend, p, .odd).newest);
}

test "Deinterlace: aPictureCarriesNoReferenceUntilTheDeinterlacerGivesIt" {
    var p = interlaced();
    p.has_reference = 1;
    try expectEqual(0, deinterlace.picture(.adaptive, p, .odd).has_reference);
}

const size: [2]u32 = .{ 640, 480 };

fn tag(id: u64, newest: u32) History.Tag {
    return .{ .id = id, .newest = newest, .size = size };
}

test "Deinterlace: theSamePictureAgainDrawsNothing" {
    var h: History = .{};
    const first = h.admit(tag(1, 0));
    try expect(first.draw);
    const again = h.admit(tag(1, 0));
    try expect(!again.draw);
    try expectEqual(first.slot, again.slot);
}

test "Deinterlace: inSteadyPlayTheReferenceIsThePictureTwoBack" {
    var h: History = .{};
    _ = h.admit(tag(1, 0));
    try expectEqual(null, h.reference());
    _ = h.admit(tag(2, 1));
    try expectEqual(null, h.reference());
    const one = h.tags[(h.head + 2) % History.len].?;
    try expectEqual(1, one.id);
    var slots: [8]usize = undefined;
    for (3..11) |id| {
        const a = h.admit(tag(id, @intCast((id + 1) & 1)));
        try expect(a.draw);
        const r = h.reference().?;
        try expectEqual(id - 2, h.tags[r].?.id);
        try expect(r != a.slot);
        slots[id - 3] = a.slot;
    }
    // Three slots, each reused in turn.
    for (slots[3..], slots[0..5]) |later, earlier| try expectEqual(earlier, later);
}

test "Deinterlace: afterAGapTheNewestOlderPictureThatLinesUpIsTheReference" {
    var h: History = .{};
    _ = h.admit(tag(1, 0));
    _ = h.admit(tag(2, 1));
    // Picture 3 was never shown: 4 has picture 2's parity.
    _ = h.admit(tag(4, 1));
    try expectEqual(2, h.tags[h.reference().?].?.id);
    // A run of one parity leaves nothing of the other to compare with.
    var g: History = .{};
    _ = g.admit(tag(1, 1));
    _ = g.admit(tag(2, 1));
    _ = g.admit(tag(3, 0));
    try expectEqual(null, g.reference());
}

test "Deinterlace: aPictureOfAnotherSizeStartsTheHistoryOver" {
    var h: History = .{};
    _ = h.admit(tag(1, 0));
    _ = h.admit(tag(2, 1));
    _ = h.admit(.{ .id = 3, .newest = 0, .size = .{ 512, 480 } });
    try expectEqual(null, h.reference());
    for (h.tags) |t| if (t) |x| try expectEqual(3, x.id);
}

test "Deinterlace: aClearedHistoryHasNoReference" {
    var h: History = .{};
    _ = h.admit(tag(1, 0));
    _ = h.admit(tag(2, 1));
    _ = h.admit(tag(3, 0));
    try expect(h.reference() != null);
    h.clear();
    try expectEqual(null, h.reference());
    try expect(h.admit(tag(3, 0)).draw);
}
