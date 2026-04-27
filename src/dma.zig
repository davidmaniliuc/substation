const std = @import("std");

pub const Channel = struct {
    base_addr: u32 = 0, // MADR (Memory Address)
    block_control: u32 = 0, // BCR  (Block Control)
    control: u32 = 0, // CHCR (Channel Control)

    pub fn read(self: *const Channel, offset: u32) u32 {
        return switch (offset) {
            0x0 => self.base_addr,
            0x4 => self.block_control,
            0x8 => self.control,
            else => unreachable,
        };
    }

    pub fn write(self: *Channel, offset: u32, value: u32) void {
        switch (offset) {
            0x0 => self.base_addr = value & 0x00FFFFFF, // 24-bit address
            0x4 => self.block_control = value,
            0x8 => {
                self.control = value;
                // TODO: Check if bit 24 is 1. If so, a DMA transfer just started!
                if ((value & (1 << 24)) != 0) {
                    std.debug.print("DMA Transfer started!\n", .{});
                }
            },
            else => unreachable,
        }
    }
};

pub const Dma = struct {
    const Self = @This();

    channels: [7]Channel = [_]Channel{.{}} ** 7,

    dpcr: u32 = 0x07654321, // DMA Control Register (Reset value)
    dicr: u32 = 0, // DMA Interrupt Register

    pub fn init() Self {
        return .{};
    }

    pub fn read(self: *const Self, offset: u32) u32 {
        const channel_idx = (offset >> 4) & 0x7;

        if (offset < 0x70) {
            return self.channels[channel_idx].read(offset & 0xF);
        }

        return switch (offset) {
            0x70 => self.dpcr,
            0x74 => self.dicr,
            else => {
                std.log.warn("Unhandled DMA read at offset 0x{X:0>2}", .{offset});
                return 0;
            },
        };
    }

    pub fn write(self: *Self, offset: u32, value: u32) void {
        const channel_idx = (offset >> 4) & 0x7;

        if (offset < 0x70) {
            self.channels[channel_idx].write(offset & 0xF, value);
            return;
        }

        switch (offset) {
            0x70 => self.dpcr = value,
            0x74 => {
                // DICR is tricky. Bits 0-14 and 16-22 are R/W.
                // Bits 24-30 are flags that are cleared by writing a 1.
                // For now, just a basic write is fine to get the BIOS to boot.
                self.dicr = value;
            },
            else => std.log.warn("Unhandled DMA write at offset 0x{X:0>2}", .{offset}),
        }
    }

    pub fn step(self: *Self) void {
        // Check all 7 channels to see if any are active
        for (0..7) |i| {
            const channel = &self.channels[i];

            // Bit 24 of CHCR is the "Start/Busy" bit.
            // If it's 0, this channel isn't doing anything.
            if ((channel.control & (1 << 24)) == 0) continue;

            // In a real emulator, we would loop and transfer words here based on MADR and BCR.
            // For now, we will just instantly finish the transfer so the BIOS can continue!
            switch (i) {
                2 => std.debug.print("[DMA] Executing GPU Transfer (Channel 2)...\n", .{}),
                6 => std.debug.print("[DMA] Executing OTC Transfer (Channel 6)...\n", .{}),
                else => std.debug.print("[DMA] Executing Transfer on Channel {}...\n", .{i}),
            }

            // Transfer is "done", so clear the Start/Busy bit!
            // This is CRITICAL. If we don't clear this, the BIOS waits forever.
            channel.control &= ~@as(u32, 1 << 24);

            // TODO: Update DICR to trigger a DMA interrupt (if enabled)
        }
    }
};
