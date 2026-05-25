const std = @import("std");
const disc = @import("disc.zig");
const Spu = @import("spu.zig").Spu;

pub const DriveState = enum {
    Idle,
    Reading,
    Seeking,
    Playing,
};

const PendingInterrupt = struct {
    irq: u8,
    response: [16]u8 = [_]u8{0} ** 16,
    response_len: usize = 0,
    response_ptr: usize = 0,
    delay: i64 = 0,
    ack: bool = false,
};

const InterruptQueue = struct {
    items: [16]PendingInterrupt = [_]PendingInterrupt{.{ .irq = 0 }} ** 16,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8) void {
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
        
        self.tail = (self.tail + 1) % self.items.len;
        self.count += 1;
    }

    pub fn pop(self: *InterruptQueue) void {
        if (self.count == 0) return;
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
    }

    pub fn peekMut(self: *InterruptQueue) ?*PendingInterrupt {
        if (self.count == 0) return null;
        return &self.items[self.head];
    }
};

pub const CdRom = struct {
    debug_enable: bool = false,
    index: u2 = 0,

    // Interrupts
    irq_flag: u8 = 0,
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
    xa_filter_file: u8 = 0,
    xa_filter_channel: u8 = 0,

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
        return switch (offset) {
            0 => self.getStatus(),
            1 => self.readResponse(),
            2 => self.readData(), // Port 2 is ALWAYS the Data FIFO
            3 => switch (self.index) {
                0 => self.irq_enable | 0xE0, // Top 3 bits are always 1
                else => self.irq_flag | 0xE0,
            },
            else => 0,
        };
    }

    pub fn write(self: *CdRom, offset: u32, value: u8) void {
        switch (offset) {
            0 => self.index = @truncate(value & 3),
            1 => switch (self.index) {
                0 => self.executeCommand(value),
                else => {},
            },
            2 => switch (self.index) {
                0 => self.pushParameter(value),
                1 => self.irq_enable = value & 0x1F,
                else => {},
            },
            3 => switch (self.index) {
                1 => {
                    // Acknowledge interrupts by writing 1s to them.
                    self.irq_flag &= ~(value & 0x1F);
                    if (self.irq_queue.peekMut()) |item| {
                        item.ack = true;
                        // If all response bytes have been read, we can pop it immediately
                        if (item.response_ptr >= item.response_len) {
                            self.irq_queue.pop();
                        }
                    }
                    if (value & 0x40 != 0) {
                        self.parameter_len = 0;
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    pub fn step(self: *CdRom, cycles: u32, spu: *Spu) void {
        // Tick Interrupt Queue Delay
        if (self.irq_queue.peekMut()) |item| {
            if (item.delay > 0) {
                item.delay -= cycles;
            }
            if (item.delay <= 0) {
                // Assert the IRQ flag (if not already asserted)
                // Note: The hardware triggers INT repeatedly if not cleared, but setting the flag is sufficient.
                if ((self.irq_flag & 0x7) == 0) {
                    self.irq_flag = (self.irq_flag & ~@as(u8, 0x7)) | (item.irq & 0x7);
                }
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

    fn readNextSector(self: *CdRom) void {
        const lba = self.seek_target.toLba();
        if (self.disc) |d| {
            var raw_sector: [2352]u8 = undefined;
            if (!d.readSector2352(lba, &raw_sector)) {
                self.drive_state = .Idle;
                self.status &= ~@as(u8, 0x20);
                self.queueIrq(5, 1000, &[_]u8{self.status | 0x01}); // Read error
                return;
            }

            @memcpy(&self.last_sector_header, raw_sector[0x0C..0x14]);
            self.current_pos = self.seek_target;
            self.status |= 0x20; // Reading bit
            self.seek_target = disc.MSF.fromLba(lba + 1);

            if (self.drive_state == .Playing) {
                // CD-DA Playback
                if ((self.mode & 0x10) != 0) {
                    var q: [8]u8 = undefined;
                    self.getSubchannelQ(&q);
                    var resp = [_]u8{self.status, q[0], q[1], 0, 0, 0, 0, 0};
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
                self.queueIrq(1, 1000, &[_]u8{self.status});
            }
        }
    }

    fn getStatus(self: *const CdRom) u8 {
        var real_stat: u8 = @as(u8, self.index);
        if (self.parameter_len == 0) real_stat |= (1 << 3);
        if (self.parameter_len < 16) real_stat |= (1 << 4);
        
        // Response FIFO is not empty if there is a pending interrupt that is currently asserting
        // or has unread response bytes.
        const responseFifoEmpty = if (self.irq_queue.count > 0) 
            (self.irq_queue.items[self.irq_queue.head].response_ptr >= self.irq_queue.items[self.irq_queue.head].response_len)
        else true;

        if (!responseFifoEmpty) real_stat |= (1 << 5);
        if (!self.data_fifo_empty) real_stat |= (1 << 6);
        if (self.is_busy) real_stat |= (1 << 7);

        return real_stat;
    }

    fn readResponse(self: *CdRom) u8 {
        if (self.irq_queue.peekMut()) |item| {
            if (item.response_ptr < item.response_len) {
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

    pub fn readDataWord(self: *CdRom) u32 {
        if (self.data_fifo_empty) return 0;
        const ptr = self.sector_buffer_ptr;
        var word: u32 = 0;
        if (ptr + 4 <= self.sector_buffer_len) {
            const slice = self.sector_buffer[ptr .. ptr + 4];
            word = @as(u32, slice[0]) | (@as(u32, slice[1]) << 8) | (@as(u32, slice[2]) << 16) | (@as(u32, slice[3]) << 24);
            self.sector_buffer_ptr += 4;
        } else {
            for (0..4) |i| {
                if (ptr + i < self.sector_buffer_len) {
                    word |= @as(u32, self.sector_buffer[ptr + i]) << @as(u5, @truncate(i * 8));
                }
            }
            self.sector_buffer_ptr += 4;
        }
        if (self.sector_buffer_ptr >= self.sector_buffer_len) {
            self.data_fifo_empty = true;
        }
        return word;
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
            std.debug.print("CDROM CMD: 0x{X:0>2}\n", .{cmd});
        }
        self.processCommand(cmd);
        self.parameter_len = 0;
        self.is_busy = false;
    }

    fn processCommand(self: *CdRom, cmd: u8) void {
        // Initial delay before ACK is fired.
        const ack_delay = 10000;
        
        switch (cmd) {
            0x01 => { // Getstat
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x02 => { // Setloc
                if (self.parameter_len >= 3) {
                    self.seek_target.m = self.parameter_fifo[0];
                    self.seek_target.s = self.parameter_fifo[1];
                    self.seek_target.f = self.parameter_fifo[2];
                }
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x03 => { // Play
                self.drive_state = .Playing;
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x06 => { // ReadN
                self.drive_state = .Reading;
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x09 => { // Pause
                self.drive_state = .Idle;
                self.status &= ~@as(u8, 0x20);
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
                self.queueIrq(2, 2000000, &[_]u8{self.status});
            },
            0x0A, 0x80 => { // Init / reset variant used by some test helpers
                self.mode = 0;
                self.status = 0x02;
                self.drive_state = .Idle;
                self.loc_l_valid = false;
                self.muted = false;
                self.xa_filter_file = 0;
                self.xa_filter_channel = 0;
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
                self.queueIrq(2, 2000000, &[_]u8{self.status});
            },
            0x0B => { // Mute
                self.muted = true;
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x0C => { // Demute
                self.muted = false;
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x0D => { // Setfilter
                if (self.parameter_len >= 2) {
                    self.xa_filter_file = self.parameter_fifo[0];
                    self.xa_filter_channel = self.parameter_fifo[1];
                }
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x0E => { // Setmode
                if (self.parameter_len > 0) {
                    self.mode = self.parameter_fifo[0];
                }
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
            0x10 => { // GetlocL
                if (!self.loc_l_valid) {
                    self.queueIrq(5, ack_delay, &[_]u8{self.status | 0x01}); // INT5 (Error)
                    return;
                }
                self.queueIrq(3, ack_delay, &self.last_sector_header);
            },
            0x11 => { // GetlocP
                var resp: [8]u8 = undefined;
                self.getSubchannelQ(&resp);
                self.queueIrq(3, ack_delay, &resp);
            },
            0x13 => { // GetTN
                const first = if (self.disc) |d| disc.binaryToBcd(d.firstTrack()) else 0x01;
                const last = if (self.disc) |d| disc.binaryToBcd(d.lastTrack()) else 0x01;
                self.queueIrq(3, ack_delay, &[_]u8{ self.status, first, last });
            },
            0x14 => { // GetTD
                const track = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                const msf = if (self.disc) |d|
                    if (track == 0) d.leadOut() else d.trackStart(track) orelse disc.MSF.fromLba(0)
                else if (track == 0)
                    disc.MSF.fromLba(0)
                else
                    disc.MSF.fromLba(0);
                const resp = [_]u8{ self.status, msf.m, msf.s, msf.f };
                self.queueIrq(3, ack_delay, &resp);
            },
            0x15 => { // SeekL
                self.drive_state = .Seeking;
                self.current_pos = self.seek_target;
                self.loc_l_valid = true;
                self.status &= ~@as(u8, 0x20);
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
                self.queueIrq(2, 2000000, &[_]u8{self.status}); // Long seek delay
            },
            0x19 => { // Test
                const sub_cmd = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                if (sub_cmd == 0x20) { // Get version
                    self.queueIrq(3, ack_delay, &[_]u8{ 0x94, 0x09, 0x19, 0xC0 });
                } else {
                    self.queueIrq(3, ack_delay, &[_]u8{self.status});
                }
            },
            else => {
                std.log.warn("Unhandled CD-ROM command: 0x{X:0>2}", .{cmd});
                self.queueIrq(3, ack_delay, &[_]u8{self.status});
            },
        }
    }

    fn getSubchannelQ(self: *CdRom, resp: *[8]u8) void {
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

        resp[0] = disc.binaryToBcd(current_track.number);
        resp[1] = disc.binaryToBcd(index);
        resp[2] = disc.binaryToBcd(relative.m);
        resp[3] = disc.binaryToBcd(relative.s);
        resp[4] = disc.binaryToBcd(relative.f);
        resp[5] = disc.binaryToBcd(self.current_pos.m);
        resp[6] = disc.binaryToBcd(self.current_pos.s);
        resp[7] = disc.binaryToBcd(self.current_pos.f);
    }

    fn queueIrq(self: *CdRom, irq: u8, delay: i64, resp: []const u8) void {
        self.irq_queue.push(irq, delay, resp);
    }

    pub fn updateInterrupts(self: *const CdRom, i_stat: *u32) void {
        // Trigger INT3 (bit 2) if any unmasked interrupt is active
        if ((self.irq_flag & self.irq_enable & 0x1F) != 0) {
            i_stat.* |= (1 << 2);
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
