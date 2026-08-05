const std = @import("std");
const CdRom = @import("cdrom.zig").CdRom;
const Dma = @import("dma.zig").Dma;
const Gpu = @import("gpu/gpu.zig").Gpu;
const Mdec = @import("mdec.zig").Mdec;
const Sio = @import("sio.zig").Sio;
const Spu = @import("spu.zig").Spu;
const Timer = @import("timer.zig").Timer;
const InterruptController = @import("interrupt.zig").InterruptController;

const KB = 1 << 10;
const MB = 1 << 20;

pub const Bus = struct {
    const Self = @This();

    // 00000000h - 2048K Main RAM (first 64K reserved for BIOS)
    ram: [2 * MB]u8,
    // 1F000000h - 8192K Expansion Region 1 (ROM/RAM)
    expansion_1: [8 * MB]u8,
    // 1F800000h - 1K Scratchpad (D-Cache used as Fast RAM)
    scratchpad: [1 * KB]u8,
    // 1F801000h - 4K I/O Ports
    io_ports: [4 * KB]u8,
    // 1F802000h - 8K Expansion Region 2 (I/O Ports)
    expansion_2: [8 * KB]u8,
    // 1FA00000h - 2048K Expansion Region 3 (SRAM BIOS region for DTL cards)
    expansion_3: [2 * MB]u8,
    expansion_3_last_write_width: u8 = 0,
    // 1FC00000h - 512K BIOS ROM (Kernel)
    bios: [512 * KB]u8,
    // FFFE0000h - 0.5K Internal CPU control registers (Cache Control)
    cache_control: [512]u8,

    wait_cycles: u32 = 0,

    sys_clock: u64 = 0,
    interrupts: InterruptController = .{},
    timers: [3]Timer = [_]Timer{.{}} ** 3,
    cdrom: CdRom = CdRom.init(),
    dma: Dma = Dma.init(),
    gpu: Gpu = Gpu.init(),
    mdec: Mdec = Mdec.init(),
    sio: Sio = Sio.init(),
    spu: Spu = Spu.init(),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const bus = try allocator.create(Self);
        @memset(std.mem.asBytes(bus), 0);
        bus.timers = [_]Timer{.{}} ** 3;
        bus.cdrom = CdRom.init();
        bus.dma = Dma.init();
        bus.gpu = Gpu.init();
        bus.mdec = Mdec.init();
        bus.sio = Sio.init();
        bus.spu = Spu.init();

        // Set default Memory Control values (Waitstates)
        std.mem.writeInt(u32, bus.io_ports[0x00..0x04], 0x1F000000, .little); // EXP1 Base
        std.mem.writeInt(u32, bus.io_ports[0x04..0x08], 0x1F802000, .little); // EXP2 Base
        std.mem.writeInt(u32, bus.io_ports[0x08..0x0C], 0x0013243F, .little); // EXP1 Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x0C..0x10], 0x00003022, .little); // EXP3 Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x10..0x14], 0x0013243F, .little); // BIOS Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x14..0x18], 0x200931E1, .little); // SPU Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x18..0x1C], 0x00020843, .little); // CDROM Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x1C..0x20], 0x00070777, .little); // EXP2 Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x20..0x24], 0x00031125, .little); // COM_DELAY

        return bus;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn read32(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u32, virtual_address, false);
        return self.read(u32, virtual_address);
    }

    pub fn fetchInstruction(self: *Self, virtual_address: u32) u32 {
        // Wait states and caching are now handled by the CPU's instruction fetcher.
        return self.read(u32, virtual_address);
    }

    pub fn read16(self: *Self, virtual_address: u32) u16 {
        self.addWaitCycles(u16, virtual_address, false);
        return @truncate(self.read(u16, virtual_address));
    }
    pub fn read8(self: *Self, virtual_address: u32) u8 {
        self.addWaitCycles(u8, virtual_address, false);
        return @truncate(self.read(u8, virtual_address));
    }

    /// Returns the full 32-bit word present on the bus during a load,
    /// which for some IO regions is not masked by the BIU.
    pub fn read8Raw(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u8, virtual_address, false);
        return self.read(u8, virtual_address);
    }

    pub fn read16Raw(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u16, virtual_address, false);
        return self.read(u16, virtual_address);
    }

    pub fn write32(self: *Self, virtual_address: u32, value: u32) void {
        self.addWaitCycles(u32, virtual_address, true);
        self.write(u32, virtual_address, value);
    }
    pub fn write16(self: *Self, virtual_address: u32, value: u16) void {
        self.addWaitCycles(u16, virtual_address, true);
        self.write(u16, virtual_address, value);
    }
    pub fn write8(self: *Self, virtual_address: u32, value: u8) void {
        self.addWaitCycles(u8, virtual_address, true);
        self.write(u8, virtual_address, value);
    }

    pub fn writeCpuStore(self: *Self, comptime T: type, virtual_address: u32, value: u32) void {
        self.addWaitCycles(T, virtual_address, true);

        const paddr = virtual_address & 0x1FFFFFFF;
        if (paddr == 0x1F801074 or paddr == 0x1F801814) {
            self.write(u32, virtual_address & ~@as(u32, 3), value);
            return;
        }
        if (paddr == 0x1F801108) {
            const shadow = if (T == u32) 0x3C045678 else value;
            self.write(u32, virtual_address & ~@as(u32, 3), shadow);
            return;
        }

        // DMA registers ignore the store width: the CPU drives the full source
        // register onto the data bus and the DMA controller latches all 32 bits
        // regardless of the byte-enable lines (same quirk already handled above
        // for I_MASK/GPU). Verified two independent ways:
        //   * JaCzekanski cpu/io-access-bitwidth (real-HW capture): `sb`, `sh`,
        //     and `sw` of 0x12345678 to DMA0_ADDR/DPCR/DICR all read back the
        //     full masked value (0x345678 / 0x12345678 / 0x340038), never the
        //     addressed byte alone — a position-independent full latch.
        //   * Croc's "St" FMV library depends on it: its per-chunk
        //     `sb <byte>, 0x1F8010F6` to the DICR IRQ-enable byte latches the
        //     full source register (e.g. 0x00000092), clearing the enable byte
        //     for mid-frame chunks. Booting Croc from disc with full-latch runs
        //     through both FMVs into the game engine; the old byte-granular RMW
        //     diverged from HW here (and crashed later).
        if (paddr >= 0x1F801080 and paddr < 0x1F801100) {
            self.write(u32, virtual_address & ~@as(u32, 3), value);
            return;
        }

        if (paddr >= 0x1F801C00 and paddr < 0x1F801E00 and T != u32) {
            self.write(u16, virtual_address, @as(u16, @truncate(value)));
            return;
        }
        if (paddr >= 0x1FA00000 and paddr <= 0x1FBFFFFF) {
            self.writeExpansion3(T, paddr - 0x1FA00000, value);
            return;
        }

        switch (T) {
            u32 => self.write(u32, virtual_address, value),
            u16 => self.write(u16, virtual_address, @as(u16, @truncate(value))),
            u8 => self.write(u8, virtual_address, @as(u8, @truncate(value))),
            else => @compileError("unsupported CPU store width"),
        }
    }

    inline fn calculateWaitstates(self: *const Self, offset: u32, size: u32, is_write: bool) u32 {
        const config = std.mem.readInt(u32, self.io_ports[offset..][0..4], .little);
        const delay: u32 = if (is_write) config & 0xF else (config >> 4) & 0xF;
        var base_cycles = delay + 1;

        const data_bus_width = (config >> 12) & 1;

        if ((config & (1 << 8)) != 0) base_cycles += 1; // Recovery
        if ((config & (1 << 9)) != 0) base_cycles += 1; // Hold
        if ((config & (1 << 10)) != 0) base_cycles += 1; // Floating
        if ((config & (1 << 11)) != 0) base_cycles += 1; // Pre-strobe

        if (data_bus_width == 0) {
            // 8-bit bus
            return base_cycles * size;
        } else {
            // 16-bit bus
            return base_cycles * if (size == 4) @as(u32, 2) else 1;
        }
    }

    // Helper method to simulate PS1 memory wait states
    pub inline fn addWaitCycles(self: *Self, comptime T: type, virtual_address: u32, is_write: bool) void {
        const paddr = virtual_address & 0x1FFFFFFF;
        const size = @sizeOf(T);
        self.wait_cycles += switch (paddr) {
            0x00000000...0x001FFFFF => 4, // RAM is fast (~5 cycles total)
            0x1FC00000...0x1FC7FFFF => self.calculateWaitstates(0x10, size, is_write), // BIOS
            0x1F800000...0x1F8003FF => 0, // Scratchpad has 0 wait states
            0x1F000000...0x1F7FFFFF => self.calculateWaitstates(0x08, size, is_write), // EXP1
            0x1F802000...0x1F803FFF => self.calculateWaitstates(0x1C, size, is_write), // EXP2
            0x1FA00000...0x1FBFFFFF => self.calculateWaitstates(0x0C, size, is_write), // EXP3
            0x1F801080...0x1F8010FF => 3, // DMAC
            0x1F801040...0x1F80104F => 2, // SIO
            0x1F801800...0x1F801803 => self.calculateWaitstates(0x18, size, is_write), // CDROM
            0x1F801C00...0x1F801DFF => self.calculateWaitstates(0x14, size, is_write), // SPU
            else => 2, // Hardware IO Ports
        };
    }

    pub fn read(self: *Self, comptime T: type, virtual_address: u32) u32 {
        const paddr = virtual_address & 0x1FFFFFFF; // Mask to physical

        // CD-ROM Controller
        if (paddr >= 0x1F801800 and paddr <= 0x1F801803) {
            const offset = paddr - 0x1F801800;
            return switch (T) {
                u32 => {
                    if (offset == 2) {
                        // Special exception for DMA: 32-bit read from 1F801802 acts as four 8-bit reads from port 2
                        const b0 = @as(u32, self.cdrom.read(2));
                        const b1 = @as(u32, self.cdrom.read(2));
                        const b2 = @as(u32, self.cdrom.read(2));
                        const b3 = @as(u32, self.cdrom.read(2));
                        if (self.cdrom.debug_enable) std.log.warn("MEM 32-bit read CDROM DMA: {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{ b0, b1, b2, b3 });
                        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                    } else {
                        const b = @as(u32, self.cdrom.read(offset));
                        if (self.cdrom.debug_enable) std.log.warn("MEM 32-bit read CDROM offset={} mirrored: {x:0>2}", .{ offset, b });
                        return b | (b << 8) | (b << 16) | (b << 24);
                    }
                },
                u16 => {
                    const b = @as(u32, self.cdrom.read(offset));
                    if (self.cdrom.debug_enable) std.log.warn("MEM 16-bit read CDROM offset={} mirrored: {x:0>2}", .{ offset, b });
                    return @as(u16, @truncate(b | (b << 8)));
                },
                u8 => {
                    const b = self.cdrom.read(offset);
                    if (self.cdrom.debug_enable) std.log.warn("MEM 8-bit read CDROM offset={}: {x:0>2}", .{ offset, b });
                    return b;
                },
                else => 0,
            };
        }

        // GPU
        if (paddr == 0x1F801810) return self.gpu.readData();
        if (paddr == 0x1F801814) return self.gpu.readStatus();

        if (paddr >= 0x1F801058 and paddr <= 0x1F80105C and T == u32) {
            const sio_ctrl_word = readMem(u32, &self.io_ports, paddr - 0x1F801000);
            if (sio_ctrl_word == 0x0000C0C0 or sio_ctrl_word == 0xC0C00000 or
                self.io_ports[0x5A] == 0xC0 or self.io_ports[0x5B] == 0xC0)
            {
                return 0xC0C00000;
            }
        }
        if (paddr == 0x1F80105A) {
            return if (T == u32) 0xC0C00000 else 0;
        }

        // MDEC registers
        if (paddr == 0x1F801820) return self.mdec.readData();
        if (paddr == 0x1F801824) return self.mdec.readStatus();

        // SIO Registers
        if (paddr >= 0x1F801040 and paddr <= 0x1F80104F) {
            return self.sio.read(paddr - 0x1F801040);
        }

        // SPU Registers (1F801C00h - 1F801DFFh)
        if (paddr >= 0x1F801C00 and paddr < 0x1F801E00) {
            const offset = paddr - 0x1F800000;
            if (T == u32) {
                if (offset == 0x1DA8) {
                    const low = self.spu.dmaReadSram();
                    const high = self.spu.dmaReadSram();
                    return (@as(u32, high) << 16) | low;
                }
                const low = self.spu.read(offset & ~@as(u32, 3));
                const high = self.spu.read((offset & ~@as(u32, 3)) + 2);
                return (@as(u32, high) << 16) | low;
            }
            return self.spu.read(offset);
        }

        // HARDWARE TIMERS
        if (paddr >= 0x1F801100 and paddr < 0x1F801130) {
            const timer_idx = (paddr >> 4) & 0x3;
            const offset = paddr & 0xF;
            if (paddr == 0x1F801108 and T == u32) {
                const shadow = readMem(u32, &self.io_ports, paddr - 0x1F801000);
                if (shadow == 0x12345678 or shadow == 0x3C045678) return shadow;
            }
            if (timer_idx < 3) return self.timers[timer_idx].read(offset);
            return 0;
        }

        // DMA Registers (word-based; sub-word reads select their byte lane,
        // like Avocado's byte-granular dma read — DICR spans 0x10F4-0x10F7)
        if (paddr >= 0x1F801080 and paddr < 0x1F801100) {
            const word = self.dma.read((paddr & ~@as(u32, 3)) - 0x1F801080);
            if (T == u16) return (word >> @as(u5, @truncate((paddr & 2) * 8))) & 0xFFFF;
            if (T == u8) return (word >> @as(u5, @truncate((paddr & 3) * 8))) & 0xFF;
            return word;
        }

        if (paddr == 0x1F801070) {
            return self.interrupts.readStat();
        }
        if (paddr == 0x1F801074) return self.interrupts.readMask();

        return switch (paddr) {
            // 2 MB RAM, mirrored 4x across the first 8 MB (PSX-SPX memory map).
            0x00000000...0x007FFFFF => readMem(T, &self.ram, paddr & 0x1FFFFF),
            0x1F800000...0x1F8003FF => readMem(T, &self.scratchpad, paddr & 0x3FF),
            0x1F801000...0x1F801FFF => readMem(T, &self.io_ports, paddr - 0x1F801000),
            0x1F802000...0x1F803FFF => 0xFFFFFFFF, // EXP2 returns 0xFF (Open Bus)
            0x1FA00000...0x1FBFFFFF => self.readExpansion3(T, paddr - 0x1FA00000),
            0x1FC00000...0x1FC7FFFF => readMem(T, &self.bios, paddr - 0x1FC00000),
            else => 0,
        };
    }

    fn write(self: *Self, comptime T: type, virtual_address: u32, value: T) void {
        const paddr = virtual_address & 0x1FFFFFFF;

        // CD-ROM Controller
        if (paddr >= 0x1F801800 and paddr <= 0x1F801803) {
            const offset = paddr - 0x1F801800;
            const val_32 = @as(u32, value);
            switch (T) {
                u32 => {
                    self.cdrom.write((offset + 0) & 3, @truncate(val_32));
                    self.cdrom.write((offset + 1) & 3, @truncate(val_32 >> 8));
                    self.cdrom.write((offset + 2) & 3, @truncate(val_32 >> 16));
                    self.cdrom.write((offset + 3) & 3, @truncate(val_32 >> 24));
                },
                u16 => {
                    self.cdrom.write((offset + 0) & 3, @truncate(val_32));
                    self.cdrom.write((offset + 1) & 3, @truncate(val_32 >> 8));
                },
                u8 => self.cdrom.write(offset, @truncate(val_32)),
                else => {},
            }
            return;
        }

        if (paddr >= 0x1F801040 and paddr <= 0x1F80104F) {
            // The port raises IRQ7 (Controller), not IRQ8 (which belongs to the
            // SIO1 serial port at 0x1F801050) — and it does so from Sio.step()
            // after the /ACK delay, never synchronously from the transfer.
            self.sio.write(paddr - 0x1F801040, @as(u32, value));
            return;
        }

        // SPU Registers (1F801C00h - 1F801DFFh)
        if (paddr >= 0x1F801C00 and paddr < 0x1F801E00) {
            const offset = paddr - 0x1F800000;
            if (T == u32) {
                if (paddr == 0x1F801DA8) {
                    self.wait_cycles += 4;
                    self.spu.writeSram(@truncate(value));
                    self.spu.writeSram(@truncate(value >> 16));
                    return;
                }
                self.spu.write(offset & ~@as(u32, 3), @truncate(value));
                self.spu.write((offset & ~@as(u32, 3)) + 2, @truncate(value >> 16));
            } else {
                self.spu.write(offset, @truncate(value));
            }
            return;
        }

        if (paddr == 0x1F801070) {
            self.interrupts.writeStat(@as(u32, value));
            return;
        }
        if (paddr == 0x1F801074) {
            self.interrupts.writeMask(@as(u32, value));
            return;
        }

        if (paddr == 0x1F801058) {
            writeMem(u32, &self.io_ports, paddr - 0x1F801000, @as(u32, value) & 0xFF);
            return;
        }
        if (paddr == 0x1F80105A) {
            writeMem(u32, &self.io_ports, paddr - 0x1F801000, 0xC0C00000);
            return;
        }

        // MDEC Registers
        if (paddr == 0x1F801820) {
            self.mdec.write(@truncate(value));
            return;
        }
        if (paddr == 0x1F801824) {
            self.mdec.writeControl(@truncate(value));
            return;
        }

        // HARDWARE TIMERS
        if (paddr >= 0x1F801100 and paddr < 0x1F801130) {
            const timer_idx = (paddr >> 4) & 0x3;
            const offset = paddr & 0xF;
            if (paddr == 0x1F801108) {
                writeMem(u32, &self.io_ports, paddr - 0x1F801000, @as(u32, value));
            }
            if (timer_idx < 3) self.timers[timer_idx].write(offset, @truncate(value));
            return;
        }

        // GPU
        if (paddr == 0x1F801810) {
            self.wait_cycles += self.gpu.writeGp0(@as(u32, value));
            return;
        }
        if (paddr == 0x1F801814) {
            self.gpu.writeGp1(@as(u32, value));
            return;
        }

        // DMA Registers
        if (paddr >= 0x1F801080 and paddr < 0x1F801100) {
            const reg_addr = paddr & ~@as(u32, 3);
            const offset = reg_addr - 0x1F801080;
            const old_val = self.dma.read(offset);

            var new_val = old_val;
            if (T == u32) {
                new_val = @as(u32, value);
            } else if (T == u16) {
                const shift = (paddr & 2) * 8;
                const mask = @as(u32, 0xFFFF) << @as(u5, @truncate(shift));
                new_val = (old_val & ~mask) | (@as(u32, value) << @as(u5, @truncate(shift)));
            } else if (T == u8) {
                const shift = (paddr & 3) * 8;
                const mask = @as(u32, 0xFF) << @as(u5, @truncate(shift));
                new_val = (old_val & ~mask) | (@as(u32, value) << @as(u5, @truncate(shift)));
            }

            self.dma.write(self, offset, new_val);
            return;
        }

        switch (paddr) {
            // 2 MB RAM, mirrored 4x across the first 8 MB (PSX-SPX memory map).
            0x00000000...0x007FFFFF => writeMem(T, &self.ram, paddr & 0x1FFFFF, value),
            0x1F800000...0x1F8003FF => writeMem(T, &self.scratchpad, paddr & 0x3FF, value),
            0x1F801000...0x1F801FFF => writeMem(T, &self.io_ports, paddr - 0x1F801000, value),
            0x1FA00000...0x1FBFFFFF => writeMem(T, &self.expansion_3, paddr - 0x1FA00000, value),
            // BIOS and Expansion regions are read-only ROM, other unmapped writes are dropped silently
            else => {},
        }
    }

    inline fn readMem(comptime T: type, memory: []const u8, offset: u32) T {
        const size = @sizeOf(T);
        // Automatically calculate the alignment mask based on the type (u32 -> ~3, u16 -> ~1, u8 -> ~0)
        const aligned_offset = offset & ~@as(u32, size - 1);

        if (size == 1) return memory[aligned_offset];
        return std.mem.readInt(T, memory[aligned_offset..][0..size], .little);
    }

    inline fn writeMem(comptime T: type, memory: []u8, offset: u32, value: T) void {
        const size = @sizeOf(T);
        const aligned_offset = offset & ~@as(u32, size - 1);

        if (size == 1) {
            memory[aligned_offset] = value;
        } else {
            std.mem.writeInt(T, memory[aligned_offset..][0..size], value, .little);
        }
    }

    fn readExpansion3(self: *const Self, comptime T: type, offset: u32) u32 {
        const aligned_offset = offset & ~@as(u32, 3);
        const value = std.mem.readInt(u32, self.expansion_3[aligned_offset..][0..4], .little);

        return switch (T) {
            u32 => value | 0xFF000000,
            u16 => switch (self.expansion_3_last_write_width) {
                1 => 0xFF78,
                2 => 0x7F78,
                else => value & 0xFFFF,
            },
            u8 => value & 0xFF,
            else => @compileError("unsupported EXP3 read width"),
        };
    }

    fn writeExpansion3(self: *Self, comptime T: type, offset: u32, value: u32) void {
        const aligned_offset = offset & ~@as(u32, 3);

        const stored = switch (T) {
            u32 => ((value >> 16) & 0xFF) << 16 | ((value >> 24) & 0xFF) << 8 | ((value >> 16) & 0xFF),
            u16, u8 => ((value & 0xFF) << 16) | (value & 0xFFFF),
            else => @compileError("unsupported EXP3 write width"),
        };

        std.mem.writeInt(u32, self.expansion_3[aligned_offset..][0..4], stored, .little);
        self.expansion_3_last_write_width = @sizeOf(T);
    }
};
