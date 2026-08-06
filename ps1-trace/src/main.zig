const std = @import("std");
const ps1 = @import("ps1_core");

// TEMPORARY FMV-pipeline probe (revert to the clean syscall tracer when done).
//
// Logs, at every component boundary of the MDEC/FMV path:
//   DMA ch0 (MDECin) -> MDEC input FIFO -> decodeAllMacroblocks -> MDEC output
//   FIFO -> DMA ch1 (MDECout) -> RAM -> DMA ch2 (GPU) -> VRAM -> display env.
// Everything is sampled from OUTSIDE ps1-core (all state is pub), so the core
// is untouched.
//
// Usage: ps1-trace <bios.bin> <disc.bin> <max_instr> <snapshot_dir>

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
    // "autostart" taps Start twice a second so intros/FMVs/menus can be walked
    // past headlessly. Off by default -- synthetic input perturbs a trace.
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

    const disc_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, disc_path, a, .limited(700 * 1024 * 1024));
    cpu.bus.cdrom.setDisc(ps1.disc.Disc.init(disc_bytes));
    std.debug.print("[probe] disc: {} sectors, bios: {s}\n", .{ disc_bytes.len / 2352, bios_path });

    // ---- boundary counters ----
    var n_decode_cmds: u64 = 0; // MDEC cmd1 (decode macroblocks) issued
    var in_words: u64 = 0; // words pushed into MDEC input
    var out_words_made: u64 = 0; // words produced by decodeAllMacroblocks
    var out_words_read: u64 = 0; // words drained via readData (-> DMA ch1)
    var out_nonzero: u64 = 0; // of the produced words, how many are != 0
    var n_uploads: u64 = 0; // GP0(A0) VRAM uploads started
    var upload_px: u64 = 0; // pixels covered by those uploads
    var last_decode_first_word: u32 = 0;
    var last_decode_instr: u64 = 0;

    var prev_words_rem: u32 = 0;
    var prev_cmd: u32 = 0;
    var prev_out_len: usize = 0;
    var prev_out_ptr: usize = 0;
    var prev_write_active = false;

    const snap_every: u64 = 10_000_000;
    var next_snap: u64 = snap_every;

    // PC histogram over each snapshot window (sampled every 16 instructions).
    var pc_hist = std.AutoHashMap(u32, u32).init(a);

    const press_period: u64 = 8_000_000;
    const press_hold: u64 = 2_000_000;

    var i: u64 = 0;
    while (i < max_instr) : (i += 1) {
        if (autostart) {
            if (i % press_period == 0) cpu.bus.sio.setButtons(1 << 3);
            if (i % press_period == press_hold) cpu.bus.sio.setButtons(0);
        }

        if (i & 0xF == 0) {
            const e = try pc_hist.getOrPut(cpu.pc);
            if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
        }
        cpu.step();

        const m = &cpu.bus.mdec;

        // MDEC command boundary: a new decode command latches words_remaining.
        if (m.current_cmd == 1 and prev_words_rem == 0 and m.words_remaining > 0) {
            n_decode_cmds += 1;
        }
        if (m.current_cmd == 1 and m.words_remaining < prev_words_rem) {
            in_words += prev_words_rem - m.words_remaining;
        }

        // MDEC output production: output_len grows only in assembleMacroblock.
        if (m.output_len > prev_out_len and m.output_ptr == prev_out_ptr) {
            const made = m.output_len - prev_out_len;
            out_words_made += made;
            var k: usize = 0;
            var idx = (m.output_ptr + prev_out_len) % 131072;
            var first_nz: u32 = 0;
            while (k < made) : (k += 1) {
                const w = m.output_fifo[idx];
                if (w != 0) {
                    out_nonzero += 1;
                    if (first_nz == 0) first_nz = w;
                }
                idx = (idx + 1) % 131072;
            }
            if (first_nz != 0) last_decode_first_word = first_nz;
            last_decode_instr = i;
        }
        // MDEC output drain (readData advances output_ptr).
        if (m.output_ptr != prev_out_ptr) {
            out_words_read += (m.output_ptr + 131072 - prev_out_ptr) % 131072;
        }

        prev_words_rem = m.words_remaining;
        prev_cmd = m.current_cmd;
        prev_out_len = m.output_len;
        prev_out_ptr = m.output_ptr;

        // VRAM upload boundary (GP0 A0 -> setupWrite).
        const wa = cpu.bus.gpu.vram.write_active;
        if (wa and !prev_write_active) {
            n_uploads += 1;
            upload_px += cpu.bus.gpu.vram.write_w * cpu.bus.gpu.vram.write_h;
        }
        prev_write_active = wa;

        if (i >= next_snap) {
            next_snap += snap_every;
            try snapshot(a, init, &cpu, snap_dir, i, .{
                .n_decode_cmds = n_decode_cmds,
                .in_words = in_words,
                .out_words_made = out_words_made,
                .out_words_read = out_words_read,
                .out_nonzero = out_nonzero,
                .n_uploads = n_uploads,
                .upload_px = upload_px,
                .last_decode_first_word = last_decode_first_word,
                .last_decode_instr = last_decode_instr,
            });

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
    n_decode_cmds: u64,
    in_words: u64,
    out_words_made: u64,
    out_words_read: u64,
    out_nonzero: u64,
    n_uploads: u64,
    upload_px: u64,
    last_decode_first_word: u32,
    last_decode_instr: u64,
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

    std.debug.print(
        "\n[probe @{d}] mdec: cmds={d} in_w={d} out_made={d} out_read={d} out_nz={d} lastdec@{d} w0={x:0>8}\n" ++
            "            gpu: uploads={d} upload_px={d} disp=({d},{d}) {d}x{d} 24bpp={} off={} nonblack={d}/{d}\n" ++
            "            dma: dpcr={x:0>8} dicr={x:0>8} ch0_bcr={x:0>8} ch1_bcr={x:0>8}\n",
        .{
            instr,                    c.n_decode_cmds,
            c.in_words,               c.out_words_made,
            c.out_words_read,         c.out_nonzero,
            c.last_decode_instr,      c.last_decode_first_word,
            c.n_uploads,              c.upload_px,
            de.vram_x_start,          de.vram_y_start,
            w,                        h,
            is24,                     de.display_disabled,
            nonblack,                 @as(u64, w) * @as(u64, h),
            cpu.bus.dma.dpcr,         cpu.bus.dma.dicr,
            cpu.bus.dma.channels[0].block_control, cpu.bus.dma.channels[1].block_control,
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
