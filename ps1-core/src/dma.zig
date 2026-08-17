const std = @import("std");
const Bus = @import("memory.zig").Bus;

/// Naming only -- these substitute for the literals in place; nothing about
/// control flow, branch order, or the values themselves changed. Module-
/// private (see memory.zig's Addr block and constants.zig's doc comment for
/// the two-scope rule). A few of these mirror addresses also named in
/// memory.zig's Addr block (gpu_data, mdec_data, spu_fifo) -- both files keep
/// their own copy rather than sharing one, since this task's file list is
/// scoped to dma.zig and memory.zig only.
const DmaConst = struct {
    // Deliberately untyped (comptime_int), like the bare literals they
    // replace: several of these feed contexts requiring different concrete
    // types (u32 masks, u5 shift amounts, usize channel indices), and an
    // untyped constant coerces to whichever the use site needs, exactly as
    // the literal did.

    /// PS1 has 7 DMA channels (MDECin, MDECout, GPU, CDROM, SPU, PIO, OTC).
    const channel_count = 7;

    // Channel-local register block (Channel.read/write's `offset`).
    const reg_madr = 0x0; // Base address
    const reg_bcr = 0x4; // Block control
    const reg_chcr = 0x8; // Channel control

    // Dma.read/write's top-level offset dispatch: channel blocks are 0x10
    // bytes each, followed by the two shared registers.
    const channel_index_mask = 0x7; // (offset >> 4) & this selects the channel
    const channel_reg_mask = 0xF; // offset & this selects the register within it
    const dpcr_offset = 0x70;
    const dicr_offset = 0x74;
    const dpcr_reset = 0x07654321;

    /// MADR only wires 24 bits (Channel.write case reg_madr, and the address
    /// masking in doBlockCopyWord/doLinkedListWord). Numerically identical to
    /// chain_terminator below, but that is a mask applied to bits, not a
    /// sentinel compared for equality -- named separately.
    const madr_mask = 0x00FFFFFF;
    /// End-of-chain sentinel: a next-address field whose low 24 bits are all
    /// set means "no next node," for both OTC's reverse order table and a
    /// GPU linked-list packet's header. Same value as madr_mask (the
    /// terminator is simply "every address bit set"), different role.
    const chain_terminator = 0x00FFFFFF;
    /// words_remaining sentinel meaning "the next word read is a linked-list
    /// header, not data" (sync mode 2's free-running marker, and
    /// doLinkedListWord's header-mode flag). Numerically distinct from
    /// chain_terminator, no collision.
    const header_pending_marker = 0xFFFFFFFF;
    /// -4 as a wrapping u32, MADR's decrement-direction step.
    const step_decrement = 0xFFFFFFFC;
    /// Word-aligned mask into the 2 MB RAM window; DMA only ever targets
    /// main RAM as its "addr" side, so every base_addr/header address gets
    /// masked down to this before use.
    const ram_word_mask = 0x1FFFFC;

    // Sync-mode-1 chopping (Channel.startTransfer).
    /// (control >> 9) & this: the 2-bit sync mode field.
    const sync_mode_mask = 3;
    /// The chop DMA/CPU window fields are each 3 bits ((control>>16)&this,
    /// (control>>20)&this) -- a window *size* selector, unrelated to
    /// channel_index_mask above despite sharing the value 7.
    const chop_window_mask = 7;

    /// BCR's word-count (sync mode 0) and per-block word-count/block-count
    /// (sync mode 1) sub-fields are each 16 bits; a field reading 0 means
    /// "0x10000" (65536), not "empty" -- hardware's way of encoding a full
    /// 16-bit-plus-one range in 16 bits.
    const bcr_field_mask = 0xFFFF;
    const bcr_field_wrap = 0x10000;

    // DPCR: 7 channels x 4 bits each, bit 3 of each nibble is the enable.
    const dpcr_bits_per_channel = 4;
    const dpcr_enable_bit_offset = 3;

    // DICR (Dma.write's 0x74 case, updateDicr31, and step()'s completion
    // handling) -- bits 0-5/15-23 are r/w, bits 24-30 write-1-to-clear, bit
    // 31 is computed.
    const dicr_rw_mask = 0x00FF803F;
    /// Width of the per-channel IRQ-enable and IRQ-flags bitfields (7
    /// channels, one bit each) -- same mask, two different fields below.
    const dicr_channel_bits_mask = 0x7F;
    const dicr_force_irq_bit = 15;
    const dicr_irq_enable_shift = 16;
    const dicr_master_enable_bit = 23;
    const dicr_irq_flags_shift = 24;
    const dicr_master_irq_bit = 31;

    // DMA targets: the device-side port each channel moves words to/from.
    // See memory.zig's Addr.gpu_data / Addr.mdec_data / Addr.spu_transfer_fifo
    // for the same addresses reached from the CPU side.
    const target_mdec_data = 0x1F801820;
    const target_gpu_data = 0x1F801810;
    const target_cdrom_data = 0x1F801802;
    const target_spu_fifo = 0x1F801DA8;
};

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

    // Sync-mode-1 block pacing. Mode 1 moves one block per device request, so
    // the bus belongs to the CPU between blocks. `block_words` is BCR's block
    // size, `block_word_progress`/`block_cycles` track the block in flight, and
    // `block_gap_counter` is the CPU's remaining slice before the device asks
    // for the next block. See `blockPacingCyclesPerWord`.
    block_words: u32 = 0,
    block_word_progress: u32 = 0,
    block_cycles: u32 = 0,
    block_gap_counter: u32 = 0,

    pub fn read(self: *const Channel, offset: u32) u32 {
        return switch (offset) {
            DmaConst.reg_madr => self.base_addr,
            DmaConst.reg_bcr => self.block_control,
            DmaConst.reg_chcr => self.control,
            else => 0,
        };
    }

    pub fn write(self: *Channel, offset: u32, value: u32) void {
        switch (offset) {
            DmaConst.reg_madr => self.base_addr = value & DmaConst.madr_mask, // 24-bit address
            DmaConst.reg_bcr => self.block_control = value,
            DmaConst.reg_chcr => {
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
        const sync_mode = (self.control >> 9) & DmaConst.sync_mode_mask;

        // Sync mode 3 is reserved: only modes 0/1/2 are dispatched, so a
        // reserved-mode channel simply never transfers.
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
            self.words_remaining = self.block_control & DmaConst.bcr_field_mask;
            if (self.words_remaining == 0) self.words_remaining = DmaConst.bcr_field_wrap;
        } else if (sync_mode == 1) {
            const words: u32 = if ((self.block_control & DmaConst.bcr_field_mask) == 0) DmaConst.bcr_field_wrap else self.block_control & DmaConst.bcr_field_mask;
            const blocks: u32 = if (((self.block_control >> 16) & DmaConst.bcr_field_mask) == 0) DmaConst.bcr_field_wrap else (self.block_control >> 16) & DmaConst.bcr_field_mask;
            self.words_remaining = words * blocks;
            self.block_words = words;
        } else if (sync_mode == 2) {
            self.words_remaining = DmaConst.header_pending_marker; // special marker
        }

        const chop_enable = (self.control & (1 << 8)) != 0;
        if (chop_enable and sync_mode == 0) {
            const dma_win = (self.control >> 16) & DmaConst.chop_window_mask;
            const cpu_win = (self.control >> 20) & DmaConst.chop_window_mask;
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

        self.block_word_progress = 0;
        self.block_cycles = 0;
        self.block_gap_counter = 0;

        self.transfer_active = true;
    }
};

/// How long a paced sync-mode-1 channel takes per word, end to end, including
/// the CPU's slice between blocks. 0 means "not paced": the channel keeps the
/// bus for the whole transfer, which is what every channel did before.
///
/// Only the SPU is paced. Mode 1 is "sync to DMA requests", so on hardware the
/// gap between blocks is set by how fast the *device* asks for the next one,
/// and that rate is per-device — there is no single correct number to apply
/// across the board. Channel 3 already models its own request signal (see the
/// `data_fifo_empty` check in `step`/`isCpuStalled`); this is the same idea for
/// the SPU, whose request rate is the one we have a hardware measurement for.
///
/// jaczekanski `spu/memory-transfer` measures 1024 bytes with BS=0x10 and
/// requires 1638 < cycles < 18022 for the resulting 256 words, i.e. 6.4..70
/// cycles per word; hardware's nominal is 64. RAM wait states already cost us
/// ~14 a word, so only the gap is missing. 32 sits mid-window and leaves a
/// ~288-cycle slice per block — the earlier attempt at this handed the CPU a
/// single instruction per gap, which was not enough for the ROM's poll loop to
/// complete one iteration, so nothing moved.
///
/// Deliberately *not* applied to channels 2 (GPU) and 3 (CDROM): both carry
/// real game traffic through mode 1, pacing them changes CPU/DMA interleaving
/// everywhere, and there is no disc image here to smoke-test Croc or Crash.
/// What one word costs the DMA controller, per PSX-SPX's "DMA Transfer Rates".
///
/// This is deliberately *not* the memory map's wait states. Those describe what
/// the CPU pays to touch an address; the DMA controller has its own path to RAM
/// and moves a word for the GPU, the MDEC or the OTC in a single clock, where
/// summing the wait states of both ends charged around six. The overcharge does
/// not merely slow the transfer down — it is taken out of the CPU's budget
/// between CDROM sector interrupts, because a stalled CPU still ticks the
/// peripherals with whatever the DMA billed. Croc's FMV starved on exactly that:
/// it missed roughly one STR chunk per frame, which desynced the RLE stream
/// feeding the MDEC and tore the right-hand side of every frame.
///
/// The CDROM's 24 and the SPU's 4 are slow because the device, not the bus, sets
/// the pace; ch4 layers `blockPacingCyclesPerWord` on top of this for the gap
/// *between* mode-1 blocks.
fn transferCyclesPerWord(channel_index: usize) u32 {
    return switch (channel_index) {
        3 => 24, // CDROM
        4 => 4, // SPU
        5 => 20, // PIO
        else => 1, // MDECin, MDECout, GPU, OTC
    };
}

fn blockPacingCyclesPerWord(channel_index: usize) u32 {
    return switch (channel_index) {
        4 => 32, // SPU
        else => 0,
    };
}

pub const Dma = struct {
    const Self = @This();

    channels: [DmaConst.channel_count]Channel = [_]Channel{.{}} ** DmaConst.channel_count,

    dpcr: u32 = DmaConst.dpcr_reset,
    dicr: u32 = 0,

    /// Fast-path guard for `isCpuStalled` and `tickCpuWindow`, the two entry
    /// points `Cpu.step()` calls on every single instruction. Both walk all
    /// seven channels, and a `Channel` is wide enough that the pair of walks
    /// touches the whole array twice per instruction — which a profile of
    /// Tekken 3 mid-fight put at ~20% of run time, nearly all of it spent
    /// confirming that nothing is in flight.
    ///
    /// Only a CHCR write can start a transfer, so `write` sets this
    /// optimistically and `tickCpuWindow` clears it again once a full walk
    /// finds nothing left pending. It is a hint in one direction only: a stale
    /// `true` costs one walk and changes nothing, and a false negative is the
    /// only way it could alter behaviour, so safety-checked builds re-walk and
    /// assert rather than trust it.
    busy_hint: bool = false,

    pub fn init() Self {
        return .{};
    }

    pub fn read(self: *const Self, offset: u32) u32 {
        const channel_idx = (offset >> 4) & DmaConst.channel_index_mask;

        if (offset < DmaConst.dpcr_offset) {
            return self.channels[channel_idx].read(offset & DmaConst.channel_reg_mask);
        }

        return switch (offset) {
            DmaConst.dpcr_offset => self.dpcr,
            DmaConst.dicr_offset => self.dicr,
            else => {
                std.log.warn("Unhandled DMA read at offset 0x{x:0>2}", .{offset});
                return 0;
            },
        };
    }

    pub fn write(self: *Self, bus: *Bus, offset: u32, value: u32) void {
        const channel_idx = (offset >> 4) & DmaConst.channel_index_mask;

        // Any channel-register or DPCR write can put a channel in a state the
        // per-instruction walk has to look at; see `busy_hint`.
        self.busy_hint = true;

        if (offset < DmaConst.dpcr_offset) {
            self.channels[channel_idx].write(offset & DmaConst.channel_reg_mask, value);
            return;
        }

        switch (offset) {
            DmaConst.dpcr_offset => self.dpcr = value,
            DmaConst.dicr_offset => {
                // Bits 0-5/15-23 are r/w; flag bits 24-30 are write-1-to-clear
                // (unconditionally); bit 31 is computed.
                const rw_mask = DmaConst.dicr_rw_mask;
                const clear_mask = (value >> DmaConst.dicr_irq_flags_shift) & DmaConst.dicr_channel_bits_mask;
                const old_flags = (self.dicr >> DmaConst.dicr_irq_flags_shift) & DmaConst.dicr_channel_bits_mask;

                self.dicr = (value & rw_mask) | ((old_flags & ~clear_mask) << DmaConst.dicr_irq_flags_shift);
                self.updateDicr31(bus);
            },
            else => std.log.warn("Unhandled DMA write at offset 0x{x:0>2}", .{offset}),
        }
    }

    pub fn updateDicr31(self: *Self, bus: *Bus) void {
        _ = bus;
        const force_irq = (self.dicr >> DmaConst.dicr_force_irq_bit) & 1;
        const irq_en = (self.dicr >> DmaConst.dicr_irq_enable_shift) & DmaConst.dicr_channel_bits_mask;
        const master_en = (self.dicr >> DmaConst.dicr_master_enable_bit) & 1;
        const irq_flags = (self.dicr >> DmaConst.dicr_irq_flags_shift) & DmaConst.dicr_channel_bits_mask;

        const master_irq = force_irq == 1 or (master_en == 1 and (irq_en & irq_flags) != 0);

        if (master_irq) {
            self.dicr |= (1 << DmaConst.dicr_master_irq_bit);
        } else {
            self.dicr &= ~@as(u32, 1 << DmaConst.dicr_master_irq_bit);
        }
    }

    /// True while a channel still needs the per-instruction walk: it is mid
    /// transfer, chopping, or counting out a mode-1 block gap.
    fn channelNeedsAttention(channel: *const Channel) bool {
        return channel.transfer_active or
            channel.block_gap_counter > 0 or
            (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn);
    }

    /// Debug-only guard on `busy_hint`'s one dangerous direction: a cleared
    /// hint must mean the channels really are idle.
    fn assertHintIsIdle(self: *const Self) void {
        for (0..DmaConst.channel_count) |i| {
            std.debug.assert(!channelNeedsAttention(&self.channels[i]));
        }
    }

    pub fn isCpuStalled(self: *Self, bus: *Bus) bool {
        if (!self.busy_hint) {
            if (std.debug.runtime_safety) self.assertHintIsIdle();
            return false;
        }

        for (0..DmaConst.channel_count) |i| {
            const channel = &self.channels[i];
            if (!channel.transfer_active) continue;

            const dpcr_channel_en = (self.dpcr >> @as(u5, @truncate(i * DmaConst.dpcr_bits_per_channel + DmaConst.dpcr_enable_bit_offset))) & 1;
            if (dpcr_channel_en == 0) continue;

            if (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn) continue;

            // Between mode-1 blocks the device has not requested yet, so the
            // bus is the CPU's.
            if (channel.block_gap_counter > 0) continue;

            const sync_mode = (channel.control >> 9) & DmaConst.sync_mode_mask;
            if (sync_mode == 1 and i == 3 and bus.cdrom.fifos.data_fifo_empty) continue;

            return true;
        }
        return false;
    }

    pub fn tickCpuWindow(self: *Self, cpu_cycles: u32) void {
        if (!self.busy_hint) {
            if (std.debug.runtime_safety) self.assertHintIsIdle();
            return;
        }

        // This walk is the one place that sees every channel after all of a
        // step's DMA work has settled, so it is where the hint gets retired.
        var still_busy = false;
        for (0..DmaConst.channel_count) |i| {
            const channel = &self.channels[i];

            if (channel.block_gap_counter > 0) {
                channel.block_gap_counter -= @min(channel.block_gap_counter, cpu_cycles);
            }

            if (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn) {
                if (channel.chop_counter > cpu_cycles) {
                    channel.chop_counter -= cpu_cycles;
                } else {
                    channel.chop_counter = channel.chop_dma_window;
                    channel.chop_is_cpu_turn = false;
                }
            }

            if (channelNeedsAttention(channel)) still_busy = true;
        }
        self.busy_hint = still_busy;
    }

    pub fn step(self: *Self, bus: *Bus) u32 {
        for (0..DmaConst.channel_count) |i| {
            const channel = &self.channels[i];
            if (!channel.transfer_active) continue;

            const dpcr_channel_en = (self.dpcr >> @as(u5, @truncate(i * DmaConst.dpcr_bits_per_channel + DmaConst.dpcr_enable_bit_offset))) & 1;
            if (dpcr_channel_en == 0) continue;

            if (channel.chop_dma_window > 0 and channel.chop_is_cpu_turn) continue;

            if (channel.block_gap_counter > 0) continue;

            const sync_mode = (channel.control >> 9) & DmaConst.sync_mode_mask;
            if (sync_mode == 1 and i == 3 and bus.cdrom.fifos.data_fifo_empty) continue;

            // Transfer one word or block piece. The wait states the device and
            // RAM accumulate along the way belong to the CPU's cost model, not
            // the controller's, so they are collected and thrown away rather
            // than leaking into either clock.
            const old_wait_cycles = bus.wait_cycles;
            bus.wait_cycles = 0;

            var done = false;
            if (sync_mode == 2) {
                done = self.doLinkedListWord(bus, i);
            } else {
                done = self.doBlockCopyWord(bus, i);
            }

            const cycles_taken = transferCyclesPerWord(i);
            bus.wait_cycles = old_wait_cycles; // Restore just in case

            // Mode-1 block pacing: once a block is delivered, hand the bus back
            // until the device would request the next one.
            if (sync_mode == 1 and !done) {
                const rate = blockPacingCyclesPerWord(i);
                if (rate > 0 and channel.block_words > 0) {
                    channel.block_cycles += cycles_taken;
                    channel.block_word_progress += 1;
                    if (channel.block_word_progress >= channel.block_words) {
                        const target = channel.block_words * rate;
                        channel.block_gap_counter = if (target > channel.block_cycles)
                            target - channel.block_cycles
                        else
                            1;
                        channel.block_word_progress = 0;
                        channel.block_cycles = 0;
                    }
                }
            }

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
                // enable bit (16+n) is set (PSX-SPX). Croc's
                // CD-streaming library relies on this: mid-frame sector DMAs run
                // with ch3 IRQ disabled and only the frame's last chunk may
                // raise the DMA interrupt.
                if ((self.dicr >> @as(u5, @truncate(DmaConst.dicr_irq_enable_shift + i))) & 1 == 1) {
                    self.dicr |= (@as(u32, 1) << @as(u5, @truncate(DmaConst.dicr_irq_flags_shift + i)));
                    self.updateDicr31(bus);
                    if ((self.dicr & (1 << DmaConst.dicr_master_irq_bit)) != 0) {
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
        const addr = channel.base_addr & DmaConst.ram_word_mask;

        const direction = (channel.control >> 0) & 1;
        const step_val: u32 = if ((channel.control >> 1) & 1 == 0) 4 else DmaConst.step_decrement;

        if (direction == 0) {
            if (channel_idx == 1) bus.write32(addr, bus.read32(DmaConst.target_mdec_data)) else if (channel_idx == 2) bus.write32(addr, bus.read32(DmaConst.target_gpu_data)) else if (channel_idx == 3) bus.write32(addr, bus.read32(DmaConst.target_cdrom_data)) else if (channel_idx == 4) bus.write32(addr, bus.dmaRead32(DmaConst.target_spu_fifo)) else if (channel_idx == 6) {
                const next = if (channel.words_remaining == 1) DmaConst.chain_terminator else (addr -% 4) & DmaConst.madr_mask;
                bus.write32(addr, next);
                if (channel.words_remaining == 1) {
                    channel.base_addr = addr;
                } else {
                    channel.base_addr = next & DmaConst.ram_word_mask;
                }
            } else bus.write32(addr, 0);
        } else {
            const val = bus.read32(addr);
            if (channel_idx == 0) bus.write32(DmaConst.target_mdec_data, val) else if (channel_idx == 2) bus.write32(DmaConst.target_gpu_data, val) else if (channel_idx == 4) bus.write32(DmaConst.target_spu_fifo, val);
        }

        if (channel_idx != 6) {
            channel.base_addr = (addr +% step_val) & DmaConst.ram_word_mask;
        }

        if (channel.words_remaining > 0) {
            channel.words_remaining -= 1;
        }

        return channel.words_remaining == 0;
    }

    fn doLinkedListWord(self: *Self, bus: *Bus, channel_idx: usize) bool {
        const channel = &self.channels[channel_idx];
        const addr = channel.base_addr & DmaConst.ram_word_mask;
        // std.log.warn("LL Word: addr={x}, words={x}", .{addr, channel.words_remaining});

        if (channel.words_remaining == DmaConst.header_pending_marker) {
            // Read header
            const header = bus.read32(addr);
            const words = (header >> 24) & 0xFF;

            if (words > 0) {
                channel.words_remaining = words;
                channel.linked_list_next = header & DmaConst.ram_word_mask;
                channel.base_addr = (addr +% 4) & DmaConst.ram_word_mask;
            } else {
                if ((header & DmaConst.madr_mask) == DmaConst.chain_terminator) return true;
                channel.base_addr = header & DmaConst.ram_word_mask;
            }
        } else {
            const data = bus.read32(addr);
            // Linked list DMA only goes to GPU (channel 2)
            if (channel_idx == 2) {
                bus.write32(DmaConst.target_gpu_data, data);
            }

            channel.base_addr = (addr +% 4) & DmaConst.ram_word_mask;
            channel.words_remaining -= 1;

            if (channel.words_remaining == 0) {
                // Packet complete, jump to next header
                if (channel.linked_list_next == (DmaConst.chain_terminator & DmaConst.ram_word_mask)) return true; // Actually 0xFFFFFF end marker

                channel.base_addr = channel.linked_list_next;
                channel.words_remaining = DmaConst.header_pending_marker; // Reset to header mode
            }
        }

        return false;
    }
};
