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
    /// controller. 500 ticks of `Sio.step()` is ~500 instructions, which lands
    /// inside that window: after the routine has cleared both flags, well
    /// before its ~730-instruction timeout.
    const ack_delay: u32 = 500;

    /// Pad ID byte returned as the first response to Read Controller (0x42).
    /// Digital pad: two button bytes follow. DualShock (analog): four stick
    /// axes follow the button bytes too — see `analog_enabled`.
    const digital_pad_id: u8 = 0x41;
    const dualshock_pad_id: u8 = 0x73;

    /// A Sony memory card block is 128 bytes; both the read and write command
    /// sequences step through one byte at a time.
    const memcard_sector_bytes = 128;
    /// MemcardAddressMsb/Lsb only carry a 10-bit block address.
    const memcard_address_mask = 0x3FF;
    /// The whole card: 1024 addressable blocks of 128 bytes.
    pub const memcard_bytes = memcard_sector_bytes * (memcard_address_mask + 1);

    /// FLAG, the byte the card returns on the command byte of every packet.
    /// Bit 3 ("fresh") tells software the directory has not been read since
    /// the card appeared, so it re-reads it rather than trusting a cache; bit
    /// 4 is documented only as always-set. Bit 2 is the error latch, raised by
    /// an out-of-range address or a failed checksum and cleared by the read.
    const memcard_flag_fresh: u8 = 0x08;
    const memcard_flag_unknown: u8 = 0x10;
    const memcard_flag_error: u8 = 0x04;

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
        MemcardCmd,
        MemcardAck1,
        MemcardAck2,
        MemcardAddressMsb,
        MemcardAddressLsb,

        MemcardReadAck1,
        MemcardReadAck2,
        MemcardReadConfirmMsb,
        MemcardReadConfirmLsb,
        MemcardReadData,
        MemcardReadChecksum,
        MemcardReadEnd,

        MemcardWriteData,
        MemcardWriteChecksum,
        MemcardWriteAck1,
        MemcardWriteAck2,
        MemcardWriteStatus,
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
    /// Asserted whenever the peripheral is mid-packet, and cleared by the
    /// read.
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
    memcard_data: [memcard_bytes]u8 = [_]u8{0} ** memcard_bytes,
    /// The 128 bytes of an in-flight write, held back until its checksum
    /// verifies. A rejected sector must not reach `memcard_data`: the image is
    /// persisted to disk, so a corrupt block written and then reported bad
    /// would outlive the session that produced it.
    memcard_staging: [memcard_sector_bytes]u8 = [_]u8{0} ** memcard_sector_bytes,
    memcard_address: u16 = 0,
    memcard_checksum: u8 = 0,
    memcard_step: u32 = 0,
    memcard_is_write: bool = false,
    memcard_dirty: bool = false,
    memcard_flag: u8 = memcard_flag_fresh | memcard_flag_unknown,
    /// What the write sequence will report in its final byte: 'G' good, 'N'
    /// bad checksum, 0xFF bad sector.
    memcard_status: u8 = 'G',

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
                        // The first byte of a packet ADDRESSES a peripheral:
                        // 0x01 the controller, 0x81 the memory card. Anything
                        // else leaves the port with nobody listening.
                        if (tx == 0x01) {
                            self.ctrl_state = .AwaitingCmd;
                        } else if (tx == 0x81) {
                            self.ctrl_state = .MemcardCmd;
                        }
                    },
                    .AwaitingCmd => {
                        if (tx == 0x42) { // Read Controller
                            // A pad powers up in digital mode and only reports
                            // the DualShock ID once analog mode has been enabled
                            // (escape command 0x43/0x44, not implemented here).
                            // Claiming 0x73 unconditionally makes pre-DualShock
                            // titles parse a 6-byte analog packet they don't expect.
                            self.rx_data = if (self.analog_enabled) dualshock_pad_id else digital_pad_id;
                            self.ctrl_state = .CtrlAwaitingTap;
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
                    .MemcardCmd => {
                        // The command byte is answered with FLAG, and reading
                        // it clears the error latch — the next packet reports
                        // only its own failures.
                        self.rx_data = self.memcard_flag;
                        self.memcard_flag &= ~memcard_flag_error;
                        if (tx == 'R') {
                            self.memcard_is_write = false;
                            self.ctrl_state = .MemcardAck1;
                        } else if (tx == 'W') {
                            self.memcard_is_write = true;
                            self.ctrl_state = .MemcardAck1;
                        } else {
                            // 'S' (get card ID) included: Avocado does not
                            // implement it either, and nothing is known to
                            // send it.
                            self.rx_data = 0xFF;
                            self.ctrl_state = .Idle;
                        }
                    },
                    .MemcardAck1 => {
                        self.rx_data = 0x5A;
                        self.ctrl_state = .MemcardAck2;
                    },
                    .MemcardAck2 => {
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

                        self.memcard_status = 'G';
                        if (self.memcard_address > memcard_address_mask) {
                            self.memcard_flag |= memcard_flag_error;
                            self.memcard_address &= memcard_address_mask;
                            self.memcard_status = 0xFF; // bad sector
                        }

                        self.memcard_step = 0;
                        if (self.memcard_is_write) {
                            self.memcard_checksum = @truncate(self.memcard_address >> 8);
                            self.memcard_checksum ^= @as(u8, @truncate(self.memcard_address & 0xFF));
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
                        self.ctrl_state = .MemcardReadConfirmMsb;
                    },
                    .MemcardReadConfirmMsb => {
                        // The read checksum starts from the ECHOED address
                        // bytes, not from the ones software sent: an address
                        // masked into range must be checksummed as it will be
                        // reported.
                        const msb: u8 = @truncate(self.memcard_address >> 8);
                        self.rx_data = msb;
                        self.memcard_checksum = msb;
                        self.ctrl_state = .MemcardReadConfirmLsb;
                    },
                    .MemcardReadConfirmLsb => {
                        const lsb: u8 = @truncate(self.memcard_address & 0xFF);
                        self.rx_data = lsb;
                        self.memcard_checksum ^= lsb;
                        self.memcard_step = 0;
                        self.ctrl_state = .MemcardReadData;
                    },
                    .MemcardReadData => {
                        const addr = self.memcard_address * memcard_sector_bytes + self.memcard_step;
                        const data = self.memcard_data[addr];
                        self.rx_data = data;
                        self.memcard_checksum ^= data;
                        self.memcard_step += 1;
                        if (self.memcard_step == memcard_sector_bytes) {
                            self.ctrl_state = .MemcardReadChecksum;
                        }
                    },
                    .MemcardReadChecksum => {
                        self.rx_data = self.memcard_checksum;
                        self.ctrl_state = .MemcardReadEnd;
                    },
                    .MemcardReadEnd => {
                        self.rx_data = 'G';
                        self.ctrl_state = .Idle;
                    },
                    .MemcardWriteData => {
                        self.rx_data = 0x00;
                        self.memcard_staging[self.memcard_step] = tx;
                        self.memcard_checksum ^= tx;
                        self.memcard_step += 1;
                        if (self.memcard_step == memcard_sector_bytes) {
                            self.ctrl_state = .MemcardWriteChecksum;
                        }
                    },
                    .MemcardWriteChecksum => {
                        self.rx_data = 0x00;
                        if (tx != self.memcard_checksum) {
                            self.memcard_flag |= memcard_flag_error;
                            self.memcard_status = 'N';
                        }
                        if (self.memcard_status == 'G') {
                            const base = self.memcard_address * memcard_sector_bytes;
                            @memcpy(self.memcard_data[base..][0..memcard_sector_bytes], &self.memcard_staging);
                            self.memcard_dirty = true;
                            self.memcard_flag &= ~memcard_flag_fresh;
                        }
                        self.ctrl_state = .MemcardWriteAck1;
                    },
                    .MemcardWriteAck1 => {
                        self.rx_data = 0x5C;
                        self.ctrl_state = .MemcardWriteAck2;
                    },
                    .MemcardWriteAck2 => {
                        self.rx_data = 0x5D;
                        self.ctrl_state = .MemcardWriteStatus;
                    },
                    .MemcardWriteStatus => {
                        self.rx_data = self.memcard_status;
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
