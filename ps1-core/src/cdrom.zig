const std = @import("std");
const disc = @import("disc.zig");

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
};

const InterruptQueue = struct {
    items: [8]PendingInterrupt = [_]PendingInterrupt{.{ .irq = 0 }} ** 8,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *InterruptQueue, irq: u8, resp: []const u8) void {
        if (self.count >= self.items.len) {
            std.log.warn("CDROM InterruptQueue overflow!", .{});
            return;
        }
        var item = &self.items[self.tail];
        item.irq = irq;
        @memcpy(item.response[0..resp.len], resp);
        item.response_len = resp.len;
        self.tail = (self.tail + 1) % self.items.len;
        self.count += 1;
    }

    pub fn pop(self: *InterruptQueue) ?PendingInterrupt {
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return item;
    }
};

pub const CdRom = struct {
    index: u2 = 0,

    // Interrupts
    irq_flag: u8 = 0,
    irq_enable: u8 = 0,

    // FIFOs
    response_fifo: [16]u8 = [_]u8{0} ** 16,
    response_ptr: usize = 0,
    response_len: usize = 0,

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

    // Command Execution
    active_command: ?u8 = null,
    command_timer: i64 = 0,

    // Drive mechanism
    drive_state: DriveState = .Idle,
    drive_timer: i64 = 0,
    drive_pending_irq: ?u8 = null,
    drive_pending_response: [16]u8 = [_]u8{0} ** 16,
    drive_pending_response_len: usize = 0,

    // Interrupt Queue
    irq_queue: InterruptQueue = .{},

    disc: ?disc.Disc = null,

    pub fn init() CdRom {
        return .{
            .status = 0x02, // Motor on by default for now
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
                    if (value & 0x40 != 0) {
                        self.parameter_len = 0;
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    pub fn step(self: *CdRom, cycles: u32) void {
        if (self.command_timer > 0) {
            self.command_timer -= cycles;
            if (self.command_timer <= 0) {
                if (self.active_command) |cmd| {
                    self.processCommand(cmd);
                    self.active_command = null;
                }
            }
        }

        if (self.drive_timer > 0) {
            self.drive_timer -= cycles;
            if (self.drive_timer <= 0) {
                if (self.drive_pending_irq) |irq| {
                    self.queueIrq(irq, self.drive_pending_response[0..self.drive_pending_response_len]);
                    self.drive_pending_irq = null;
                    self.drive_pending_response_len = 0;
                }
            }
        }

        if (self.drive_state == .Reading and self.drive_timer <= 0) {
            // INT1: Data Ready
            const lba = self.seek_target.toLba();
            if (self.disc) |d| {
                var raw_sector: [2352]u8 = undefined;
                if (!d.readSector2352(lba, &raw_sector)) {
                    self.drive_state = .Idle;
                    self.status &= ~@as(u8, 0x20);
                    return;
                }

                @memcpy(&self.last_sector_header, raw_sector[0x0C..0x14]);
                self.current_pos = self.seek_target;
                self.status |= 0x20; // Reading bit
                self.seek_target = disc.MSF.fromLba(lba + 1);

                const base_cycles: i64 = 33868;
                const delay: i64 = if (self.mode & 0x80 != 0) @divExact(base_cycles, 2) else base_cycles;

                if (!self.isXaAudioSector(&raw_sector)) {
                    // Determine sector size from mode bit 5 (0: 2048, 1: 2340/2352)
                    const sector_size: usize = if (self.mode & 0x20 != 0) 2340 else 2048;
                    const data_start: usize = if (sector_size == 2048) 24 else 16;
                    @memcpy(self.sector_buffer[0..sector_size], raw_sector[data_start..][0..sector_size]);
                    self.sector_buffer_ptr = 0;
                    self.sector_buffer_len = sector_size;
                    self.data_fifo_empty = false;
                }

                self.queueDriveIrq(1, &[_]u8{self.status}, delay);
            }
        }

        if ((self.irq_flag & 0x7) == 0) {
            if (self.irq_queue.pop()) |item| {
                for (0..item.response_len) |i| {
                    self.pushResponse(item.response[i]);
                }
                self.fireIrq(item.irq);
            }
        }
    }

    fn getStatus(self: *const CdRom) u8 {
        var real_stat: u8 = @as(u8, self.index);
        if (self.parameter_len == 0) real_stat |= (1 << 3);
        if (self.parameter_len < 16) real_stat |= (1 << 4);
        if (self.response_len > 0) real_stat |= (1 << 5);
        if (!self.data_fifo_empty) real_stat |= (1 << 6);
        if (self.is_busy) real_stat |= (1 << 7);

        return real_stat;
    }

    fn readResponse(self: *CdRom) u8 {
        if (self.response_len == 0) return 0;

        const val = self.response_fifo[self.response_ptr];
        self.response_ptr = (self.response_ptr + 1) % 16;
        self.response_len -= 1;
        return val;
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
            // Edge case: less than 4 bytes remaining
            const b0 = self.readData();
            const b1 = self.readData();
            const b2 = self.readData();
            const b3 = self.readData();
            word = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
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
        const mode = sector[0x0F];
        if (mode != 2) return false;

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

        self.active_command = cmd;
        self.command_timer = 30000;
        self.is_busy = true;
    }

    fn processCommand(self: *CdRom, cmd: u8) void {
        self.response_len = 0;
        self.response_ptr = 0;

        switch (cmd) {
            0x01 => { // GetStat
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x02 => { // Setloc
                if (self.parameter_len >= 3) {
                    self.seek_target.m = self.parameter_fifo[0];
                    self.seek_target.s = self.parameter_fifo[1];
                    self.seek_target.f = self.parameter_fifo[2];
                }
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x06 => { // ReadN
                self.drive_state = .Reading;
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x09 => { // Pause
                self.drive_state = .Idle;
                self.status &= ~@as(u8, 0x20);
                self.queueIrq(3, &[_]u8{self.status});
                self.queueDriveIrq(2, &[_]u8{self.status}, 10000);
            },
            0x0A, 0x80 => { // Init / reset variant used by some test helpers
                self.mode = 0;
                self.status = 0x02;
                self.drive_state = .Idle;
                self.loc_l_valid = false;
                self.muted = false;
                self.xa_filter_file = 0;
                self.xa_filter_channel = 0;
                self.queueIrq(3, &[_]u8{self.status});
                self.queueDriveIrq(2, &[_]u8{self.status}, 10000);
            },
            0x0B => { // Mute
                self.muted = true;
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x0C => { // Demute
                self.muted = false;
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x0D => { // Setfilter
                if (self.parameter_len >= 2) {
                    self.xa_filter_file = self.parameter_fifo[0];
                    self.xa_filter_channel = self.parameter_fifo[1];
                }
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x0E => { // Setmode
                if (self.parameter_len > 0) {
                    self.mode = self.parameter_fifo[0];
                }
                self.queueIrq(3, &[_]u8{self.status});
            },
            0x10 => { // GetlocL
                if (!self.loc_l_valid) {
                    self.queueIrq(5, &[_]u8{self.status | 0x01}); // INT5 (Error)
                    return;
                }
                self.queueIrq(3, &self.last_sector_header);
            },
            0x11 => { // GetlocP
                var resp: [8]u8 = undefined;
                self.getSubchannelQ(&resp);
                self.queueIrq(3, &resp);
            },
            0x13 => { // GetTN
                const first = if (self.disc) |d| disc.binaryToBcd(d.firstTrack()) else 0x01;
                const last = if (self.disc) |d| disc.binaryToBcd(d.lastTrack()) else 0x01;
                self.queueIrq(3, &[_]u8{ self.status, first, last });
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
                self.queueIrq(3, &resp);
            },
            0x15 => { // SeekL
                self.drive_state = .Seeking;
                self.current_pos = self.seek_target;
                self.loc_l_valid = true;
                self.status &= ~@as(u8, 0x20);
                self.queueIrq(3, &[_]u8{self.status});
                self.queueDriveIrq(2, &[_]u8{self.status}, 20000);
            },
            0x19 => { // Test
                const sub_cmd = if (self.parameter_len > 0) self.parameter_fifo[0] else 0;
                if (sub_cmd == 0x20) { // Get version
                    self.queueIrq(3, &[_]u8{ 0x94, 0x09, 0x19, 0xC0 });
                } else {
                    self.queueIrq(3, &[_]u8{self.status});
                }
            },
            else => {
                std.log.warn("Unhandled CD-ROM command: 0x{X:0>2}", .{cmd});
                self.queueIrq(3, &[_]u8{self.status});
            },
        }
        self.parameter_len = 0;
        self.is_busy = false;
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
        resp[2] = relative.m;
        resp[3] = relative.s;
        resp[4] = relative.f;
        resp[5] = self.current_pos.m;
        resp[6] = self.current_pos.s;
        resp[7] = self.current_pos.f;
    }

    fn queueIrq(self: *CdRom, irq: u8, resp: []const u8) void {
        self.irq_queue.push(irq, resp);
    }

    fn queueDriveIrq(self: *CdRom, irq: u8, resp: []const u8, delay: i64) void {
        self.drive_pending_irq = irq;
        @memcpy(self.drive_pending_response[0..resp.len], resp);
        self.drive_pending_response_len = resp.len;
        self.drive_timer = delay;
    }

    fn pushResponse(self: *CdRom, val: u8) void {
        if (self.response_len < 16) {
            self.response_fifo[(self.response_ptr + self.response_len) % 16] = val;
            self.response_len += 1;
        }
    }

    fn fireIrq(self: *CdRom, irq_code: u8) void {
        self.irq_flag = (self.irq_flag & ~@as(u8, 0x7)) | (irq_code & 0x7);
    }

    pub fn updateInterrupts(self: *const CdRom, i_stat: *u32) void {
        // Trigger INT3 (bit 2) if any unmasked interrupt is active (5 bits total).
        if ((self.irq_flag & self.irq_enable & 0x1F) != 0) {
            i_stat.* |= (1 << 2);
        }
    }
};
