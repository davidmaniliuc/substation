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

fn ttyWrite(ctx: ?*anyopaque, ch: u8) void {
    _ = ctx;
    std.debug.print("{c}", .{ch});
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
        std.debug.print("usage: ps1-trace <bios.bin> <disc.bin> [max_instr] [snapdir] [autostart]\n", .{});
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
        const cue_text = try std.Io.Dir.cwd().readFileAlloc(init.io, disc_path, a, .limited(1024 * 1024));
        const bin_path = try std.fmt.allocPrint(a, "{s}.bin", .{disc_path[0 .. disc_path.len - 4]});
        const bin_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, bin_path, a, .limited(900 * 1024 * 1024));
        d = ps1.disc.Disc.initFromCue(cue_text, bin_bytes);
        std.debug.print("[probe] cue: {} sectors, tracks {}..{}\n", .{ bin_bytes.len / 2352, d.firstTrack(), d.lastTrack() });
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

    var i: u64 = 0;
    while (i < max_instr) : (i += 1) {
        if (autostart) {
            if (i % press_period == 0) {
                cpu.bus.sio.setButtons(press_seq[press_idx]);
                press_idx = (press_idx + 1) % press_seq.len;
            }
            if (i % press_period == press_hold) cpu.bus.sio.setButtons(released);
        }

        if (i & 0xF == 0) {
            const e = try pc_hist.getOrPut(cpu.pc);
            if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
        }
        cpu.step();

        const cd = &cpu.bus.cdrom;
        const spu = &cpu.bus.spu;

        // CD command boundary: a write to the command port latches pending_command.
        if (cd.pending_command) |c| {
            if (prev_pending == null) cd_cmd_hist[c] += 1;
        }
        prev_pending = cd.pending_command;

        // Sector-delivery boundary: which drive mode produced it, and did the
        // sector reach the audio FIFO at all?
        if (cd.sectors_delivered != prev_sectors_delivered) {
            prev_sectors_delivered = cd.sectors_delivered;
            switch (cd.drive_state) {
                .Playing => sectors_played += 1,
                else => sectors_read += 1,
            }
            if (cd.audio_fifo_write != prev_fifo_w) xa_sectors += 1;
            prev_fifo_w = cd.audio_fifo_write;
        }

        // SPU voice key-on boundary. keyOn() always restarts the envelope into
        // Attack, so an into-Attack transition catches a re-trigger of a voice
        // that never went is_on=false (an off->on edge would miss those).
        var voices_on: u32 = 0;
        for (&spu.voices, 0..) |*v, vi| {
            const attacking = v.env.state == .Attack;
            if (attacking and !prev_voice_on[vi]) key_ons += 1;
            prev_voice_on[vi] = attacking;
            if (v.is_on) {
                voices_on += 1;
                if (v.env.current_ad_vol > 0x100) voice_samples_nz += 1;
            }
        }
        if (voices_on > max_voices_on) max_voices_on = voices_on;

        // SPU output boundary: what actually lands in the ring buffer.
        if (spu.write_idx != prev_out_idx) {
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
        if (cd.audio_fifo_write != prev_fifo_scan) {
            var idx = prev_fifo_scan;
            while (idx != cd.audio_fifo_write) : (idx = (idx + 1) % cd.audio_fifo_l.len) {
                cd_pushes += 1;
                if (cd.audio_fifo_l[idx] != 0 or cd.audio_fifo_r[idx] != 0) cd_pushes_nz += 1;
            }
            prev_fifo_scan = cd.audio_fifo_write;
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
            for (cpu.bus.spu.sram) |b| {
                if (b != 0) spu_ram_nz += 1;
            }
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
    const cur_lba = cpu.bus.cdrom.current_pos.toLba();
    var sec_nz: u32 = 0;
    for (cpu.bus.cdrom.last_raw_sector) |b| {
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
            instr,                c.sectors_read,
            c.sectors_played,     c.xa_sectors,
            c.cd_pushes_nz,       c.cd_pushes,
            cpu.bus.cdrom.mode,   cpu.bus.cdrom.muted,
            c.key_ons,            c.max_voices_on,
            c.voice_samples_nz,   c.spu_ram_nz,
            c.out_nz,             c.out_peak,
            spu.spu_cnt,          spu.main_vol_l,
            spu.main_vol_r,       spu.mix.cd_vol_l,
            spu.mix.cd_vol_r,     spu.mix.current_cd_l,
            spu.mix.current_cd_r, c.n_uploads,
            de.vram_x_start,      de.vram_y_start,
            w,                    h,
            is24,                 de.display_disabled,
            nonblack,             @as(u64, w) * @as(u64, h),
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
    std.debug.print(
        "            cpu: pc={x:0>8} sr={x:0>8} cause={x:0>8} | irq: stat={x:0>4} mask={x:0>4} | cdrom: drive={s} q={d} irq_en={x:0>2} pos={d}:{d}:{d}\n",
        .{
            cpu.pc,
            cpu.cop0.readReg(.sr),
            cpu.cop0.readReg(.cause),
            cpu.bus.interrupts.stat,
            cpu.bus.interrupts.mask,
            @tagName(cpu.bus.cdrom.drive_state),
            cpu.bus.cdrom.irq_queue.count,
            cpu.bus.cdrom.irq_enable,
            cpu.bus.cdrom.current_pos.m,
            cpu.bus.cdrom.current_pos.s,
            cpu.bus.cdrom.current_pos.f,
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
}
