const std = @import("std");

pub const Sio = struct {
    const Self = @This();

    pub const ControllerState = enum {
        Idle,
        AwaitingCmd,
        AwaitingTap,
        SendingButtonsLow,
        SendingButtonsHigh,
    };

    // Registers
    stat: u32 = 0x05, // Starts with TX Ready (bit 0) and TX Empty (bit 2) set
    mode: u32 = 0,
    ctrl: u32 = 0,
    baud: u32 = 0,

    // Simple FIFO for testing (we'll expand this later)
    rx_data: u8 = 0xFF,
    ctrl_state: ControllerState = .Idle,
    buttons: u16 = 0xFFFF, // 0 = pressed, 1 = released

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
                        if (tx == 0x42) {
                            self.rx_data = 0x41; // Digital Pad ID
                            self.ctrl_state = .AwaitingTap;
                        } else {
                            self.ctrl_state = .Idle;
                        }
                    },
                    .AwaitingTap => {
                        self.rx_data = 0x5A; // Controller acknowledge
                        self.ctrl_state = .SendingButtonsLow;
                    },
                    .SendingButtonsLow => {
                        self.rx_data = @truncate(self.buttons & 0x00FF);
                        self.ctrl_state = .SendingButtonsHigh;
                    },
                    .SendingButtonsHigh => {
                        self.rx_data = @truncate(self.buttons >> 8);
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
};
