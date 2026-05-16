const std = @import("std");
const disc = @import("disc.zig");

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

    // Timing / Events
    pending_irq: ?u8 = null,
    pending_response: [16]u8 = [_]u8{0} ** 16,
    pending_response_len: usize = 0,
    cycles_until_irq: i64 = 0,

    // Second stage interrupt (for INT3 then INT2)
    next_pending_irq: ?u8 = null,
    next_pending_response: [16]u8 = [_]u8{0} ** 16,
    next_pending_response_len: usize = 0,
    cycles_until_next_irq: i64 = 0,

    disc: ?disc.Disc = null,

    pub fn init() CdRom {
        return .{
            .status = 0x10, // Motor on by default for now
        };
    }

    pub fn setDisc(self: *CdRom, d: disc.Disc) void {
        self.disc = d;
    }

    pub fn read(self: *CdRom, offset: u32) u8 {
        return switch (offset) {
            0 => self.getStatus(),
            1 => self.readResponse(),
            2 => self.readData(),
            3 => switch (self.index) {
                0 => self.irq_enable,
                1 => self.irq_flag | 0xF8,
                else => 0,
            },
            else => 0,
        };
    }

    pub fn write(self: *CdRom, offset: u32, value: u8) void {
        switch (offset) {
            0 => self.index = @truncate(value & 3),
            1 => self.executeCommand(value),
            2 => self.pushParameter(value),
            3 => switch (self.index) {
                1 => {
                    // Acknowledge interrupts by writing 1s to them.
                    self.irq_flag &= ~value;
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
        if (self.cycles_until_irq > 0) {
            self.cycles_until_irq -= cycles;
            if (self.cycles_until_irq <= 0) {
                if (self.pending_irq) |irq| {
                    for (0..self.pending_response_len) |i| {
                        self.pushResponse(self.pending_response[i]);
                    }
                    self.fireIrq(irq);
                    self.pending_irq = null;
                    self.pending_response_len = 0;
                    self.is_busy = false;

                    // If there's a second stage IRQ queued, start its timer
                    if (self.next_pending_irq != null) {
                        self.pending_irq = self.next_pending_irq;
                        @memcpy(self.pending_response[0..self.next_pending_response_len], self.next_pending_response[0..self.next_pending_response_len]);
                        self.pending_response_len = self.next_pending_response_len;
                        self.cycles_until_irq = self.cycles_until_next_irq;

                        self.next_pending_irq = null;
                        self.next_pending_response_len = 0;
                    }
                }
            }
        }

        if (self.is_reading and self.cycles_until_irq <= 0) {
            // INT1: Data Ready
            const lba = self.seek_target.toLba();
            if (self.disc) |d| {
                // Determine sector size from mode bit 5 (0: 2048, 1: 2340/2352)
                const sector_size: usize = if (self.mode & 0x20 != 0) 2340 else 2048;
                if (d.readSectorRaw(lba, &self.sector_buffer, sector_size)) {
                    self.sector_buffer_ptr = 0;
                    self.sector_buffer_len = sector_size;
                    self.data_fifo_empty = false;

                    self.current_pos = self.seek_target;
                    self.status |= 0x20; // Reading bit

                    self.pending_irq = 1;
                    self.pending_response[0] = self.status;
                    self.pending_response_len = 1;
                    // Double speed (mode bit 7) = 2x faster (1/150th sec)
                    const base_cycles = 33868;
                    self.cycles_until_irq = if (self.mode & 0x80 != 0) @divExact(base_cycles, 2) else base_cycles;

                    // Advance seek target
                    self.seek_target = disc.MSF.fromLba(lba + 1);
                } else {
                    self.is_reading = false;
                    self.status &= ~@as(u8, 0x20);
                }
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

    fn pushParameter(self: *CdRom, val: u8) void {
        if (self.parameter_len < 16) {
            self.parameter_fifo[self.parameter_len] = val;
            self.parameter_len += 1;
        }
    }

    fn executeCommand(self: *CdRom, cmd: u8) void {
        self.response_len = 0;
        self.response_ptr = 0;
        self.is_busy = true;

        switch (cmd) {
            0x01 => { // GetStat
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
            },
            0x02 => { // Setloc
                self.seek_target.m = self.parameter_fifo[0];
                self.seek_target.s = self.parameter_fifo[1];
                self.seek_target.f = self.parameter_fifo[2];
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
            },
            0x06 => { // ReadN
                self.is_reading = true;
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
            },
            0x09 => { // Pause
                self.is_reading = false;
                self.status &= ~@as(u8, 0x20);
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
                self.queueSecondResponse(2, &[_]u8{self.status}, 10000);
            },
            0x0A => { // Init
                self.mode = 0;
                self.status = 0x10;
                self.is_reading = false;
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
                self.queueSecondResponse(2, &[_]u8{self.status}, 10000);
            },
            0x0E => { // Setmode
                self.mode = self.parameter_fifo[0];
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
            },
            0x10 => { // GetlocL
                const resp = [_]u8{
                    self.current_pos.m,
                    self.current_pos.s,
                    self.current_pos.f,
                    0, // Mode (Form 1)
                    0, // Track
                    0, 0, 0, // Extra info
                };
                self.scheduleResponse(3, &resp, 1000);
            },
            0x15 => { // SeekL
                self.is_reading = false;
                self.status &= ~@as(u8, 0x20);
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
                self.queueSecondResponse(2, &[_]u8{self.status}, 20000);
            },
            0x19 => { // Test
                const sub_cmd = self.parameter_fifo[0];
                if (sub_cmd == 0x20) { // Get version
                    self.scheduleResponse(3, &[_]u8{ 0x94, 0x09, 0x19, 0xC0 }, 1000);
                } else {
                    self.scheduleResponse(3, &[_]u8{self.status}, 1000);
                }
            },
            else => {
                std.log.warn("Unhandled CD-ROM command: 0x{X:0>2}", .{cmd});
                self.scheduleResponse(3, &[_]u8{self.status}, 1000);
            },
        }
        self.parameter_len = 0;
    }

    fn scheduleResponse(self: *CdRom, irq: u8, resp: []const u8, delay: i64) void {
        self.pending_irq = irq;
        @memcpy(self.pending_response[0..resp.len], resp);
        self.pending_response_len = resp.len;
        self.cycles_until_irq = delay;
    }

    fn queueSecondResponse(self: *CdRom, irq: u8, resp: []const u8, delay: i64) void {
        self.next_pending_irq = irq;
        @memcpy(self.next_pending_response[0..resp.len], resp);
        self.next_pending_response_len = resp.len;
        self.cycles_until_next_irq = delay;
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
};
