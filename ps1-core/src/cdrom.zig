const std = @import("std");
const disc = @import("disc.zig");
const Spu = @import("spu.zig").Spu;
const InterruptController = @import("interrupt.zig").InterruptController;

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

const PendingInterrupt = struct {
    irq: u8,
    response: [16]u8 = [_]u8{0} ** 16,
    response_len: usize = 0,
    response_ptr: usize = 0,
    delay: i64 = 0,
    ack: bool = false,
    triggered: bool = false,
    action: IrqAction = .None,
    auto_status: bool = false,
};

const InterruptQueue = struct {
    items: [16]PendingInterrupt = [_]PendingInterrupt{.{ .irq = 0 }} ** 16,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    /// Counts dropped pushes. Avocado's fifo silently returns false when full
    /// (fifo.h:34), so dropping matches the reference — but a *sustained*
    /// overflow means software has stopped acknowledging, which is a real
    /// symptom worth surfacing. Frontends poll this instead of logging here,
    /// because the drop path runs once per sector and floods the console.
    overflow_count: u32 = 0,

    pub fn push(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8) void {
        self.pushAction(irq, delay, resp, .None, false);
    }

    pub fn pushAction(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8, action: IrqAction, auto_status: bool) void {
        if (self.count >= self.items.len) {
            self.overflow_count +%= 1;
            return;
        }
        var item = &self.items[self.tail];
        item.irq = irq;
        @memcpy(item.response[0..resp.len], resp);
        item.response_len = resp.len;
        item.response_ptr = 0;
        item.delay = delay;
        item.ack = false;
        item.triggered = false;
        item.action = action;
        item.auto_status = auto_status;

        self.tail = (self.tail + 1) % self.items.len;
        self.count += 1;
    }

    pub fn pop(self: *InterruptQueue) void {
        if (self.count == 0) return;
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
    }

    pub fn peek(self: *const InterruptQueue) ?*const PendingInterrupt {
        if (self.count == 0) return null;
        return &self.items[self.head];
    }

    pub fn peekMut(self: *InterruptQueue) ?*PendingInterrupt {
        if (self.count == 0) return null;
        return &self.items[self.head];
    }

    pub fn clear(self: *InterruptQueue) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }
};

/// 37800Hz -> 44100Hz resampling kernels (Avocado src/sound/tables.cpp).
const xa_zigzag_table = [7][29]i16{
    .{
        0x0000,  0x0000,  0x0000,  0x0000,  0x0000,  -0x0002,
        0x000A,  -0x0022, 0x0041,  -0x0054, 0x0034,  0x0009,
        -0x010A, 0x0400,  -0x0A78, 0x234C,  0x6794,  -0x1780,
        0x0BCD,  -0x0623, 0x0350,  -0x016D, 0x006B,  0x000A,
        -0x0010, 0x0011,  -0x0008, 0x0003,  -0x0001,
    },
    .{
        0x0000,  0x0000,  0x0000,  -0x0002, 0x0000,  0x0003,
        -0x0013, 0x003C,  -0x004B, 0x00A2,  -0x00E3, 0x0132,
        -0x0043, -0x0267, 0x0C9D,  0x74BB,  -0x11B4, 0x09B8,
        -0x05BF, 0x0372,  -0x01A8, 0x00A6,  -0x001B, 0x0005,
        0x0006,  -0x0008, 0x0003,  -0x0001, 0x0000,
    },
    .{
        0x0000,  0x0000,  -0x0001, 0x0003,  -0x0002, -0x0005,
        0x001F,  -0x004A, 0x00B3,  -0x0192, 0x02B1,  -0x039E,
        0x04F8,  -0x05A6, 0x7939,  -0x05A6, 0x04F8,  -0x039E,
        0x02B1,  -0x0192, 0x00B3,  -0x004A, 0x001F,  -0x0005,
        -0x0002, 0x0003,  -0x0001, 0x0000,  0x0000,
    },
    .{
        0x0000,  -0x0001, 0x0003,  -0x0008, 0x0006,  0x0005,
        -0x001B, 0x00A6,  -0x01A8, 0x0372,  -0x05BF, 0x09B8,
        -0x11B4, 0x74BB,  0x0C9D,  -0x0267, -0x0043, 0x0132,
        -0x00E3, 0x00A2,  -0x004B, 0x003C,  -0x0013, 0x0003,
        0x0000,  -0x0002, 0x0000,  0x0000,  0x0000,
    },
    .{
        0x0001, 0x0003,  -0x0008, 0x0011,  -0x0010, 0x000A,
        0x006B, -0x016D, 0x0350,  -0x0623, 0x0BCD,  -0x1780,
        0x6794, 0x234C,  -0x0A78, 0x0400,  -0x010A, 0x0009,
        0x0034, -0x0054, 0x0041,  -0x0022, 0x000A,  -0x0001,
        0x0000, 0x0001,  0x0000,  0x0000,  0x0000,
    },
    .{
        0x0002,  -0x0008, 0x0010,  -0x0023, 0x002B,  0x001A,
        -0x00EB, 0x027B,  -0x0548, 0x0AFA,  -0x16FA, 0x53E0,
        0x3C07,  -0x1249, 0x080E,  -0x0347, 0x015B,  -0x0044,
        -0x0017, 0x0046,  -0x0023, 0x0011,  -0x0005, 0x0000,
        0x0000,  0x0000,  0x0000,  0x0000,  0x0000,
    },
    .{
        -0x0005, 0x0011,  -0x0023, 0x0046,  -0x0017, -0x0044,
        0x015B,  -0x0347, 0x080E,  -0x1249, 0x3C07,  0x53E0,
        -0x16FA, 0x0AFA,  -0x0548, 0x027B,  -0x00EB, 0x001A,
        0x002B,  -0x0023, 0x0010,  -0x0008, 0x0002,  0x0000,
        0x0000,  0x0000,  0x0000,  0x0000,  0x0000,
    },
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
    irq_queue: InterruptQueue = .{},

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
            1 => self.readResponse(),
            2 => self.readData(), // Port 2 is ALWAYS the Data FIFO
            3 => switch (self.index) {
                0, 2 => self.irq_enable | 0xE0, // Interrupt Enable Register
                else => {
                    // Interrupt Flag Register (index 1 or 3)
                    var flag: u8 = 0xE0; // Bits 7-5 always set
                    if (self.irq_queue.peek()) |item| {
                        if (item.delay <= 0) {
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
                    0 => self.pushParameter(value),
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
                    // Acknowledge front interrupt ONLY if low 5 bits are non-zero
                    if (value & 0x1F != 0) {
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
                self.executeCommand(cmd);
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

    fn synthesizeHeaderAndQ(self: *CdRom, msf: disc.MSF) void {
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
            // CD-DA Playback
            if ((self.mode & 0x10) != 0) {
                const q = &self.last_subchannel_q;
                var resp = [_]u8{ self.getDriveStatus(), q[0], q[1], 0, 0, 0, 0, 0 };
                if (self.autoreport_is_absolute) {
                    resp[3] = q[5];
                    resp[4] = q[6];
                    resp[5] = q[7];
                } else {
                    resp[3] = q[2];
                    resp[4] = q[3] | 0x80;
                    resp[5] = q[4];
                }
                self.autoreport_is_absolute = !self.autoreport_is_absolute;
                self.queueIrq(1, 0, &resp); // Avocado ackMoreData()
            }
        } else {
            // Real-time XA audio sectors are additionally decoded to the SPU.
            if (self.isXaAudioSector(&raw_sector)) {
                self.playXaAudioSector(&raw_sector);
            }
            self.queueIrq(1, 0, &[_]u8{self.getDriveStatus()}); // Avocado ackMoreData()
        }
    }

    fn getDriveStatus(self: *const CdRom) u8 {
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

    fn readResponse(self: *CdRom) u8 {
        if (self.irq_queue.peekMut()) |item| {
            if (item.delay <= 0 and item.response_ptr < item.response_len) {
                const val = item.response[item.response_ptr];
                item.response_ptr += 1;
                self.last_response_byte = val;

                if (self.debug_enable) std.log.warn("CDROM readResponse returning 0x{x} at ptr {}", .{ val, item.response_ptr - 1 });

                if (item.response_ptr >= item.response_len and item.ack) {
                    self.irq_queue.pop();
                }
                return val;
            } else if (item.delay <= 0) {}
        }
        return self.last_response_byte;
    }

    pub fn readData(self: *CdRom) u8 {
        if (self.data_fifo_empty) return 0;
        const val = self.sector_buffer[self.sector_buffer_ptr];
        self.sector_buffer_ptr += 1;
        if (self.sector_buffer_ptr >= self.sector_buffer_len) {
            self.data_fifo_empty = true;
        }
        return val;
    }

    fn pushParameter(self: *CdRom, val: u8) void {
        if (self.parameter_len < 16) {
            self.parameter_fifo[self.parameter_len] = val;
            self.parameter_len += 1;
        }
    }

    pub fn isXaAudioSector(self: *const CdRom, sector: *const [2352]u8) bool {
        _ = self;
        const mode_byte = sector[0x0F];
        if (mode_byte != 2) return false;

        const submode = sector[0x12];
        const submode_copy = sector[0x16];
        if (submode != submode_copy) return false;

        // CD-XA submode bits (Avocado `cd::Submode`, utils/cd.h):
        // 0=endOfRecord 1=video 2=audio 3=data 4=trigger 5=form2 6=realtime 7=endOfFile
        const is_audio = (submode & 0x04) != 0;
        const is_form2 = (submode & 0x20) != 0;
        const is_realtime = (submode & 0x40) != 0;
        return is_realtime and is_form2 and is_audio;
    }

    fn executeCommand(self: *CdRom, cmd: u8) void {
        if (self.debug_enable) {
            std.log.warn("CDROM cmd=0x{x:0>2} irq_enable=0x{x} queue_count={} drive_state={s}", .{ cmd, self.irq_enable, self.irq_queue.count, @tagName(self.drive_state) });
        }
        self.irq_queue.clear();
        self.busy_for = 0; // Avocado used 1000, but it blocks CdStatus
        self.processCommand(cmd);
        self.parameter_len = 0;
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

    fn processCommand(self: *CdRom, cmd: u8) void {
        switch (cmd) {
            0x01 => { // Getstat
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x02 => { // Setloc
                if (self.parameter_len >= 3) {
                    self.seek_target.m = self.parameter_fifo[0];
                    self.seek_target.s = self.parameter_fifo[1];
                    self.seek_target.f = self.parameter_fifo[2];
                }
                self.queueIrq(3, 5000, &[_]u8{self.getDriveStatus()}); // Avocado cmdSetloc
            },
            0x03 => { // Play
                self.read_after_seek = false;
                self.drive_state = .Playing;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
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
                self.drive_state = .Seeking;
                self.read_after_seek = true;
                self.seek_timer = 1000000;
                // Avocado: cmdReadN uses 1000, cmdReadS 500.
                self.queueIrq(3, if (cmd == 0x06) 1000 else 500, &[_]u8{self.getDriveStatus()});
            },
            0x07 => { // MotorOn
                self.status |= 0x02;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
            },
            0x08 => { // Stop
                self.status &= ~@as(u8, 0x02);
                self.read_after_seek = false;
                self.drive_state = .Idle;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
            },
            0x09 => { // Pause
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.read_after_seek = false;
                self.drive_state = .Idle;
                self.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .SetIdle, true);
            },
            0x0A, 0x80 => { // Init (Avocado: cmdInit)
                // INT3 first response with stat (delay 0x13CE = 5070 cycles)
                self.queueIrq(3, 0x13CE, &[_]u8{self.getDriveStatus()});
                self.mode = 0;
                self.status = 0x02;
                self.loc_l_valid = false;
                self.muted = false;
                self.xa_filter_file = 0;
                self.xa_filter_channel = 0;
                self.read_after_seek = false;
                self.drive_state = .Idle;

                self.last_subchannel_q[0] = 0x01; // track 1
                self.last_subchannel_q[1] = 0x00; // index 0
                self.last_subchannel_q[2] = 0x00; // rel m
                self.last_subchannel_q[3] = 0x00; // rel s
                self.last_subchannel_q[4] = 0x06; // rel f = 6
                self.last_subchannel_q[5] = 0x00; // abs m
                self.last_subchannel_q[6] = 0x01; // abs s = 1
                self.last_subchannel_q[7] = 0x68; // abs f = 68

                // INT2 second response with stat (default delay)
                self.irq_queue.pushAction(2, 50000, &[_]u8{self.getDriveStatus()}, .SetIdle, false);
            },
            0x0B => { // Mute
                self.muted = true;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x0C => { // Demute
                self.muted = false;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x0D => { // Setfilter
                if (self.parameter_len >= 2) {
                    self.xa_filter_file = self.parameter_fifo[0];
                    self.xa_filter_channel = self.parameter_fifo[1];
                }
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x0E => { // Setmode
                if (self.parameter_len > 0) {
                    self.mode = self.parameter_fifo[0];
                }
                self.queueIrq(3, 2000, &[_]u8{self.getDriveStatus()}); // Avocado cmdSetmode
            },
            0x0F => { // Getparam
                self.queueIrq(3, ack_delay, &[_]u8{
                    self.getDriveStatus(),
                    self.mode,
                    0x00,
                    self.xa_filter_file,
                    self.xa_filter_channel,
                });
            },
            0x10 => { // GetlocL
                if (!self.loc_l_valid) {
                    self.queueIrq(5, ack_delay, &[_]u8{ self.getDriveStatus() | 0x01, 0x80 }); // Error
                    return;
                }
                var resp = [_]u8{0} ** 8;
                @memcpy(resp[0..8], self.last_sector_header[0..8]);
                self.queueIrq(3, ack_delay, &resp);
            },
            0x11 => { // GetlocP
                var resp = [_]u8{0} ** 8;
                @memcpy(resp[0..8], self.last_subchannel_q[0..8]);
                self.queueIrq(3, 1000, &resp); // Avocado cmdGetlocP
            },
            0x13 => { // GetTN
                const first = if (self.disc) |d| disc.binaryToBcd(d.firstTrack()) else 0x01;
                const last = if (self.disc) |d| disc.binaryToBcd(d.lastTrack()) else 0x01;
                self.queueIrq(3, ack_delay, &[_]u8{ self.getDriveStatus(), first, last });
            },
            0x14 => { // GetTD
                const track_bcd = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                const track = disc.bcdToBinary(track_bcd);
                const msf = if (self.disc) |d|
                    if (track == 0) d.leadOut() else d.trackStart(track) orelse disc.MSF.fromLba(0)
                else if (track == 0)
                    disc.MSF.fromLba(0)
                else
                    disc.MSF.fromLba(0);
                const resp = [_]u8{ self.getDriveStatus(), msf.m, msf.s };
                self.queueIrq(3, ack_delay, &resp);
            },
            0x15, 0x16 => { // SeekL, SeekP
                self.read_after_seek = false;
                self.drive_state = .Seeking;
                // Avocado cmdSeekL uses 5000; cmdSeekP uses the default.
                self.queueIrq(3, if (cmd == 0x15) 5000 else ack_delay, &[_]u8{self.getDriveStatus()});
                self.current_pos = self.seek_target;

                self.loc_l_valid = true;
                const lba = self.seek_target.toLba();
                if (self.disc) |d| {
                    var raw_sector: [2352]u8 = undefined;
                    if (d.readSector2352(lba, &raw_sector)) {
                        @memcpy(&self.last_sector_header, raw_sector[0x0C..0x14]);
                        self.updateSubchannelQ();
                    }
                } else {
                    self.synthesizeHeaderAndQ(self.seek_target);
                    self.loc_l_valid = true;
                }

                // Avocado cmdSeekL/cmdSeekP both post the INT2 with a 500000 delay.
                self.irq_queue.pushAction(2, 500000, &[_]u8{0}, .SetIdle, true);
            },
            0x1A => { // GetID
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                if (self.disc) |d| {
                    if (d.track_count == 0) {
                        self.irq_queue.pushAction(5, ack_delay, &[_]u8{ self.getDriveStatus() | 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
                    } else {
                        self.irq_queue.pushAction(2, ack_delay, &[_]u8{ 0x02, 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A' }, .None, false);
                    }
                } else {
                    self.irq_queue.pushAction(5, ack_delay, &[_]u8{ self.getDriveStatus() | 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
                }
            },

            0x1E => { // ReadTOC
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
            },
            0x19 => { // Test
                const sub_cmd = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                switch (sub_cmd) {
                    0x03 => { // Force motor off
                        self.status &= ~@as(u8, 0x02);
                        self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                    },
                    0x04 => { // Read SCEx
                        self.status |= 0x02;
                        self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                    },
                    0x05 => { // Get SCEx counters
                        self.queueIrq(3, ack_delay, &[_]u8{ self.getDriveStatus(), 0 });
                    },
                    0x20 => { // Get version
                        self.queueIrq(3, ack_delay, &[_]u8{ self.getDriveStatus(), 0x94, 0x09, 0x19, 0xC0 });
                    },
                    0x22 => { // Get region
                        self.queueIrq(3, ack_delay, &[_]u8{ self.getDriveStatus(), 'f', 'o', 'r', ' ', 'U', '/', 'C' });
                    },
                    else => {
                        self.queueIrq(5, ack_delay, &[_]u8{ 0x11, 0x40 }); // Error
                    },
                }
            },
            0x04, 0x05 => { // Forward, Backward
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x12 => { // SetSession
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, ack_delay, &[_]u8{0}, .None, true);
            },
            0x50...0x56 => { // Unlock
                self.queueIrq(5, ack_delay, &[_]u8{ 0x11, 0x40 }); // Semi-implemented error
            },
            else => {
                std.log.warn("Unhandled CD-ROM command: 0x{x:0>2}", .{cmd});
                self.queueIrq(5, ack_delay, &[_]u8{ 0x11, 0x40 }); // Error: Invalid Command
            },
        }
    }

    fn updateSubchannelQ(self: *CdRom) void {
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

    fn queueIrq(self: *CdRom, irq: u8, delay: i64, resp: []const u8) void {
        self.irq_queue.push(irq, delay, resp);
    }

    pub fn updateInterrupts(self: *CdRom, interrupts: *InterruptController) void {
        // Level-triggered (matches Avocado cdrom.cpp:173-179): re-assert the CPU
        // IRQ on every step while the front queue item is ready and its IFR bit
        // is enabled. No `ack` gate and no once-only latch — software that ACKs
        // but leaves response bytes unread relies on the line being re-asserted
        // to re-enter the handler and drain the rest.
        if (self.irq_queue.peek()) |item| {
            if (item.delay <= 0 and ((self.irq_enable & item.irq & 7) != 0)) {
                interrupts.trigger(.Cdrom);
            }
        }
    }

    pub fn playXaAudioSector(self: *CdRom, sector: *const [2352]u8) void {
        const file = sector[0x10];
        const channel = sector[0x11];
        const coding_info = sector[0x13];

        if ((self.mode & 0x08) != 0) { // Filter bit
            if (file != self.xa_filter_file or channel != self.xa_filter_channel) {
                return; // Ignored by filter
            }
        }

        // Coding info is a set of 1-bit fields (Avocado `cd::Codinginfo`);
        // the odd bits are reserved and bit6 (emphasis) is commonly set.
        const is_stereo = (coding_info & 0x01) != 0;
        const is_18900 = (coding_info & 0x04) != 0;
        const is_8bit = (coding_info & 0x10) != 0;
        if (is_8bit) {
            std.log.warn("XA-ADPCM 8-bit mode not fully supported!", .{});
            return;
        }

        // Worst case per 128-byte group: mono, 8 blocks * 28 samples = 224 inputs,
        // resampled 6->7 and doubled for 18900Hz.
        var left_buf: [768]i16 = undefined;
        var right_buf: [768]i16 = undefined;

        var group: usize = 0;
        while (group < 18) : (group += 1) {
            const g = sector[0x18 + group * 128 ..][0..128];
            if (is_stereo) {
                const nl = self.decodeXaPacket(g, .left, is_18900, &left_buf);
                const nr = self.decodeXaPacket(g, .right, is_18900, &right_buf);
                for (0..@min(nl, nr)) |i| self.pushXaSample(left_buf[i], right_buf[i]);
            } else {
                const n = self.decodeXaPacket(g, .mono, is_18900, &left_buf);
                for (0..n) |i| self.pushXaSample(left_buf[i], left_buf[i]);
            }
        }
    }

    fn pushXaSample(self: *CdRom, l: i16, r: i16) void {
        const next = (self.audio_fifo_write + 1) % self.audio_fifo_l.len;
        if (next == self.audio_fifo_read) return; // FIFO full: drop rather than wrap over unread samples
        self.audio_fifo_l[self.audio_fifo_write] = l;
        self.audio_fifo_r[self.audio_fifo_write] = r;
        self.audio_fifo_write = next;
    }

    const XaChannel = enum { mono, left, right };

    /// Decodes one 128-byte sound group for a single channel, appending
    /// 44100Hz samples to `out`. Port of Avocado `ADPCM::decodePacket`.
    ///
    /// A group holds 8 sound units. Their headers live at group offsets 4..11
    /// (0..3 is the redundant copy), and the 28 data words at 0x10..0x7F carry
    /// unit `b` in bits `b*4` of each little-endian 32-bit word. Stereo splits
    /// the units by parity: even -> left, odd -> right.
    fn decodeXaPacket(
        self: *CdRom,
        group: *const [128]u8,
        comptime channel: XaChannel,
        is_18900: bool,
        out: []i16,
    ) usize {
        const blocks: []const usize = switch (channel) {
            .mono => &[_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 },
            .left => &[_]usize{ 0, 2, 4, 6 },
            .right => &[_]usize{ 1, 3, 5, 7 },
        };
        const ch: usize = if (channel == .right) 1 else 0;
        const old = if (channel == .right) &self.xa_old_r else &self.xa_old_l;
        const older = if (channel == .right) &self.xa_older_r else &self.xa_older_l;

        const filter_pos = [5]i32{ 0, 60, 115, 98, 122 };
        const filter_neg = [5]i32{ 0, 0, -52, -55, -60 };

        var count: usize = 0;
        for (blocks) |block| {
            const header = group[4 + block];
            var shift: u5 = @truncate(header & 0x0F);
            if (shift > 12) shift = 9;
            const filter = (header & 0x30) >> 4;
            const f0 = filter_pos[filter];
            const f1 = filter_neg[filter];

            for (0..28) |n| {
                const base = 0x10 + n * 4;
                const word = @as(u32, group[base]) |
                    (@as(u32, group[base + 1]) << 8) |
                    (@as(u32, group[base + 2]) << 16) |
                    (@as(u32, group[base + 3]) << 24);
                const nibble: u16 = @truncate((word >> @intCast(block * 4)) & 0x0F);

                // Sign-extend the 4-bit sample via bit 15, then scale by the shift.
                var sample: i32 = @as(i32, @as(i16, @bitCast(nibble << 12))) >> shift;
                sample += @divTrunc(old.* * f0 + older.* * f1 + 32, 64);

                const clamped = std.math.clamp(sample, -32768, 32767);
                // The predictor history keeps the *unclamped* value (Avocado adpcm.cpp:141-142).
                older.* = old.*;
                old.* = sample;

                count += self.interpolateXa(ch, @intCast(clamped), is_18900, out[count..]);
            }
        }
        return count;
    }

    /// Feeds one 37800Hz sample into the per-channel ring buffer, emitting 7
    /// output samples for every 6 inputs (37800 -> 44100Hz), doubled when the
    /// source is 18900Hz. Port of Avocado `ADPCM::interpolate`.
    fn interpolateXa(self: *CdRom, ch: usize, sample: i16, is_18900: bool, out: []i16) usize {
        self.xa_ringbuf[ch][self.xa_ring_p[ch] & 0x1F] = sample;
        self.xa_ring_p[ch] +%= 1;

        self.xa_sixstep[ch] -= 1;
        if (self.xa_sixstep[ch] != 0) return 0;
        self.xa_sixstep[ch] = 6;

        var n: usize = 0;
        for (0..7) |table| {
            const v = self.zigzagXa(ch, table);
            out[n] = v;
            n += 1;
            if (is_18900) {
                out[n] = v;
                n += 1;
            }
        }
        return n;
    }

    fn zigzagXa(self: *const CdRom, ch: usize, table: usize) i16 {
        var sum: i32 = 0;
        var i: u32 = 1;
        while (i < 29) : (i += 1) {
            const idx = (self.xa_ring_p[ch] -% i) & 0x1F;
            sum += @divTrunc(@as(i32, self.xa_ringbuf[ch][idx]) * @as(i32, xa_zigzag_table[table][i]), 0x8000);
        }
        return @intCast(std.math.clamp(sum, -32768, 32767));
    }
};
