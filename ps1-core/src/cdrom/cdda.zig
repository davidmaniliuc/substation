const std = @import("std");
const CdRom = @import("cdrom.zig").CdRom;

/// The `.Playing` branch of `readNextSector`: CD-DA (Red Book) playback. Reads
/// `mode`/`last_subchannel_q`/`disc`/`muted` and emits through `queueIrq` and
/// `pushXaSample`. The one piece of drive state it owns is the mode bit1
/// autopause edge: it advances `previous_track` and, on a boundary crossing,
/// stops the drive.
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
    const track = if (cdrom.disc) |d| d.trackForLba(lba) else null;
    const is_audio_track = if (track) |t| t.type == .audio else false;
    if (is_audio_track and !cdrom.drive.muted and (cdrom.drive.mode & 0x01) != 0) {
        var i: usize = 0;
        while (i + 4 <= raw_sector.len) : (i += 4) {
            const l = std.mem.readInt(i16, raw_sector[i..][0..2], .little);
            const r = std.mem.readInt(i16, raw_sector[i + 2 ..][0..2], .little);
            cdrom.pushXaSample(l, r);
        }
    }

    // Autopause (mode bit1): playback that runs off the end of the track it was
    // started on stops there and reports INT4. Games use it to time a jingle --
    // Rayman plays its Ubi Soft logo track with mode 0x07 and spins on a flag
    // its CD callback only sets from this interrupt, so without it the drive
    // runs on into the next track and the logo never leaves the screen.
    if (track) |t| {
        if ((cdrom.drive.mode & 0x02) != 0 and t.number > cdrom.drive.previous_track) {
            cdrom.drive.drive_state = .Idle;
            cdrom.queueIrq(4, 0, &[_]u8{cdrom.getDriveStatus()});
        }
        cdrom.drive.previous_track = t.number;
    }
}
