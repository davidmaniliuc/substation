const std = @import("std");
const CdRom = @import("cdrom.zig").CdRom;

/// The `.Playing` branch of `readNextSector`: CD-DA (Red Book) playback. Owns
/// no state of its own — it is a pure function over `(*CdRom, lba, raw_sector)`
/// that reads `mode`/`last_subchannel_q`/`disc`/`muted` and writes only
/// through `queueIrq` and `pushXaSample`.
pub fn handleSector(cdrom: *CdRom, lba: i32, raw_sector: *const [2352]u8) void {
    // CD-DA Playback.
    //
    // Report is mode bit2, NOT bit4 -- bit4 is
    // the "ignore" bit. Hardware reports on a fixed frame cadence
    // rather than once per sector: absolute position every 0x20
    // frames, track-relative position offset 0x10 into that window.
    if ((cdrom.drive.mode & 0x04) != 0) {
        const ff: i32 = @mod(lba + 150, 75);
        const is_absolute = @mod(ff, 0x20) == 0;
        const is_relative = @mod(ff - 0x10, 0x20) == 0;
        if (is_absolute or is_relative) {
            const q = &cdrom.drive.last_subchannel_q;
            var resp = [_]u8{ cdrom.getDriveStatus(), q[0], q[1], 0, 0, 0, 0, 0 };
            if (is_absolute) {
                resp[3] = q[5];
                resp[4] = q[6];
                resp[5] = q[7];
            } else {
                resp[3] = q[2];
                resp[4] = q[3] | 0x80;
                resp[5] = q[4];
            }
            cdrom.queueIrq(1, 0, &resp);
        }
    }

    // Decode Red Book Audio (16bit Stereo 44100Hz) into the same FIFO
    // the SPU drains for XA. Without this the drive faithfully spins
    // over the track while emitting nothing, so every CD-DA
    // soundtrack -- Tomb Raider's entire in-game score -- is silent.
    const is_audio_track = if (cdrom.disc) |d| d.trackForLba(lba).type == .audio else false;
    if (is_audio_track and !cdrom.drive.muted and (cdrom.drive.mode & 0x01) != 0) {
        var i: usize = 0;
        while (i + 4 <= raw_sector.len) : (i += 4) {
            const l = std.mem.readInt(i16, raw_sector[i..][0..2], .little);
            const r = std.mem.readInt(i16, raw_sector[i + 2 ..][0..2], .little);
            cdrom.pushXaSample(l, r);
        }
    }
}
