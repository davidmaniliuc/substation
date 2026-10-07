//! The controller in port 1: a DualShock, which powers up as a plain digital
//! pad.
//!
//! A packet is the command byte and up to seven more. The pad decides its
//! whole reply when the command byte arrives (`begin`) and then clocks it out
//! one byte per exchange (`transfer`), recording what the console sent beside
//! it: a later byte's effect can depend on an earlier one, and a reply byte
//! can be rewritten by the byte that arrives with it.

const std = @import("std");

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
            0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x4C, 0x4D => true,
            else => false,
        };
    }

    /// Called on the command byte. Builds the reply and says whether the pad
    /// answers at all: a pad that does not leaves the port with nobody
    /// listening, which software reads as no /ACK.
    pub fn begin(self: *Self, cmd: u8) bool {
        const answers = switch (cmd) {
            0x42, 0x43 => true,
            0x44, 0x45, 0x46, 0x47, 0x4C, 0x4D => self.config,
            else => false,
        };
        if (!answers) return false;
        self.command = cmd;
        self.step = 0;
        // Config mode reports three halfwords whatever the analog flag says.
        self.len = if (self.config or self.analog) 8 else 4;
        self.rx = @splat(0);
        self.tx = .{ self.id(), self.status, 0, 0, 0, 0, 0, 0 };
        switch (cmd) {
            0x42 => self.fillRead(),
            // Outside config mode, entering it is answered as a read.
            0x43 => if (!self.config) self.fillRead(),
            0x44 => self.resetRumble(),
            0x45 => self.tx[2..8].* = .{ 0x01, 0x02, @intFromBool(self.analog), 0x02, 0x01, 0x00 },
            0x47 => self.tx[2..8].* = .{ 0x00, 0x00, 0x02, 0x00, 0x01, 0x00 },
            else => {},
        }
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
        switch (self.command) {
            // Config mode changes at the packet's END, so a packet abandoned
            // part-way changes nothing.
            0x42 => self.driveRumble(s, byte_in),
            0x43 => if (s == self.len - 1) self.setConfig(self.rx[2] == 0x01),
            0x44 => switch (s) {
                2 => if (byte_in <= 0x01) {
                    self.analog = byte_in == 0x01;
                },
                3 => if (byte_in == 0x02 or byte_in == 0x03) {
                    self.locked = byte_in == 0x03;
                },
                else => {},
            },
            0x46 => if (s == 2) switch (byte_in) {
                0x00 => self.tx[4..8].* = .{ 0x01, 0x02, 0x00, 0x0A },
                0x01 => self.tx[4..8].* = .{ 0x01, 0x01, 0x01, 0x14 },
                else => {},
            },
            0x47 => if (s == 2 and byte_in != 0x00) {
                self.tx[4..8].* = @splat(0);
            },
            0x4C => if (s == 2) switch (byte_in) {
                0x00 => self.tx[5] = 0x04,
                0x01 => self.tx[5] = 0x07,
                else => {},
            },
            0x4D => self.remapRumble(s, byte_in),
            else => {},
        }
        // Buttons and sticks are read as each byte goes out, so a frontend
        // update mid-packet reaches the bytes still to come.
        if (self.command == 0x42 and s >= 2) self.fillRead();
        // After the effect: a reply byte may be rewritten by the byte that
        // arrives with it.
        const out = self.tx[s];
        self.step += 1;
        return .{ .out = out, .more = self.step < self.len };
    }

    /// What a read's TX bytes do to the motors.
    fn driveRumble(self: *Self, s: u8, byte_in: u8) void {
        if (self.dualshock) {
            if (s < 2) return;
            switch (self.rumble_map[s - 2]) {
                0x00 => self.motor_small = if (byte_in != 0) 255 else 0,
                0x01 => self.motor_large = byte_in,
                else => {},
            }
        } else if (s == 3) {
            // The single-motor encoding of pads from before the DualShock.
            const on = (self.rx[2] & 0xC0) == 0x40 and (self.rx[3] & 0x01) != 0;
            self.motor_small = if (on) 255 else 0;
        }
    }

    /// Replies with the old map while taking the new one, then stops any
    /// motor the new map no longer reaches.
    fn remapRumble(self: *Self, s: u8, byte_in: u8) void {
        if (s >= 2) {
            self.tx[s] = self.rumble_map[s - 2];
            self.rumble_map[s - 2] = byte_in;
        }
        if (s == self.len - 1) {
            if (std.mem.indexOfScalar(u8, &self.rumble_map, 0x00) == null) self.motor_small = 0;
            if (std.mem.indexOfScalar(u8, &self.rumble_map, 0x01) == null) self.motor_large = 0;
        }
    }

    fn setConfig(self: *Self, on: bool) void {
        self.config = on;
        if (on) {
            self.dualshock = true;
            self.status = status_ok;
        }
    }

    /// The transfer state resets: packet end, deselect, SIO reset. A queued
    /// Analog-button press lands here, so a reply is never re-shaped mid-way.
    pub fn idle(self: *Self) void {
        if (self.toggle_queued) {
            self.toggle_queued = false;
            self.applyToggle();
        }
        self.command = 0;
        self.step = 0;
        self.len = 0;
    }

    /// Queued, not applied: see `idle`.
    pub fn pressAnalogButton(self: *Self) void {
        self.toggle_queued = true;
    }

    fn applyToggle(self: *Self) void {
        if (self.locked) return;
        self.analog = !self.analog;
        self.resetRumble();
        // How a game that has used config mode notices the change.
        if (self.dualshock) self.status = 0x00;
    }

    /// Every mode change unmaps both motors and stops them.
    fn resetRumble(self: *Self) void {
        self.rumble_map = @splat(0xFF);
        self.motor_small = 0;
        self.motor_large = 0;
    }

    pub fn setSticks(self: *Self, lx: u8, ly: u8, rx: u8, ry: u8) void {
        self.sticks = .{ rx, ry, lx, ly };
    }
};
