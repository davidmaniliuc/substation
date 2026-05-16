const std = @import("std");

pub const CdRom = struct {
    index: u2 = 0,

    // Interrupts
    irq_flag: u8 = 0,
    irq_enable: u8 = 0,

    // FIFOs
    response_fifo: [16]u8 = [_]u8{0} ** 16,
    response_ptr: usize = 0,
    response_len: usize = 0,

    pub fn init() CdRom {
        return .{};
    }

    pub fn read(self: *CdRom, offset: u32) u8 {
        return switch (offset) {
            0 => self.getStatus(),
            1 => self.readResponse(),
            2 => 0, // Data FIFO (unimplemented)
            3 => switch (self.index) {
                0 => self.irq_enable,
                1 => self.irq_flag,
                else => 0,
            },
            else => 0,
        };
    }

    pub fn write(self: *CdRom, offset: u32, value: u8) void {
        switch (offset) {
            0 => self.index = @truncate(value & 3),
            1 => self.executeCommand(value),
            2 => {}, // Parameter FIFO (unimplemented)
            3 => switch (self.index) {
                1 => {
                    // Acknowledge interrupts by writing 1s to them.
                    self.irq_flag &= ~value;
                },
                else => {},
            },
            else => {},
        }
    }

    fn getStatus(self: *const CdRom) u8 {
        var stat: u8 = 0x18;
        stat |= @as(u8, self.index);
        if (self.response_len > 0) stat |= (1 << 5); // Response FIFO not empty
        return stat;
    }

    fn readResponse(self: *CdRom) u8 {
        if (self.response_len == 0) return 0;

        const val = self.response_fifo[self.response_ptr];
        self.response_ptr = (self.response_ptr + 1) % 16;
        self.response_len -= 1;
        return val;
    }

    fn executeCommand(self: *CdRom, cmd: u8) void {
        self.response_len = 0;
        self.response_ptr = 0;

        switch (cmd) {
            0x01 => { // GetStat
                self.pushResponse(0x02); // Motor on
                self.fireIrq(3); // IRQ3 = command acknowledge
            },
            0x19 => { // Test (Get version info)
                self.pushResponse(0x94);
                self.pushResponse(0x09);
                self.pushResponse(0x19);
                self.pushResponse(0xC0);
                self.fireIrq(3);
            },
            else => {
                self.pushResponse(0x02);
                self.fireIrq(3);
            },
        }
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
