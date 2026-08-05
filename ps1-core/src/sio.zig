const std = @import("std");

pub const Sio = struct {
    const Self = @This();

    /// Instructions between a byte being clocked out and /ACK raising IRQ7.
    ///
    /// This deferral is load-bearing, not cosmetic. The BIOS pad routine (in RAM
    /// at ~0x4548) does, per byte:
    ///
    ///     sb   byte, JOY_TX        ; clock the byte out
    ///     jal  delay(20)           ; ~140 instructions
    ///     sh   ctrl|0x10, JOY_CTRL ; Acknowledge — clears the port's IRQ
    ///     sw   0xFFFFFF7F, I_STAT  ; clear IRQ7 in the interrupt controller
    ///     ...poll I_STAT bit 7, up to 81 times (~730 instructions), else abort
    ///
    /// So /ACK must land *after* the routine has cleared both flags and *before*
    /// its timeout — raise it synchronously from the TX write and the routine's
    /// own acknowledge swallows it, then it times out, deselects, and reports no
    /// controller. avocado uses `irqTimer = 5` (controller.cpp:29) ticked once
    /// per `System::emulateFrame` iteration, and each iteration runs 100
    /// instructions (`executeInstructions(systemCycles / 3)`, systemCycles=300) —
    /// i.e. ~500 instructions, which is what this constant reproduces given our
    /// per-`Cpu.step()` tick.
    const ack_delay: u32 = 500;

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
    /// /ACK (DSR) input level, surfaced as JOY_STAT bit 7. The addressed
    /// peripheral pulls /ACK low after every byte it intends to follow up on;
    /// software reads this to decide whether to keep clocking the transfer.
    /// Mirrors avocado's `AbstractDevice::getAck() { return state != 0; }`
    /// plus the read-clears behaviour in `Controller::read` (controller.cpp:91).
    ack: bool = false,
    /// Interrupt request line, surfaced as JOY_STAT bit 9 and IRQ7.
    irq: bool = false,
    /// Countdown, in `step()` calls, from a byte being clocked out to /ACK
    /// pulling the interrupt line low. See `ack_delay`.
    irq_timer: u32 = 0,
    buttons: u16 = 0xFFFF, // 0 = pressed, 1 = released
    /// False = digital pad (ID 0x41, two button bytes); true = DualShock
    /// (ID 0x73, plus four stick axes). Nothing flips this yet — the analog
    /// escape commands aren't implemented — so the pad behaves as a plain
    /// digital controller, which every title supports.
    analog_enabled: bool = false,

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
            0x4 => blk: { // STAT    (0x1F801044)
                const data = self.stat |
                    (@as(u32, @intFromBool(self.ack)) << 7) |
                    (@as(u32, @intFromBool(self.irq)) << 9);
                self.ack = false; // /ACK is a level that reads as a one-shot
                break :blk data;
            },
            0x8 => self.mode, // MODE    (0x1F801048)
            0xA => self.ctrl, // CTRL    (0x1F80104A)
            0xE => self.baud, // BAUD    (0x1F80104E)
            else => 0,
        };
    }

    pub fn write(self: *Self, offset: u32, value: u32) void {
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
                            // A pad powers up in digital mode and only reports
                            // the DualShock ID once analog mode has been enabled
                            // (escape command 0x43/0x44, not implemented here).
                            // avocado does the same: `analogEnabled ? 0x73 : 0x41`
                            // with analog off by default (analog_controller.cpp:32).
                            // Claiming 0x73 unconditionally makes pre-DualShock
                            // titles parse a 6-byte analog packet they don't expect.
                            self.rx_data = if (self.analog_enabled) 0x73 else 0x41;
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
                        // A digital pad's packet ends here; only an analog pad
                        // follows the two button bytes with the four stick axes.
                        self.ctrl_state = if (self.analog_enabled) .CtrlJoyRightX else .Idle;
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

                // A peripheral holds /ACK asserted for as long as it is mid-sequence
                // and expects another byte; landing back on .Idle means either the
                // transfer finished or nothing responded to the command.
                self.ack = self.ctrl_state != .Idle;
                if (self.ack) self.irq_timer = ack_delay;

                self.stat |= 0x02; // RX FIFO not empty
            },
            0x4 => {}, // STAT is Read-Only!
            0x8 => self.mode = value & 0x3F,
            0xA => { // CTRL
                self.ctrl = value;

                // Command Acknowledge (Bit 4)
                if ((value & (1 << 4)) != 0) {
                    self.irq = false; // Clear SIO interrupt request flag
                }

                // Deselecting the port (/JOYn Output, bit 1) drops the chip
                // select line, which resets every peripheral's transfer state.
                // Without this the state machine leaks across polls: a routine
                // that stops early, or alternates between slots, re-enters
                // mid-sequence and desynchronises permanently.
                // (avocado controller.cpp:121-126)
                if ((value & (1 << 1)) == 0) {
                    self.ctrl_state = .Idle;
                }

                // SIO Reset (Bit 6)
                if ((value & (1 << 6)) != 0) {
                    self.stat = 0x05;
                    self.mode = 0;
                    self.ctrl = 0;
                    self.baud = 0;
                    self.rx_data = 0xFF;
                    self.ctrl_state = .Idle;
                    self.ack = false;
                    self.irq = false;
                    self.irq_timer = 0;
                }
            },
            0xE => self.baud = value,
            else => {},
        }
    }

    /// Advances the /ACK deferral. Called once per `Cpu.step()`; returns true
    /// while the controller port is asserting IRQ7 (level, like every other
    /// device here — software clears it via JOY_CTRL bit 4).
    pub fn step(self: *Self) bool {
        if (self.irq_timer > 0) {
            self.irq_timer -= 1;
            if (self.irq_timer == 0) {
                self.irq = true;
                self.ack = false;
            }
        }
        return self.irq;
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
