const std = @import("std");
const Bus = @import("memory.zig").Bus;

pub const Channel = struct {
    base_addr: u32 = 0, // MADR (Memory Address)
    block_control: u32 = 0, // BCR  (Block Control)
    control: u32 = 0, // CHCR (Channel Control)

    transfer_active: bool = false,
    words_remaining: u32 = 0,
    linked_list_next: u32 = 0,

    chop_dma_window: u32 = 0,
    chop_cpu_window: u32 = 0,
    chop_is_cpu_turn: bool = false,
    chop_counter: u32 = 0,

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

                if (!was_busy and becomes_busy) {
                    self.startTransfer();
                } else if (was_busy and !becomes_busy) {
                    self.transfer_active = false;
                }
            },
            else => {},
        }
    }

    fn startTransfer(self: *Channel) void {
        const sync_mode = (self.control >> 9) & 3;

        // Sync mode 3 is reserved: Avocado's DMAChannel::step() dispatches only
        // on modes 0/1/2, so a reserved-mode channel simply never transfers.
        // We must bail out *before* setting transfer_active, because an active
        // channel stalls the CPU here. Leaving it active also ran the transfer
        // on a stale words_remaining — after a linked-list transfer that is the
        // 0xFFFFFFFF marker, i.e. ~4.3 billion words with the CPU frozen the
        // whole time (dma/otc-test's testOtcSyncModeReserved hung on exactly
        // this, right after testOtcSyncModeLinkedList).
        if (sync_mode == 3) {
            self.transfer_active = false;
            self.words_remaining = 0;
            return;
        }

        if (sync_mode == 0) {
            self.words_remaining = self.block_control & 0xFFFF;
            if (self.words_remaining == 0) self.words_remaining = 0x10000;
        } else if (sync_mode == 1) {
            const words: u32 = if ((self.block_control & 0xFFFF) == 0) 0x10000 else self.block_control & 0xFFFF;
            const blocks: u32 = if (((self.block_control >> 16) & 0xFFFF) == 0) 0x10000 else (self.block_control >> 16) & 0xFFFF;
            self.words_remaining = words * blocks;
        } else if (sync_mode == 2) {
            self.words_remaining = 0xFFFFFFFF; // special marker
        }

        const chop_enable = (self.control & (1 << 8)) != 0;
        if (chop_enable and sync_mode == 0) {
            const dma_win = (self.control >> 16) & 7;
            const cpu_win = (self.control >> 20) & 7;
            self.chop_dma_window = @as(u32, 1) << @as(u5, @truncate(dma_win));
            self.chop_cpu_window = @as(u32, 1) << @as(u5, @truncate(cpu_win));
            self.chop_is_cpu_turn = false;
            self.chop_counter = self.chop_dma_window;
        } else {
            self.chop_dma_window = 0;
            self.chop_cpu_window = 0;
            self.chop_is_cpu_turn = false;
            self.chop_counter = 0;
        }

        self.transfer_active = true;
    }
};

pub const Dma = struct {
    const Self = @This();

    channels: [7]Channel = [_]Channel{.{}} ** 7,

    dpcr: u32 = 0x07654321,
    dicr: u32 = 0,

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
                std.log.warn("Unhandled DMA read at offset 0x{x:0>2}", .{offset});
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
                // Bits 0-5/15-23 are r/w; flag bits 24-30 are write-1-to-clear
                // (unconditionally — Avocado DICR::write); bit 31 is computed.
                const rw_mask = 0x00FF803F;
                const clear_mask = (value >> 24) & 0x7F;
                const old_flags = (self.dicr >> 24) & 0x7F;

                self.dicr = (value & rw_mask) | ((old_flags & ~clear_mask) << 24);
                self.updateDicr31(bus);
            },
            else => std.log.warn("Unhandled DMA write at offset 0x{x:0>2}", .{offset}),
        }
    }

    pub fn updateDicr31(self: *Self, bus: *Bus) void {
        _ = bus;
        const force_irq = (self.dicr >> 15) & 1;
        const irq_en = (self.dicr >> 16) & 0x7F;
        const master_en = (self.dicr >> 23) & 1;
        const irq_flags = (self.dicr >> 24) & 0x7F;

        const master_irq = force_irq == 1 or (master_en == 1 and (irq_en & irq_flags) != 0);

        if (master_irq) {
            self.dicr |= (1 << 31);
        } else {
            self.dicr &= ~@as(u32, 1 << 31);
        }
    }

    pub fn isCpuStalled(self: *Self, bus: *Bus) bool {
        for (0..7) |i| {
            const channel = &self.channels[i];
            if (!channel.transfer_active) continue;

            const dpcr_channel_en = (self.dpcr >> @as(u5, @truncate(i * 4 + 3))) & 1;
            if (dpcr_channel_en == 0) continue;

            if (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn) continue;

            const sync_mode = (channel.control >> 9) & 3;
            if (sync_mode == 1 and i == 3 and bus.cdrom.data_fifo_empty) continue;

            return true;
        }
        return false;
    }

    pub fn tickCpuWindow(self: *Self, cpu_cycles: u32) void {
        for (0..7) |i| {
            const channel = &self.channels[i];
            if (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn) {
                if (channel.chop_counter > cpu_cycles) {
                    channel.chop_counter -= cpu_cycles;
                } else {
                    channel.chop_counter = channel.chop_dma_window;
                    channel.chop_is_cpu_turn = false;
                }
            }
        }
    }

    pub fn step(self: *Self, bus: *Bus) u32 {
        for (0..7) |i| {
            const channel = &self.channels[i];
            if (!channel.transfer_active) continue;

            const dpcr_channel_en = (self.dpcr >> @as(u5, @truncate(i * 4 + 3))) & 1;
            if (dpcr_channel_en == 0) continue;

            if (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn) continue;

            const sync_mode = (channel.control >> 9) & 3;
            if (sync_mode == 1 and i == 3 and bus.cdrom.data_fifo_empty) continue;

            // Transfer one word or block piece
            const old_wait_cycles = bus.wait_cycles;
            bus.wait_cycles = 0;

            var done = false;
            if (sync_mode == 2) {
                done = self.doLinkedListWord(bus, i);
            } else {
                done = self.doBlockCopyWord(bus, i);
            }

            var cycles_taken = bus.wait_cycles;
            if (cycles_taken == 0) cycles_taken = 2; // Default baseline if memory didn't add wait states
            bus.wait_cycles = old_wait_cycles; // Restore just in case

            // Chopping logic
            if (channel.chop_dma_window > 0 and !channel.chop_is_cpu_turn) {
                if (channel.chop_counter > 0) channel.chop_counter -= 1;
                if (channel.chop_counter == 0) {
                    channel.chop_is_cpu_turn = true;
                    channel.chop_counter = channel.chop_cpu_window; // Will be ticked by tickCpuWindow
                }
            }

            if (done) {
                channel.transfer_active = false;
                channel.control &= ~@as(u32, 1 << 24);
                if (sync_mode == 0) channel.control &= ~@as(u32, 1 << 28);

                // The completion flag latches only when the channel's DICR IRQ
                // enable bit (16+n) is set (PSX-SPX; Avocado DMA::step). Croc's
                // CD-streaming library relies on this: mid-frame sector DMAs run
                // with ch3 IRQ disabled and only the frame's last chunk may
                // raise the DMA interrupt.
                if ((self.dicr >> @as(u5, @truncate(16 + i))) & 1 == 1) {
                    self.dicr |= (@as(u32, 1) << @as(u5, @truncate(24 + i)));
                    self.updateDicr31(bus);
                    if ((self.dicr & (1 << 31)) != 0) {
                        bus.interrupts.trigger(.Dma);
                    }
                }
            }

            return cycles_taken;
        }
        return 0;
    }

    fn doBlockCopyWord(self: *Self, bus: *Bus, channel_idx: usize) bool {
        const channel = &self.channels[channel_idx];
        const addr = channel.base_addr & 0x1FFFFC;

        const direction = (channel.control >> 0) & 1;
        const step_val: u32 = if ((channel.control >> 1) & 1 == 0) 4 else 0xFFFFFFFC;

        if (direction == 0) {
            if (channel_idx == 1) bus.write32(addr, bus.read32(0x1F801820)) else if (channel_idx == 2) bus.write32(addr, bus.read32(0x1F801810)) else if (channel_idx == 3) bus.write32(addr, bus.read32(0x1F801802)) else if (channel_idx == 4) bus.write32(addr, bus.dmaRead32(0x1F801DA8)) else if (channel_idx == 6) {
                const next = if (channel.words_remaining == 1) 0x00FFFFFF else (addr -% 4) & 0xFFFFFF;
                bus.write32(addr, next);
                if (channel.words_remaining == 1) {
                    channel.base_addr = addr;
                } else {
                    channel.base_addr = next & 0x1FFFFC;
                }
            } else bus.write32(addr, 0);
        } else {
            const val = bus.read32(addr);
            if (channel_idx == 0) bus.write32(0x1F801820, val) else if (channel_idx == 2) bus.write32(0x1F801810, val) else if (channel_idx == 4) bus.write32(0x1F801DA8, val);
        }

        if (channel_idx != 6) {
            channel.base_addr = (addr +% step_val) & 0x1FFFFC;
        }

        if (channel.words_remaining > 0) {
            channel.words_remaining -= 1;
        }

        return channel.words_remaining == 0;
    }

    fn doLinkedListWord(self: *Self, bus: *Bus, channel_idx: usize) bool {
        const channel = &self.channels[channel_idx];
        const addr = channel.base_addr & 0x1FFFFC;
        // std.log.warn("LL Word: addr={x}, words={x}", .{addr, channel.words_remaining});

        if (channel.words_remaining == 0xFFFFFFFF) {
            // Read header
            const header = bus.read32(addr);
            const words = (header >> 24) & 0xFF;

            if (words > 0) {
                channel.words_remaining = words;
                channel.linked_list_next = header & 0x1FFFFC;
                channel.base_addr = (addr +% 4) & 0x1FFFFC;
            } else {
                if ((header & 0x00FFFFFF) == 0x00FFFFFF) return true;
                channel.base_addr = header & 0x1FFFFC;
            }
        } else {
            const data = bus.read32(addr);
            // Linked list DMA only goes to GPU (channel 2)
            if (channel_idx == 2) {
                bus.write32(0x1F801810, data);
            }

            channel.base_addr = (addr +% 4) & 0x1FFFFC;
            channel.words_remaining -= 1;

            if (channel.words_remaining == 0) {
                // Packet complete, jump to next header
                if (channel.linked_list_next == 0x1FFFFC) return true; // Actually 0xFFFFFF end marker

                channel.base_addr = channel.linked_list_next;
                channel.words_remaining = 0xFFFFFFFF; // Reset to header mode
            }
        }

        return false;
    }
};
