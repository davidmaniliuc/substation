//! CD positions: minute/second/frame in BCD, and the LBA they name.
const constants = @import("constants.zig");

pub const MSF = struct {
    m: u8,
    s: u8,
    f: u8,

    pub fn toLba(self: MSF) i32 {
        const m = @as(i32, bcdToBinary(self.m));
        const s = @as(i32, bcdToBinary(self.s));
        const f = @as(i32, bcdToBinary(self.f));
        return (m * 60 + s) * 75 + f - constants.lead_in_frames;
    }

    pub fn fromLba(lba: i32) MSF {
        const total_f = lba + constants.lead_in_frames;
        const m = @divFloor(total_f, 60 * 75);
        const s = @divFloor(@mod(total_f, 60 * 75), 75);
        const f = @mod(total_f, 75);
        return .{
            .m = binaryToBcd(@intCast(m)),
            .s = binaryToBcd(@intCast(s)),
            .f = binaryToBcd(@intCast(f)),
        };
    }

    pub fn fromFrames(frames: i32) MSF {
        const clamped = @max(frames, 0);
        const m = @divFloor(clamped, 60 * 75);
        const s = @divFloor(@mod(clamped, 60 * 75), 75);
        const f = @mod(clamped, 75);
        return .{
            .m = binaryToBcd(@intCast(m)),
            .s = binaryToBcd(@intCast(s)),
            .f = binaryToBcd(@intCast(f)),
        };
    }
};

pub fn bcdToBinary(value: u8) u8 {
    return ((value >> 4) * 10) + (value & 0x0F);
}

pub fn binaryToBcd(value: u8) u8 {
    return ((value / 10) << 4) | (value % 10);
}
