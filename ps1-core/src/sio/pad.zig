//! The controller in port 1: a DualShock, which powers up as a plain digital
//! pad.
//!
//! A packet is the command byte and up to seven more. The pad decides its
//! whole reply when the command byte arrives (`begin`) and then clocks it out
//! one byte per exchange (`transfer`), recording what the console sent beside
//! it: a later byte's effect can depend on an earlier one, and a reply byte
//! can be rewritten by the byte that arrives with it.

pub const Pad = struct {
    const Self = @This();

    /// The ID byte is `mode << 4 | halfwords after the 0x5A`.
    pub const id_digital: u8 = 0x41;
    pub const id_analog: u8 = 0x73;
    pub const id_config: u8 = 0xF3;
    /// The byte after the ID on every reply, until an Analog-button toggle
    /// clears it on a pad that has been in config mode.
    pub const status_ok: u8 = 0x5A;

    pub const Reply = struct { out: u8, more: bool };

    buttons: u16 = 0xFFFF, // 0 = pressed, 1 = released
    /// RX, RY, LX, LY: the order they go out on the wire. 0x80 is centre and
    /// Y grows downward.
    sticks: [4]u8 = @splat(0x80),
    analog: bool = false,
    config: bool = false,
    /// Set the first time a game enters config mode: from then on the
    /// rumble map, not the legacy encoding, decides what drives the motors.
    dualshock: bool = false,
    /// The game has locked the mode, so the Analog button does nothing.
    locked: bool = false,
    status: u8 = status_ok,
    /// Which motor each of TX bytes 2..7 of a read drives: 0x00 small,
    /// 0x01 large, anything else nothing.
    rumble_map: [6]u8 = @splat(0xFF),
    /// 0 or 255: the small motor has one speed.
    motor_small: u8 = 0,
    motor_large: u8 = 0,
    toggle_queued: bool = false,

    // The packet in flight. `len` is 0 between packets.
    command: u8 = 0,
    tx: [8]u8 = @splat(0),
    rx: [8]u8 = @splat(0),
    step: u8 = 0,
    len: u8 = 0,

    pub fn id(self: *const Self) u8 {
        if (self.config) return id_config;
        return if (self.analog) id_analog else id_digital;
    }

    /// Every command byte this pad can ever answer. Whether it answers one
    /// NOW also depends on config mode; see `begin`.
    pub fn isCommand(cmd: u8) bool {
        return switch (cmd) {
            0x42 => true,
            else => false,
        };
    }

    /// Called on the command byte. Builds the reply and says whether the pad
    /// answers at all: a pad that does not leaves the port with nobody
    /// listening, which software reads as no /ACK.
    pub fn begin(self: *Self, cmd: u8) bool {
        if (!isCommand(cmd)) return false;
        self.command = cmd;
        self.step = 0;
        self.len = if (self.config or self.analog) 8 else 4;
        self.rx = @splat(0);
        self.tx = .{ self.id(), self.status, 0, 0, 0, 0, 0, 0 };
        self.fillRead();
        return true;
    }

    /// The buttons, and in analog or config mode the four axes after them.
    fn fillRead(self: *Self) void {
        self.tx[2] = @truncate(self.buttons);
        self.tx[3] = @truncate(self.buttons >> 8);
        if (self.analog or self.config) self.tx[4..8].* = self.sticks;
    }

    /// One exchange: record what the console sent, apply its effect, and
    /// return the reply byte for this position. `more` is false on the
    /// packet's last byte, where the pad stops asserting /ACK.
    pub fn transfer(self: *Self, byte_in: u8) Reply {
        const s = self.step;
        self.rx[s] = byte_in;
        // Buttons and sticks are read as each byte goes out, so a frontend
        // update mid-packet reaches the bytes still to come.
        if (self.command == 0x42 and s >= 2) self.fillRead();
        const out = self.tx[s];
        self.step += 1;
        return .{ .out = out, .more = self.step < self.len };
    }

    /// The transfer state resets: packet end, deselect, SIO reset. A queued
    /// Analog-button press lands here, so a reply is never re-shaped mid-way.
    pub fn idle(self: *Self) void {
        self.command = 0;
        self.step = 0;
        self.len = 0;
    }

    pub fn setSticks(self: *Self, lx: u8, ly: u8, rx: u8, ry: u8) void {
        self.sticks = .{ rx, ry, lx, ly };
    }
};
