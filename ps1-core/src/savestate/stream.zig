//! The byte stream a savestate is written to and read from.
//!
//! Integers go out at the next whole-byte width of their type, little-endian;
//! `usize` always goes out as u64 so a state does not depend on the pointer
//! width of the build that wrote it. Arrays go out as their in-memory bytes,
//! which is the same little-endian wire format on every host this ships on —
//! the comptime check below makes any other host a compile error rather than
//! a silently byte-swapped state.
//!
//! Every read is checked. A value that does not fit its field (a 32 in a u5,
//! a 2 in a bool, an enum tag no variant carries) is `StateCorrupt`, never an
//! `@intCast` panic: the bytes come from a file on disk.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("savestates assume a little-endian host");
}

pub const Error = error{ StateBadMagic, StateVersion, StateBios, StateDisc, StateCorrupt, NoSpace };

fn WireInt(comptime T: type) type {
    if (T == usize) return u64;
    const info = @typeInfo(T).int;
    const bits = if (info.bits <= 8) 8 else if (info.bits <= 16) 16 else if (info.bits <= 32) 32 else 64;
    return std.meta.Int(info.signedness, bits);
}

pub const Writer = struct {
    /// Null counts without writing; that is how a caller sizes its buffer.
    buf: ?[]u8 = null,
    len: usize = 0,

    pub fn bytes(w: *Writer, b: []const u8) Error!void {
        if (w.buf) |buf| {
            if (b.len > buf.len - w.len) return error.NoSpace;
            @memcpy(buf[w.len..][0..b.len], b);
        }
        w.len += b.len;
    }

    pub fn int(w: *Writer, v: anytype) Error!void {
        const Wire = WireInt(@TypeOf(v));
        var tmp: [@sizeOf(Wire)]u8 = undefined;
        std.mem.writeInt(Wire, &tmp, v, .little);
        try w.bytes(&tmp);
    }

    pub fn flag(w: *Writer, v: bool) Error!void {
        try w.int(@as(u8, @intFromBool(v)));
    }

    pub fn tag(w: *Writer, v: anytype) Error!void {
        try w.int(@as(u32, @intFromEnum(v)));
    }

    /// `a` is a pointer to an array (of any element type, nested arrays included).
    pub fn array(w: *Writer, a: anytype) Error!void {
        try w.bytes(std.mem.sliceAsBytes(a[0..]));
    }

    /// Rewrites a u32 already written at `at` — the section and header
    /// lengths are only known after their contents.
    pub fn patchU32(w: *Writer, at: usize, v: u32) void {
        const buf = w.buf orelse return;
        std.mem.writeInt(u32, buf[at..][0..4], v, .little);
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.buf.len - r.pos) return error.StateCorrupt;
        defer r.pos += n;
        return r.buf[r.pos..][0..n];
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const Wire = WireInt(T);
        const raw = std.mem.readInt(Wire, (try r.bytes(@sizeOf(Wire)))[0..@sizeOf(Wire)], .little);
        return std.math.cast(T, raw) orelse error.StateCorrupt;
    }

    pub fn flag(r: *Reader) Error!bool {
        return switch (try r.int(u8)) {
            0 => false,
            1 => true,
            else => error.StateCorrupt,
        };
    }

    pub fn tag(r: *Reader, comptime E: type) Error!E {
        const v = try r.int(u32);
        inline for (@typeInfo(E).@"enum".fields) |f| {
            if (v == f.value) return @enumFromInt(f.value);
        }
        return error.StateCorrupt;
    }

    pub fn array(r: *Reader, a: anytype) Error!void {
        const dst = std.mem.sliceAsBytes(a[0..]);
        @memcpy(dst, try r.bytes(dst.len));
    }

    /// A section must be consumed exactly: a reader that stops short of the
    /// writer's length is reading a different layout than was written.
    pub fn end(r: *const Reader) Error!void {
        if (r.pos != r.buf.len) return error.StateCorrupt;
    }
};
