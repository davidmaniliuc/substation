const std = @import("std");

pub const MSF = struct {
    m: u8,
    s: u8,
    f: u8,

    pub fn toLba(self: MSF) i32 {
        const m = @as(i32, bcdToBinary(self.m));
        const s = @as(i32, bcdToBinary(self.s));
        const f = @as(i32, bcdToBinary(self.f));
        return (m * 60 + s) * 75 + f - 150;
    }

    pub fn fromLba(lba: i32) MSF {
        const total_f = lba + 150;
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

pub const Track = struct {
    number: u8,
    start: MSF,
};

pub const SubchannelQ = struct {
    track: u8,
    index: u8,
    rel_m: u8,
    rel_s: u8,
    rel_f: u8,
    abs_m: u8,
    abs_s: u8,
    abs_f: u8,
};

pub const Disc = struct {
    data: []const u8,
    tracks: [99]Track = undefined,
    track_count: u8 = 0,

    pub fn init(data: []const u8) Disc {
        var d = Disc{ .data = data };
        d.tracks[0] = .{
            .number = 1,
            .start = MSF.fromLba(0),
        };
        d.track_count = 1;
        return d;
    }

    pub fn firstTrack(self: Disc) u8 {
        if (self.track_count == 0) return 1;
        return self.tracks[0].number;
    }

    pub fn lastTrack(self: Disc) u8 {
        if (self.track_count == 0) return 1;
        return self.tracks[self.track_count - 1].number;
    }

    pub fn trackStart(self: Disc, track_bcd: u8) ?MSF {
        const track = bcdToBinary(track_bcd);
        for (self.tracks[0..self.track_count]) |entry| {
            if (entry.number == track) return entry.start;
        }
        return null;
    }

    pub fn trackForLba(self: Disc, lba: i32) Track {
        var current = self.tracks[0];
        for (self.tracks[0..self.track_count]) |entry| {
            if (entry.start.toLba() > lba) break;
            current = entry;
        }
        return current;
    }

    pub fn leadOut(self: Disc) MSF {
        const sector_count: i32 = @intCast(self.data.len / 2352);
        return MSF.fromLba(sector_count);
    }

    pub fn getSubchannelQ(self: Disc, lba: i32) SubchannelQ {
        const current_track = self.trackForLba(lba);
        const track_lba = current_track.start.toLba();

        const index: u8 = if (lba < track_lba) 0x00 else 0x01;
        const relative = MSF.fromFrames(lba - track_lba);
        const absolute = MSF.fromLba(lba);

        return .{
            .track = binaryToBcd(current_track.number),
            .index = index,
            .rel_m = relative.m,
            .rel_s = relative.s,
            .rel_f = relative.f,
            .abs_m = absolute.m,
            .abs_s = absolute.s,
            .abs_f = absolute.f,
        };
    }

    pub fn readSectorRaw(self: Disc, lba: i32, buffer: []u8, size: usize) bool {
        var raw: [2352]u8 = undefined;
        if (!self.readSector2352(lba, &raw)) return false;

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

        @memcpy(buffer[0..actual_size], raw[data_start..][0..actual_size]);

        return true;
    }

    pub fn readSector2352(self: Disc, lba: i32, buffer: *[2352]u8) bool {
        if (lba < 0) return false;

        const sector_size = 2352;
        const offset = @as(usize, @intCast(lba)) * sector_size;

        if (offset + sector_size > self.data.len) {
            return false;
        }

        @memcpy(buffer, self.data[offset..][0..sector_size]);
        return true;
    }

    pub fn readSector(self: Disc, lba: i32, buffer: *[2048]u8) bool {
        return self.readSectorRaw(lba, buffer[0..], 2048);
    }
};
