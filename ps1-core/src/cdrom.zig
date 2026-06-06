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
    SetReading,
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

    pub fn push(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8) void {
        self.pushAction(irq, delay, resp, .None, false);
    }

    pub fn pushAction(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8, action: IrqAction, auto_status: bool) void {
        if (self.count >= self.items.len) {
            std.log.warn("CDROM InterruptQueue overflow!", .{});
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

pub const CdRom = struct {
    debug_enable: bool = false,
    index: u2 = 0,

    // Interrupts

    irq_enable: u8 = 0,

    parameter_fifo: [16]u8 = [_]u8{0} ** 16,
    parameter_len: usize = 0,

    // Data FIFO
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
    is_busy: bool = false,
    loc_l_valid: bool = false,
    muted: bool = false,
    last_sector_header: [8]u8 = [_]u8{0} ** 8,
    last_subchannel_q: [8]u8 = [_]u8{0} ** 8,
    xa_filter_file: u8 = 0,
    xa_filter_channel: u8 = 0,
    volume_ll: u8 = 0x80,
    volume_lr: u8 = 0x00,
    volume_rl: u8 = 0x00,
    volume_rr: u8 = 0x80,

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

    // Drive mechanism
    drive_state: DriveState = .Idle,
    sector_timer: i64 = 0,

    // Interrupt Queue
    irq_queue: InterruptQueue = .{},

    disc: ?disc.Disc = null,

    pub fn init() CdRom {
        return .{
            .status = 0x02, // Motor on by default
        };
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
                0, 2 => self.irq_enable | 0xE0, // HINTMSK
                else => {
                    var flag: u8 = 0;
                    if (self.irq_queue.peek()) |item| {
                        if (item.delay <= 0) {
                            flag = item.irq & 7;
                        }
                    }
                    if (self.irq_queue.peek() != null) {
                        // std.debug.print("CDROM REG3 read: {X}\n", .{flag | 0xE0});
                    }
                    return flag | 0xE0; // HINTSTS
                },
            },
            else => 0,
        };
        return val;
    }

    pub fn write(self: *CdRom, offset: u32, value: u8) void {
        switch (offset) {
            0 => self.index = @truncate(value & 3),
            1 => switch (self.index) {
                0 => self.executeCommand(value),
                1 => {}, // WRDATA
                2 => {}, // CI
                3 => self.volume_rr = value, // ATV2
            },
            2 => {
                switch (self.index) {
                    0 => self.pushParameter(value),
                    1 => {
                        self.irq_enable = value & 0x1F;
                    },
                    2 => self.volume_ll = value, // ATV0
                    3 => self.volume_rl = value, // ATV3
                }
            },
            3 => switch (self.index) {
                0 => {}, // HCHPCTL
                1 => {
                    if (value & 0x40 != 0) {
                        self.parameter_len = 0;
                    }
                    if (self.irq_queue.peekMut()) |item| {
                        if ((value & item.irq & 7) != 0) {
                            std.debug.print("CDROM Acking IRQ: {d} (value={X})\n", .{item.irq, value});
                            item.ack = true;
                            if (item.response_ptr >= item.response_len) {
                                self.irq_queue.pop();
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
        // Tick Interrupt Queue Delay
        if (self.irq_queue.peekMut()) |item| {
            if (item.delay > 0) {
                item.delay -= @min(item.delay, cycles);
            }
            if (item.delay <= 0) {
                self.is_busy = false;
                if (!item.triggered) {
                    item.triggered = true;
                    switch (item.action) {
                        .SetIdle => self.drive_state = .Idle,
                        .SetReading => self.drive_state = .Reading,
                        .SetSeeking => self.drive_state = .Seeking,
                        .SetPlaying => self.drive_state = .Playing,
                        .None => {},
                    }
                    if (item.auto_status and item.response_len > 0) {
                        item.response[0] = self.getDriveStatus();
                    }
                }
            }
        } else {
            self.is_busy = false;
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

    fn readNextSector(self: *CdRom) void {
        const lba = self.seek_target.toLba();
        if (self.disc) |d| {
            var raw_sector: [2352]u8 = undefined;
            if (!d.readSector2352(lba, &raw_sector)) {
                self.drive_state = .Idle;
                self.queueIrq(5, 1000, &[_]u8{self.getDriveStatus() | 0x01}); // Read error
                return;
            }

            @memcpy(&self.last_sector_header, raw_sector[0x0C..0x14]);
            self.updateSubchannelQ();
            self.loc_l_valid = true;
            
            self.current_pos = self.seek_target;
            self.seek_target = disc.MSF.fromLba(lba + 1);

            if (self.drive_state == .Playing) {
                // CD-DA Playback
                if ((self.mode & 0x10) != 0) {
                    const q = &self.last_subchannel_q;
                    var resp = [_]u8{self.getDriveStatus(), q[0], q[1], 0, 0, 0, 0, 0};
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
                    self.queueIrq(1, 1000, &resp);
                }
            } else {
                if (!self.isXaAudioSector(&raw_sector)) {
                    const sector_size: usize = if (self.mode & 0x20 != 0) 2340 else 2048;
                    const data_start: usize = if (sector_size == 2048) 24 else 16;
                    @memcpy(self.sector_buffer[0..sector_size], raw_sector[data_start..][0..sector_size]);
                    self.sector_buffer_ptr = 0;
                    self.sector_buffer_len = sector_size;
                    self.data_fifo_empty = false;
                } else {
                    self.playXaAudioSector(&raw_sector);
                }
                self.queueIrq(1, 1000, &[_]u8{self.getDriveStatus()});
            }
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
        if (self.is_busy) stat |= (1 << 7);

        return stat;
    }

    fn readResponse(self: *CdRom) u8 {
        if (self.irq_queue.peekMut()) |item| {
            if (item.delay <= 0 and item.response_ptr < item.response_len) {
                const val = item.response[item.response_ptr];
                item.response_ptr += 1;
                
                // If we just read the last byte AND the interrupt was already acknowledged, pop it.
                if (item.response_ptr >= item.response_len and item.ack) {
                    self.irq_queue.pop();
                }
                return val;
            }
        }
        return 0;
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

    fn isXaAudioSector(self: *const CdRom, sector: *const [2352]u8) bool {
        _ = self;
        const mode_byte = sector[0x0F];
        if (mode_byte != 2) return false;

        const submode = sector[0x12];
        const submode_copy = sector[0x16];
        if (submode != submode_copy) return false;

        const is_form2 = (submode & 0x20) != 0;
        const is_audio = (submode & 0x04) != 0;
        return is_form2 and is_audio;
    }

    fn executeCommand(self: *CdRom, cmd: u8) void {
        if (@import("builtin").os.tag != .freestanding) {
            if (cmd == 0x10) {
                std.debug.print("CDROM CMD: 0x10 (GetlocL), loc_l_valid={}\n", .{self.loc_l_valid});
            } else {
                std.debug.print("CDROM CMD: 0x{X:0>2}\n", .{cmd});
            }
        }
        self.irq_queue.clear();
        self.is_busy = true;
        self.processCommand(cmd);
        self.parameter_len = 0;
    }

    fn processCommand(self: *CdRom, cmd: u8) void {
        // Initial delay before ACK is fired.
        const ack_delay: i64 = 10000;
        
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
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x03 => { // Play
                self.drive_state = .Playing;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x06 => { // ReadN
                self.drive_state = .Reading;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x07 => { // MotorOn
                self.status |= 0x02;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, 500000, &[_]u8{0}, .None, true);
            },
            0x08 => { // Stop
                self.status &= ~@as(u8, 0x02);
                self.drive_state = .Idle;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, 500000, &[_]u8{0}, .None, true);
            },
            0x09 => { // Pause
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.drive_state = .Idle;
                self.irq_queue.pushAction(2, 2000000, &[_]u8{0}, .SetIdle, true);
            },
            0x0A, 0x80 => { // Init / reset variant used by some test helpers
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.mode = 0;
                self.status = 0x02;
                self.loc_l_valid = false;
                self.muted = false;
                self.xa_filter_file = 0;
                self.xa_filter_channel = 0;
                self.drive_state = .Idle;
                self.irq_queue.pushAction(2, 2000000, &[_]u8{0}, .SetIdle, true);
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
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
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
                    std.debug.print("GetlocL queue INT5 error\n", .{});
                    self.queueIrq(5, ack_delay, &[_]u8{0x80}); // INT5 (Error)
                    return;
                }
                std.debug.print("GetlocL queue INT3 success\n", .{});
                self.queueIrq(3, ack_delay, &self.last_sector_header);
            },
            0x11 => { // GetlocP
                self.queueIrq(3, ack_delay, &self.last_subchannel_q);
            },
            0x13 => { // GetTN
                const first = if (self.disc) |d| disc.binaryToBcd(d.firstTrack()) else 0x01;
                const last = if (self.disc) |d| disc.binaryToBcd(d.lastTrack()) else 0x01;
                self.queueIrq(3, ack_delay, &[_]u8{ self.getDriveStatus(), first, last });
            },
            0x14 => { // GetTD
                const track = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                const msf = if (self.disc) |d|
                    if (track == 0) d.leadOut() else d.trackStart(track) orelse disc.MSF.fromLba(0)
                else if (track == 0)
                    disc.MSF.fromLba(0)
                else
                    disc.MSF.fromLba(0);
                const resp = [_]u8{ self.getDriveStatus(), msf.m, msf.s, msf.f };
                self.queueIrq(3, ack_delay, &resp);
            },
            0x15 => { // SeekL
                self.drive_state = .Seeking;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.current_pos = self.seek_target;
                self.irq_queue.pushAction(2, 2000000, &[_]u8{0}, .SetIdle, true); // Long seek delay
            },
            0x1A => { // GetID
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                if (self.disc) |d| {
                    if (d.track_count == 0) {
                        self.irq_queue.pushAction(5, 20000, &[_]u8{ self.getDriveStatus(), 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
                    } else {
                        self.irq_queue.pushAction(2, 20000, &[_]u8{ self.getDriveStatus(), 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A' }, .None, false);
                    }
                } else {
                    self.irq_queue.pushAction(5, 20000, &[_]u8{ self.getDriveStatus(), 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .None, false);
                }
            },
            0x1B => { // ReadS (Read with retry)
                // Treated same as ReadN for now
                self.drive_state = .Reading;
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
            },
            0x1E => { // ReadTOC
                self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                self.irq_queue.pushAction(2, 2000000, &[_]u8{0}, .None, true);
            },
            0x19 => { // Test
                const sub_cmd = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                if (sub_cmd == 0x20) { // Get version
                    self.queueIrq(3, ack_delay, &[_]u8{ 0x94, 0x09, 0x19, 0xC0 });
                } else {
                    self.queueIrq(3, ack_delay, &[_]u8{self.getDriveStatus()});
                }
            },
            else => {
                std.log.warn("Unhandled CD-ROM command: 0x{X:0>2}", .{cmd});
                self.queueIrq(5, ack_delay, &[_]u8{ self.getDriveStatus(), 0x40 }); // Error: Invalid Command
            },
        }
    }

    fn updateSubchannelQ(self: *CdRom) void {
        const current_lba = self.current_pos.toLba();
        const current_track = if (self.disc) |d| d.trackForLba(current_lba) else disc.Track{
            .number = 1,
            .start = disc.MSF.fromLba(0),
        };
        const track_lba = current_track.start.toLba();

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
        self.last_subchannel_q[2] = disc.binaryToBcd(relative.m);
        self.last_subchannel_q[3] = disc.binaryToBcd(relative.s);
        self.last_subchannel_q[4] = disc.binaryToBcd(relative.f);
        self.last_subchannel_q[5] = disc.binaryToBcd(self.current_pos.m);
        self.last_subchannel_q[6] = disc.binaryToBcd(self.current_pos.s);
        self.last_subchannel_q[7] = disc.binaryToBcd(self.current_pos.f);
    }

    fn queueIrq(self: *CdRom, irq: u8, delay: i64, resp: []const u8) void {
        self.irq_queue.push(irq, delay, resp);
    }

    pub fn updateInterrupts(self: *const CdRom, interrupts: *InterruptController) void {
        if (self.irq_queue.peek()) |item| {
            if (item.delay <= 0) {
                const flag_val = item.irq & 7;
                if (flag_val != 0) {
                    if ((self.irq_enable & 0x1F) & flag_val != 0) {
                        interrupts.trigger(.Cdrom);
                    }
                }
            }
        }
    }

    fn playXaAudioSector(self: *CdRom, sector: *const [2352]u8) void {
        const file = sector[0x10];
        const channel = sector[0x11];
        const coding_info = sector[0x13];

        if ((self.mode & 0x08) != 0) { // Filter bit
            if (file != self.xa_filter_file or channel != self.xa_filter_channel) {
                return; // Ignored by filter
            }
        }

        const is_stereo = (coding_info & 3) == 1;
        const is_18900 = ((coding_info >> 2) & 3) == 1;
        const is_8bit = ((coding_info >> 4) & 3) == 1;
        if (is_8bit) {
            std.log.warn("XA-ADPCM 8-bit mode not fully supported!", .{});
            return;
        }

        var group: usize = 0;
        while (group < 18) : (group += 1) {
            const group_offset = 0x18 + (group * 128);
            self.decodeXaGroup(sector[group_offset .. group_offset + 128][0..128], is_stereo, is_18900);
        }
    }

    fn decodeXaGroup(self: *CdRom, group: *const [128]u8, is_stereo: bool, is_18900: bool) void {
        for (0..4) |unit| {
            const shift_filter = group[unit];
            const filter = (shift_filter >> 4) & 3;
            const shift_factor = shift_filter & 0x0F;
            const shift = if (shift_factor <= 12) 12 - @as(u5, @truncate(shift_factor)) else 0;

            const is_right = is_stereo and ((unit == 1) or (unit == 3));
            const old = if (is_right) &self.xa_old_r else &self.xa_old_l;
            const older = if (is_right) &self.xa_older_r else &self.xa_older_l;

            const adpcm_filters = [5][2]i32{
                .{ 0, 0 },
                .{ 60, 0 },
                .{ 115, -52 },
                .{ 98, -55 },
                .{ 122, -60 },
            };
            const f0 = if (filter < 5) adpcm_filters[filter][0] else 0;
            const f1 = if (filter < 5) adpcm_filters[filter][1] else 0;

            for (0..28) |word_idx| {
                const data_byte = group[16 + (word_idx * 4) + unit];
                
                for (0..2) |nibble_idx| {
                    const nibble = if (nibble_idx == 0) (data_byte & 0x0F) else (data_byte >> 4);
                    const sample: i32 = @as(i4, @bitCast(@as(u4, @truncate(nibble))));

                    var val: i32 = sample << shift;
                    val += @divFloor(old.* * f0 + older.* * f1 + 32, 64);
                    const clamped = std.math.clamp(val, -32768, 32767);

                    older.* = old.*;
                    old.* = clamped;

                    const s16 = @as(i16, @intCast(clamped));
                    
                    if (is_stereo) {
                        if (is_right) {
                            self.audio_fifo_r[self.audio_fifo_write] = s16;
                            self.audio_fifo_write = (self.audio_fifo_write + 1) % 16384;
                            if (is_18900) {
                                self.audio_fifo_r[self.audio_fifo_write] = s16;
                                self.audio_fifo_write = (self.audio_fifo_write + 1) % 16384;
                            }
                        } else {
                            self.audio_fifo_l[self.audio_fifo_write] = s16;
                            if (is_18900) {
                                self.audio_fifo_l[(self.audio_fifo_write + 1) % 16384] = s16;
                            }
                        }
                    } else {
                        self.audio_fifo_l[self.audio_fifo_write] = s16;
                        self.audio_fifo_r[self.audio_fifo_write] = s16;
                        self.audio_fifo_write = (self.audio_fifo_write + 1) % 16384;
                        if (is_18900) {
                            self.audio_fifo_l[self.audio_fifo_write] = s16;
                            self.audio_fifo_r[self.audio_fifo_write] = s16;
                            self.audio_fifo_write = (self.audio_fifo_write + 1) % 16384;
                        }
                    }
                }
            }
        }
    }
};
