//! MSB-first bit reader for the CHD map and the FLAC decoder. Reading past the
//! end yields zero bits and sets `overflow`, which a caller checks once at a
//! boundary instead of after every field.
const std = @import("std");

/// Bits a single `window` guarantees after the byte-offset shift.
const window_bits = 57;

pub const BitReader = struct {
    bytes: []const u8,
    /// Bit position from the start of `bytes`.
    pos: usize = 0,
    overflow: bool = false,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    /// The next 64 bits from `pos`, left-aligned; bytes past the end read as zero.
    fn window(self: *const BitReader) u64 {
        const start = self.pos >> 3;
        var word: u64 = 0;
        for (0..8) |i| {
            const byte: u64 = if (start + i < self.bytes.len) self.bytes[start + i] else 0;
            word = (word << 8) | byte;
        }
        return word << @intCast(self.pos & 7);
    }

    pub fn peek(self: *const BitReader, count: u6) u32 {
        std.debug.assert(count <= 32);
        if (count == 0) return 0;
        return @intCast(self.window() >> @intCast(64 - @as(u7, count)));
    }

    pub fn skip(self: *BitReader, count: usize) void {
        self.pos += count;
        if (self.pos > self.bytes.len * 8) self.overflow = true;
    }

    pub fn read(self: *BitReader, count: u6) u32 {
        const value = self.peek(count);
        self.skip(count);
        return value;
    }

    pub fn readSigned(self: *BitReader, count: u6) i32 {
        if (count == 0) return 0;
        const shift: u5 = @intCast(32 - @as(u6, count));
        const raw: i32 = @bitCast(self.read(count) << shift);
        return raw >> shift;
    }

    /// FLAC's unary code: the number of zero bits before the next one bit,
    /// consuming both.
    pub fn readUnary(self: *BitReader) u32 {
        var zeros: u32 = 0;
        while (true) {
            const word = self.window();
            if (word != 0) {
                const leading: u32 = @clz(word);
                self.skip(leading + 1);
                return zeros + leading;
            }
            zeros += window_bits - 1;
            self.skip(window_bits - 1);
            if (self.overflow) return zeros;
        }
    }

    pub fn alignToByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    pub fn bytePos(self: *const BitReader) usize {
        return self.pos >> 3;
    }
};
