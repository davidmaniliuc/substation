const std = @import("std");
const builtin = @import("builtin");
const disc = @import("../disc.zig");
const CdRom = @import("cdrom.zig").CdRom;

pub fn executeCommand(cdrom: *CdRom, cmd: u8) void {
    if (cdrom.debug_enable) {
        std.log.warn("CDROM cmd=0x{x:0>2} irq_enable=0x{x} queue_count={} drive_state={s}", .{ cmd, cdrom.regs.irq_enable, cdrom.fifos.irq_queue.count, @tagName(cdrom.drive.drive_state) });
    }
    // TEMPORARY. Deliberately `std.debug.print`, not `std.log.warn`: the log
    // path above is invisible at ReleaseFast (default log level is `.err`) and
    // routing a high-rate line through it wedged a headless run outright.
    // The comptime guard is load-bearing -- `std.debug.print` pulls in the
    // POSIX I/O stack, which does not exist on the wasm32-freestanding target
    // the browser frontend builds for.
    if (comptime builtin.target.os.tag != .freestanding) if (cdrom.trace_commands) {
        const n = @min(cdrom.fifos.parameter_len, cdrom.fifos.parameter_fifo.len);
        std.debug.print("CDROM cmd=0x{x:0>2} q={d} drive={s} pos={x:0>2}:{x:0>2}:{x:0>2} params=", .{
            cmd,                              cdrom.fifos.irq_queue.count, @tagName(cdrom.drive.drive_state),
            cdrom.drive.current_pos.m,        cdrom.drive.current_pos.s,   cdrom.drive.current_pos.f,
        });
        for (cdrom.fifos.parameter_fifo[0..n]) |p| std.debug.print("{x:0>2} ", .{p});
        std.debug.print("\n", .{});
    };
    cdrom.fifos.irq_queue.clear();
    cdrom.regs.busy_for = 0; // a non-zero busy timer blocks CdStatus polls
    processCommand(cdrom, cmd);
    cdrom.fifos.parameter_len = 0;
}

/// The default command acknowledge delay. Most commands acknowledge at this
/// rate; the handful that differ are spelled out at their call sites below.
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
            if (cdrom.fifos.parameter_len >= 3) {
                cdrom.drive.seek_target.m = cdrom.fifos.parameter_fifo[0];
                cdrom.drive.seek_target.s = cdrom.fifos.parameter_fifo[1];
                cdrom.drive.seek_target.f = cdrom.fifos.parameter_fifo[2];
            }
            cdrom.queueIrq(3, 5000, &[_]u8{cdrom.getDriveStatus()});
        },
        0x03 => { // Play
            cdrom.drive.read_after_seek = false;
            // Play(track) seeks to that track's INDEX 01; a parameterless
            // Play resumes from the pending Setloc position. Dropping the
            // parameter leaves the drive wherever it happened to be -- in
            // practice inside the previous track's pregap, which is
            // digital silence.
            if (cdrom.fifos.parameter_len >= 1 and cdrom.fifos.parameter_fifo[0] != 0) {
                if (cdrom.disc) |d| {
                    if (d.trackStart(cdrom.fifos.parameter_fifo[0])) |msf| {
                        cdrom.drive.seek_target = msf;
                    }
                }
            }
            // Latch the track playback starts on, so the mode bit1 autopause
            // check in cdda.zig only fires on a real boundary crossing.
            if (cdrom.disc) |d| {
                cdrom.drive.previous_track = d.trackForLba(cdrom.drive.seek_target.toLba()).number;
            }
            cdrom.drive.drive_state = .Playing;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x06, 0x1B => { // ReadN, ReadS
            // Drive mode is set synchronously and persists across the
            // irq_queue.clear() that every command (e.g. the GetStat poll
            // loop) performs. The Seeking->Reading transition is driven by
            // `seek_timer` in step(), not by a queued action.
            //
            // NOTE: the 1,000,000-cycle seek below is invented, not a real
            // hardware seek time, but it is load-bearing: setting Reading
            // immediately and letting a free-running counter deliver
            // sectors makes Crash Bandicoot die at the same point every
            // BIOS already fails at with SCPH-101 (the loader overruns its
            // decompression buffer into the kernel vectors). The real
            // defect is elsewhere in the read pipeline; don't "correct"
            // this line in isolation.
            cdrom.drive.drive_state = .Seeking;
            cdrom.drive.read_after_seek = true;
            cdrom.drive.seek_timer = 1000000;
            // ReadN acknowledges in 1000 cycles, ReadS in 500.
            cdrom.queueIrq(3, if (cmd == 0x06) 1000 else 500, &[_]u8{cdrom.getDriveStatus()});
        },
        0x07 => { // MotorOn
            cdrom.drive.status |= 0x02;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.fifos.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x08 => { // Stop
            cdrom.drive.status &= ~@as(u8, 0x02);
            cdrom.drive.read_after_seek = false;
            cdrom.drive.drive_state = .Idle;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.fifos.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x09 => { // Pause
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.drive.read_after_seek = false;
            cdrom.drive.drive_state = .Idle;
            cdrom.fifos.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .SetIdle, true);
        },
        0x0A, 0x80 => { // Init
            // INT3 first response with stat (delay 0x13CE = 5070 cycles)
            cdrom.queueIrq(3, 0x13CE, &[_]u8{cdrom.getDriveStatus()});
            cdrom.drive.mode = 0;
            cdrom.drive.status = 0x02;
            cdrom.drive.loc_l_valid = false;
            cdrom.drive.muted = false;
            cdrom.xa.xa_filter_file = 0;
            cdrom.xa.xa_filter_channel = 0;
            cdrom.drive.read_after_seek = false;
            cdrom.drive.drive_state = .Idle;

            cdrom.drive.last_subchannel_q[0] = 0x01; // track 1
            cdrom.drive.last_subchannel_q[1] = 0x00; // index 0
            cdrom.drive.last_subchannel_q[2] = 0x00; // rel m
            cdrom.drive.last_subchannel_q[3] = 0x00; // rel s
            cdrom.drive.last_subchannel_q[4] = 0x06; // rel f = 6
            cdrom.drive.last_subchannel_q[5] = 0x00; // abs m
            cdrom.drive.last_subchannel_q[6] = 0x01; // abs s = 1
            cdrom.drive.last_subchannel_q[7] = 0x68; // abs f = 68

            // INT2 second response with stat (default delay)
            cdrom.fifos.irq_queue.pushAction(2, 50000, &[_]u8{cdrom.getDriveStatus()}, .SetIdle, false);
        },
        0x0B => { // Mute
            cdrom.drive.muted = true;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0C => { // Demute
            cdrom.drive.muted = false;
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0D => { // Setfilter
            if (cdrom.fifos.parameter_len >= 2) {
                cdrom.xa.xa_filter_file = cdrom.fifos.parameter_fifo[0];
                cdrom.xa.xa_filter_channel = cdrom.fifos.parameter_fifo[1];
            }
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0E => { // Setmode
            if (cdrom.fifos.parameter_len > 0) {
                cdrom.drive.mode = cdrom.fifos.parameter_fifo[0];
            }
            cdrom.queueIrq(3, 2000, &[_]u8{cdrom.getDriveStatus()});
        },
        0x0F => { // Getparam
            cdrom.queueIrq(3, ack_delay, &[_]u8{
                cdrom.getDriveStatus(),
                cdrom.drive.mode,
                0x00,
                cdrom.xa.xa_filter_file,
                cdrom.xa.xa_filter_channel,
            });
        },
        0x10 => { // GetlocL
            if (!cdrom.drive.loc_l_valid) {
                cdrom.queueIrq(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x01, 0x80 }); // Error
                return;
            }
            var resp = [_]u8{0} ** 8;
            @memcpy(resp[0..8], cdrom.drive.last_sector_header[0..8]);
            cdrom.queueIrq(3, ack_delay, &resp);
        },
        0x11 => { // GetlocP
            var resp = [_]u8{0} ** 8;
            @memcpy(resp[0..8], cdrom.drive.last_subchannel_q[0..8]);
            cdrom.queueIrq(3, 1000, &resp);
        },
        0x13 => { // GetTN
            const first = if (cdrom.disc) |d| disc.binaryToBcd(d.firstTrack()) else 0x01;
            const last = if (cdrom.disc) |d| disc.binaryToBcd(d.lastTrack()) else 0x01;
            cdrom.queueIrq(3, ack_delay, &[_]u8{ cdrom.getDriveStatus(), first, last });
        },
        0x14 => { // GetTD
            const track_bcd = if (cdrom.fifos.parameter_len > 0) cdrom.fifos.parameter_fifo[0] else 0;
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
            cdrom.drive.read_after_seek = false;
            cdrom.drive.drive_state = .Seeking;
            // SeekL acknowledges in 5000 cycles; SeekP uses the default.
            cdrom.queueIrq(3, if (cmd == 0x15) 5000 else ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.drive.current_pos = cdrom.drive.seek_target;

            cdrom.drive.loc_l_valid = true;
            const lba = cdrom.drive.seek_target.toLba();
            if (cdrom.disc) |d| {
                var raw_sector: [2352]u8 = undefined;
                if (d.readSector2352(lba, &raw_sector)) {
                    @memcpy(&cdrom.drive.last_sector_header, raw_sector[0x0C..0x14]);
                    cdrom.updateSubchannelQ();
                }
            } else {
                cdrom.synthesizeHeaderAndQ(cdrom.drive.seek_target);
                cdrom.drive.loc_l_valid = true;
            }

            // SeekL and SeekP both post their INT2 with a 500000 delay.
            cdrom.fifos.irq_queue.pushAction(2, 500000, &[_]u8{0}, .SetIdle, true);
        },
        0x1A => { // GetID
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            if (cdrom.disc) |d| {
                if (d.track_count == 0) {
                    cdrom.fifos.irq_queue.pushAction(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
                } else {
                    cdrom.fifos.irq_queue.pushAction(2, ack_delay, &[_]u8{ 0x02, 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A' }, .None, false);
                }
            } else {
                cdrom.fifos.irq_queue.pushAction(5, ack_delay, &[_]u8{ cdrom.getDriveStatus() | 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
            }
        },

        0x1E => { // ReadTOC
            cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
            cdrom.fifos.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
        },
        0x19 => { // Test
            const sub_cmd = if (cdrom.fifos.parameter_len > 0) cdrom.fifos.parameter_fifo[0] else 0;
            switch (sub_cmd) {
                0x03 => { // Force motor off
                    cdrom.drive.status &= ~@as(u8, 0x02);
                    cdrom.queueIrq(3, ack_delay, &[_]u8{cdrom.getDriveStatus()});
                },
                0x04 => { // Read SCEx
                    cdrom.drive.status |= 0x02;
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
            cdrom.fifos.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
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
