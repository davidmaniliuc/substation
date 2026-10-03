//! Physical PC -> Block, and the bookkeeping that keeps RAM blocks honest.
//!
//! A RAM write that lands in a 4 KB page holding code drops every block in
//! that page. `Bus.write` is the one RAM-write path: CPU stores and every
//! DMA word both pass through it. The only writes that bypass it are
//! `Cpu.loadExe`'s and a savestate load's `@memcpy`, and both flush.
//!
//! A dropped block is freed by the dispatcher (`reap`), never by the store
//! that dropped it: the running block may still be iterating its own ops.

const std = @import("std");
const block = @import("block.zig");
const Block = block.Block;

const ram_words = (2 << 20) / 4;
const bios_words = (512 << 10) / 4;
pub const ram_pages = (2 << 20) >> block.page_shift; // 512
const ram_mask: u32 = 0x001F_FFFF;
const bios_base: u32 = 0x1FC0_0000;

pub const BlockCache = struct {
    allocator: std.mem.Allocator,
    ram: []?*Block,
    bios: []?*Block,
    /// One bit per RAM page holding a live block. While it is clear, this
    /// is the whole cost a RAM write pays.
    has_code: [ram_pages / 64]u64 = @splat(0),
    page_blocks: [ram_pages]std.ArrayList(*Block) = @splat(.empty),
    /// Invalidations per page. A game that keeps hot data beside its code
    /// shows up here; smaller pages only if a measurement asks.
    invalidations: [ram_pages]u32 = @splat(0),
    /// Dropped blocks waiting for `reap`, linked through `next_dead`.
    dead: ?*Block = null,
    /// The block a block engine is executing, so a store into it can end it.
    running: ?*Block = null,
    /// An interpreter fallback step has filled I-cache lines since the last
    /// block; the dispatcher flushes them before the next one (see `run.zig`).
    icache_dirty: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*BlockCache {
        const self = try allocator.create(BlockCache);
        errdefer allocator.destroy(self);
        const ram = try allocator.alloc(?*Block, ram_words);
        errdefer allocator.free(ram);
        const bios = try allocator.alloc(?*Block, bios_words);
        @memset(ram, null);
        @memset(bios, null);
        self.* = .{ .allocator = allocator, .ram = ram, .bios = bios };
        return self;
    }

    pub fn destroy(self: *BlockCache) void {
        self.flush();
        for (&self.page_blocks) |*list| list.deinit(self.allocator);
        self.allocator.free(self.ram);
        self.allocator.free(self.bios);
        self.allocator.destroy(self);
    }

    fn slot(self: *BlockCache, phys: u32) *?*Block {
        return switch (block.regionOf(phys).?) {
            .ram => &self.ram[(phys & ram_mask) >> 2],
            .bios => &self.bios[(phys - bios_base) >> 2],
        };
    }

    pub fn lookup(self: *BlockCache, phys: u32) ?*Block {
        return self.slot(phys).*;
    }

    pub fn insert(self: *BlockCache, phys: u32, b: *Block) !void {
        if (block.regionOf(phys).? == .ram) {
            try self.page_blocks[b.first_page].append(self.allocator, b);
            if (b.last_page != b.first_page) {
                self.page_blocks[b.last_page].append(self.allocator, b) catch |err| {
                    _ = self.page_blocks[b.first_page].pop();
                    return err;
                };
                self.setBit(b.last_page);
            }
            self.setBit(b.first_page);
        }
        self.slot(phys).* = b;
    }

    /// The RAM write hook. True when the running block was among those
    /// dropped, so the block must stop after this store.
    pub inline fn onRamWrite(self: *BlockCache, offset: u32) bool {
        const page: u16 = @intCast(offset >> block.page_shift);
        if (!self.hasBit(page)) return false;
        return self.invalidatePage(page);
    }

    fn invalidatePage(self: *BlockCache, page: u16) bool {
        self.invalidations[page] += 1;
        var hit_running = false;
        while (self.page_blocks[page].pop()) |b| {
            if (b == self.running) hit_running = true;
            self.drop(b, page);
        }
        self.clearBit(page);
        return hit_running;
    }

    /// Unlinks `b` from its table slot and from the other page it straddles,
    /// and queues it for `reap`. `from_page`'s own list is the caller's.
    fn drop(self: *BlockCache, b: *Block, from_page: u16) void {
        const s = self.slot(b.start_pc & 0x1FFF_FFFF);
        if (s.* == b) s.* = null;
        const other = if (b.first_page == from_page) b.last_page else b.first_page;
        if (other != from_page) {
            const list = &self.page_blocks[other];
            for (list.items, 0..) |x, k| {
                if (x == b) {
                    _ = list.swapRemove(k);
                    break;
                }
            }
            if (list.items.len == 0) self.clearBit(other);
        }
        b.dead = true;
        b.next_dead = self.dead;
        self.dead = b;
    }

    /// Frees the dropped blocks. Only between blocks.
    pub fn reap(self: *BlockCache) void {
        while (self.dead) |b| {
            self.dead = b.next_dead;
            block.destroy(self.allocator, b);
        }
    }

    /// Frees every block. Each live block sits in exactly one table slot,
    /// its start, so walking the tables frees each once.
    pub fn flush(self: *BlockCache) void {
        self.reap();
        for (self.ram) |*s| if (s.*) |b| {
            block.destroy(self.allocator, b);
            s.* = null;
        };
        for (self.bios) |*s| if (s.*) |b| {
            block.destroy(self.allocator, b);
            s.* = null;
        };
        for (&self.page_blocks) |*list| list.clearRetainingCapacity();
        self.has_code = @splat(0);
        self.running = null;
    }

    fn hasBit(self: *const BlockCache, page: u16) bool {
        return self.has_code[page >> 6] & (@as(u64, 1) << @intCast(page & 63)) != 0;
    }
    fn setBit(self: *BlockCache, page: u16) void {
        self.has_code[page >> 6] |= @as(u64, 1) << @intCast(page & 63);
    }
    fn clearBit(self: *BlockCache, page: u16) void {
        self.has_code[page >> 6] &= ~(@as(u64, 1) << @intCast(page & 63));
    }
};
