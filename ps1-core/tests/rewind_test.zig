const std = @import("std");
const ps1 = @import("ps1_core");
const savestate = ps1.savestate;
const rewind = savestate.rewind;
const Rewind = savestate.Rewind;
const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;

const a = std.testing.allocator;

fn roundTrip(newer: []const u8, older: []const u8) !void {
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);
    try rewind.encode(newer, older, &delta, a);
    const buf = try a.dupe(u8, newer);
    defer a.free(buf);
    rewind.apply(delta.items, buf);
    try std.testing.expectEqualSlices(u8, older, buf);
}

fn filled(comptime n: usize, byte: u8) [n]u8 {
    return @splat(byte);
}

test "a reverse delta turns the newer buffer back into the older one" {
    const zeros = filled(64, 0);
    const ones = filled(64, 1);
    try roundTrip(&zeros, &zeros);
    try roundTrip(&ones, &zeros);

    var first = zeros;
    first[3] = 9;
    try roundTrip(&zeros, &first);

    var last = zeros;
    last[63] = 9;
    try roundTrip(&zeros, &last);

    // Alternating words: every run is one word long.
    var alternating = zeros;
    var i: usize = 0;
    while (i < alternating.len) : (i += 16) alternating[i] = 7;
    try roundTrip(&zeros, &alternating);
}

test "an equal pair encodes to nothing" {
    const zeros = filled(64, 0);
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);
    try rewind.encode(&zeros, &zeros, &delta, a);
    try std.testing.expectEqual(@as(usize, 0), delta.items.len);
}

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init() !Machine {
        const bus = try Bus.init(a);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(a);
    }

    fn snapshot(m: *Machine) ![]u8 {
        const n = try savestate.saveTrusted(&m.cpu, null);
        const buf = try a.alloc(u8, n);
        _ = try savestate.saveTrusted(&m.cpu, buf);
        return buf;
    }
};

/// One "frame" of a test machine: a RAM byte that names it, so any two
/// frames' states differ.
fn frame(m: *Machine, r: *Rewind, n: u8) !void {
    m.bus.ram[0x1000 + @as(usize, n)] = n;
    m.bus.ram[0x10] = n;
    try r.frameDone(&m.cpu);
}

test "a step with no history is NoHistory and changes nothing" {
    var m = try Machine.init();
    defer m.deinit();
    var r = Rewind.init(a);
    defer r.deinit();
    try r.configure(64 << 20);

    const before = try m.snapshot();
    defer a.free(before);
    try std.testing.expectError(error.NoHistory, r.step(&m.cpu));
    const after = try m.snapshot();
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    // One capture is the head alone: still nothing to step back to.
    try frame(&m, &r, 1);
    try frame(&m, &r, 2);
    try std.testing.expectError(error.NoHistory, r.step(&m.cpu));
}

test "a capture every two frames, and a step returns the older capture exactly" {
    var m = try Machine.init();
    defer m.deinit();
    var r = Rewind.init(a);
    defer r.deinit();
    try r.configure(64 << 20);

    try frame(&m, &r, 1);
    try frame(&m, &r, 2); // capture 1
    const at_two = try m.snapshot();
    defer a.free(at_two);
    try frame(&m, &r, 3);
    try frame(&m, &r, 4); // capture 2
    try frame(&m, &r, 5);
    try frame(&m, &r, 6); // capture 3

    const info = r.info();
    try std.testing.expectEqual(@as(u32, 2), info.entries);
    try std.testing.expectEqual(@as(u32, 4), info.frames_covered);

    try r.step(&m.cpu); // back to capture 2
    try r.step(&m.cpu); // back to capture 1
    const back = try m.snapshot();
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, at_two, back);
    try std.testing.expectError(error.NoHistory, r.step(&m.cpu));
}

test "over budget the oldest entries go, and the bytes used never exceed it" {
    var m = try Machine.init();
    defer m.deinit();
    var r = Rewind.init(a);
    defer r.deinit();

    // Room for the two buffers and a handful of small deltas.
    const state_len = (try savestate.saveTrusted(&m.cpu, null) + 7) / 8 * 8;
    const budget = 2 * state_len + 4 * 64;
    try r.configure(budget);

    var n: u8 = 0;
    while (n < 40) : (n += 1) try frame(&m, &r, n);
    const info = r.info();
    try std.testing.expect(info.bytes_used <= budget);
    try std.testing.expect(info.entries > 0);
    try std.testing.expect(info.entries < 19);

    // The entries that survived are the NEWEST: stepping back through all of
    // them ends at the capture just before the oldest survivor's.
    var steps: u32 = 0;
    while (r.step(&m.cpu)) |_| steps += 1 else |_| {}
    try std.testing.expectEqual(info.entries, steps);
    try std.testing.expectEqual(@as(u8, 39 - 2 * @as(u8, @intCast(steps))), m.bus.ram[0x10]);
}

test "clear and configure(0) drop the history" {
    var m = try Machine.init();
    defer m.deinit();
    var r = Rewind.init(a);
    defer r.deinit();
    try r.configure(64 << 20);

    var n: u8 = 0;
    while (n < 6) : (n += 1) try frame(&m, &r, n);
    r.clear();
    try std.testing.expectEqual(@as(u32, 0), r.info().entries);
    try std.testing.expectError(error.NoHistory, r.step(&m.cpu));

    while (n < 12) : (n += 1) try frame(&m, &r, n);
    try r.configure(0);
    try std.testing.expect(!r.enabled());
    try std.testing.expectEqual(@as(usize, 0), r.info().bytes_used);
    // Off, frames capture nothing.
    while (n < 16) : (n += 1) try frame(&m, &r, n);
    try std.testing.expectEqual(@as(u32, 0), r.info().entries);
}
