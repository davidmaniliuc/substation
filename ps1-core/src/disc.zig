const std = @import("std");

pub const MSF = struct {
    m: u8,
    s: u8,
    f: u8,

    pub fn toLba(self: MSF) i32 {
        const m = @as(i32, self.m);
        const s = @as(i32, self.s);
        const f = @as(i32, self.f);
        return (m * 60 + s) * 75 + f - 150;
    }

    pub fn fromLba(lba: i32) MSF {
        const total_f = lba + 150;
        const m = @divFloor(total_f, 60 * 75);
        const s = @divFloor(@mod(total_f, 60 * 75), 75);
        const f = @mod(total_f, 75);
        return .{
            .m = @intCast(m),
            .s = @intCast(s),
            .f = @intCast(f),
        };
    }
};

pub const Disc = struct {
    data: []const u8,

    pub fn init(data: []const u8) Disc {
        return .{ .data = data };
    }

    pub fn readSectorRaw(self: Disc, lba: i32, buffer: []u8, size: usize) bool {
        if (lba < 0) return false;

        const sector_size = 2352;
        const offset = @as(usize, @intCast(lba)) * sector_size;

        if (offset + sector_size > self.data.len) {
            return false;
        }

        const actual_size = @min(size, buffer.len);

        // Standard PS1 raw sector (2352 bytes):
        // 00h-0Bh: Sync (12 bytes)
        // 0Ch-0Fh: Header (4 bytes: M, S, F, Mode)
        // 10h-17h: Sub-header (8 bytes)
        // 18h-817h: Data (2048 bytes) - Mode 2 Form 1
        // 818h-92Fh: ECC/EDC (280 bytes)

        // For Mode 2 Form 2 (2340 bytes):
        // 10h-17h: Sub-header (8 bytes)
        // 18h-93Bh: Data (2328 bytes) + EDC (4 bytes) = 2332 bytes?
        // Wait, Mode 2 Form 2 is usually 2324 or 2336 bytes of data.
        // Let's just allow reading up to the requested size from the start of the data area.

        // If size is 2048, we start at 0x18 (after sub-header).
        // If size is 2340, we start at 0x10 (including sub-header).
        const data_start: usize = if (size == 2048) 24 else 16;
        const data_offset = offset + data_start;

        @memcpy(buffer[0..actual_size], self.data[data_offset .. data_offset + actual_size]);

        return true;
    }

    pub fn readSector(self: Disc, lba: i32, buffer: *[2048]u8) bool {
        return self.readSectorRaw(lba, buffer[0..], 2048);
    }
};
