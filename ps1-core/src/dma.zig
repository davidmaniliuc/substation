const std = @import("std");
const Bus = @import("memory.zig").Bus;

pub const Channel = struct {
    base_addr: u32 = 0, // MADR (Memory Address)
    block_control: u32 = 0, // BCR  (Block Control)
    control: u32 = 0, // CHCR (Channel Control)
    start_delay: bool = false,
    cooldown: u32 = 0,

    pub fn read(self: *const Channel, offset: u32) u32 {
        return switch (offset) {
            0x0 => self.base_addr,
            0x4 => self.block_control,
            0x8 => self.control,
            else => 0,
        };
    }

    pub fn write(self: *Channel, offset: u32, value: u32) void {
        switch (offset) {
            0x0 => self.base_addr = value & 0x00FFFFFF, // 24-bit address
            0x4 => self.block_control = value,
            0x8 => {
                const was_busy = (self.control & (1 << 24)) != 0;
                const becomes_busy = (value & (1 << 24)) != 0;
                self.control = value;
                const sync_mode = (value >> 9) & 3;
                if (!was_busy and becomes_busy and sync_mode == 1) {
                    self.start_delay = true;
                    self.cooldown = 128;
                }
            },
            else => {},
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
                const rw_mask = 0x00FF803F;
                const old_val = self.dicr;
                // Bits 24-30 are flags that are cleared by writing 1
                const clear_mask = (value >> 24) & 0x7F;
                const preserve_flags = (value & (1 << 23)) != 0;
                const new_flags = if (preserve_flags) ((old_val >> 24) & 0x7F) & ~clear_mask else 0;

                // Keep the old Master Flag (Bit 31) so updateDicr31 can see the transition
                self.dicr = (value & rw_mask) | (@as(u32, new_flags) << 24) | (old_val & (1 << 31));
                self.updateDicr31(bus);
            },
            else => std.log.warn("Unhandled DMA write at offset 0x{X:0>2}", .{offset}),
        }
    }

    pub fn updateDicr31(self: *Self, bus: *Bus) void {
        const force_irq = (self.dicr >> 15) & 1;
        const irq_en = (self.dicr >> 16) & 0x7F;
        const master_en = (self.dicr >> 23) & 1;
        const irq_flags = (self.dicr >> 24) & 0x7F;

        const master_irq = force_irq == 1 or (master_en == 1 and (irq_en & irq_flags) != 0);
        const old_master = (self.dicr & (1 << 31)) != 0;

        if (master_irq) {
            self.dicr |= (1 << 31);
            if (!old_master) {
                bus.i_stat |= (1 << 3); // DMA interrupt bit in I_STAT
            }
        } else {
            self.dicr &= ~@as(u32, 1 << 31);
        }
    }

    pub fn step(self: *Self, bus: *Bus) void {
        for (0..7) |i| {
            const channel = &self.channels[i];

            // Bit 24 of CHCR is the "Start/Busy" bit.
            if ((channel.control & (1 << 24)) == 0) continue;
            if (channel.start_delay) {
                channel.start_delay = false;
                continue;
            }

            // Check if DMA for this channel is enabled in DPCR
            const dpcr_channel_en = (self.dpcr >> @as(u5, @truncate(i * 4 + 3))) & 1;
            if (dpcr_channel_en == 0) continue;

            // Determine synchronization mode (0: Manual, 1: Request, 2: Linked List)
            const sync_mode = (channel.control >> 9) & 3;

            if (sync_mode == 1 and channel.cooldown > 0) {
                channel.cooldown -= 1;
                continue;
            }

            // CD-ROM (Channel 3) DRQ (Data Request) checking
            if (sync_mode == 1 and i == 3 and bus.cdrom.data_fifo_empty) {
                continue;
            }

            const transfer_complete = switch (sync_mode) {
                0 => blk: {
                    if (i == 6) {
                        self.doOtc(bus);
                    } else {
                        _ = self.doBlockCopy(bus, i);
                    }
                    // In Manual mode, clear the Trigger bit (28) as well as Busy (24)
                    channel.control &= ~@as(u32, 1 << 28);
                    break :blk true;
                },
                1 => self.doBlockCopy(bus, i),
                2 => blk: {
                    if (i == 2) {
                        self.doGpuLinkedList(bus);
                        break :blk true;
                    } else {
                        std.log.warn("Linked List mode only supported on GPU (Channel 2)", .{});
                        break :blk true;
                    }
                },
                else => blk: {
                    std.log.warn("Unknown DMA sync mode: {}", .{sync_mode});
                    break :blk true;
                },
            };

            if (!transfer_complete) continue;

            // Transfer is "done", so clear the Start/Busy bit!
            channel.control &= ~@as(u32, 1 << 24);

            // Update DICR flags (bits 24-30)
            self.dicr |= (@as(u32, 1) << @as(u5, @truncate(24 + i)));
            self.updateDicr31(bus);
        }
    }

    fn doBlockCopy(self: *Self, bus: *Bus, channel_idx: usize) bool {
        const channel = &self.channels[channel_idx];
        var addr = channel.base_addr & 0x1FFFFC;

        const sync_mode = (channel.control >> 9) & 3;
        var total_words: u64 = 0;

        if (sync_mode == 0) {
            // Manual Mode: Only use the lower 16 bits (words)
            total_words = channel.block_control & 0xFFFF;
            if (total_words == 0) total_words = 0x10000;
        } else {
            // Request Mode: Multiply words * blocks
            const words: u64 = if ((channel.block_control & 0xFFFF) == 0) 0x10000 else channel.block_control & 0xFFFF;
            const blocks: u64 = if (((channel.block_control >> 16) & 0xFFFF) == 0) 0x10000 else (channel.block_control >> 16) & 0xFFFF;
            total_words = words;
            channel.block_control = (channel.block_control & 0x0000FFFF) | (@as(u32, @intCast((blocks - 1) & 0xFFFF)) << 16);
        }

        const direction = (channel.control >> 0) & 1; // 0: To RAM, 1: From RAM
        const step_val: u32 = if ((channel.control >> 1) & 1 == 0) 4 else 0xFFFFFFFC; // 0: +4, 1: -4

        // Cap transfer size to prevent emulator freezing on absurdly large intentional bounds
        if (total_words > 0x100000) total_words = 0x100000;

        while (total_words > 0) : (total_words -= 1) {
            if (direction == 0) {
                // To RAM (From Peripheral)
                if (channel_idx == 1) {
                    // MDEC Out
                    bus.write32(addr, bus.mdec.readData());
                } else if (channel_idx == 2) {
                    bus.write32(addr, bus.gpu.readData());
                } else if (channel_idx == 3) {
                    // CD-ROM
                    bus.write32(addr, bus.cdrom.readDataWord());
                } else if (channel_idx == 4) {
                    const low = bus.spu.dmaReadSram();
                    const high = bus.spu.dmaReadSram();
                    bus.write32(addr, (@as(u32, high) << 16) | low);
                } else {
                    bus.write32(addr, 0); // Drop other reads for now
                }
            } else {
                // From RAM (To Peripheral)
                const val = bus.read32(addr);
                if (channel_idx == 0) {
                    // MDEC In
                    bus.mdec.writeData(val);
                } else if (channel_idx == 2) {
                    bus.gpu.writeGp0(val);
                } else if (channel_idx == 4) {
                    bus.spu.writeSram(@truncate(val & 0xFFFF));
                    bus.spu.writeSram(@truncate(val >> 16));
                }
            }
            addr = (addr +% step_val) & 0x1FFFFC;
        }
        channel.base_addr = addr;

        if (sync_mode == 1) {
            const complete = ((channel.block_control >> 16) & 0xFFFF) == 0;
            if (!complete) channel.cooldown = 128;
            return complete;
        }
        return true;
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

        var safety_counter: usize = 0;
        // Avoid freezing the emulator if a test ROM links the list into a cyclic ring
        while (safety_counter < 0x100000) : (safety_counter += 1) {
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
