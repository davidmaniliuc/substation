const std = @import("std");
const disc = @import("../disc.zig");
const Spu = @import("../spu/spu.zig").Spu;
const InterruptController = @import("../interrupt.zig").InterruptController;
const fifo = @import("fifo.zig");
const commands = @import("commands.zig");
pub const xa = @import("xa.zig");
const cdda = @import("cdda.zig");

pub const DriveState = enum {
    Idle,
    Reading,
    Seeking,
    Playing,
};

pub const IrqAction = enum {
    None,
    SetIdle,
    SetSeeking,
    SetPlaying,
};

pub const CdRom = struct {
    debug_enable: bool = false,
    index: u2 = 0,

    // Interrupts

    irq_enable: u8 = 0x1F,

    parameter_fifo: [16]u8 = [_]u8{0} ** 16,
    parameter_len: usize = 0,
    last_response_byte: u8 = 0,

    // Data FIFO
    /// The sector the drive read most recently, raw. The drive refills this
    /// every sector; software never sees it directly (Avocado `rawSector`).
    last_raw_sector: [2352]u8 = [_]u8{0} ** 2352,
    /// The software-visible data FIFO: a *copy* of `last_raw_sector` taken when
    /// software writes Request bit 0x80 (Avocado `dataBuffer`). Keeping it
    /// separate is what stops a sector arriving mid-DMA from corrupting the
    /// transfer already in flight.
    sector_buffer: [2352]u8 = [_]u8{0} ** 2352,
    sector_buffer_ptr: usize = 0,
    sector_buffer_len: usize = 2048,
    data_fifo_empty: bool = true,

    // Drive State
    status: u8 = 0, // Drive status byte (Motor, etc.)
    mode: u8 = 0,
    seek_target: disc.MSF = .{ .m = 0, .s = 0, .f = 0 },
    current_pos: disc.MSF = .{ .m = 0, .s = 0, .f = 0 },
    is_reading: bool = false,
    busy_for: i32 = 0, // Separate busy timer (Avocado: busyFor), distinct from irq delay
    loc_l_valid: bool = false,
    muted: bool = false,
    last_sector_header: [8]u8 = [_]u8{0} ** 8,
    last_subchannel_q: [8]u8 = [_]u8{0} ** 8,
    xa_adpcm_filter: u8 = 0,
    xa_filter_file: u8 = 0,
    xa_filter_channel: u8 = 0,
    volume_ll: u8 = 0x80,
    volume_lr: u8 = 0x00,
    volume_rl: u8 = 0x00,
    volume_rr: u8 = 0x80,

    pending_command: ?u8 = null,
    pending_command_delay: u32 = 0,

    // XA-ADPCM Audio
    audio_fifo_l: [16384]i16 = [_]i16{0} ** 16384,
    audio_fifo_r: [16384]i16 = [_]i16{0} ** 16384,
    audio_fifo_read: usize = 0,
    autoreport_is_absolute: bool = false,
    audio_fifo_write: usize = 0,
    audio_tick_counter: u32 = 0,
    xa_old_l: i32 = 0,
    xa_older_l: i32 = 0,
    xa_old_r: i32 = 0,
    xa_older_r: i32 = 0,
    // 37800Hz -> 44100Hz zigzag resampler state, one set per channel.
    xa_ringbuf: [2][32]i16 = [_][32]i16{[_]i16{0} ** 32} ** 2,
    xa_ring_p: [2]u32 = .{ 0, 0 },
    xa_sixstep: [2]u8 = .{ 6, 6 },

    // Drive mechanism
    drive_state: DriveState = .Idle,
    sector_timer: i64 = 0,
    // Seek timer for ReadN's Seeking->Reading transition. Ticked unconditionally
    // in step() and gated on `read_after_seek`, so it survives the irq_queue.clear()
    // that every command performs (Avocado keeps drive mode in a persistent `stat`
    // field, decoupled from the interrupt queue).
    seek_timer: i64 = 0,
    read_after_seek: bool = false,

    // Interrupt Queue
    irq_queue: fifo.InterruptQueue = .{},
    /// Last observed level of the drive's IRQ line, so `updateInterrupts` can
    /// latch I_STAT on the rising edge the way the hardware does.
    irq_line: bool = false,

    /// Sectors the drive has delivered. Diagnostic counter; also lets tests
    /// pin down exactly when a sector lands relative to a transfer.
    sectors_delivered: u64 = 0,

    disc: ?disc.Disc = null,

    pub fn init() CdRom {
        var cd = CdRom{
            .status = 0x02, // Motor on by default
        };
        cd.last_subchannel_q[0] = 0x01; // track 1
        cd.last_subchannel_q[4] = 0x06; // rel f = 6
        cd.last_subchannel_q[6] = 0x01; // abs s = 1
        cd.last_subchannel_q[7] = 0x68; // abs f = 68
        return cd;
    }

    pub fn setDisc(self: *CdRom, d: disc.Disc) void {
        self.disc = d;
    }

    pub fn read(self: *CdRom, offset: u32) u8 {
        const val: u8 = switch (offset) {
            0 => self.getStatus(),
            1 => fifo.readResponse(self),
            2 => fifo.readData(self), // Port 2 is ALWAYS the Data FIFO
            3 => switch (self.index) {
                0, 2 => self.irq_enable | 0xE0, // Interrupt Enable Register
                else => {
                    // Interrupt Flag Register (index 1 or 3)
                    var flag: u8 = 0xE0; // Bits 7-5 always set
                    if (self.irq_queue.peek()) |item| {
                        // `ack` matters here: writing the IFR clears bits 0-2 on
                        // hardware even though the response FIFO stays readable,
                        // so an acknowledged-but-undrained item must report 0.
                        if (item.delay <= 0 and !item.ack) {
                            flag |= item.irq & 7;
                        }
                    }
                    if (self.debug_enable) std.log.warn("CDROM Read IFR({}, {}): 0x{x} queue_count={}", .{ offset, self.index, flag, self.irq_queue.count });
                    return flag;
                },
            },
            else => 0,
        };
        if (self.debug_enable) std.log.warn("CDROM Read({}, {}): 0x{x}", .{ offset, self.index, val });
        return val;
    }

    pub fn write(self: *CdRom, offset: u32, value: u8) void {
        if (self.debug_enable) std.log.warn("CDROM Write({}, {}): 0x{x}", .{ offset, self.index, value });
        switch (offset) {
            0 => self.index = @truncate(value & 3),
            1 => switch (self.index) {
                0 => {
                    self.irq_queue.clear();
                    self.pending_command = value;
                    self.pending_command_delay = 0; // Instant execution
                },
                1 => {}, // WRDATA
                2 => {}, // CI
                3 => self.volume_rr = value, // ATV2
            },
            2 => {
                switch (self.index) {
                    0 => fifo.pushParameter(self, value),
                    1 => self.irq_enable = value & 0x1F,
                    2 => self.volume_ll = value, // ATV0
                    3 => self.volume_rl = value, // ATV3
                }
            },
            3 => switch (self.index) {
                0 => {
                    // Request register
                    if (value & 0x80 != 0) {
                        // Want data: latch a copy of the last sector the drive
                        // read, but only once the previous one has been fully
                        // drained (Avocado cdrom.cpp:396 `if (isBufferEmpty())`).
                        // Re-latching mid-transfer would rewind the read pointer
                        // and splice in a newer sector.
                        if (self.data_fifo_empty) {
                            const sector_size: usize = if (self.mode & 0x20 != 0) 2340 else 2048;
                            const data_start: usize = if (sector_size == 2048) 24 else 12;
                            @memcpy(
                                self.sector_buffer[0..sector_size],
                                self.last_raw_sector[data_start..][0..sector_size],
                            );
                            self.sector_buffer_ptr = 0;
                            self.sector_buffer_len = sector_size;
                            self.data_fifo_empty = false;
                        }
                    } else {
                        // Clear data FIFO
                        self.data_fifo_empty = true;
                        self.sector_buffer_ptr = 0;
                    }
                },
                1 => {
                    // Interrupt Flag register write (ACK)
                    if (value & 0x40 != 0) {
                        self.parameter_len = 0; // Reset parameter FIFO
                    }
                    // Acknowledge front interrupt ONLY if low 5 bits are non-zero
                    if (value & 0x1F != 0) {
                        // Writing the IFR clears the flag bits, so the line goes
                        // low here even when the entry survives (unread response
                        // bytes) or when the next queued interrupt is already
                        // ready — without the drop, that next one would never
                        // produce a rising edge and would be lost.
                        self.irq_line = false;
                        if (self.irq_queue.peekMut()) |item| {
                            // Only ACK interrupts that have actually fired (delay expired)
                            if (item.delay <= 0) {
                                if (self.debug_enable) std.log.warn("CDROM Ack IFR value=0x{x} irq={} resp={}/{}", .{ value, item.irq, item.response_ptr, item.response_len });
                                item.ack = true;
                                // Match Avocado: only pop if the response FIFO is already fully consumed.
                                // Software can ACK first and continue reading remaining response bytes.
                                if (item.response_ptr >= item.response_len) {
                                    self.irq_queue.pop();
                                }
                            }
                        }
                    }
                },
                2 => self.volume_lr = value, // ATV1
                3 => {}, // ADPCTL
            },
            else => {},
        }
    }

    pub fn step(self: *CdRom, cycles: u32, spu: *Spu) void {
        // Handle pending command
        if (self.pending_command) |cmd| {
            if (self.pending_command_delay > 0) {
                self.pending_command_delay -= @min(self.pending_command_delay, cycles);
            }
            if (self.pending_command_delay <= 0) {
                self.pending_command = null;
                commands.executeCommand(self, cmd);
            }
        }

        // Tick busy timer (separate from IRQ delay, matching Avocado busyFor)
        if (self.busy_for > 0) {
            self.busy_for -= @intCast(@min(@as(u32, @intCast(self.busy_for)), cycles));
        }

        // Tick Interrupt Queue Delay
        if (self.irq_queue.peekMut()) |item| {
            if (item.delay > 0) {
                item.delay -= @min(item.delay, cycles);
            }
            if (item.delay <= 0) {
                if (!item.triggered) {
                    item.triggered = true;
                    switch (item.action) {
                        .SetIdle => self.drive_state = .Idle,
                        .SetSeeking => self.drive_state = .Seeking,
                        .SetPlaying => self.drive_state = .Playing,
                        .None => {},
                    }
                    if (item.auto_status and item.response_len > 0) {
                        item.response[0] = self.getDriveStatus();
                    }
                    if (self.debug_enable) std.log.warn("CDROM INT fire: irq={} resp_len={} drive_state={s} status=0x{x:0>2}", .{ item.irq, item.response_len, @tagName(self.drive_state), self.getDriveStatus() });
                }
                if (item.irq == 0) {
                    self.irq_queue.pop();
                }
            }
        }

        // Tick the read seek timer. Independent of irq_queue, so the GetStat
        // poll loop's repeated irq_queue.clear() cannot lose the Seeking->Reading
        // transition. Gated on read_after_seek so SeekL/SeekP (which also set
        // .Seeking but resolve via their own queued INT2) are unaffected.
        if (self.drive_state == .Seeking and self.read_after_seek) {
            self.seek_timer -= cycles;
            if (self.seek_timer <= 0) {
                self.read_after_seek = false;
                self.drive_state = .Reading;
                self.sector_timer = 0; // deliver the first sector promptly
            }
        }

        // Tick Drive Mechanism
        if (self.drive_state == .Reading or self.drive_state == .Playing) {
            self.sector_timer -= cycles;
            if (self.sector_timer <= 0) {
                // 33868800 / 75 Hz = 451584 cycles per sector. For 2x speed: 225792.
                const cycles_per_sector: i64 = if (self.mode & 0x80 != 0) 225792 else 451584;
                self.sector_timer += cycles_per_sector;

                if (self.drive_state == .Reading or self.drive_state == .Playing) {
                    self.readNextSector();
                }
            }
        }

        // XA Resampling and SPU push (approx 44100Hz = 768 CPU cycles)
        self.audio_tick_counter += cycles;
        if (self.audio_tick_counter >= 768) {
            self.audio_tick_counter -= 768;
            var l: i16 = 0;
            var r: i16 = 0;
            if (self.audio_fifo_read != self.audio_fifo_write) {
                l = self.audio_fifo_l[self.audio_fifo_read];
                r = self.audio_fifo_r[self.audio_fifo_read];
                self.audio_fifo_read = (self.audio_fifo_read + 1) % 16384;
            }
            spu.pushCdAudio(l, r);
        }
    }

    pub fn synthesizeHeaderAndQ(self: *CdRom, msf: disc.MSF) void {
        const lba = msf.toLba();
        self.last_sector_header[0] = msf.m;
        self.last_sector_header[1] = msf.s;
        self.last_sector_header[2] = msf.f;
        self.last_sector_header[3] = 0x02; // mode 2

        const abs_lba = if (lba >= 5) lba - 5 else 0;
        const abs_msf = disc.MSF.fromLba(abs_lba);
        const rel_msf = disc.MSF.fromFrames(abs_lba);

        self.last_subchannel_q[0] = 0x01; // track 1
        self.last_subchannel_q[1] = if (lba >= 0) @as(u8, 0x01) else @as(u8, 0x00);
        self.last_subchannel_q[2] = rel_msf.m;
        self.last_subchannel_q[3] = rel_msf.s;
        self.last_subchannel_q[4] = rel_msf.f;
        self.last_subchannel_q[5] = abs_msf.m;
        self.last_subchannel_q[6] = abs_msf.s;
        self.last_subchannel_q[7] = abs_msf.f;
    }

    fn readNextSector(self: *CdRom) void {
        self.sectors_delivered += 1;
        const lba = self.seek_target.toLba();
        var raw_sector: [2352]u8 = [_]u8{0} ** 2352;

        if (self.disc) |d| {
            if (!d.readSector2352(lba, &raw_sector)) {
                self.drive_state = .Idle;
                self.queueIrq(5, 1000, &[_]u8{self.getDriveStatus() | 0x01}); // Read error
                return;
            }

            @memcpy(&self.last_sector_header, raw_sector[0x0C..0x14]);
            self.updateSubchannelQ();
            self.loc_l_valid = true;
        } else {
            self.synthesizeHeaderAndQ(self.seek_target);
            self.loc_l_valid = true;
        }

        self.current_pos = self.seek_target;
        self.seek_target = disc.MSF.fromLba(lba + 1);

        // Avocado's `handleSector` only refills `rawSector` (cdrom.cpp:24). The
        // FIFO software reads from is loaded later, on Request(0x80).
        self.last_raw_sector = raw_sector;

        if (self.drive_state == .Playing) {
            cdda.handleSector(self, lba, &raw_sector);
        } else {
            // Real-time XA audio sectors are additionally decoded to the SPU.
            if (xa.isXaAudioSector(self, &raw_sector)) {
                xa.playXaAudioSector(self, &raw_sector);
            }
            self.queueIrq(1, 0, &[_]u8{self.getDriveStatus()}); // Avocado ackMoreData()
        }
    }

    pub fn getDriveStatus(self: *const CdRom) u8 {
        var stat = self.status & 0x1F;
        switch (self.drive_state) {
            .Reading => stat |= 0x20,
            .Seeking => stat |= 0x40,
            .Playing => stat |= 0x80,
            .Idle => {},
        }
        return stat;
    }

    fn getStatus(self: *const CdRom) u8 {
        var stat: u8 = @as(u8, self.index);
        if (self.parameter_len == 0) stat |= (1 << 3);
        if (self.parameter_len < 16) stat |= (1 << 4);

        const has_response = if (self.irq_queue.peek()) |item| (item.delay <= 0 and item.response_ptr < item.response_len) else false;
        if (has_response) stat |= (1 << 5);
        if (!self.data_fifo_empty) stat |= (1 << 6);
        if (self.busy_for > 0) stat |= (1 << 7);

        return stat;
    }

    pub fn updateSubchannelQ(self: *CdRom) void {
        const current_lba = self.current_pos.toLba();
        const current_track = if (self.disc) |d| d.trackForLba(current_lba) else disc.Track{
            .number = 1,
            .start_lba = 0,
        };
        const track_lba = current_track.start_lba;

        var relative_frames: i32 = 0;
        var index: u8 = 1;
        if (current_lba < track_lba) {
            relative_frames = track_lba - current_lba;
            index = 0; // Pregap
        } else {
            relative_frames = current_lba - track_lba;
        }

        const relative = disc.MSF.fromFrames(relative_frames);

        self.last_subchannel_q[0] = disc.binaryToBcd(current_track.number);
        self.last_subchannel_q[1] = disc.binaryToBcd(index);
        self.last_subchannel_q[2] = relative.m;
        self.last_subchannel_q[3] = relative.s;
        self.last_subchannel_q[4] = relative.f;
        self.last_subchannel_q[5] = self.current_pos.m;
        self.last_subchannel_q[6] = self.current_pos.s;
        self.last_subchannel_q[7] = self.current_pos.f;
    }

    pub fn queueIrq(self: *CdRom, irq: u8, delay: i64, resp: []const u8) void {
        self.irq_queue.push(irq, delay, resp);
    }

    pub fn updateInterrupts(self: *CdRom, interrupts: *InterruptController) void {
        // The drive drives a *level* on its IRQ line — high while an enabled,
        // unacknowledged interrupt is pending — but I_STAT latches the low->high
        // *edge*. Both halves matter, and getting either wrong is a real bug we
        // have shipped:
        //
        //  - Re-latching on the level (what Avocado's cdrom.cpp:173-179 does)
        //    delivers a phantom second interrupt, because the BIOS handler
        //    acknowledges I_STAT *before* it writes the CDROM IFR. The handler
        //    re-enters, reads an IFR that by then reads 0, and records IRQ=0 —
        //    that is `cdrom/getloc`'s "GetlocL failed, IRQ = 0".
        //  - A once-only latch per queue item (what this code did before June)
        //    loses interrupts that become enabled after they are queued, which
        //    is why it was replaced with the level model in the first place.
        //
        // Tracking the line itself gets both: an item that is queued while
        // masked raises a genuine edge when software enables it.
        const line = if (self.irq_queue.peek()) |item|
            item.delay <= 0 and !item.ack and ((self.irq_enable & item.irq & 7) != 0)
        else
            false;

        if (line and !self.irq_line) interrupts.trigger(.Cdrom);
        self.irq_line = line;
    }

    pub fn pushXaSample(self: *CdRom, l: i16, r: i16) void {
        const next = (self.audio_fifo_write + 1) % self.audio_fifo_l.len;
        if (next == self.audio_fifo_read) return; // FIFO full: drop rather than wrap over unread samples
        self.audio_fifo_l[self.audio_fifo_write] = l;
        self.audio_fifo_r[self.audio_fifo_write] = r;
        self.audio_fifo_write = next;
    }
};
