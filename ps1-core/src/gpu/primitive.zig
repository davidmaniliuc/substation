//! Primitive-decode helpers for GP0 polygon/line/rectangle commands. Pure
//! functions on raw command words with no dependency on `Gp0Engine` — the
//! command-buffer glue that calls these stays in `gp0.zig`.

pub const Point = struct {
    x: i16,
    y: i16,
};

pub const Size = struct {
    w: i32,
    h: i32,
};

pub const Texcoord = struct {
    u: u8,
    v: u8,
};

pub const TexturedPoint = struct {
    point: Point,
    texcoord: Texcoord,
};

pub inline fn getCommandLength(opcode: u8) usize {
    return switch (opcode) {
        0x00, 0x01, 0x1F => 1,
        0x02 => 3,
        0x20...0x23 => 4,
        0x24...0x27 => 7,
        0x30...0x33 => 6,
        0x34...0x37 => 9,
        0x28...0x2B => 5,
        0x2C...0x2F => 9,
        0x38...0x3B => 8,
        0x3C...0x3F => 12,
        0x40...0x47 => 3,
        0x50...0x57 => 4,
        0x60...0x63 => 3,
        0x64...0x67 => 4,
        0x70...0x73 => 2,
        0x74...0x77 => 3,
        0x78...0x7B => 2,
        0x7C...0x7F => 3,
        0x80 => 4,
        0xA0, 0xC0 => 3,
        0xE1...0xE6 => 1,
        else => 1,
    };
}

pub inline fn getPoint(value: u32) Point {
    return .{
        .x = getX(value),
        .y = getY(value),
    };
}

pub inline fn getSize(value: u32) Size {
    return .{
        .w = @intCast(value & 0xFFFF),
        .h = @intCast((value >> 16) & 0xFFFF),
    };
}

pub inline fn getTexcoord(value: u32) Texcoord {
    return .{
        .u = @truncate(value),
        .v = @truncate(value >> 8),
    };
}

pub inline fn getTexturedPoint(point_word: u32, texcoord_word: u32) TexturedPoint {
    return .{
        .point = getPoint(point_word),
        .texcoord = getTexcoord(texcoord_word),
    };
}

pub inline fn getClut(value: u32) u16 {
    return @truncate(value >> 16);
}

pub inline fn getTpage(value: u32) u16 {
    return @truncate(value >> 16);
}

pub inline fn isTransparent(opcode: u8) bool {
    return (opcode & 0x02) != 0;
}

pub inline fn getTexturedRectangleSize(opcode: u8, size_word: u32) Size {
    return switch (opcode & 0x18) {
        0x00 => getSize(size_word),
        0x10 => .{ .w = 8, .h = 8 },
        0x18 => .{ .w = 16, .h = 16 },
        else => unreachable,
    };
}

pub inline fn getX(val: u32) i16 {
    const bits = val & 0x7FF;
    const sign_extended = if ((bits & 0x400) != 0) bits | 0xF800 else bits;
    return @as(i16, @bitCast(@as(u16, @truncate(sign_extended))));
}

pub inline fn getY(val: u32) i16 {
    const bits = (val >> 16) & 0x7FF;
    const sign_extended = if ((bits & 0x400) != 0) bits | 0xF800 else bits;
    return @as(i16, @bitCast(@as(u16, @truncate(sign_extended))));
}
