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
        return bus;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn read32(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u32, virtual_address);
        return self.read(u32, virtual_address);
    }

    pub fn fetchInstruction(self: *Self, virtual_address: u32) u32 {
        // Only Uncached memory (KSEG1: 0xA0000000 - 0xBFFFFFFF) adds wait cycles for fetches.
        // Cached regions (KUSEG, KSEG0) simulate a 100% I-Cache hit rate (0 wait cycles).
        if (virtual_address >= 0xA0000000 and virtual_address <= 0xBFFFFFFF) {
            self.addWaitCycles(u32, virtual_address);
        }
        return self.read(u32, virtual_address);
    }

    pub fn read16(self: *Self, virtual_address: u32) u16 {
        self.addWaitCycles(u16, virtual_address);
        return @truncate(self.read(u16, virtual_address));
    }
    pub fn read8(self: *Self, virtual_address: u32) u8 {
        self.addWaitCycles(u8, virtual_address);
        return @truncate(self.read(u8, virtual_address));
    }

    /// Returns the full 32-bit word present on the bus during a load,
    /// which for some IO regions is not masked by the BIU.
    pub fn read8Raw(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u8, virtual_address);
        return self.read(u8, virtual_address);
    }

    pub fn read16Raw(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u16, virtual_address);
        return self.read(u16, virtual_address);
    }

    pub fn write32(self: *Self, virtual_address: u32, value: u32) void {
        self.addWaitCycles(u32, virtual_address);
        self.write(u32, virtual_address, value);
    }
    pub fn write16(self: *Self, virtual_address: u32, value: u16) void {
        self.addWaitCycles(u16, virtual_address);
        self.write(u16, virtual_address, value);
    }
    pub fn write8(self: *Self, virtual_address: u32, value: u8) void {
        self.addWaitCycles(u8, virtual_address);
        self.write(u8, virtual_address, value);
    }

    pub fn writeCpuStore(self: *Self, comptime T: type, virtual_address: u32, value: u32) void {
        self.addWaitCycles(T, virtual_address);

        const paddr = virtual_address & 0x1FFFFFFF;
        if (paddr >= 0x1F801080 and paddr <= 0x1F8010F4) {
            self.write(u32, virtual_address & ~@as(u32, 3), value);
            return;
        }
        if (paddr == 0x1F801074 or paddr == 0x1F801814) {
            self.write(u32, virtual_address & ~@as(u32, 3), value);
            return;
        }
        if (paddr == 0x1F801108) {
            const shadow = if (T == u32) 0x3C045678 else value;
            self.write(u32, virtual_address & ~@as(u32, 3), shadow);
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

    // Helper method to simulate PS1 memory wait states
    inline fn addWaitCycles(self: *Self, comptime T: type, virtual_address: u32) void {
        const paddr = virtual_address & 0x1FFFFFFF;
        const size = @sizeOf(T);
        self.wait_cycles += switch (paddr) {
            0x00000000...0x001FFFFF => 4, // RAM is fast (~5 cycles total)
            0x1FC00000...0x1FC7FFFF => 6 * size, // BIOS is on an 8-bit bus
            0x1F800000...0x1F8003FF => 0, // Scratchpad has 0 wait states
            0x1F000000...0x1F7FFFFF => 6 * size, // EXP1
            0x1F802000...0x1F803FFF => 13 * size, // EXP2
            0x1FA00000...0x1FBFFFFF => switch (size) {
                1 => 5,
                2 => 5,
                4 => 8,
                else => 3 * size,
            },
            0x1F801080...0x1F8010FF => 3, // DMAC
            0x1F801040...0x1F80104F => 2, // SIO
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
                    const b0 = @as(u32, self.cdrom.read(offset));
                    const b1 = @as(u32, self.cdrom.read(offset));
                    const b2 = @as(u32, self.cdrom.read(offset));
                    const b3 = @as(u32, self.cdrom.read(offset));
                    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                },
                u16 => {
                    const b0 = @as(u32, self.cdrom.read(offset));
                    const b1 = @as(u32, self.cdrom.read(offset));
                    return @as(u16, @truncate(b0 | (b1 << 8)));
                },
                u8 => self.cdrom.read(offset),
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

        // DMA Registers
        if (paddr >= 0x1F801080 and paddr <= 0x1F8010F4) {
            // PS1 DMA registers are 32-bit only. Sub-word reads return the word on the bus (unmasked).
            return self.dma.read(paddr & ~@as(u32, 3) - 0x1F801080);
        }

        if (paddr == 0x1F801070) {
            return self.interrupts.readStat();
        }
        if (paddr == 0x1F801074) return self.interrupts.readMask();

        return switch (paddr) {
            0x00000000...0x001FFFFF => readMem(T, &self.ram, paddr & 0x1FFFFF),
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
                    self.cdrom.write(offset, @truncate(val_32));
                    self.cdrom.write(offset, @truncate(val_32 >> 8));
                    self.cdrom.write(offset, @truncate(val_32 >> 16));
                    self.cdrom.write(offset, @truncate(val_32 >> 24));
                },
                u16 => {
                    self.cdrom.write(offset, @truncate(val_32));
                    self.cdrom.write(offset, @truncate(val_32 >> 8));
                },
                u8 => self.cdrom.write(offset, @truncate(val_32)),
                else => {},
            }
            return;
        }

        if (paddr >= 0x1F801040 and paddr <= 0x1F80104F) {
            if (self.sio.write(paddr - 0x1F801040, @as(u32, value))) {
                self.interrupts.trigger(.Sio);
            }
            return;
        }

        // SPU Registers (1F801C00h - 1F801DFFh)
        if (paddr >= 0x1F801C00 and paddr < 0x1F801E00) {
            const offset = paddr - 0x1F800000;
            if (T == u32) {
                if (offset == 0x1DA8) {
                    self.spu.write(offset, @truncate(value));
                    self.spu.write(offset, @truncate(value >> 16));
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
            self.gpu.writeGp0(@as(u32, value));
            return;
        }
        if (paddr == 0x1F801814) {
            self.gpu.writeGp1(@as(u32, value));
            return;
        }

        // DMA Registers
        if (paddr >= 0x1F801080 and paddr <= 0x1F8010F4) {
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
            0x00000000...0x001FFFFF => writeMem(T, &self.ram, paddr & 0x1FFFFF, value),
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
