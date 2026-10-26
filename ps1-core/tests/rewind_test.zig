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
    const buf = try a.dupe(u8, older);
    defer a.free(buf);
    try rewind.encode(newer, buf, &delta, a);
    try std.testing.expectEqualSlices(u8, newer, buf);
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
    var older = zeros;
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);
    try rewind.encode(&zeros, &older, &delta, a);
    try std.testing.expectEqual(@as(usize, 0), delta.items.len);
}

/// The runs `encode` must produce, found one word at a time.
fn referenceEncode(newer: []const u8, older: []const u8, out: *std.ArrayList(u8)) !void {
    const n: u32 = @intCast(newer.len / rewind.word);
    var i: u32 = 0;
    while (i < n) {
        if (std.mem.eql(u8, wordBytes(newer, i), wordBytes(older, i))) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < n and !std.mem.eql(u8, wordBytes(newer, i), wordBytes(older, i))) i += 1;
        const count = i - start;
        try out.appendSlice(a, std.mem.asBytes(&start));
        try out.appendSlice(a, std.mem.asBytes(&count));
        try out.appendSlice(a, older[start * rewind.word ..][0 .. count * rewind.word]);
    }
}

fn wordBytes(buf: []const u8, i: u32) []const u8 {
    return buf[i * rewind.word ..][0..rewind.word];
}

test "the delta is the maximal runs of changed words, whatever the lane and piece boundaries" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);

    // Word counts on and off a multiple of the lane width, and changes from
    // one byte to runs that cross several lanes.
    for ([_]usize{ 1, 7, 8, 9, 15, 16, 17, 63, 64, 65, 257 }) |words| {
        for (0..40) |_| {
            const older = try a.alloc(u8, words * rewind.word);
            defer a.free(older);
            const newer = try a.alloc(u8, older.len);
            defer a.free(newer);
            rand.bytes(older);
            @memcpy(newer, older);
            for (0..rand.uintAtMost(usize, 6)) |_| {
                const at = rand.uintLessThan(usize, newer.len);
                const len = @min(newer.len - at, rand.uintAtMost(usize, 3 * 8 * rewind.word));
                for (newer[at..][0..len]) |*b| b.* +%= 1 + rand.uintLessThan(u8, 255);
            }
            expected.clearRetainingCapacity();
            delta.clearRetainingCapacity();
            try referenceEncode(newer, older, &expected);
            const buf = try a.dupe(u8, older);
            defer a.free(buf);
            try rewind.encode(newer, buf, &delta, a);
            try std.testing.expectEqualSlices(u8, expected.items, delta.items);
            try roundTrip(newer, older);

            // As a save writes it: pieces of any length, across words.
            @memcpy(buf, older);
            delta.clearRetainingCapacity();
            var diff = rewind.Diff{ .head = buf, .out = &delta, .allocator = a };
            var pos: usize = 0;
            while (pos < newer.len) {
                const len = @min(newer.len - pos, 1 + rand.uintLessThan(usize, 3 * 8 * rewind.word));
                try diff.write(pos, newer[pos..][0..len]);
                pos += len;
            }
            try diff.finish(newer.len);
            try std.testing.expectEqualSlices(u8, expected.items, delta.items);
            try std.testing.expectEqualSlices(u8, newer, buf);
        }
    }
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
        const n = try savestate.saveTrusted(&m.cpu, null, .write);
        const buf = try a.alloc(u8, n);
        _ = try savestate.saveTrusted(&m.cpu, buf, .write);
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

test "the frames a step's picture takes capture nothing, so every step goes further back" {
    var m = try Machine.init();
    defer m.deinit();
    var r = Rewind.init(a);
    defer r.deinit();
    try r.configure(64 << 20);

    var n: u8 = 1;
    while (n <= 8) : (n += 1) try frame(&m, &r, n); // captures at 2, 4, 6, 8
    try std.testing.expectEqual(@as(u32, 3), r.info().entries);

    try r.step(&m.cpu); // back to 6
    var k: u8 = 0;
    while (k < rewind.picture_frames) : (k += 1) try frame(&m, &r, 100 + k);
    try std.testing.expectEqual(@as(u32, 2), r.info().entries);
    try r.step(&m.cpu); // back to 4, not to a capture the picture took
    try std.testing.expectEqual(@as(u8, 4), m.bus.ram[0x10]);

    // Let go: the next capture waits out the picture, then the cadence
    // resumes, and the entry counts every frame it covers.
    k = 0;
    while (k < rewind.picture_frames) : (k += 1) try frame(&m, &r, 110 + k);
    try std.testing.expectEqual(@as(u32, 1), r.info().entries);
    try frame(&m, &r, 120);
    try std.testing.expectEqual(@as(u32, 2), r.info().entries);
    try std.testing.expectEqual(@as(u32, 2 + rewind.picture_frames + 1), r.info().frames_covered);
}

test "over budget the oldest entries go, and the bytes used never exceed it" {
    var m = try Machine.init();
    defer m.deinit();
    var r = Rewind.init(a);
    defer r.deinit();

    // Room for `head` and a handful of small deltas.
    const state_len = (try savestate.saveTrusted(&m.cpu, null, .write) + 7) / 8 * 8;
    const budget = state_len + 4 * 64;
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

test "Diff: keepRecordsNothingAndLeavesTheBytes" {
    var prng = std.Random.DefaultPrng.init(0x6b656570);
    const rand = prng.random();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);

    const len = 64 * rewind.word;
    var older: [len]u8 = undefined;
    var newer: [len]u8 = undefined;
    var head: [len]u8 = undefined;
    // The fixed case first, then keeps starting and ending anywhere in a word.
    var trial: usize = 0;
    while (trial < 400) : (trial += 1) {
        rand.bytes(&older);
        const keep_at: usize = if (trial == 0) 5 else rand.uintLessThan(usize, len);
        const keep_len: usize = if (trial == 0) 19 else rand.uintAtMost(usize, len - keep_at);
        if (trial < 2) {
            // Only the bytes after the kept range differ.
            @memcpy(&newer, &older);
            for (newer[keep_at + keep_len ..]) |*b| b.* +%= 1;
        } else {
            rand.bytes(&newer);
            // Equal stretches too, so runs open and close around the keep.
            for (0..rand.uintAtMost(usize, 4)) |_| {
                const at = rand.uintLessThan(usize, len);
                const n = @min(len - at, rand.uintAtMost(usize, 16 * rewind.word));
                @memcpy(newer[at..][0..n], older[at..][0..n]);
            }
        }
        // What the head ends up holding: the newer bytes, the older ones kept.
        var want = newer;
        @memcpy(want[keep_at..][0..keep_len], older[keep_at..][0..keep_len]);

        head = older;
        delta.clearRetainingCapacity();
        var diff = rewind.Diff{ .head = &head, .out = &delta, .allocator = a };
        try writePieces(&diff, rand, &newer, 0, keep_at);
        try diff.keep(keep_at, keep_len);
        try writePieces(&diff, rand, &newer, keep_at + keep_len, len);
        try diff.finish(len);
        try std.testing.expectEqualSlices(u8, &want, &head);

        expected.clearRetainingCapacity();
        try referenceEncode(&want, &older, &expected);
        try std.testing.expectEqualSlices(u8, expected.items, delta.items);
        rewind.apply(delta.items, &head);
        try std.testing.expectEqualSlices(u8, &older, &head);
    }
}

fn writePieces(diff: *rewind.Diff, rand: std.Random, src: []const u8, from: usize, to: usize) !void {
    var pos = from;
    while (pos < to) {
        const n = @min(to - pos, 1 + rand.uintLessThan(usize, 3 * rewind.word));
        try diff.write(pos, src[pos..][0..n]);
        pos += n;
    }
}

const native_pixels = ps1.constants.vram_width * ps1.constants.vram_height;
const Pixels = [native_pixels]u16;

/// A machine whose VRAM lives elsewhere, as under GPU-only: `vram` is the
/// truth the host would gather, and the machine's own `vram.data` is a
/// landing area holding garbage.
const Deferred = struct {
    m: Machine,
    r: Rewind,
    vram: *Pixels,
    /// The VRAM each capture still waiting for its bytes was taken with,
    /// oldest first.
    waiting: std.ArrayList(*Pixels) = .empty,

    fn init(defer_vram: bool) !Deferred {
        var d = Deferred{ .m = try Machine.init(), .r = Rewind.init(a), .vram = try a.create(Pixels) };
        d.vram.* = @splat(0);
        d.r.defer_vram = defer_vram;
        try d.r.configure(64 << 20);
        return d;
    }

    fn deinit(d: *Deferred) void {
        for (d.waiting.items) |p| a.destroy(p);
        d.waiting.deinit(a);
        a.destroy(d.vram);
        d.r.deinit();
        d.m.deinit();
    }

    /// One frame, painting VRAM pixels that name it.
    fn frame(d: *Deferred, n: u8) !void {
        d.vram[0] = n;
        d.vram[1000 + 3 * @as(usize, n)] = 0x8000 | @as(u16, n);
        d.vram[native_pixels - 1] = @as(u16, n) *% 7;
        if (d.r.defer_vram) {
            @memset(&d.m.bus.gpu.vram.data, 0xdead +% @as(u16, n));
        } else {
            d.m.bus.gpu.vram.data = d.vram.*;
        }
        const before = d.r.pendingVram();
        d.m.bus.ram[0x1000 + @as(usize, n)] = n;
        d.m.bus.ram[0x10] = n;
        try d.r.frameDone(&d.m.cpu);
        const after = d.r.pendingVram();
        const captured = if (after) |p| before == null or p.last != before.?.last else false;
        if (captured) {
            const copy = try a.create(Pixels);
            copy.* = d.vram.*;
            try d.waiting.append(a, copy);
        }
    }

    /// Hands the oldest waiting capture its VRAM.
    fn fillOldest(d: *Deferred) !void {
        const p = d.r.pendingVram().?;
        const pixels = d.waiting.orderedRemove(0);
        defer a.destroy(pixels);
        try std.testing.expect(try d.r.fillVram(p.first, pixels));
    }

    /// The machine as it is, with the true VRAM in place of the landing area.
    fn truth(d: *Deferred) ![]u8 {
        const landing = try a.create(Pixels);
        defer a.destroy(landing);
        landing.* = d.m.bus.gpu.vram.data;
        d.m.bus.gpu.vram.data = d.vram.*;
        defer d.m.bus.gpu.vram.data = landing.*;
        return d.m.snapshot();
    }
};

test "Rewind: aDeferredCaptureFilledLaterStepsBackToTheSameMachine" {
    var want = try Deferred.init(false);
    defer want.deinit();
    var got = try Deferred.init(true);
    defer got.deinit();

    var n: u8 = 1;
    while (n <= 24) : (n += 1) {
        try want.frame(n);
        const pending_before = got.waiting.items.len;
        try got.frame(n);
        if (got.waiting.items.len > pending_before) try std.testing.expect(got.r.pendingVram() != null);
        // Filled at once on some frames, up to two frames late on others.
        const late: usize = if (n % 6 < 3) 0 else 2;
        while (got.waiting.items.len > late) try got.fillOldest();
    }
    while (got.waiting.items.len > 0) try got.fillOldest();
    try std.testing.expectEqual(@as(?Rewind.PendingVram, null), got.r.pendingVram());
    try std.testing.expectEqual(want.r.info().entries, got.r.info().entries);

    var steps: u32 = 0;
    while (true) : (steps += 1) {
        const w = want.r.step(&want.m.cpu);
        const g = got.r.step(&got.m.cpu);
        if (w) |_| {} else |err| {
            try std.testing.expectError(err, g);
            break;
        }
        try g;
        const ws = try want.m.snapshot();
        defer a.free(ws);
        const gs = try got.m.snapshot();
        defer a.free(gs);
        try std.testing.expectEqualSlices(u8, ws, gs);
    }
    try std.testing.expectEqual(@as(u32, 11), steps);
}

/// Four captures, C1..C4 at frames 2, 4, 6 and 8, with the truth at each.
fn fourCaptures(d: *Deferred, truths: *[4][]u8) !void {
    var n: u8 = 1;
    while (n <= 8) : (n += 1) {
        try d.frame(n);
        if (n % 2 == 0) truths[n / 2 - 1] = try d.truth();
    }
    try std.testing.expectEqual(@as(usize, 4), d.waiting.items.len);
}

fn freeTruths(truths: *[4][]u8) void {
    for (truths) |t| a.free(t);
}

test "Rewind: aStepWithPendingCapturesLandsOnTheNewestCompleteOne" {
    var d = try Deferred.init(true);
    defer d.deinit();
    var truths: [4][]u8 = undefined;
    try fourCaptures(&d, &truths);
    defer freeTruths(&truths);
    try d.fillOldest(); // C1
    try d.fillOldest(); // C2

    try d.r.step(&d.m.cpu);
    try std.testing.expectEqual(@as(?Rewind.PendingVram, null), d.r.pendingVram());
    const at_c2 = try d.m.snapshot();
    defer a.free(at_c2);
    try std.testing.expectEqualSlices(u8, truths[1], at_c2);

    try d.r.step(&d.m.cpu);
    const at_c1 = try d.m.snapshot();
    defer a.free(at_c1);
    try std.testing.expectEqualSlices(u8, truths[0], at_c1);
    try std.testing.expectError(error.NoHistory, d.r.step(&d.m.cpu));
}

test "Rewind: dropVramFromDropsThatCaptureAndEveryNewerOne" {
    var d = try Deferred.init(true);
    defer d.deinit();
    var truths: [4][]u8 = undefined;
    try fourCaptures(&d, &truths);
    defer freeTruths(&truths);
    try d.fillOldest(); // C1
    const c2 = d.r.pendingVram().?.first;
    try std.testing.expectEqual(c2 + 2, d.r.pendingVram().?.last);

    d.r.dropVramFrom(c2 + 1);
    try std.testing.expectEqual(Rewind.PendingVram{ .first = c2, .last = c2 }, d.r.pendingVram().?);
    for (d.waiting.items[1..]) |p| a.destroy(p);
    d.waiting.shrinkRetainingCapacity(1);

    // The next capture's entry covers the dropped captures' frames.
    try d.frame(9);
    try std.testing.expectEqual(@as(u32, 9 - 2), d.r.info().frames_covered);
    d.r.dropVramFrom(d.r.pendingVram().?.last);
    a.destroy(d.waiting.pop().?);

    try d.fillOldest(); // C2
    try std.testing.expectEqual(@as(?Rewind.PendingVram, null), d.r.pendingVram());
    try d.r.step(&d.m.cpu);
    const at_c1 = try d.m.snapshot();
    defer a.free(at_c1);
    try std.testing.expectEqualSlices(u8, truths[0], at_c1);
}

test "Rewind: aFillForAnyButTheOldestPendingIsRefused" {
    var d = try Deferred.init(true);
    defer d.deinit();
    var n: u8 = 1;
    while (n <= 4) : (n += 1) try d.frame(n);
    const p = d.r.pendingVram().?;
    try std.testing.expectEqual(p.first + 1, p.last);

    const head = try a.dupe(u8, d.r.head);
    defer a.free(head);
    const info = d.r.info();
    try std.testing.expect(!try d.r.fillVram(p.last, d.waiting.items[1]));
    try std.testing.expect(!try d.r.fillVram(p.last + 1, d.waiting.items[1]));
    try std.testing.expectEqual(p, d.r.pendingVram().?);
    try std.testing.expectEqual(info, d.r.info());
    try std.testing.expectEqualSlices(u8, head, d.r.head);
}

test "Rewind: aStepWithOnlyAPendingFirstCaptureIsNoHistory" {
    var d = try Deferred.init(true);
    defer d.deinit();
    try d.frame(1);
    try d.frame(2);
    try std.testing.expect(d.r.pendingVram() != null);

    const before = try d.m.snapshot();
    defer a.free(before);
    try std.testing.expectError(error.NoHistory, d.r.step(&d.m.cpu));
    const after = try d.m.snapshot();
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(@as(?Rewind.PendingVram, null), d.r.pendingVram());
}

test "Rewind: clearForgetsPendingCaptures" {
    var d = try Deferred.init(true);
    defer d.deinit();
    var n: u8 = 1;
    while (n <= 6) : (n += 1) try d.frame(n);
    try d.fillOldest();
    try std.testing.expect(d.r.pendingVram() != null);
    d.r.clear();
    try std.testing.expectEqual(@as(?Rewind.PendingVram, null), d.r.pendingVram());
    try std.testing.expectError(error.NoHistory, d.r.step(&d.m.cpu));
}
