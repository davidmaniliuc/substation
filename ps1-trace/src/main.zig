const std = @import("std");
const ps1 = @import("ps1_core");

// TEMPORARY audio-pipeline probe (revert to the clean syscall tracer when done).
//
// Logs, at every component boundary of the sound path:
//   CD command stream (esp. Play/ReadN) -> drive state -> XA vs CD-DA sector
//   decode -> cdrom audio FIFO -> spu.pushCdAudio -> SPU mix, alongside the
//   SPU voice path: DMA ch4 uploads -> SPU RAM -> key-on -> ADSR -> mix.
// Everything is sampled from OUTSIDE ps1-core (all state is pub), so the core
// is untouched.
//
// Usage: ps1-trace <bios.bin> <disc.bin|disc.cue> <max_instr> <snapshot_dir>

// TEMPORARY. `std.log`'s default level at ReleaseFast is `.err`, so every
// `std.log.warn` in ps1-core -- including the per-command CDROM line that
// `debug_enable` gates -- is compiled out of the optimised build this harness
// is meant to be run at. Without this the CD instrumentation is silently dead.
pub const std_options: std.Options = .{ .log_level = .warn };

/// TEMPORARY. Instruction count after which `cdrom.debug_enable` is turned on.
/// Tekken 3's headless wedge starts around 300M, and logging every command
/// from boot buries it, so the log is armed just before.
/// `std.math.maxInt(u64)` disables it. The game polls the CD hard enough that
/// a command line per call costs more than the emulation does.
const cd_log_from: u64 = 1_300_000_000;

/// TEMPORARY. Function-entry watch. Every entry printed carries `a0` and `ra`,
/// which between them turn "the game is stuck in a CD retry loop" into an
/// ordered call sequence. Armed by `PS1_FNWATCH=<instr>`; inert otherwise, and
/// the whole check is a handful of compares per step.
const WatchFn = struct { addr: u32, name: []const u8 };
const fn_watch = [_]WatchFn{
    .{ .addr = 0x8006bea8, .name = "q_cancel_all" },
    .{ .addr = 0x8006bf20, .name = "q_enqueue" },
    .{ .addr = 0x8006c084, .name = "q_start_read" },
    .{ .addr = 0x8006c1fc, .name = "q_request_abort" },
    .{ .addr = 0x8006c26c, .name = "cb_cmd(a0)" },
    .{ .addr = 0x8006c2a0, .name = "cb_data(a0)" },
    .{ .addr = 0x8006c41c, .name = "cb_data_other" },
    .{ .addr = 0x8008f08c, .name = "cd_read_start" },
    .{ .addr = 0x80090aa8, .name = "cd_get_sector" },
    .{ .addr = 0x80091f38, .name = "cd_set_data_cb" },
    .{ .addr = 0x80091fbc, .name = "cd_stop" },
    // The library's data-ready ISR converts the sector header it just read back
    // to an LBA and compares it with the one it asked for; a mismatch jumps to
    // the retry at 0x80092230. s0 = header LBA, v1 = expected LBA.
    .{ .addr = 0x800920d0, .name = "hdr_lba_check" },
    .{ .addr = 0x80092230, .name = "RETRY" },
};

fn ttyWrite(ctx: ?*anyopaque, ch: u8) void {
    _ = ctx;
    std.debug.print("{c}", .{ch});
}

/// Steps on one PC before a wedged DMA is called: comfortably longer than any
/// real wait loop, which still retires instructions.
const stall_threshold: u64 = 4_000_000;

/// Dumps the DMA state behind a frozen CPU, and follows a linked list with
/// Floyd's algorithm so a chain that closes into a ring is named as such.
fn reportStall(cpu: *ps1.cpu.Cpu, instr: u64) void {
    const dma = &cpu.bus.dma;
    std.debug.print("\n[stall] instr={d} pc={x:0>8} stalled={}\n", .{
        instr, cpu.pipeline.pc, dma.isCpuStalled(cpu.bus),
    });

    var culprit: ?usize = null;
    for (0..7) |c| {
        const ch = &dma.channels[c];
        if (!ch.transfer_active) continue;
        if (culprit == null) culprit = c;
        std.debug.print("[stall] ch{d} sync={d} madr={x:0>8} bcr={x:0>8} chcr={x:0>8} words={x:0>8} next={x:0>6}\n", .{
            c, (ch.control >> 9) & 3, ch.base_addr, ch.block_control, ch.control, ch.words_remaining, ch.linked_list_next,
        });
    }

    const idx = culprit orelse return;
    const ch = &dma.channels[idx];
    if ((ch.control >> 9) & 3 != 2) return;

    const ram: []const u8 = &cpu.bus.ram;
    const peek = struct {
        fn at(mem: []const u8, addr: u32) u32 {
            const a2 = addr & 0x1FFFFC;
            return std.mem.readInt(u32, mem[a2..][0..4], .little);
        }
    }.at;

    var slow = (if (ch.words_remaining == 0xFFFFFFFF) ch.base_addr else ch.linked_list_next) & 0x1FFFFC;
    var fast = slow;
    var nodes: u32 = 0;
    while (nodes < 400_000) : (nodes += 1) {
        const ns = peek(ram, slow) & 0xFFFFFF;
        if (ns == 0xFFFFFF) break;
        slow = ns & 0x1FFFFC;
        var k: u8 = 0;
        var done = false;
        while (k < 2) : (k += 1) {
            const nf = peek(ram, fast) & 0xFFFFFF;
            if (nf == 0xFFFFFF) {
                done = true;
                break;
            }
            fast = nf & 0x1FFFFC;
        }
        if (done) break;
        if (slow == fast) {
            var len: u32 = 1;
            var p = peek(ram, slow) & 0x1FFFFC;
            while (p != slow and len < 400_000) : (len += 1) p = peek(ram, p) & 0x1FFFFC;
            std.debug.print("[stall] CYCLE at {x:0>6} loop_len={d} after {d} nodes\n", .{ slow, len, nodes });
            return;
        }
    }
    std.debug.print("[stall] chain ended/limited after {d} nodes\n", .{nodes});
}

const LoadedCue = struct { cue: []const u8, data: []const u8, files: usize };

/// Reads a CUE plus every .bin it references, concatenated in cue order, and
/// hands back the sheet with a `REM FILESIZE` synthesized ahead of each FILE.
///
/// `Disc.initFromCue` takes one flat data slice and uses those FILESIZE lines
/// to work out where each FILE's base LBA falls; without them every FILE stacks
/// at LBA 0 and the audio tracks land on top of the data track. Rips split per
/// track (Tekken 3: one MODE2 data track plus two Red Book audio tracks) carry
/// no FILESIZE of their own, so it is derived from the files on disk. This
/// mirrors what ps1-wasm/www/index.html does with an uploaded folder, so the
/// two frontends see byte-identical discs.
fn loadCue(io: std.Io, a: std.mem.Allocator, cue_path: []const u8) !LoadedCue {
    const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1024 * 1024));
    const dir = std.fs.path.dirname(cue_path) orelse ".";

    // Pass 1: resolve every FILE and total up the image.
    var paths = std.ArrayList([]const u8).empty;
    var sizes = std.ArrayList(u64).empty;
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        const name = cueFileName(raw) orelse continue;
        const path = try std.fs.path.join(a, &.{ dir, name });
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        try paths.append(a, path);
        try sizes.append(a, st.size);
        total += st.size;
    }
    if (paths.items.len == 0) return error.CueHasNoFiles;

    // Pass 2: read them back to back into one exactly-sized image.
    const data = try a.alloc(u8, @intCast(total));
    var off: usize = 0;
    for (paths.items, sizes.items) |path, size| {
        const n = try std.Io.Dir.cwd().readFile(io, path, data[off..][0..@intCast(size)]);
        off += n.len;
    }

    // Pass 3: re-emit the sheet with the sizes attached.
    var cue = std.ArrayList(u8).empty;
    var i: usize = 0;
    lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        if (cueFileName(raw) != null) {
            try cue.print(a, "REM FILESIZE {d}\n", .{sizes.items[i]});
            i += 1;
        }
        try cue.appendSlice(a, raw);
        try cue.append(a, '\n');
    }

    return .{ .cue = cue.items, .data = data, .files = paths.items.len };
}

/// The quoted name out of a `FILE "foo.bin" BINARY` line, or null.
fn cueFileName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "FILE")) return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '"') orelse return null;
    const rest = trimmed[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..close];
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv = std.ArrayList([]const u8).empty;
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| try argv.append(a, arg);

    if (argv.items.len < 2) {
        std.debug.print("usage: ps1-trace <bios.bin> <disc.bin> [max_instr] [snapdir] [autostart|walk]\n", .{});
        return;
    }
    const bios_path = argv.items[0];
    const disc_path = argv.items[1];
    const max_instr: u64 = if (argv.items.len > 2) try std.fmt.parseInt(u64, argv.items[2], 10) else 400_000_000;
    const snap_dir: []const u8 = if (argv.items.len > 3) argv.items[3] else ".";
    // "autostart" cycles Start/Cross/Circle so intros, FMVs and title menus can
    // be walked past headlessly and a run can actually reach gameplay.
    // Off by default -- synthetic input perturbs a trace.
    const autostart = argv.items.len > 4 and std.mem.eql(u8, argv.items[4], "autostart");
    // "walk" is autostart plus a held Up. Scenes that are gated on the player
    // actually moving (Silent Hill's opening street, for one) are unreachable
    // with confirm presses alone, so a run just idles at the first one.
    const walk = argv.items.len > 4 and std.mem.eql(u8, argv.items[4], "walk");
    // TEMPORARY. "lean" drops the audio-pipeline probe: the 24-voice scan and
    // the SPU/CD FIFO ring scans that run on *every* instruction, plus the PC
    // histogram's hashmap insert. Those cost about 20x -- a full-probe run
    // manages ~330k instr/s, which puts a 600M-instruction reproduction over
    // half an hour. Nothing they measure is relevant to a display-list bug.
    const lean = for (argv.items) |arg| {
        if (std.mem.eql(u8, arg, "lean")) break true;
    } else false;

    var bus = try ps1.memory.Bus.init(a);
    var cpu = ps1.cpu.Cpu.init(bus);

    const bios = try std.Io.Dir.cwd().readFileAlloc(init.io, bios_path, a, .limited(1024 * 1024));
    if (bios.len != 512 * 1024) {
        std.debug.print("BIOS must be 512KB, got {}\n", .{bios.len});
        return;
    }
    @memcpy(bus.bios[0..], bios);
    cpu.tty_write_fn = ttyWrite;

    // A .cue path loads the real multi-track TOC (CD-DA tracks included); a bare
    // .bin falls back to the one-data-track-at-LBA-0 model, which cannot
    // represent Red Book audio at all.
    var d: ps1.disc.Disc = undefined;
    if (std.mem.endsWith(u8, disc_path, ".cue") or std.mem.endsWith(u8, disc_path, ".CUE")) {
        const loaded = try loadCue(init.io, a, disc_path);
        d = ps1.disc.Disc.initFromCue(loaded.cue, loaded.data);
        std.debug.print("[probe] cue: {} sectors, {} file(s), tracks {}..{}\n", .{
            loaded.data.len / 2352, loaded.files, d.firstTrack(), d.lastTrack(),
        });
    } else {
        const disc_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, disc_path, a, .limited(900 * 1024 * 1024));
        d = ps1.disc.Disc.init(disc_bytes);
        std.debug.print("[probe] disc: {} sectors\n", .{disc_bytes.len / 2352});
    }
    cpu.bus.cdrom.setDisc(d);
    std.debug.print("[probe] bios: {s}\n", .{bios_path});

    // ---- boundary counters ----
    var cd_cmd_hist = [_]u64{0} ** 256; // CD command opcode histogram
    var sectors_read: u64 = 0; // sectors delivered while Reading
    var sectors_played: u64 = 0; // sectors delivered while Playing (CD-DA)
    var xa_sectors: u64 = 0; // sectors that decoded as XA audio
    var cd_pushes: u64 = 0; // spu.pushCdAudio calls
    var cd_pushes_nz: u64 = 0; // ...of which carried a non-zero sample
    var key_ons: u64 = 0; // voice off->on transitions
    var voice_samples_nz: u64 = 0; // mixed samples where some voice was audible
    var max_voices_on: u32 = 0;
    var spu_ram_nz: u64 = 0; // non-zero halfwords in SPU RAM (sampled)
    var out_nz: u64 = 0; // non-zero SPU output samples
    var out_peak: f32 = 0;
    var n_uploads: u64 = 0; // GP0(A0) VRAM uploads started (frame-progress signal)

    var prev_pending: ?u8 = null;
    var prev_sectors_delivered: u64 = 0;
    var prev_fifo_w: usize = 0;
    var prev_fifo_scan: usize = 0;
    var prev_voice_on = [_]bool{false} ** 24;
    var prev_out_idx: usize = 0;
    var prev_write_active = false;

    const snap_every: u64 = 10_000_000;
    var next_snap: u64 = snap_every;

    // PC histogram over each snapshot window (sampled every 16 instructions).
    var pc_hist = std.AutoHashMap(u32, u32).init(a);

    const press_period: u64 = 4_000_000;
    const press_hold: u64 = 1_000_000;
    // buttons are active-low (0 = pressed), so a press clears one bit of 0xFFFF.
    const released: u16 = 0xFFFF;
    const press_seq = [_]u16{
        released & ~@as(u16, 1 << 3), // Start  - skip FMVs, leave the title
        released & ~@as(u16, 1 << 14), // Cross  - confirm (US)
        released & ~@as(u16, 1 << 13), // Circle - confirm (JP layout)
    };
    var press_idx: usize = 0;

    // TEMPORARY. See `fn_watch`.
    const fn_watch_from: u64 = if (std.c.getenv("PS1_FNWATCH")) |s|
        std.fmt.parseInt(u64, std.mem.span(s), 10) catch std.math.maxInt(u64)
    else
        std.math.maxInt(u64);

    var prev_sec_count: u64 = 0;
    var prev_q_key: u32 = 0xFFFF_FFFF;
    var prev_fifo_empty = true;

    var stall_pc: u32 = 0;
    var stall_count: u64 = 0;

    var i: u64 = 0;
    while (i < max_instr) : (i += 1) {
        if (autostart or walk) {
            // In walk mode the idle state between confirm presses holds Up, so
            // the player keeps moving instead of standing still.
            const idle: u16 = if (walk) released & ~@as(u16, 1 << 4) else released;
            if (i % press_period == 0) {
                cpu.bus.sio.setButtons(press_seq[press_idx]);
                press_idx = (press_idx + 1) % press_seq.len;
            }
            if (i % press_period == press_hold) cpu.bus.sio.setButtons(idle);
        }

        if (!lean and i & 0xF == 0) {
            const e = try pc_hist.getOrPut(cpu.pipeline.pc);
            if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
        }
        if (i == cd_log_from or i == fn_watch_from) cpu.bus.cdrom.trace_commands = true;

        // TEMPORARY. Sector arrival vs. data-FIFO latch. A sector that arrives
        // while the previous one is still undrained overwrites `last_raw_sector`,
        // so the pair of streams has to be read side by side to see which sector
        // software actually ends up with.
        if (i >= fn_watch_from) {
            const cdr = &cpu.bus.cdrom;
            if (cdr.drive.sectors_delivered != prev_sec_count) {
                prev_sec_count = cdr.drive.sectors_delivered;
                std.debug.print("[sec] i={d} hdr={x:0>2}:{x:0>2}:{x:0>2} state={s} fifo_empty={} q={d}\n", .{
                    i,                          cdr.drive.last_sector_header[0],
                    cdr.drive.last_sector_header[1], cdr.drive.last_sector_header[2],
                    @tagName(cdr.drive.drive_state), cdr.fifos.data_fifo_empty,
                    cdr.fifos.irq_queue.count,
                });
            }
            if (prev_fifo_empty and !cdr.fifos.data_fifo_empty) {
                std.debug.print("[latch] i={d} first={x}\n", .{ i, cdr.fifos.sector_buffer[0..4] });
            }
            prev_fifo_empty = cdr.fifos.data_fifo_empty;

            const head_irq: u8 = if (cdr.fifos.irq_queue.peek()) |head| head.irq else 0;
            const key = (@as(u32, @intCast(cdr.fifos.irq_queue.count)) << 8) | head_irq;
            if (key != prev_q_key) {
                prev_q_key = key;
                const dly: i64 = if (cdr.fifos.irq_queue.peek()) |head| head.delay else 0;
                std.debug.print("[q] i={d} count={d} head_irq={d} delay={d} istat={x:0>4} imask={x:0>4} irq_en={x:0>2}\n", .{
                    i,                       cdr.fifos.irq_queue.count, head_irq, dly,
                    cpu.bus.interrupts.stat, cpu.bus.interrupts.mask,   cdr.regs.irq_enable,
                });
            }
        }

        // TEMPORARY. See `fn_watch`.
        if (i >= fn_watch_from) {
            const pc = cpu.pipeline.pc;
            for (fn_watch) |w| {
                if (pc == w.addr) {
                    const sp_buf = cpu.regs[29] +% 16;
                    var hdr: [12]u8 = undefined;
                    for (&hdr, 0..) |*b, k| b.* = cpu.bus.ram[(sp_buf +% @as(u32, @intCast(k))) & 0x1FFFFF];
                    std.debug.print("[fn] i={d} {s} a0={x:0>8} a1={x:0>8} v1={x:0>8} s0={x:0>8} s1={x:0>8} ra={x:0>8} drive={s} pos={x:0>2}:{x:0>2}:{x:0>2} sp16={x}\n", .{
                        i,                                          w.name,
                        cpu.regs[4],                                cpu.regs[5],
                        cpu.regs[3],                                cpu.regs[16],
                        cpu.regs[17],                               cpu.regs[31],
                        @tagName(cpu.bus.cdrom.drive.drive_state),  cpu.bus.cdrom.drive.current_pos.m,
                        cpu.bus.cdrom.drive.current_pos.s,          cpu.bus.cdrom.drive.current_pos.f,
                        &hdr,
                    });
                    break;
                }
            }
        }

        // TEMPORARY. A fine-grained progress line: the 10M-instruction
        // snapshot is far too coarse to see the CD step blow up, and once it
        // does the run never reaches the next snapshot at all.
        if (lean and i % 20_000_000 == 0) {
            const dr = &cpu.bus.cdrom.drive;
            std.debug.print("[tick] i={d} pc={x:0>8} drive={s} delivered={d} sector_timer={d} seek_timer={d} mode={x:0>2} pos={x:0>2}:{x:0>2}:{x:0>2}\n", .{
                i,                 cpu.pipeline.pc, @tagName(dr.drive_state), dr.sectors_delivered,
                dr.sector_timer,   dr.seek_timer,   dr.mode,                  dr.current_pos.m,
                dr.current_pos.s, dr.current_pos.f,
            });
        }

        cpu.step();

        // A DMA channel that never reaches its end condition owns the bus for
        // good: isCpuStalled gates every cpu.step(), so the PC stops moving
        // entirely while the peripherals carry on. Millions of steps on one
        // address is that, not a slow loop.
        if (cpu.pipeline.pc == stall_pc) {
            stall_count += 1;
            if (stall_count == stall_threshold) {
                reportStall(&cpu, i);
                break;
            }
        } else {
            stall_pc = cpu.pipeline.pc;
            stall_count = 0;
        }

        const cd = &cpu.bus.cdrom;
        const spu = &cpu.bus.spu;

        // CD command boundary: a write to the command port latches pending_command.
        if (cd.pending_command) |c| {
            if (prev_pending == null) cd_cmd_hist[c] += 1;
        }
        prev_pending = cd.pending_command;

        // Sector-delivery boundary: which drive mode produced it, and did the
        // sector reach the audio FIFO at all?
        if (cd.drive.sectors_delivered != prev_sectors_delivered) {
            prev_sectors_delivered = cd.drive.sectors_delivered;
            switch (cd.drive.drive_state) {
                .Playing => sectors_played += 1,
                else => sectors_read += 1,
            }
            if (cd.audio.audio_fifo_write != prev_fifo_w) xa_sectors += 1;
            prev_fifo_w = cd.audio.audio_fifo_write;
        }

        // SPU voice key-on boundary. keyOn() always restarts the envelope into
        // Attack, so an into-Attack transition catches a re-trigger of a voice
        // that never went is_on=false (an off->on edge would miss those).
        var voices_on: u32 = 0;
        if (!lean) for (&spu.voices, 0..) |*v, vi| {
            const attacking = v.env.state == .Attack;
            if (attacking and !prev_voice_on[vi]) key_ons += 1;
            prev_voice_on[vi] = attacking;
            if (v.is_on) {
                voices_on += 1;
                if (v.env.current_ad_vol > 0x100) voice_samples_nz += 1;
            }
        };
        if (voices_on > max_voices_on) max_voices_on = voices_on;

        // SPU output boundary: what actually lands in the ring buffer.
        if (!lean and spu.write_idx != prev_out_idx) {
            var idx = prev_out_idx;
            while (idx != spu.write_idx) : (idx = (idx + 1) % spu.output_buffer.len) {
                const s = spu.output_buffer[idx];
                if (s != 0) out_nz += 1;
                const mag = if (s < 0) -s else s;
                if (mag > out_peak) out_peak = mag;
            }
            prev_out_idx = spu.write_idx;
        }
        // Count the samples actually written into the CD audio FIFO, and how
        // many of them are non-zero: a FIFO that fills with silence and one
        // that never fills at all look identical from the SPU side.
        if (!lean and cd.audio.audio_fifo_write != prev_fifo_scan) {
            var idx = prev_fifo_scan;
            while (idx != cd.audio.audio_fifo_write) : (idx = (idx + 1) % cd.audio.audio_fifo_l.len) {
                cd_pushes += 1;
                if (cd.audio.audio_fifo_l[idx] != 0 or cd.audio.audio_fifo_r[idx] != 0) cd_pushes_nz += 1;
            }
            prev_fifo_scan = cd.audio.audio_fifo_write;
        }

        // VRAM upload boundary (GP0 A0 -> setupWrite).
        const wa = cpu.bus.gpu.vram.write_active;
        if (wa and !prev_write_active) {
            n_uploads += 1;
        }
        prev_write_active = wa;

        if (i >= next_snap) {
            next_snap += snap_every;
            spu_ram_nz = 0;
            if (!lean) for (cpu.bus.spu.sram) |b| {
                if (b != 0) spu_ram_nz += 1;
            };
            try snapshot(a, init, &cpu, snap_dir, i, .{
                .sectors_read = sectors_read,
                .sectors_played = sectors_played,
                .xa_sectors = xa_sectors,
                .cd_pushes = cd_pushes,
                .cd_pushes_nz = cd_pushes_nz,
                .key_ons = key_ons,
                .voice_samples_nz = voice_samples_nz,
                .max_voices_on = max_voices_on,
                .spu_ram_nz = spu_ram_nz,
                .out_nz = out_nz,
                .out_peak = out_peak,
                .n_uploads = n_uploads,
            });

            std.debug.print("            voices:", .{});
            for (&cpu.bus.spu.voices, 0..) |*v, vi| {
                if (vi >= 8) break;
                std.debug.print(" {d}:{s}{s}v={d}/p={x:0>4}", .{
                    vi,
                    @tagName(v.env.state),
                    if (v.is_on) "*" else "-",
                    v.env.current_ad_vol,
                    v.regs.pitch,
                });
            }
            std.debug.print("\n            cd cmds:", .{});
            for (cd_cmd_hist, 0..) |n, op| {
                if (n != 0) std.debug.print(" {x:0>2}={d}", .{ op, n });
            }
            std.debug.print("\n", .{});

            // Top PCs in this window.
            var top: [8]struct { pc: u32, n: u32 } = @splat(.{ .pc = 0, .n = 0 });
            var hit = pc_hist.iterator();
            while (hit.next()) |kv| {
                var slot: usize = 0;
                while (slot < top.len) : (slot += 1) {
                    if (kv.value_ptr.* > top[slot].n) {
                        var j = top.len - 1;
                        while (j > slot) : (j -= 1) top[j] = top[j - 1];
                        top[slot] = .{ .pc = kv.key_ptr.*, .n = kv.value_ptr.* };
                        break;
                    }
                }
            }
            std.debug.print("            pc: ", .{});
            for (top) |t| {
                if (t.n != 0) std.debug.print("{x:0>8}={d} ", .{ t.pc, t.n });
            }
            std.debug.print("(distinct={d})\n", .{pc_hist.count()});
            pc_hist.clearRetainingCapacity();
        }
    }

    // PS1_RAM_DUMP=1 writes the full 2 MB RAM image at the end of the run, for
    // offline disassembly of whatever game code a trace has implicated.
    if (std.c.getenv("PS1_RAM_DUMP") != null) {
        const rpath = try std.fmt.allocPrint(a, "{s}/ram.bin", .{snap_dir});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = rpath, .data = bus.peekRam(0, 0x200000) });
        std.debug.print("[probe] wrote {s}\n", .{rpath});
    }

    std.debug.print("\n[probe] done at {} instr\n", .{i});
}

const Counters = struct {
    sectors_read: u64,
    sectors_played: u64,
    xa_sectors: u64,
    cd_pushes: u64,
    cd_pushes_nz: u64,
    key_ons: u64,
    voice_samples_nz: u64,
    max_voices_on: u32,
    spu_ram_nz: u64,
    out_nz: u64,
    out_peak: f32,
    n_uploads: u64,
};

fn snapshot(
    a: std.mem.Allocator,
    init: std.process.Init,
    cpu: *ps1.cpu.Cpu,
    dir: []const u8,
    instr: u64,
    c: Counters,
) !void {
    const gpu = &cpu.bus.gpu;
    const de = gpu.disp_env;
    const w = de.getVisibleWidth();
    const h = de.getVisibleHeight();
    const is24 = (de.display_mode & (1 << 4)) != 0;

    // Count non-black pixels in the currently displayed VRAM rect.
    var nonblack: u64 = 0;
    const vram = &gpu.vram.data;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const vy = (de.vram_y_start + y) & 0x1FF;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const vx = (de.vram_x_start + x) & 0x3FF;
            if (vram[vy * 1024 + vx] != 0) nonblack += 1;
        }
    }

    const spu = &cpu.bus.spu;
    const cur_lba = cpu.bus.cdrom.drive.current_pos.toLba();
    var sec_nz: u32 = 0;
    for (cpu.bus.cdrom.fifos.last_raw_sector) |b| {
        if (b != 0) sec_nz += 1;
    }
    const cur_trk = if (cpu.bus.cdrom.disc) |dd| dd.trackForLba(cur_lba) else ps1.disc.Track{ .number = 0 };
    std.debug.print("            cd pos: lba={d} sec_nz={d}/2352 trk={d}/{s} start_lba={d}\n", .{
        cur_lba,           sec_nz,
        cur_trk.number,    @tagName(cur_trk.type),
        cur_trk.start_lba,
    });
    std.debug.print(
        "\n[probe @{d}] cd: read={d} played={d} xa={d} fifo_nonempty={d}/{d} mode={x:0>2} muted={}\n" ++
            "            spu: key_ons={d} max_on={d} voice_nz={d} ram_nz={d} out_nz={d} peak={d:.4}\n" ++
            "            spu regs: cnt={x:0>4} main=({d},{d}) cd_vol=({d},{d}) cd_cur=({d},{d})\n" ++
            "            gpu: uploads={d} disp=({d},{d}) {d}x{d} 24bpp={} off={} nonblack={d}/{d}\n",
        .{
            instr,                    c.sectors_read,
            c.sectors_played,         c.xa_sectors,
            c.cd_pushes_nz,           c.cd_pushes,
            cpu.bus.cdrom.drive.mode, cpu.bus.cdrom.drive.muted,
            c.key_ons,                c.max_voices_on,
            c.voice_samples_nz,       c.spu_ram_nz,
            c.out_nz,                 c.out_peak,
            spu.spu_cnt,              spu.main_vol_l,
            spu.main_vol_r,           spu.mix.cd_vol_l,
            spu.mix.cd_vol_r,         spu.mix.current_cd_l,
            spu.mix.current_cd_r,     c.n_uploads,
            de.vram_x_start,          de.vram_y_start,
            w,                        h,
            is24,                     de.display_disabled,
            nonblack,                 @as(u64, w) * @as(u64, h),
        },
    );
    std.debug.print(
        "            disp: mode={x:0>6} hres_bits={d} vres={d} pal={d} ilace={d} | rangeX={d}..{d} (span={d}) rangeY={d}..{d} (span={d})\n",
        .{
            de.display_mode,
            (de.display_mode & 0x3) | ((de.display_mode >> 4) & 0x4),
            (de.display_mode >> 2) & 1,
            (de.display_mode >> 3) & 1,
            (de.display_mode >> 5) & 1,
            de.screen_x1,
            de.screen_x2,
            @as(i32, de.screen_x2) - @as(i32, de.screen_x1),
            de.screen_y1,
            de.screen_y2,
            @as(i32, de.screen_y2) - @as(i32, de.screen_y1),
        },
    );
    std.debug.print("            timers: t0 mode={x:0>4} cnt={x:0>4} tgt={x:0>4} | t1 mode={x:0>4} cnt={x:0>4} tgt={x:0>4} | t2 mode={x:0>4} cnt={x:0>4} tgt={x:0>4}\n", .{
        cpu.bus.timers[0].mode, cpu.bus.timers[0].counter, cpu.bus.timers[0].target,
        cpu.bus.timers[1].mode, cpu.bus.timers[1].counter, cpu.bus.timers[1].target,
        cpu.bus.timers[2].mode, cpu.bus.timers[2].counter, cpu.bus.timers[2].target,
    });
    std.debug.print(
        // MSF fields are BCD, so they print as hex digits -- {d} on a BCD byte
        // reads ~1.5x high (BCD 0x57 minutes shows as 87) and has already sent
        // one investigation chasing a seek past the end of the disc.
        "            cpu: pc={x:0>8} sr={x:0>8} cause={x:0>8} | irq: stat={x:0>4} mask={x:0>4} | cdrom: drive={s} q={d} irq_en={x:0>2} pos={x:0>2}:{x:0>2}:{x:0>2}\n",
        .{
            cpu.pipeline.pc,
            cpu.cop0.readReg(.sr),
            cpu.cop0.readReg(.cause),
            cpu.bus.interrupts.stat,
            cpu.bus.interrupts.mask,
            @tagName(cpu.bus.cdrom.drive.drive_state),
            cpu.bus.cdrom.fifos.irq_queue.count,
            cpu.bus.cdrom.regs.irq_enable,
            cpu.bus.cdrom.drive.current_pos.m,
            cpu.bus.cdrom.drive.current_pos.s,
            cpu.bus.cdrom.drive.current_pos.f,
        },
    );

    // Dump the displayed rect as a PPM so the frame can actually be looked at.
    var ppm = std.ArrayList(u8).empty;
    try ppm.appendSlice(a, try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ w, h }));
    y = 0;
    while (y < h) : (y += 1) {
        const vy = (de.vram_y_start + y) & 0x1FF;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            if (is24) {
                const byte_x = (de.vram_x_start * 2 + x * 3);
                const base = vy * 2048 + (byte_x % 2048);
                const bytes = std.mem.sliceAsBytes(vram[0..]);
                r = bytes[base + 0];
                g = bytes[(base + 1) % bytes.len];
                b = bytes[(base + 2) % bytes.len];
            } else {
                const vx = (de.vram_x_start + x) & 0x3FF;
                const p = vram[vy * 1024 + vx];
                r = @as(u8, @truncate((p & 0x1F) << 3));
                g = @as(u8, @truncate(((p >> 5) & 0x1F) << 3));
                b = @as(u8, @truncate(((p >> 10) & 0x1F) << 3));
            }
            try ppm.append(a, r);
            try ppm.append(a, g);
            try ppm.append(a, b);
        }
    }
    const path = try std.fmt.allocPrint(a, "{s}/frame_{d}.ppm", .{ dir, instr / 1_000_000 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = ppm.items });

    // PS1_VRAM_DUMP=1 also writes the whole 1024x512 VRAM. The displayed rect
    // alone cannot tell a corrupt texture page or CLUT apart from a bad fetch of
    // an intact one; this can.
    if (std.c.getenv("PS1_VRAM_DUMP") != null) {
        var vd = std.ArrayList(u8).empty;
        try vd.appendSlice(a, "P6\n1024 512\n255\n");
        for (0..512) |vy| {
            for (0..1024) |vx| {
                const p = vram[vy * 1024 + vx];
                try vd.append(a, @as(u8, @truncate((p & 0x1F) << 3)));
                try vd.append(a, @as(u8, @truncate(((p >> 5) & 0x1F) << 3)));
                try vd.append(a, @as(u8, @truncate(((p >> 10) & 0x1F) << 3)));
            }
        }
        const vpath = try std.fmt.allocPrint(a, "{s}/vram_{d}.ppm", .{ dir, instr / 1_000_000 });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = vpath, .data = vd.items });
    }
}
