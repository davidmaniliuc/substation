const std = @import("std");

pub const Gpu = struct {
    const Self = @This();

    // GP0: Data / Command
    // GP1: Control / Status

    status: u32 = 0x1C000000, // Initial status (Ready for commands/DMA)

    // 1024 pixels wide * 512 pixels high.
    // PS1 uses 16-bit colors: 1 bit for transparency, 5 bits each for R, G, B.
    vram: [1024 * 512]u16 = [_]u16{0} ** (1024 * 512),

    // GP0 command buffering / state machine
    gp0_cmd_buffer: [16]u32 = [_]u32{0} ** 16,
    gp0_words_remaining: usize = 0,
    gp0_words_read: usize = 0,

    // Data transfer (CPU -> VRAM) streaming state
    vram_transfer_active: bool = false,
    vram_transfer_x: usize = 0,
    vram_transfer_y: usize = 0,
    vram_transfer_w: usize = 0,
    vram_transfer_h: usize = 0,
    vram_transfer_curr_x: usize = 0,
    vram_transfer_curr_y: usize = 0,
    vram_transfer_remaining: usize = 0, // number of u32 data words remaining

    // Environment registers (E1-E6)
    env_regs: [6]u32 = [_]u32{0} ** 6,

    pub fn init() Self {
        return .{};
    }

    // Provide a way for frontends to grab the framebuffer!
    pub fn getVramPtr(self: *Self) [*]const u16 {
        return &self.vram[0];
    }

    pub fn readStatus(self: *const Self) u32 {
        return self.status;
    }

    pub fn readData(self: *const Self) u32 {
        _ = self;
        // GP0 read is usually for responses to certain commands
        return 0;
    }

    // Start/continue GP0 command buffering and execute when complete
    pub fn writeGp0(self: *Self, value: u32) void {
        // If a VRAM transfer is active, stream data directly into VRAM
        if (self.vram_transfer_active) {
            self.writeVramData(value);
            return;
        }

        if (self.gp0_words_remaining == 0) {
            // Start of a new command
            const opcode = @intCast(u8, (value >> 24) & 0xFF);
            const length = self.getCommandLength(opcode);

            self.gp0_cmd_buffer[0] = value;
            self.gp0_words_read = 1;
            self.gp0_words_remaining = if (length > 0) length - 1 else 0;
        } else {
            // Continue buffering
            if (self.gp0_words_read < self.gp0_cmd_buffer.len) {
                self.gp0_cmd_buffer[self.gp0_words_read] = value;
            }
            self.gp0_words_read += 1;
            if (self.gp0_words_remaining > 0) self.gp0_words_remaining -= 1;
        }

        // Execute if we have all the words
        if (self.gp0_words_remaining == 0) {
            self.executeGp0Command();
        }
    }

    fn getCommandLength(self: *Self, opcode: u8) usize {
        // Treat A0 as a 3-word header (opcode + coord + size); payload is streamed
        return switch (opcode) {
            0x00 => 1, // NOP
            0x02 => 3, // Fill Rectangle
            0xA0 => 3, // CPU -> VRAM (header only)
            0xE1..=0xE6 => 1, // Environment settings
            else => 1, // Default: treat as single-word command
        };
    }

    fn executeGp0Command(self: *Self) void {
        const opcode = @intCast(u8, (self.gp0_cmd_buffer[0] >> 24) & 0xFF);

        switch (opcode) {
            0x00 => {
                // NOP: do nothing
            },

            // Environment settings 0xE1 - 0xE6: save to env_regs
            0xE1..=0xE6 => {
                const idx = @intCast(usize, opcode - 0xE1);
                if (idx < self.env_regs.len) self.env_regs[idx] = self.gp0_cmd_buffer[0];
            },

            // Fill rectangle: expects 3 words: [opcode|color], [x+y], [w+h]
            0x02 => {
                const color = @intCast(u16, self.gp0_cmd_buffer[0] & 0xFFFF);
                const word1 = self.gp0_cmd_buffer[1];
                const x = @intCast(usize, word1 & 0x3FF);
                const y = @intCast(usize, (word1 >> 10) & 0x1FF);
                const word2 = self.gp0_cmd_buffer[2];
                const w = @intCast(usize, word2 & 0x3FF);
                const h = @intCast(usize, (word2 >> 10) & 0x3FF);

                // Clamp to VRAM bounds and write pixels
                const max_w = 1024;
                const max_h = 512;
                var yy: usize = 0;
                while (yy < h) : (yy += 1) {
                    var xx: usize = 0;
                    while (xx < w) : (xx += 1) {
                        const px = x + xx;
                        const py = y + yy;
                        if (px < max_w and py < max_h) {
                            const idx = py * max_w + px;
                            self.vram[idx] = color;
                        }
                    }
                }
            },

            // CPU -> VRAM: header-only here — initialize streaming state
            0xA0 => {
                // Header: [opcode], [x:y packed], [w:h packed]
                const word1 = self.gp0_cmd_buffer[1];
                const x = @intCast(usize, word1 & 0x3FF);
                const y = @intCast(usize, (word1 >> 10) & 0x1FF);
                const word2 = self.gp0_cmd_buffer[2];
                var w = @intCast(usize, word2 & 0x3FF);
                var h = @intCast(usize, (word2 >> 10) & 0x3FF);

                // Hardware quirk: 0 width or height may mean full width/height
                if (w == 0) w = 1024;
                if (h == 0) h = 512;

                self.vram_transfer_x = x;
                self.vram_transfer_y = y;
                self.vram_transfer_w = w;
                self.vram_transfer_h = h;
                self.vram_transfer_curr_x = 0;
                self.vram_transfer_curr_y = 0;

                const pixels = w * h;
                // two pixels per u32 word
                self.vram_transfer_remaining = (pixels + 1) / 2;
                if (self.vram_transfer_remaining > 0) self.vram_transfer_active = true;
            },

            else => {
                std.debug.print("Unhandled GP0 opcode: 0x{X}\n", .{opcode});
            },
        }

        // Reset buffering state (payload for A0 will be streamed via writeGp0)
        self.gp0_words_remaining = 0;
        self.gp0_words_read = 0;
    }

    // Stream a single u32 of pixel data into VRAM (two 16-bit pixels)
    fn writeVramData(self: *Self, value: u32) void {
        if (!self.vram_transfer_active) return;

        const low = @intCast(u16, value & 0xFFFF);
        const high = @intCast(u16, (value >> 16) & 0xFFFF);

        // Helper to write one pixel and advance coordinates
        inline fn write_pixel(self: *Self, pix: u16) void {
            const px = self.vram_transfer_x + self.vram_transfer_curr_x;
            const py = self.vram_transfer_y + self.vram_transfer_curr_y;
            if (px < 1024 and py < 512) {
                const idx = py * 1024 + px;
                self.vram[idx] = pix;
            }
            self.vram_transfer_curr_x += 1;
            if (self.vram_transfer_curr_x >= self.vram_transfer_w) {
                self.vram_transfer_curr_x = 0;
                self.vram_transfer_curr_y += 1;
            }
        }

        // Write low pixel
        if (self.vram_transfer_remaining == 0) return; // nothing expected
        write_pixel(self, low);

        // If the transfer had an odd number of pixels and this is the final u32,
        // the high half may be padding; still safe to write if within bounds.
        // Only write high pixel if there are still pixels remaining after consuming low
        const pixels_left_after_low = (self.vram_transfer_remaining * 2) - 1 - (self.vram_transfer_curr_y * self.vram_transfer_w + self.vram_transfer_curr_x);
        // Simpler: write high iff we still haven't filled all pixels
        if ((self.vram_transfer_curr_y * self.vram_transfer_w + self.vram_transfer_curr_x) < (self.vram_transfer_w * self.vram_transfer_h)) {
            write_pixel(self, high);
        }

        // One u32 consumed
        if (self.vram_transfer_remaining > 0) self.vram_transfer_remaining -= 1;
        if (self.vram_transfer_remaining == 0) self.vram_transfer_active = false;
    }

    pub fn writeGp1(self: *Self, value: u32) void {
        // Handle GPU control commands
        const command = (value >> 24) & 0xFF;

        switch (command) {
            0x00 => {
                // Reset GPU
                self.status = 0x1C000000;
            },
            else => {
                // unhandled: silently ignore for now
                _ = command;
            },
        }
    }

    pub fn step(self: *Self, cycles: u64) void {
        // Update VBlank bit in status based on cycle count
        // Assuming ~33.8MHz, 60fps is ~563333 cycles per frame
        // VBlank is usually active for a portion of the frame
        const frame_cycles = 563333;
        const vblank_start = 500000; // Rough estimate

        const current_cycle = cycles % frame_cycles;

        if (current_cycle >= vblank_start) {
            self.status |= (1 << 31); // Set Vertical Retrace bit
        } else {
            self.status &= ~@as(u32, 1 << 31);
        }
    }
};
