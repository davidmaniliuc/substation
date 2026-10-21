//! The memory-card files and the debounce that decides when they are written.
//! Ported from MemoryCardFlushPolicyTests and MemoryCardStoreTests, plus the
//! three rules the Zig side adds: the directory is made on first write, a
//! failed write is kept and retried, and no temporary file is left behind.

const std = @import("std");
const session = @import("ps1_session");

const cards = session.cards;
const CardStore = cards.CardStore;
const FlushPolicy = cards.FlushPolicy;

const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const s_ns = std.time.ns_per_s;

fn at(seconds: f64) u64 {
    return @intFromFloat(seconds * s_ns);
}

// MemoryCardFlushPolicyTests

test "FlushPolicy: aCleanCardIsNeverWritten" {
    var p: FlushPolicy = .{};
    try expect(!p.shouldWrite(false, at(0)));
    try expect(!p.shouldWrite(false, at(100)));
    try expect(!p.hasPendingWrite());
}

test "FlushPolicy: aDirtyCardIsNotWrittenImmediately" {
    var p: FlushPolicy = .{};
    try expect(!p.shouldWrite(true, at(0)));
    try expect(p.hasPendingWrite());
}

test "FlushPolicy: aDirtyCardIsWrittenOnceItSettles" {
    var p: FlushPolicy = .{};
    _ = p.shouldWrite(true, at(0));
    try expect(!p.shouldWrite(false, at(0.5)));
    try expect(p.shouldWrite(false, at(1.0)));
}

test "FlushPolicy: theSettleWindowRestartsOnEachNewWrite" {
    var p: FlushPolicy = .{};
    _ = p.shouldWrite(true, at(0));
    try expect(!p.shouldWrite(true, at(0.9)));
    try expect(!p.shouldWrite(false, at(1.5)));
    try expect(p.shouldWrite(false, at(1.9)));
}

test "FlushPolicy: aWriteIsNotRepeatedWhileTheCardStaysClean" {
    var p: FlushPolicy = .{};
    _ = p.shouldWrite(true, at(0));
    try expect(p.shouldWrite(false, at(1.0)));
    try expect(!p.shouldWrite(false, at(2.0)));
    try expect(!p.shouldWrite(false, at(60.0)));
    try expect(!p.hasPendingWrite());
}

test "FlushPolicy: aNewWriteAfterAFlushStartsAFreshWindow" {
    var p: FlushPolicy = .{};
    _ = p.shouldWrite(true, at(0));
    try expect(p.shouldWrite(false, at(1.0)));
    try expect(!p.shouldWrite(true, at(5.0)));
    try expect(p.shouldWrite(false, at(6.0)));
}

// MemoryCardStoreTests

/// A fresh temporary directory and a card directory path inside it that does
/// not exist yet.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    buf: [256]u8 = undefined,
    path: []const u8 = "",

    fn init() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn cardDir(self: *Scratch) []const u8 {
        self.path = std.fmt.bufPrint(&self.buf, ".zig-cache/tmp/{s}/cards", .{self.tmp.sub_path}) catch unreachable;
        return self.path;
    }

    fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
    }
};

fn image(fill: u8) [cards.bytes]u8 {
    return @splat(fill);
}

test "CardStore: aCardThatWasNeverWrittenLoadsAsNil" {
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    var out: [cards.bytes]u8 = undefined;
    try expect(!store.load(io, 0, &out));
    try expect(!store.load(io, 1, &out));
}

test "CardStore: aCardReadsBackByteForByte" {
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    try expect(store.write(io, 0, &image(0x5A)));
    var out: [cards.bytes]u8 = undefined;
    try expect(store.load(io, 0, &out));
    try expect(std.mem.eql(u8, &out, &image(0x5A)));
}

test "CardStore: theTwoSlotsAreSeparateFiles" {
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    _ = store.write(io, 0, &image(0x11));
    _ = store.write(io, 1, &image(0x22));
    var out: [cards.bytes]u8 = undefined;
    try expect(store.load(io, 0, &out));
    try expect(std.mem.eql(u8, &out, &image(0x11)));
    try expect(store.load(io, 1, &out));
    try expect(std.mem.eql(u8, &out, &image(0x22)));
}

test "CardStore: aFileOfTheWrongSizeIsRefusedRatherThanPadded" {
    // A short file is far more likely a botched copy than a card worth
    // salvaging, and refusing it presents as "unformatted" (which the BIOS
    // offers to fix), instead of as corrupt save data.
    var s = Scratch.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(io, "cards");
    const short: [4096]u8 = @splat(0xFF);
    try s.tmp.dir.writeFile(io, .{ .sub_path = "cards/card1.mcd", .data = &short });
    const long: [cards.bytes + 1]u8 = @splat(0xFF);
    try s.tmp.dir.writeFile(io, .{ .sub_path = "cards/card2.mcd", .data = &long });
    const store = CardStore.open(s.cardDir());
    var out: [cards.bytes]u8 = undefined;
    try expect(!store.load(io, 0, &out));
    try expect(!store.load(io, 1, &out));
}

test "CardStore: writingRefusesAnImageOfTheWrongSize" {
    // Swift checked the length at run time; here the image is a
    // `*const [bytes]u8`, so a wrong-sized one does not compile.
    const params = @typeInfo(@TypeOf(CardStore.write)).@"fn".param_types;
    try expect(params[3] == *const [cards.bytes]u8);
}

test "CardStore: aSecondWriteReplacesTheFirst" {
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    _ = store.write(io, 0, &image(0x01));
    _ = store.write(io, 0, &image(0x02));
    var out: [cards.bytes]u8 = undefined;
    try expect(store.load(io, 0, &out));
    try expect(std.mem.eql(u8, &out, &image(0x02)));
}

test "CardStore: theFileNamesAreTheOnesOtherEmulatorsRead" {
    // Raw 131072-byte .mcd, one file per slot, so a save can be carried in
    // from or out to other emulators.
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    _ = store.write(io, 1, &image(0x33));
    const st = try s.tmp.dir.statFile(io, "cards/card2.mcd", .{});
    try expectEqual(cards.bytes, st.size);
    try std.testing.expectEqualStrings("card1.mcd", cards.fileName(0));
    try std.testing.expectEqualStrings("card2.mcd", cards.fileName(1));
}

test "CardStore: aMissingDirectoryIsCreatedOnTheFirstWrite" {
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    try std.testing.expectError(error.FileNotFound, s.tmp.dir.statFile(io, "cards", .{}));
    try expect(store.write(io, 0, &image(0x44)));
    const st = try s.tmp.dir.statFile(io, "cards", .{});
    try expectEqual(.directory, st.kind);
}

test "CardStore: aFailedWriteKeepsTheImageForTheNextSettle" {
    var s = Scratch.init();
    defer s.deinit();
    // The card directory's path is a FILE: nothing can be written under it.
    try s.tmp.dir.writeFile(io, .{ .sub_path = "cards", .data = "not a directory" });
    const store = CardStore.open(s.cardDir());
    var pending: cards.Pending = .{};
    pending.images[0] = image(0x66);
    pending.writeAll(&store, io);
    try expect(pending.images[0] != null);

    try s.tmp.dir.deleteFile(io, "cards");
    try s.tmp.dir.createDirPath(io, "cards");
    pending.writeAll(&store, io);
    try expect(pending.images[0] == null);
    var out: [cards.bytes]u8 = undefined;
    try expect(store.load(io, 0, &out));
    try expect(std.mem.eql(u8, &out, &image(0x66)));
}

test "CardStore: aWriteLeavesNoTemporaryFileBehind" {
    var s = Scratch.init();
    defer s.deinit();
    const store = CardStore.open(s.cardDir());
    _ = store.write(io, 0, &image(0x77));
    _ = store.write(io, 1, &image(0x78));
    var dir = try s.tmp.dir.openDir(io, "cards", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var names: usize = 0;
    while (try it.next(io)) |e| {
        try expect(!std.mem.endsWith(u8, e.name, ".tmp"));
        names += 1;
    }
    try expectEqual(2, names);
}
