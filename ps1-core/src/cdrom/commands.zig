const std = @import("std");
const disc = @import("../disc.zig");
const CdRom = @import("cdrom.zig").CdRom;

pub fn executeCommand(cdrom: *CdRom, cmd: u8) void {
    if (cdrom.debug_enable) {
        std.log.warn("CDROM cmd=0x{x:0>2} irq_enable=0x{x} queue_count={} drive_state={s}", .{ cmd, cdrom.irq_enable, cdrom.irq_queue.count, @tagName(cdrom.drive_state) });
    }
    cdrom.irq_queue.clear();
    cdrom.busy_for = 0; // Avocado used 1000, but it blocks CdStatus
    processCommand(cdrom, cmd);
    cdrom.parameter_len = 0;
}

/// Avocado's `postInterrupt(irq, delay = 50000)` default (cdrom.h:178). Most
/// commands acknowledge at this rate; the handful that differ are spelled out
/// at their call sites below, matching `commands.cpp` one for one.
///
/// This is not cosmetic. Crash Bandicoot's streaming loader polls the IRQ
/// flag register (0x1F801803) to decide what to load next; acknowledging 50x
/// too fast made it take a different branch, load a file into a differently
/// sized buffer, and eventually run its LZ decompressor off the end of RAM.
const ack_delay: i64 = 50000;

pub fn processCommand(cdrom: *CdRom, cmd: u8) void {
    switch (cmd) {
        0x01 => { // Getstat
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x02 => { // Setloc
            if (cdrom.parameter_len >= 3) {
                cdrom.seek_target.m = cdrom.parameter_fifo[0];
                cdrom.seek_target.s = cdrom.parameter_fifo[1];
                cdrom.seek_target.f = cdrom.parameter_fifo[2];
            }
            cdrom.queueIrq(3, 5000, &[_]u8{cdrom.getDriveStatus()}); // Avocado cmdSetloc
        },
        0x03 => { // Play
            cdrom.read_after_seek = false;
            // Play(track) seeks to that track's INDEX 01; a parameterless
            // Play resumes from the pending Setloc position (Avocado
            // cmdPlay, commands.cpp:34-76). Dropping the parameter leaves
            // the drive wherever it happened to be -- in practice inside
            // the previous track's pregap, which is digital silence.
            if (cdrom.parameter_len >= 1 and cdrom.parameter_fifo[0] != 0) {
                if (cdrom.disc) |d| {
                    if (d.trackStart(cdrom.parameter_fifo[0])) |msf| {
                        cdrom.seek_target = msf;
                    }
                }
            }
            cdrom.drive_state = .Playing;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x06, 0x1B => { // ReadN, ReadS
            // Drive mode is set synchronously and persists across the
            // irq_queue.clear() that every command (e.g. the GetStat poll
            // loop) performs. The Seeking->Reading transition is driven by
            // `seek_timer` in step(), not by a queued action — Avocado reads
            // plain `readSector = seekSector` with drive mode in `stat`.
            //
            // NOTE: the 1,000,000-cycle seek below is NOT Avocado's behaviour
            // (cmdReadN sets Reading immediately and lets a free-running
            // counter deliver sectors), but it is load-bearing: porting
            // Avocado faithfully here makes Crash Bandicoot die at the same
            // point every BIOS already fails at with SCPH-101 (the loader
            // overruns its decompression buffer into the kernel vectors).
            // The real defect is elsewhere in the read pipeline; don't
            // "correct" this line in isolation.
            cdrom.drive_state = .Seeking;
            cdrom.read_after_seek = true;
            cdrom.seek_timer = 1000000;
            // Avocado: cmdReadN uses 1000, cmdReadS 500.
            cdrom.queueIrq(3, if (cmd == 0x06) 1000 else 500, &[_]u8{cdrom.getDriveStatus()});
        },
        0x07 => { // MotorOn
            cdrom.status |= 0x02;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x08 => { // Stop
            cdrom.status &= ~@as(u8, 0x02);
            cdrom.read_after_seek = false;
            cdrom.drive_state = .Idle;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x09 => { // Pause
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.read_after_seek = false;
            cdrom.drive_state = .Idle;
            cdrom.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .SetIdle, true);
        },
        0x0A, 0x80 => { // Init (Avocado: cmdInit)
            // INT3 first response with stat (delay 0x13CE = 5070 cycles)
            cdrom.queueIrq(3, 0x13CE, &[_]u8{cdrom.getDriveStatus()});
            cdrom.mode = 0;
            cdrom.status = 0x02;
            cdrom.loc_l_valid = false;
            cdrom.muted = false;
            cdrom.xa_filter_file = 0;
            cdrom.xa_filter_channel = 0;
            cdrom.read_after_seek = false;
            cdrom.drive_state = .Idle;

            cdrom.last_subchannel_q[0] = 0x01; // track 1
            cdrom.last_subchannel_q[1] = 0x00; // index 0
            cdrom.last_subchannel_q[2] = 0x00; // rel m
            cdrom.last_subchannel_q[3] = 0x00; // rel s
            cdrom.last_subchannel_q[4] = 0x06; // rel f = 6
            cdrom.last_subchannel_q[5] = 0x00; // abs m
            cdrom.last_subchannel_q[6] = 0x01; // abs s = 1
            cdrom.last_subchannel_q[7] = 0x68; // abs f = 68

            // INT2 second response with stat (default delay)
            cdrom.irq_queue.pushAction(2, 50000, &[_]u8{cdrom.getDriveStatus()}, .SetIdle, false);
        },
        0x0B => { // Mute
            cdrom.muted = true;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0C => { // Demute
            cdrom.muted = false;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0D => { // Setfilter
            if (cdrom.parameter_len >= 2) {
                cdrom.xa_filter_file = cdrom.parameter_fifo[0];
                cdrom.xa_filter_channel = cdrom.parameter_fifo[1];
            }
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0E => { // Setmode
            if (cdrom.parameter_len > 0) {
                cdrom.mode = cdrom.parameter_fifo[0];
            }
            cdrom.queueIrq(3, 2000, &[_]u8{cdrom.getDriveStatus()}); // Avocado cmdSetmode
        },
        0x0F => { // Getparam
            cdrom.queueIrq(3, ack_delay, &[_]u8{
                cdrom.getDriveStatus(),
                cdrom.mode,
                0x00,
                cdrom.xa_filter_file,
                cdrom.xa_filter_channel,
            });
        },
        0x10 => { // GetlocL
            if (!cdrom.loc_l_valid) {
                cdrom.queueIrq(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x01, 0x80 }); // Error
                return;
            }
            var resp = [_]u8{0} ** 8;
            @memcpy(resp[0..8], cdrom.last_sector_header[0..8]);
            cdrom.queueIrq(3, ack_delay, &resp);
        },
        0x11 => { // GetlocP
            var resp = [_]u8{0} ** 8;
            @memcpy(resp[0..8], cdrom.last_subchannel_q[0..8]);
            cdrom.queueIrq(3, 1000, &resp); // Avocado cmdGetlocP
        },
        0x13 => { // GetTN
            const first = if (cdrom.disc) |d| disc.binaryToBcd(d.firstTrack()) else 0x01;
            const last = if (cdrom.disc) |d| disc.binaryToBcd(d.lastTrack()) else 0x01;
            cdrom.queueIrq(3, ack_delay, &[_]u8{ cdrom.getDriveStatus(), first, last });
        },
        0x14 => { // GetTD
            const track_bcd = if (cdrom.parameter_len > 0) cdrom.parameter_fifo[0] else 0;
            const track = disc.bcdToBinary(track_bcd);
            const msf = if (cdrom.disc) |d|
                if (track == 0) d.leadOut() else d.trackStart(track) orelse disc.MSF.fromLba(0)
            else if (track == 0)
                disc.MSF.fromLba(0)
            else
                disc.MSF.fromLba(0);
            const resp = [_]u8{ cdrom.getDriveStatus(), msf.m, msf.s };
            cdrom.queueIrq(3, ack_delay, &resp);
        },
        0x15, 0x16 => { // SeekL, SeekP
            cdrom.read_after_seek = false;
            cdrom.drive_state = .Seeking;
            // Avocado cmdSeekL uses 5000; cmdSeekP uses the default.
            cdrom.queueIrq(3, if (cmd == 0x15) 5000 else ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.current_pos = cdrom.seek_target;

            cdrom.loc_l_valid = true;
            const lba = cdrom.seek_target.toLba();
            if (cdrom.disc) |d| {
                var raw_sector: [2352]u8 = undefined;
                if (d.readSector2352(lba, &raw_sector)) {
                    @memcpy(&cdrom.last_sector_header, raw_sector[0x0C..0x14]);
                    cdrom.updateSubchannelQ();
                }
            } else {
                cdrom.synthesizeHeaderAndQ(cdrom.seek_target);
                cdrom.loc_l_valid = true;
            }

            // Avocado cmdSeekL/cmdSeekP both post the INT2 with a 500000 delay.
            cdrom.irq_queue.pushAction(2, 500000, &[_]u8{0}, .SetIdle, true);
        },
        0x1A => { // GetID
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            if (cdrom.disc) |d| {
                if (d.track_count == 0) {
                    cdrom.irq_queue.pushAction(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
                } else {
                    cdrom.irq_queue.pushAction(2, ack_delay, &[_]u8{ 0x02, 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A' }, .None, false);
                }
            } else {
                cdrom.irq_queue.pushAction(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
            }
        },

        0x1E => { // ReadTOC
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x19 => { // Test
            const sub_cmd = if (cdrom.parameter_len > 0) cdrom.parameter_fifo[0] else 0;
            switch (sub_cmd) {
                0x03 => { // Force motor off
                    cdrom.status &= ~@as(u8, 0x02);
                    cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
                },
                0x04 => { // Read SCEx
                    cdrom.status |= 0x02;
                    cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
                },
                0x05 => { // Get SCEx counters
                    cdrom.queueIrq(3, ack_delay, &[_]u8{ cdrom.getDriveStatus(), 0 });
                },
                0x20 => { // Get version
                    cdrom.queueIrq(3, ack_delay, &[_]u8{ cdrom.getDriveStatus(), 0x94, 0x09, 0x19, 0xC0 });
                },
                0x22 => { // Get region
                    cdrom.queueIrq(3, ack_delay, &[_]u8{ cdrom.getDriveStatus(), 'f', 'o', 'r', ' ', 'U', '/', 'C' });
                },
                else => {
                    cdrom.queueIrq(5, ack_delay, &[_]u8{ 0x11, 0x40 }); // Error
                },
            }
        },
        0x04, 0x05 => { // Forward, Backward
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x12 => { // SetSession
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x50...0x56 => { // Unlock
            cdrom.queueIrq(5, ack_delay, &[_]u8{ 0x11, 0x40 }); // Semi-implemented error
        },
        else => {
            std.log.warn("Unhandled CD-ROM command: 0x{x:0>2}", .{cmd});
            cdrom.queueIrq(5, ack_delay, &[_]u8{ 0x11, 0x40 }); // Error: Invalid Command
        },
    }
}
