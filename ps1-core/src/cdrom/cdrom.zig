const std = @import("std");
const disc = @import("../disc.zig");
const Spu = @import("../spu/spu.zig").Spu;
const InterruptController = @import("../interrupt.zig").InterruptController;
const fifo = @import("fifo.zig");
const commands = @import("commands.zig");
pub const xa = @import("xa.zig");
const cdda = @import("cdda.zig");

/// Raw-sector layout. A 2352-byte sector opens with 12 sync bytes and a
/// 4-byte header whose last byte is the mode; `mode_byte_offset` addresses it.
/// Mode 2 then carries an 8-byte sub-header, so its 800h user bytes begin at
/// 018h, while a Mode 1 sector has no sub-header and starts them at 010h.
/// Reads that ask for the whole sector instead begin right after the sync.
const mode_byte_offset = 15;
const mode1_data_offset = 16;
const mode2_data_offset = 24;
const whole_sector_offset = 12;

pub const DriveState = enum {
    Idle,
    Reading,
    Seeking,
    Playing,
};

pub const IrqAction = enum {
    None,
    SetIdle,
    SetSeeking,
    SetPlaying,
};

/// Software-visible register state: the index register, the interrupt-enable
/// register, the busy timer, the last response byte read back, and the four
/// CD volume bytes. The volume bytes are written by the register writes below
/// and read by nothing — CD audio volume is genuinely not applied today; this
/// grouping records that gap without fixing it (see CLAUDE.md's CDROM
/// section / P6b brief follow-ups).
pub const Regs = struct {
    index: u2 = 0,
    irq_enable: u8 = 0x1F,
    // Separate busy timer, distinct from irq delay
    busy_for: i32 = 0,
    last_response_byte: u8 = 0,
    volume_ll: u8 = 0x80,
    volume_lr: u8 = 0x00,
    volume_rl: u8 = 0x00,
    volume_rr: u8 = 0x80,
};

/// The drive mechanism: position, timers, mode, and status. `drive_state` is
/// deliberately not merged with `pending_command` (in `CdRom` below) — it is
/// set synchronously by commands and survives the `irq_queue.clear()` every
/// command byte performs, and the Seeking->Reading transition is driven by
/// `seek_timer` in `step()`, gated on `read_after_seek`. That decoupling is
/// load-bearing: a polling loop would otherwise lose the transition.
pub const Drive = struct {
    drive_state: DriveState = .Idle,
    sector_timer: i64 = 0,
    // Seek timer for ReadN's Seeking->Reading transition. Ticked unconditionally
    // in step() and gated on `read_after_seek`, so it survives the irq_queue.clear()
    // that every command performs — drive mode lives here, decoupled from
    // the interrupt queue.
    seek_timer: i64 = 0,
    read_after_seek: bool = false,
    status: u8 = 0, // Drive status byte (Motor, etc.)
    mode: u8 = 0,
    seek_target: disc.MSF = .{ .m = 0, .s = 0, .f = 0 },
    current_pos: disc.MSF = .{ .m = 0, .s = 0, .f = 0 },
    loc_l_valid: bool = false,
    muted: bool = false,
    last_sector_header: [8]u8 = [_]u8{0} ** 8,
    last_subchannel_q: [8]u8 = [_]u8{0} ** 8,
    /// Sectors the drive has delivered. Diagnostic counter; also lets tests
    /// pin down exactly when a sector lands relative to a transfer.
    sectors_delivered: u64 = 0,
    /// Track the last CDDA sector belonged to, for the mode bit1 autopause
    /// check. Latched by Play/SeekP so the first sector of a track never reads
    /// as a boundary crossing; only cdda.zig advances it after that.
    previous_track: u8 = 0,
};

/// The shared mixer input both audio decoders push into: `pushXaSample` has
/// two callers on opposite sides of the cdrom/{xa,cdda}.zig split —
/// `playXaAudioSector` in xa.zig and the Red Book branch in cdda.zig — and
/// `step()` drains this FIFO to the SPU on its own 768-cycle counter. It is
/// deliberately not folded into `Xa`: that would make cdda.zig reach through
/// `self.xa` to emit Red Book audio, which is backwards.
pub const AudioOut = struct {
    audio_fifo_l: [16384]i16 = [_]i16{0} ** 16384,
    audio_fifo_r: [16384]i16 = [_]i16{0} ** 16384,
    audio_fifo_read: usize = 0,
    audio_fifo_write: usize = 0,
    audio_tick_counter: u32 = 0,
};

pub const CdRom = struct {
    debug_enable: bool = false,
    // Read-only input. Excluded from the hash: it holds a slice whose address
    // varies per run, and a `tracks` array undefined past `track_count`.
    disc: ?disc.Disc = null,

    regs: Regs = .{}, // software-visible register state
    fifos: fifo.Fifos = .{}, // parameter / response / data FIFOs + IRQ queue
    drive: Drive = .{}, // mechanism: position, timers, mode, status
    audio: AudioOut = .{}, // the SHARED sink both decoders push into
    xa: xa.Xa = .{}, // XA-ADPCM decoder + resampler state

    // Command dispatch. Ticked in step(), executed by commands.zig.
    pending_command: ?u8 = null,
    pending_command_delay: u32 = 0,

    pub fn init() CdRom {
        var cd = CdRom{
            .drive = .{ .status = 0x02 }, // Motor on by default
        };
        cd.drive.last_subchannel_q[0] = 0x01; // track 1
        cd.drive.last_subchannel_q[4] = 0x06; // rel f = 6
        cd.drive.last_subchannel_q[6] = 0x01; // abs s = 1
        cd.drive.last_subchannel_q[7] = 0x68; // abs f = 68
        return cd;
    }

    pub fn setDisc(self: *CdRom, d: disc.Disc) void {
        self.disc = d;
    }

    pub fn read(self: *CdRom, offset: u32) u8 {
        const val: u8 = switch (offset) {
            0 => self.getStatus(),
            1 => fifo.readResponse(self),
            2 => fifo.readData(self), // Port 2 is ALWAYS the Data FIFO
            3 => switch (self.regs.index) {
                0, 2 => self.regs.irq_enable | 0xE0, // Interrupt Enable Register
                else => {
                    // Interrupt Flag Register (index 1 or 3)
                    var flag: u8 = 0xE0; // Bits 7-5 always set
                    if (self.fifos.irq_queue.peek()) |item| {
                        // `ack` matters here: writing the IFR clears bits 0-2 on
                        // hardware even though the response FIFO stays readable,
                        // so an acknowledged-but-undrained item must report 0.
                        if (item.delay <= 0 and !item.ack) {
                            flag |= item.irq & 7;
                        }
                    }
                    if (self.debug_enable) std.log.warn("CDROM Read IFR({}, {}): 0x{x} queue_count={}", .{ offset, self.regs.index, flag, self.fifos.irq_queue.count });
                    return flag;
                },
            },
            else => 0,
        };
        if (self.debug_enable) std.log.warn("CDROM Read({}, {}): 0x{x}", .{ offset, self.regs.index, val });
        return val;
    }

    pub fn write(self: *CdRom, offset: u32, value: u8) void {
        if (self.debug_enable) std.log.warn("CDROM Write({}, {}): 0x{x}", .{ offset, self.regs.index, value });
        switch (offset) {
            0 => self.regs.index = @truncate(value & 3),
            1 => switch (self.regs.index) {
                0 => {
                    self.fifos.irq_queue.clear();
                    self.pending_command = value;
                    self.pending_command_delay = 0; // Instant execution
                },
                1 => {}, // WRDATA
                2 => {}, // CI
                3 => self.regs.volume_rr = value, // ATV2
            },
            2 => {
                switch (self.regs.index) {
                    0 => fifo.pushParameter(self, value),
                    1 => self.regs.irq_enable = value & 0x1F,
                    2 => self.regs.volume_ll = value, // ATV0
                    3 => self.regs.volume_rl = value, // ATV3
                }
            },
            3 => switch (self.regs.index) {
                0 => {
                    // Request register
                    if (value & 0x80 != 0) {
                        // Want data: latch a copy of the last sector the drive
                        // read, but only once the previous one has been fully
                        // drained. Re-latching mid-transfer would rewind the
                        // read pointer
                        // and splice in a newer sector.
                        if (self.fifos.data_fifo_empty) {
                            const sector_size: usize = if (self.drive.mode & 0x20 != 0) 2340 else 2048;
                            // Where the 800h user bytes sit depends on the
                            // sector's own mode byte. Only Mode 1 moves them;
                            // anything else keeps the Mode 2 offset, so a
                            // synthetic sector with a zero header still reads
                            // the way it always has.
                            const data_start: usize = if (sector_size != 2048)
                                whole_sector_offset
                            else if (self.fifos.last_raw_sector[mode_byte_offset] == 0x01)
                                mode1_data_offset
                            else
                                mode2_data_offset;
                            @memcpy(
                                self.fifos.sector_buffer[0..sector_size],
                                self.fifos.last_raw_sector[data_start..][0..sector_size],
                            );
                            self.fifos.sector_buffer_ptr = 0;
                            self.fifos.sector_buffer_len = sector_size;
                            self.fifos.data_fifo_empty = false;
                        }
                    } else {
                        // Clear data FIFO
                        self.fifos.data_fifo_empty = true;
                        self.fifos.sector_buffer_ptr = 0;
                    }
                },
                1 => {
                    // Interrupt Flag register write (ACK)
                    if (value & 0x40 != 0) {
                        self.fifos.parameter_len = 0; // Reset parameter FIFO
                    }
                    // Acknowledge front interrupt ONLY if low 5 bits are non-zero
                    if (value & 0x1F != 0) {
                        // Writing the IFR clears the flag bits, so the line goes
                        // low here even when the entry survives (unread response
                        // bytes) or when the next queued interrupt is already
                        // ready — without the drop, that next one would never
                        // produce a rising edge and would be lost.
                        self.fifos.irq_line = false;
                        if (self.fifos.irq_queue.peekMut()) |item| {
                            // Only ACK interrupts that have actually fired (delay expired)
                            if (item.delay <= 0) {
                                if (self.debug_enable) std.log.warn("CDROM Ack IFR value=0x{x} irq={} resp={}/{}", .{ value, item.irq, item.response_ptr, item.response_len });
                                item.ack = true;
                                // Only pop if the response FIFO is already fully consumed.
                                // Software can ACK first and continue reading remaining response bytes.
                                if (item.response_ptr >= item.response_len) {
                                    self.fifos.irq_queue.pop();
                                }
                            }
                        }
                    }
                },
                2 => self.regs.volume_lr = value, // ATV1
                3 => {}, // ADPCTL
            },
            else => {},
        }
    }

    pub fn step(self: *CdRom, cycles: u32, spu: *Spu) void {
        // Handle pending command
        if (self.pending_command) |cmd| {
            if (self.pending_command_delay > 0) {
                self.pending_command_delay -= @min(self.pending_command_delay, cycles);
            }
            if (self.pending_command_delay <= 0) {
                self.pending_command = null;
                commands.executeCommand(self, cmd);
            }
        }

        // Tick busy timer (separate from IRQ delay)
        if (self.regs.busy_for > 0) {
            self.regs.busy_for -= @intCast(@min(@as(u32, @intCast(self.regs.busy_for)), cycles));
        }

        // Tick Interrupt Queue Delay
        if (self.fifos.irq_queue.peekMut()) |item| {
            if (item.delay > 0) {
                item.delay -= @min(item.delay, cycles);
            }
            if (item.delay <= 0) {
                if (!item.triggered) {
                    item.triggered = true;
                    switch (item.action) {
                        .SetIdle => self.drive.drive_state = .Idle,
                        .SetSeeking => self.drive.drive_state = .Seeking,
                        .SetPlaying => self.drive.drive_state = .Playing,
                        .None => {},
                    }
                    if (item.auto_status and item.response_len > 0) {
                        item.response[0] = self.getDriveStatus();
                    }
                    if (self.debug_enable) std.log.warn("CDROM INT fire: irq={} resp_len={} drive_state={s} status=0x{x:0>2}", .{ item.irq, item.response_len, @tagName(self.drive.drive_state), self.getDriveStatus() });
                }
                if (item.irq == 0) {
                    self.fifos.irq_queue.pop();
                }
            }
        }

        // Tick the read seek timer. Independent of irq_queue, so the GetStat
        // poll loop's repeated irq_queue.clear() cannot lose the Seeking->Reading
        // transition. Gated on read_after_seek so SeekL/SeekP (which also set
        // .Seeking but resolve via their own queued INT2) are unaffected.
        if (self.drive.drive_state == .Seeking and self.drive.read_after_seek) {
            self.drive.seek_timer -= cycles;
            if (self.drive.seek_timer <= 0) {
                self.drive.read_after_seek = false;
                self.drive.drive_state = .Reading;
                // A drive that has just started reading has not read anything
                // yet -- the first sector still costs a full sector period. The
                // gap is load-bearing, not cosmetic: software polls GetStat for
                // the Reading bit, and every command clears `irq_queue`, so a
                // sector posted in the same instant the bit goes up has its INT1
                // destroyed by the very poll that observed the transition. The
                // caller then gets sector n+1 first. Tekken 3's CD library
                // checks each sector's header LBA against the one it asked for
                // and retried the whole read forever on the mismatch, which is
                // why its stage load never completed.
                self.drive.sector_timer = self.cyclesPerSector();
            }
        }

        // Tick Drive Mechanism
        if (self.drive.drive_state == .Reading or self.drive.drive_state == .Playing) {
            self.drive.sector_timer -= cycles;
            if (self.drive.sector_timer <= 0) {
                const cycles_per_sector = self.cyclesPerSector();
                self.drive.sector_timer += cycles_per_sector;

                if (self.drive.drive_state == .Reading or self.drive.drive_state == .Playing) {
                    self.readNextSector();
                }
            }
        }

        // XA Resampling and SPU push (approx 44100Hz = 768 CPU cycles)
        self.audio.audio_tick_counter += cycles;
        if (self.audio.audio_tick_counter >= 768) {
            self.audio.audio_tick_counter -= 768;
            var l: i16 = 0;
            var r: i16 = 0;
            if (self.audio.audio_fifo_read != self.audio.audio_fifo_write) {
                l = self.audio.audio_fifo_l[self.audio.audio_fifo_read];
                r = self.audio.audio_fifo_r[self.audio.audio_fifo_read];
                self.audio.audio_fifo_read = (self.audio.audio_fifo_read + 1) % 16384;
            }
            spu.pushCdAudio(l, r);
        }
    }

    pub fn synthesizeHeaderAndQ(self: *CdRom, msf: disc.MSF) void {
        const lba = msf.toLba();
        self.drive.last_sector_header[0] = msf.m;
        self.drive.last_sector_header[1] = msf.s;
        self.drive.last_sector_header[2] = msf.f;
        self.drive.last_sector_header[3] = 0x02; // mode 2

        const abs_lba = if (lba >= 5) lba - 5 else 0;
        const abs_msf = disc.MSF.fromLba(abs_lba);
        const rel_msf = disc.MSF.fromFrames(abs_lba);

        self.drive.last_subchannel_q[0] = 0x01; // track 1
        self.drive.last_subchannel_q[1] = if (lba >= 0) @as(u8, 0x01) else @as(u8, 0x00);
        self.drive.last_subchannel_q[2] = rel_msf.m;
        self.drive.last_subchannel_q[3] = rel_msf.s;
        self.drive.last_subchannel_q[4] = rel_msf.f;
        self.drive.last_subchannel_q[5] = abs_msf.m;
        self.drive.last_subchannel_q[6] = abs_msf.s;
        self.drive.last_subchannel_q[7] = abs_msf.f;
    }

    fn readNextSector(self: *CdRom) void {
        self.drive.sectors_delivered += 1;
        const lba = self.drive.seek_target.toLba();
        var raw_sector: [2352]u8 = [_]u8{0} ** 2352;

        if (self.disc) |d| {
            if (!d.readSector2352(lba, &raw_sector)) {
                self.drive.drive_state = .Idle;
                self.queueIrq(5, 1000, &[_]u8{self.getDriveStatus() | 0x01}); // Read error
                return;
            }

            @memcpy(&self.drive.last_sector_header, raw_sector[0x0C..0x14]);
            self.updateSubchannelQ();
            self.drive.loc_l_valid = true;
        } else {
            self.synthesizeHeaderAndQ(self.drive.seek_target);
            self.drive.loc_l_valid = true;
        }

        self.drive.current_pos = self.drive.seek_target;
        self.drive.seek_target = disc.MSF.fromLba(lba + 1);

        if (self.drive.drive_state == .Playing) {
            // Sector arrival only refills the raw sector. The FIFO software
            // reads from is loaded later, on Request(0x80).
            self.fifos.last_raw_sector = raw_sector;
            cdda.handleSector(self, lba, &raw_sector);
            return;
        }

        // With XA-ADPCM enabled, a real-time audio sector belongs to the audio
        // decoder alone: it never reaches the data FIFO and posts no INT1. That
        // is what lets a game read an interleaved file with a single ReadN and
        // still see a contiguous data stream. A sector the filter rejects is
        // dropped just as silently. With bit 6 clear the drive is not decoding
        // ADPCM at all, so the sector is ordinary data.
        if ((self.drive.mode & 0x40) != 0 and xa.isXaAudioSector(self, &raw_sector)) {
            xa.playXaAudioSector(self, &raw_sector);
            return;
        }

        self.fifos.last_raw_sector = raw_sector;
        self.queueIrq(1, 0, &[_]u8{self.getDriveStatus()});
    }

    /// 33868800 / 75 Hz = 451584 cycles per sector; mode bit7 halves it.
    fn cyclesPerSector(self: *const CdRom) i64 {
        return if (self.drive.mode & 0x80 != 0) 225792 else 451584;
    }

    pub fn getDriveStatus(self: *const CdRom) u8 {
        var stat = self.drive.status & 0x1F;
        switch (self.drive.drive_state) {
            .Reading => stat |= 0x20,
            .Seeking => stat |= 0x40,
            .Playing => stat |= 0x80,
            .Idle => {},
        }
        return stat;
    }

    fn getStatus(self: *const CdRom) u8 {
        var stat: u8 = @as(u8, self.regs.index);
        if (self.fifos.parameter_len == 0) stat |= (1 << 3);
        if (self.fifos.parameter_len < 16) stat |= (1 << 4);

        const has_response = if (self.fifos.irq_queue.peek()) |item| (item.delay <= 0 and item.response_ptr < item.response_len) else false;
        if (has_response) stat |= (1 << 5);
        if (!self.fifos.data_fifo_empty) stat |= (1 << 6);
        if (self.regs.busy_for > 0) stat |= (1 << 7);

        return stat;
    }

    pub fn updateSubchannelQ(self: *CdRom) void {
        const current_lba = self.drive.current_pos.toLba();
        const current_track = if (self.disc) |d| d.trackForLba(current_lba) else disc.Track{
            .number = 1,
            .start_lba = 0,
        };
        const track_lba = current_track.start_lba;

        var relative_frames: i32 = 0;
        var index: u8 = 1;
        if (current_lba < track_lba) {
            relative_frames = track_lba - current_lba;
            index = 0; // Pregap
        } else {
            relative_frames = current_lba - track_lba;
        }

        const relative = disc.MSF.fromFrames(relative_frames);

        self.drive.last_subchannel_q[0] = disc.binaryToBcd(current_track.number);
        self.drive.last_subchannel_q[1] = disc.binaryToBcd(index);
        self.drive.last_subchannel_q[2] = relative.m;
        self.drive.last_subchannel_q[3] = relative.s;
        self.drive.last_subchannel_q[4] = relative.f;
        self.drive.last_subchannel_q[5] = self.drive.current_pos.m;
        self.drive.last_subchannel_q[6] = self.drive.current_pos.s;
        self.drive.last_subchannel_q[7] = self.drive.current_pos.f;
    }

    pub fn queueIrq(self: *CdRom, irq: u8, delay: i64, resp: []const u8) void {
        self.fifos.irq_queue.push(irq, delay, resp);
    }

    pub fn updateInterrupts(self: *CdRom, interrupts: *InterruptController) void {
        // The drive drives a *level* on its IRQ line — high while an enabled,
        // unacknowledged interrupt is pending — but I_STAT latches the low->high
        // *edge*. Both halves matter, and getting either wrong is a real bug we
        // have shipped:
        //
        //  - Re-latching on the level delivers a phantom second interrupt,
        //    because the BIOS handler
        //    acknowledges I_STAT *before* it writes the CDROM IFR. The handler
        //    re-enters, reads an IFR that by then reads 0, and records IRQ=0 —
        //    that is `cdrom/getloc`'s "GetlocL failed, IRQ = 0".
        //  - A once-only latch per queue item (what this code did before June)
        //    loses interrupts that become enabled after they are queued, which
        //    is why it was replaced with the level model in the first place.
        //
        // Tracking the line itself gets both: an item that is queued while
        // masked raises a genuine edge when software enables it.
        const line = if (self.fifos.irq_queue.peek()) |item|
            item.delay <= 0 and !item.ack and ((self.regs.irq_enable & item.irq & 7) != 0)
        else
            false;

        if (line and !self.fifos.irq_line) interrupts.trigger(.Cdrom);
        self.fifos.irq_line = line;
    }

    pub fn pushXaSample(self: *CdRom, l: i16, r: i16) void {
        const next = (self.audio.audio_fifo_write + 1) % self.audio.audio_fifo_l.len;
        if (next == self.audio.audio_fifo_read) return; // FIFO full: drop rather than wrap over unread samples
        self.audio.audio_fifo_l[self.audio.audio_fifo_write] = l;
        self.audio.audio_fifo_r[self.audio.audio_fifo_write] = r;
        self.audio.audio_fifo_write = next;
    }
};
