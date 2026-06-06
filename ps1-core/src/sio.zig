const std = @import("std");

pub const Sio = struct {
    const Self = @This();

    pub const SioState = enum {
        Idle,
        AwaitingCmd,
        
        // Controller
        CtrlAwaitingTap,
        CtrlSendingButtonsLow,
        CtrlSendingButtonsHigh,
        CtrlJoyRightX,
        CtrlJoyRightY,
        CtrlJoyLeftX,
        CtrlJoyLeftY,

        // Memory Card
        MemcardAck,
        MemcardAddressMsb,
        MemcardAddressLsb,
        MemcardReadAck1,
        MemcardReadAck2,
        MemcardReadConfirmAddressMsb,
        MemcardReadConfirmAddressLsb,
        MemcardReadData,
        MemcardReadChecksum,
        MemcardReadGood,

        MemcardWriteData,
        MemcardWriteChecksum,
        MemcardWriteAck1,
        MemcardWriteAck2,
        MemcardWriteGood,
    };

    // Registers
    stat: u32 = 0x05, // Starts with TX Ready (bit 0) and TX Empty (bit 2) set
    mode: u32 = 0,
    ctrl: u32 = 0,
    baud: u32 = 0,

    // Communication state
    rx_data: u8 = 0xFF,
    ctrl_state: SioState = .Idle,
    buttons: u16 = 0xFFFF, // 0 = pressed, 1 = released
    
    // Analog Joy values (128 = center)
    joy_rx: u8 = 128,
    joy_ry: u8 = 128,
    joy_lx: u8 = 128,
    joy_ly: u8 = 128,

    // Rumble values
    motor_right_small: u8 = 0,
    motor_left_large: u8 = 0,

    // Memory Card State
    memcard_data: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024),
    memcard_address: u16 = 0,
    memcard_checksum: u8 = 0,
    memcard_step: u32 = 0,
    memcard_is_write: bool = false,
    memcard_dirty: bool = false,

    pub fn init() Self {
        return .{};
    }

    pub fn read(self: *Self, offset: u32) u32 {
        return switch (offset) {
            0x0 => blk: { // RX_DATA (0x1F801040)
                const data = self.rx_data;
                self.stat &= ~@as(u32, 0x02);
                break :blk data;
            },
            0x4 => self.stat, // STAT    (0x1F801044)
            0x8 => self.mode, // MODE    (0x1F801048)
            0xA => self.ctrl, // CTRL    (0x1F80104A)
            0xE => self.baud, // BAUD    (0x1F80104E)
            else => 0,
        };
    }

    pub fn write(self: *Self, offset: u32, value: u32) bool {
        switch (offset) {
            0x0 => { // TX_DATA (0x1F801040)
                const tx: u8 = @truncate(value);
                self.rx_data = 0xFF;

                switch (self.ctrl_state) {
                    .Idle => {
                        if (tx == 0x01) {
                            self.ctrl_state = .AwaitingCmd;
                        }
                    },
                    .AwaitingCmd => {
                        if (tx == 0x42) { // Read Controller
                            self.rx_data = 0x73; // Analog Controller ID (DualShock)
                            self.ctrl_state = .CtrlAwaitingTap;
                        } else if (tx == 0x81) { // Read Memory Card
                            self.rx_data = 0x5A;
                            self.memcard_is_write = false;
                            self.ctrl_state = .MemcardAck;
                        } else if (tx == 0x82) { // Write Memory Card
                            self.rx_data = 0x5A;
                            self.memcard_is_write = true;
                            self.ctrl_state = .MemcardAck;
                        } else {
                            self.ctrl_state = .Idle;
                        }
                    },
                    // --- CONTROLLER ---
                    .CtrlAwaitingTap => {
                        self.rx_data = 0x5A; // Controller acknowledge
                        self.ctrl_state = .CtrlSendingButtonsLow;
                    },
                    .CtrlSendingButtonsLow => {
                        self.rx_data = @truncate(self.buttons & 0x00FF);
                        self.ctrl_state = .CtrlSendingButtonsHigh;
                    },
                    .CtrlSendingButtonsHigh => {
                        self.rx_data = @truncate(self.buttons >> 8);
                        self.ctrl_state = .CtrlJoyRightX;
                    },
                    .CtrlJoyRightX => {
                        self.rx_data = self.joy_rx;
                        self.motor_right_small = tx; // Read motor rumble command from TX
                        self.ctrl_state = .CtrlJoyRightY;
                    },
                    .CtrlJoyRightY => {
                        self.rx_data = self.joy_ry;
                        self.motor_left_large = tx; // Read motor rumble command from TX
                        self.ctrl_state = .CtrlJoyLeftX;
                    },
                    .CtrlJoyLeftX => {
                        self.rx_data = self.joy_lx;
                        self.ctrl_state = .CtrlJoyLeftY;
                    },
                    .CtrlJoyLeftY => {
                        self.rx_data = self.joy_ly;
                        self.ctrl_state = .Idle;
                    },
                    // --- MEMORY CARD ---
                    .MemcardAck => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardAddressMsb;
                    },
                    .MemcardAddressMsb => {
                        self.rx_data = 0x00;
                        self.memcard_address = @as(u16, tx) << 8;
                        self.ctrl_state = .MemcardAddressLsb;
                    },
                    .MemcardAddressLsb => {
                        self.rx_data = 0x00;
                        self.memcard_address |= tx;
                        self.memcard_checksum = @truncate(self.memcard_address >> 8);
                        self.memcard_checksum ^= @truncate(self.memcard_address & 0xFF);
                        
                        if (self.memcard_is_write) {
                            self.memcard_step = 0;
                            self.ctrl_state = .MemcardWriteData;
                        } else {
                            self.ctrl_state = .MemcardReadAck1;
                        }
                    },
                    .MemcardReadAck1 => {
                        self.rx_data = 0x5C;
                        self.ctrl_state = .MemcardReadAck2;
                    },
                    .MemcardReadAck2 => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardReadConfirmAddressMsb;
                    },
                    .MemcardReadConfirmAddressMsb => {
                        self.rx_data = @truncate(self.memcard_address >> 8);
                        self.ctrl_state = .MemcardReadConfirmAddressLsb;
                    },
                    .MemcardReadConfirmAddressLsb => {
                        self.rx_data = @truncate(self.memcard_address & 0xFF);
                        self.memcard_step = 0;
                        self.ctrl_state = .MemcardReadData;
                    },
                    .MemcardReadData => {
                        const addr = (self.memcard_address & 0x3FF) * 128 + self.memcard_step;
                        const data = self.memcard_data[addr];
                        self.rx_data = data;
                        self.memcard_checksum ^= data;
                        self.memcard_step += 1;
                        if (self.memcard_step == 128) {
                            self.ctrl_state = .MemcardReadChecksum;
                        }
                    },
                    .MemcardReadChecksum => {
                        self.rx_data = self.memcard_checksum;
                        self.ctrl_state = .MemcardReadGood;
                    },
                    .MemcardReadGood => {
                        self.rx_data = 'G';
                        self.ctrl_state = .Idle;
                    },
                    .MemcardWriteData => {
                        self.rx_data = 0x00;
                        const addr = (self.memcard_address & 0x3FF) * 128 + self.memcard_step;
                        self.memcard_data[addr] = tx;
                        self.memcard_checksum ^= tx;
                        self.memcard_step += 1;
                        if (self.memcard_step == 128) {
                            self.ctrl_state = .MemcardWriteChecksum;
                        }
                    },
                    .MemcardWriteChecksum => {
                        self.rx_data = 0x00;
                        if (tx == self.memcard_checksum) {
                            self.memcard_dirty = true;
                        }
                        self.ctrl_state = .MemcardWriteAck1;
                    },
                    .MemcardWriteAck1 => {
                        self.rx_data = 0x5C;
                        self.ctrl_state = .MemcardWriteAck2;
                    },
                    .MemcardWriteAck2 => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardWriteGood;
                    },
                    .MemcardWriteGood => {
                        self.rx_data = 'G';
                        self.ctrl_state = .Idle;
                    },
                }

                self.stat |= 0x02; // RX FIFO not empty
                self.stat |= 0x200; // SIO interrupt request flag; raises IRQ7 on I_STAT
                return true;
            },
            0x4 => {}, // STAT is Read-Only!
            0x8 => self.mode = value & 0x3F,
            0xA => { // CTRL
                self.ctrl = value;

                // Command Acknowledge (Bit 4)
                if ((value & (1 << 4)) != 0) {
                    // Writing 1 to bit 4 resets the interrupt bits in STAT
                    self.stat &= ~@as(u32, 0x200); // Clear SIO interrupt request flag
                }

                // SIO Reset (Bit 6)
                if ((value & (1 << 6)) != 0) {
                    self.stat = 0x05;
                    self.mode = 0;
                    self.ctrl = 0;
                    self.baud = 0;
                    self.rx_data = 0xFF;
                    self.ctrl_state = .Idle;
                }
            },
            0xE => self.baud = value,
            else => {},
        }

        return false;
    }

    pub fn setButtons(self: *Self, buttons: u16) void {
        self.buttons = buttons;
    }

    pub fn setAnalogInputs(self: *Self, rx: u8, ry: u8, lx: u8, ly: u8) void {
        self.joy_rx = rx;
        self.joy_ry = ry;
        self.joy_lx = lx;
        self.joy_ly = ly;
    }

    pub fn getMemoryCardData(self: *Self) []u8 {
        return &self.memcard_data;
    }

    pub fn isMemoryCardDirty(self: *Self) bool {
        return self.memcard_dirty;
    }

    pub fn clearMemoryCardDirty(self: *Self) void {
        self.memcard_dirty = false;
    }
};
