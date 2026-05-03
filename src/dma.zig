const std = @import("std");
const Bus = @import("memory.zig").Bus;

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
            0x8 => self.control = value,
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

    pub fn write(self: *Self, bus: *Bus, offset: u32, value: u32) void {
        const channel_idx = (offset >> 4) & 0x7;

        if (offset < 0x70) {
            self.channels[channel_idx].write(offset & 0xF, value);
            return;
        }

        switch (offset) {
            0x70 => self.dpcr = value,
            0x74 => {
                // Bits 0-23 are mostly R/W
                const rw_mask = 0x007FFFFF;
                const old_val = self.dicr;
                // Bits 24-30 are flags that are cleared by writing 1
                const clear_mask = (value >> 24) & 0x7F;
                const new_flags = ((old_val >> 24) & 0x7F) & ~clear_mask;

                self.dicr = (value & rw_mask) | (@as(u32, new_flags) << 24);
                self.updateDicr31(bus);
            },
            else => std.log.warn("Unhandled DMA write at offset 0x{X:0>2}", .{offset}),
        }
    }

    pub fn updateDicr31(self: *Self, bus: *Bus) void {
        const force_irq = (self.dicr >> 15) & 1;
        const irq_en = (self.dicr >> 16) & 0x7F;
        const irq_flags = (self.dicr >> 24) & 0x7F;

        const master_irq = force_irq == 1 or (irq_en & irq_flags) != 0;

        if (master_irq) {
            self.dicr |= (1 << 31);
            bus.i_stat |= (1 << 3); // DMA interrupt bit in I_STAT
        } else {
            self.dicr &= ~@as(u32, 1 << 31);
        }
    }

    pub fn step(self: *Self, bus: *Bus) void {
        for (0..7) |i| {
            const channel = &self.channels[i];

            // Bit 24 of CHCR is the "Start/Busy" bit.
            if ((channel.control & (1 << 24)) == 0) continue;

            // Check if DMA for this channel is enabled in DPCR
            const dpcr_channel_en = (self.dpcr >> @as(u5, @truncate(i * 4 + 3))) & 1;
            if (dpcr_channel_en == 0) continue;

            // Determine synchronization mode (0: Manual, 1: Request, 2: Linked List)
            const sync_mode = (channel.control >> 9) & 3;

            switch (sync_mode) {
                0 => {
                    if (i == 6) {
                        self.doOtc(bus);
                    } else {
                        self.doBlockCopy(bus, i);
                    }
                },
                1 => self.doBlockCopy(bus, i),
                2 => if (i == 2) self.doGpuLinkedList(bus) else std.log.warn("Linked List mode only supported on GPU (Channel 2)", .{}),
                else => std.log.warn("Unknown DMA sync mode: {}", .{sync_mode}),
            }

            // Transfer is "done", so clear the Start/Busy bit!
            channel.control &= ~@as(u32, 1 << 24);

            // Update DICR flags (bits 24-30)
            self.dicr |= (@as(u32, 1) << @as(u5, @truncate(24 + i)));
            self.updateDicr31(bus);
        }
    }

    fn doBlockCopy(self: *Self, bus: *Bus, channel_idx: usize) void {
        const channel = &self.channels[channel_idx];
        var addr = channel.base_addr & 0x1FFFFC;

        var words = channel.block_control & 0xFFFF;
        var blocks = (channel.block_control >> 16) & 0xFFFF;

        if (words == 0) words = 0x10000;
        if (blocks == 0) blocks = 1;

        var total_words = words * blocks;

        const direction = (channel.control >> 0) & 1; // 0: To RAM, 1: From RAM
        const step_val: u32 = if ((channel.control >> 1) & 1 == 0) 4 else 0xFFFFFFFC; // 0: +4, 1: -4

        while (total_words > 0) : (total_words -= 1) {
            if (direction == 0) {
                // To RAM (From Peripheral)
            } else {
                // From RAM (To Peripheral)
                const val = bus.read32(addr);
                if (channel_idx == 2) bus.gpu.writeGp0(val);
            }
            // Update MADR in the loop so it can be polled
            channel.base_addr = addr;
            addr = (addr +% step_val) & 0x1FFFFC;
        }
    }

    fn doOtc(self: *Self, bus: *Bus) void {
        const channel = &self.channels[6];
        var addr = channel.base_addr & 0x1FFFFC;
        var count = channel.block_control & 0xFFFF;
        if (count == 0) count = 0x10000;

        while (count > 0) : (count -= 1) {
            const next = if (count == 1) 0x00FFFFFF else (addr -% 4) & 0xFFFFFF;
            bus.write32(addr, next);
            channel.base_addr = addr;
            addr = next & 0x1FFFFC;
        }
    }

    fn doGpuLinkedList(self: *Self, bus: *Bus) void {
        const channel = &self.channels[2];
        var addr = channel.base_addr & 0x1FFFFC;

        while (true) {
            // Update MADR with the current header address
            channel.base_addr = addr;
            const header = bus.read32(addr);
            var words = (header >> 24) & 0xFF;

            while (words > 0) : (words -= 1) {
                addr = (addr +% 4) & 0x1FFFFC;
                const command = bus.read32(addr);
                bus.gpu.writeGp0(command);
            }

            if ((header & 0x00FFFFFF) == 0x00FFFFFF) break;
            addr = header & 0x1FFFFC;
        }
    }
};
