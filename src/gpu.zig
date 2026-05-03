const std = @import("std");

pub const Gpu = struct {
    const Self = @This();

    // GP0: Data / Command
    // GP1: Control / Status

    status: u32 = 0x1C000000, // Initial status (Ready for commands/DMA)

    pub fn init() Self {
        return .{};
    }

    pub fn readStatus(self: *const Self) u32 {
        return self.status;
    }

    pub fn readData(self: *const Self) u32 {
        _ = self;
        // GP0 read is usually for responses to certain commands
        return 0;
    }

    pub fn writeGp0(self: *Self, value: u32) void {
        // Handle GPU commands (not implemented yet)
        _ = self;
        _ = value;
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
                // std.log.warn("Unhandled GP1 command: 0x{X:0>2}", .{command});
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
