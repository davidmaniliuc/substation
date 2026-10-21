//! Single-producer / single-consumer float ring.
//!
//! The producer is the emulator thread and the consumer is the CoreAudio
//! render callback, which may never block and may never allocate, so this
//! holds one buffer allocated up front and two atomics, and no lock.
//!
//! The two indices grow monotonically and are masked on use, so `filled` is
//! a plain subtraction and a full ring is told from an empty one without
//! wasting a slot.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const AudioRing = struct {
    alloc: Allocator,
    capacity: usize,
    buffer: []f32,
    mask: usize,
    write_index: std.atomic.Value(usize) = .init(0),
    read_index: std.atomic.Value(usize) = .init(0),

    /// `capacity` is rounded up to a power of two so the index masking is a
    /// bitwise AND rather than a modulo in the audio callback.
    pub fn init(alloc: Allocator, capacity: usize) !AudioRing {
        const rounded = std.math.ceilPowerOfTwoAssert(usize, @max(2, capacity));
        const buffer = try alloc.alloc(f32, rounded);
        @memset(buffer, 0);
        return .{ .alloc = alloc, .capacity = rounded, .buffer = buffer, .mask = rounded - 1 };
    }

    pub fn deinit(self: *AudioRing) void {
        self.alloc.free(self.buffer);
    }

    pub fn filled(self: *const AudioRing) usize {
        return self.write_index.load(.acquire) -% self.read_index.load(.acquire);
    }

    pub fn freeSpace(self: *const AudioRing) usize {
        return self.capacity - self.filled();
    }

    /// Producer side. Writes as much as fits and returns how much that was;
    /// it never overwrites unread samples.
    pub fn write(self: *AudioRing, src: []const f32) usize {
        const w = self.write_index.load(.monotonic);
        const r = self.read_index.load(.acquire);
        const n = @min(src.len, self.capacity - (w -% r));
        if (n == 0) return 0;
        for (src[0..n], 0..) |v, i| self.buffer[(w +% i) & self.mask] = v;
        self.write_index.store(w +% n, .release);
        return n;
    }

    /// Consumer side. Returns how many samples were actually available; on
    /// underrun that is fewer than asked for, and the caller writes silence.
    pub fn read(self: *AudioRing, dst: []f32) usize {
        const r = self.read_index.load(.monotonic);
        const w = self.write_index.load(.acquire);
        const n = @min(dst.len, w -% r);
        if (n == 0) return 0;
        for (dst[0..n], 0..) |*d, i| d.* = self.buffer[(r +% i) & self.mask];
        self.read_index.store(r +% n, .release);
        return n;
    }
};
