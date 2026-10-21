//! Runahead's sequence against the scripted machine, and the machine
//! contract both machines satisfy. Ported from RunaheadTests.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");
const FakeMachine = @import("fake_machine.zig").FakeMachine;

const machine = session.machine;
const StreamQueue = metal.stream_queue.StreamQueue;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Runahead: runaheadMarksRunsDrainsAndReturnsInThatOrder" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    var scratch: [64]f32 = undefined;
    session.runahead.speculate(&m, 2, 9, q, &scratch);

    // Every speculative frame's audio is read (so none is left for the real
    // timeline) and its stream taken; the return comes last.
    const want = [_][]const u8{ "mark", "run", "audio", "stream", "run", "audio", "stream", "display", "return" };
    try expectEqual(want.len, m.calls.items.len);
    for (want, m.calls.items) |w, got| try std.testing.expectEqualStrings(w, got);
    const g = q.takeSpeculativeGroup(9).?;
    try expectEqual(2, g.count);
    try expectEqual(320, g.display.vram_x);
}

test "Runahead: aRefusedMarkDoesNothing" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    m.fail_mark = true;
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    var scratch: [64]f32 = undefined;
    session.runahead.speculate(&m, 2, 9, q, &scratch);
    try expectEqual(1, m.calls.items.len);
    try expectEqual(null, q.takeSpeculativeGroup(9));
}

test "Runahead: anIncompleteFrameSpoilsTheGroup" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    m.incomplete = true;
    const q = try StreamQueue.init(alloc);
    defer q.deinit();
    var scratch: [64]f32 = undefined;
    session.runahead.speculate(&m, 2, 9, q, &scratch);
    try expectEqual(null, q.takeSpeculativeGroup(9));
}

test "Machine: machineContractHoldsForBothMachines" {
    comptime machine.check(FakeMachine);
    comptime machine.check(machine.HandleMachine);
}

test "Machine: anErrorCodeRoundTripsThroughItsName" {
    const codes = [_]i32{ -4, -8, -9, -10, -11, -12, -13, -14, -16, -17, -20 };
    for (codes) |c| {
        if (machine.fromCode(c)) |_| return error.TestUnexpectedResult else |err| try expectEqual(c, machine.errorCode(err));
    }
    try machine.fromCode(0);
}

test "Machine: aHandleMachineOverAZeroBiosRunsAFrameAndSavesAState" {
    var hm = try machine.HandleMachine.create(&@as([512 * 1024]u8, @splat(0)));
    defer hm.destroy();
    hm.runFrame();
    const size = hm.saveStateSize();
    try expect(size > 0);
    const buf = try alloc.alloc(u8, size);
    defer alloc.free(buf);
    const written = try hm.saveState(buf);
    try expect(written > 0 and written <= size);
    try hm.loadState(buf[0..written]);
    _ = hm.takeFrameStream();
    _ = hm.display();
}
