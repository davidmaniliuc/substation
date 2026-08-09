const std = @import("std");
const CdRom = @import("cdrom.zig").CdRom;
const IrqAction = @import("cdrom.zig").IrqAction;

const PendingInterrupt = struct {
    irq: u8,
    response: [16]u8 = [_]u8{0} ** 16,
    response_len: usize = 0,
    response_ptr: usize = 0,
    delay: i64 = 0,
    ack: bool = false,
    triggered: bool = false,
    action: IrqAction = .None,
    auto_status: bool = false,
};

pub const InterruptQueue = struct {
    items: [16]PendingInterrupt = [_]PendingInterrupt{.{ .irq = 0 }} ** 16,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    /// Counts dropped pushes. Avocado's fifo silently returns false when full
    /// (fifo.h:34), so dropping matches the reference — but a *sustained*
    /// overflow means software has stopped acknowledging, which is a real
    /// symptom worth surfacing. Frontends poll this instead of logging here,
    /// because the drop path runs once per sector and floods the console.
    overflow_count: u32 = 0,

    pub fn push(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8) void {
        self.pushAction(irq, delay, resp, .None, false);
    }

    pub fn pushAction(self: *InterruptQueue, irq: u8, delay: i64, resp: []const u8, action: IrqAction, auto_status: bool) void {
        if (self.count >= self.items.len) {
            self.overflow_count +%= 1;
            return;
        }
        var item = &self.items[self.tail];
        item.irq = irq;
        @memcpy(item.response[0..resp.len], resp);
        item.response_len = resp.len;
        item.response_ptr = 0;
        item.delay = delay;
        item.ack = false;
        item.triggered = false;
        item.action = action;
        item.auto_status = auto_status;

        self.tail = (self.tail + 1) % self.items.len;
        self.count += 1;
    }

    pub fn pop(self: *InterruptQueue) void {
        if (self.count == 0) return;
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
    }

    pub fn peek(self: *const InterruptQueue) ?*const PendingInterrupt {
        if (self.count == 0) return null;
        return &self.items[self.head];
    }

    pub fn peekMut(self: *InterruptQueue) ?*PendingInterrupt {
        if (self.count == 0) return null;
        return &self.items[self.head];
    }

    pub fn clear(self: *InterruptQueue) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }
};

/// Parameter / response / data FIFOs, plus the interrupt queue. Grouped
/// together because they are the software-visible transfer machinery for
/// commands and sector data.
pub const Fifos = struct {
    parameter_fifo: [16]u8 = [_]u8{0} ** 16,
    parameter_len: usize = 0,

    // Interrupt Queue
    irq_queue: InterruptQueue = .{},
    /// Last observed level of the drive's IRQ line, so `updateInterrupts` can
    /// latch I_STAT on the rising edge the way the hardware does.
    irq_line: bool = false,

    // Data FIFO
    /// The sector the drive read most recently, raw. The drive refills this
    /// every sector; software never sees it directly (Avocado `rawSector`).
    last_raw_sector: [2352]u8 = [_]u8{0} ** 2352,
    /// The software-visible data FIFO: a *copy* of `last_raw_sector` taken when
    /// software writes Request bit 0x80 (Avocado `dataBuffer`). Keeping it
    /// separate is what stops a sector arriving mid-DMA from corrupting the
    /// transfer already in flight.
    sector_buffer: [2352]u8 = [_]u8{0} ** 2352,
    sector_buffer_ptr: usize = 0,
    sector_buffer_len: usize = 2048,
    data_fifo_empty: bool = true,
};

pub fn pushParameter(cdrom: *CdRom, val: u8) void {
    if (cdrom.fifos.parameter_len < 16) {
        cdrom.fifos.parameter_fifo[cdrom.fifos.parameter_len] = val;
        cdrom.fifos.parameter_len += 1;
    }
}

pub fn readResponse(cdrom: *CdRom) u8 {
    if (cdrom.fifos.irq_queue.peekMut()) |item| {
        if (item.delay <= 0 and item.response_ptr < item.response_len) {
            const val = item.response[item.response_ptr];
            item.response_ptr += 1;
            cdrom.regs.last_response_byte = val;

            if (cdrom.debug_enable) std.log.warn("CDROM readResponse returning 0x{x} at ptr {}", .{ val, item.response_ptr - 1 });

            if (item.response_ptr >= item.response_len and item.ack) {
                cdrom.fifos.irq_queue.pop();
            }
            return val;
        } else if (item.delay <= 0) {}
    }
    return cdrom.regs.last_response_byte;
}

pub fn readData(cdrom: *CdRom) u8 {
    if (cdrom.fifos.data_fifo_empty) return 0;
    const val = cdrom.fifos.sector_buffer[cdrom.fifos.sector_buffer_ptr];
    cdrom.fifos.sector_buffer_ptr += 1;
    if (cdrom.fifos.sector_buffer_ptr >= cdrom.fifos.sector_buffer_len) {
        cdrom.fifos.data_fifo_empty = true;
    }
    return val;
}
