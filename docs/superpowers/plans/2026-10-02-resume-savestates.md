# Resume Savestates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Leaving a running game offers to save its state; opening that game again offers Resume / Fresh Boot / Delete & Boot / Cancel with a thumbnail. States survive app updates.

**Architecture:** A versioned, sectioned, hand-written serializer in `ps1-core/src/savestate/` (one section per device, each with its own version) behind three `ps1-capi` calls. The macOS app services save requests on the emulator thread, compresses with LZFSE, stores one state + PNG per GAME under Application Support, and gates every way of leaving a game through one exit sheet.

**Tech Stack:** Zig 0.16.0 (core, C ABI, ps1-golden), Swift / SwiftUI / AppKit (macOS app), swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-02-resume-savestates-design.md`

### Deviations from the spec (decided while planning, from reading the code)

1. **Deferred-tick bookkeeping is SAVED, not caught up.** `gpu.cycle_debt`/`pending_cycles`/`event_countdown`, each timer's `pending_ticks`/`event_countdown`, and the CD-ROM's `pending_cycles`/`event_countdown` are written like any other field. A save then needs no settle, which is what lets `trace-golden -- savestate` restore at an arbitrary instruction and still match the golden bit for bit. Task 5 of this plan amends the spec.
2. **No deflate in the core.** Zig 0.16's compression API is in flux; the app compresses with `NSData.compressed(using: .lzfse)` instead. The core's format is uncompressed and CRC32-checked.
3. **No `disc_index` in the header.** The header carries the SERIAL of the disc in the tray; the app maps it to a disc of the game's group. One fact, not two that could disagree.
4. **Device serializers live in `ps1-core/src/savestate/`**, not in each device file: `cdrom.zig` (754), `dma.zig` (603), `gp0.zig` (1075) and `memory.zig` (939) are already over the ~600-line rule. They are hand-written per field exactly like `ps1-golden/src/state_hash.zig`, which is the model to copy.
5. **After a resume in the app, the memory cards read as freshly inserted.** The app installs the cards after `ps1_load_state` (as it does for every boot), and `setMemoryCardData` sets the "fresh" flag. That is the safe answer: the cards are shared across games and may have changed since the save, so the game must re-read the directory. The core's own round trip restores the flag exactly.

## Global Constraints

- `zig version` is **0.16.0**; std API is 0.16's (`std.Io.Dir.cwd()`, `std.testing.io`, `std.ArrayList(T).empty`).
- **Hand-written serialization only.** No `std.meta.fields` / `@typeInfo` loops over a device struct. The only `@typeInfo` allowed is on an ENUM to validate a tag (as `state_hash.zig` does for `Region`).
- **Every section is mandatory, carries its own version, and is all-or-nothing.** An unknown tag or a newer section version is `StateVersion`; a short/long section or bad bool/enum/narrow-int value is `StateCorrupt`.
- **Not in a state:** BIOS bytes (only its SHA-256), disc bytes (only its serial), memory-card IMAGES and their dirty flags, `expansion_1`, every `pgxp_*` field and PGXP shadow (`ram_shadow`, `scratch_shadow`, `pgxp_pending`, `gpr_shadow`, `load_shadow`, `delay_shadow`, `hi_shadow`, `lo_shadow`, `cop0_shadow`, `cop2.precise`, `gpu.fifo_pgxp`, `gp0.cmd_buffer_pgxp`, `gp0.pgxp*`, `gp0.depth_state`, `gp0.weld`, `gp0.vertex_cache`, `vram.depth`), `gpu.sink`, `cdrom.disc`, `cdrom.debug_enable`, `cdrom.trace_commands`, `spu.reverb_enable`, `cpu.bus`, `cpu.tty_context`, `cpu.tty_write_fn`.
- Error codes are exactly: `PS1_ERR_STATE_BAD_MAGIC -8`, `PS1_ERR_STATE_VERSION -9`, `PS1_ERR_STATE_BIOS -10`, `PS1_ERR_STATE_DISC -11`, `PS1_ERR_STATE_CORRUPT -12`, `PS1_ERR_STATE_NO_SPACE -13`.
- Storage: `Application Support/Substation/ResumeStates/<key>.state` (LZFSE) and `<key>.png`; `<key>` = the first disc of the game's group's serial, else the SHA-256 of its path (the `CoverStore` rule).
- Exit sheet copy: title **"Confirm Exit"**, checkbox **"Save State For Resume"** (persisted, default ON, key `saveStateOnExit`), buttons **"No"** / **"Yes"**. Question: "Are you sure you want to exit the application?" for quit/close, "Are you sure you want to exit the game?" for eject/open.
- Launch sheet buttons: **Resume** (default, ⏎) · **Fresh Boot** · **Delete & Boot** · **Cancel** (⎋).
- Commits: **title line only** (no body, no trailer), on `master`, one per task. **Never `git push`.**
- Run `zig fmt` on every touched `.zig` file before committing.
- Run `pkill -x Substation` before `ps1-macos/test.sh`.

## Review Focus

1. **Quit while the emulator thread never services the save** (wedged frame, or a thread that already exited): ⌘Q must still quit. A 3-second fallback finishes the exit without the save — pinned in Task 9 (`ExitCompletion` fires once).
2. **A second leave-request while the sheet is already up** (⌘Q while the Eject sheet shows, ⌘Q twice): must not stack a second sheet, and ⌘Q must get `.terminateCancel` rather than a `.terminateLater` that is never answered — pinned in Task 9 (`ExitGate`).
3. **A damaged or newer-version state file**: the launch sheet must still appear (so Delete & Boot is reachable), and Resume must explain why it failed and offer Fresh Boot — pinned in Task 9 (`ResumeOffer.make` with garbage) and Task 10 (alert).
4. **A state whose disc is no longer in the library** (the game's disc 2 was deleted or moved): Resume is disabled with an explanation instead of booting the wrong disc into a refused load — pinned in Task 9.
5. **A load refused by the core must leave the running machine untouched** (scratch-`Bus` swap) — pinned in Task 6 (`capi_test`).

---

### Task 1: The savestate byte stream

**Files:**
- Create: `ps1-core/src/savestate/stream.zig`
- Create: `ps1-core/tests/savestate_test.zig`
- Modify: `ps1-core/src/root.zig` (export the module)
- Modify: `build.zig:190-203` (add the test file to `unit_test_files`)

**Interfaces:**
- Produces (`ps1_core.savestate_stream` while only this file exists; Task 4 re-exports it as `ps1_core.savestate.stream`):
  - `pub const Error = error{ StateBadMagic, StateVersion, StateBios, StateDisc, StateCorrupt, NoSpace };`
  - `pub const Writer = struct { buf: ?[]u8 = null, len: usize = 0, fn bytes([]const u8) Error!void, fn int(anytype) Error!void, fn flag(bool) Error!void, fn tag(anytype) Error!void, fn array(anytype) Error!void, fn patchU32(usize, u32) void }`
  - `pub const Reader = struct { buf: []const u8, pos: usize = 0, fn bytes(usize) Error![]const u8, fn int(comptime T) Error!T, fn flag() Error!bool, fn tag(comptime E) Error!E, fn array(anytype) Error!void, fn end() Error!void }`

- [ ] **Step 1: Write the failing tests**

`ps1-core/tests/savestate_test.zig`:

```zig
const std = @import("std");
const ps1 = @import("ps1_core");
const stream = ps1.savestate_stream;

test "ints round-trip at their wire width, little-endian" {
    var buf: [64]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try w.int(@as(u5, 17));
    try w.int(@as(i16, -2));
    try w.int(@as(u32, 0xDEADBEEF));
    try w.int(@as(i64, -5));
    try w.int(@as(usize, 7));
    // u5 -> 1 byte, i16 -> 2, u32 -> 4, i64 -> 8, usize -> 8 (always u64 on the wire)
    try std.testing.expectEqual(@as(usize, 1 + 2 + 4 + 8 + 8), w.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[3..7]);

    var r = stream.Reader{ .buf = buf[0..w.len] };
    try std.testing.expectEqual(@as(u5, 17), try r.int(u5));
    try std.testing.expectEqual(@as(i16, -2), try r.int(i16));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.int(u32));
    try std.testing.expectEqual(@as(i64, -5), try r.int(i64));
    try std.testing.expectEqual(@as(usize, 7), try r.int(usize));
    try r.end();
}

test "a counting writer measures without writing" {
    var w = stream.Writer{};
    try w.int(@as(u32, 1));
    try w.array(&[_]i16{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 4 + 6), w.len);
}

test "a full buffer is NoSpace, not an overrun" {
    var buf: [3]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try std.testing.expectError(error.NoSpace, w.int(@as(u32, 1)));
}

test "out-of-range narrow ints, bools and enums are StateCorrupt" {
    const E = enum(u8) { a = 0, b = 5 };
    var r = stream.Reader{ .buf = &.{0x20} }; // 32 does not fit a u5
    try std.testing.expectError(error.StateCorrupt, r.int(u5));
    r = .{ .buf = &.{2} };
    try std.testing.expectError(error.StateCorrupt, r.flag());
    r = .{ .buf = &.{ 3, 0, 0, 0 } }; // 3 is not a value of E
    try std.testing.expectError(error.StateCorrupt, r.tag(E));
    r = .{ .buf = &.{ 5, 0, 0, 0 } };
    try std.testing.expectEqual(E.b, try r.tag(E));
}

test "reading past the end, or stopping short of it, is StateCorrupt" {
    var r = stream.Reader{ .buf = &.{ 1, 2 } };
    try std.testing.expectError(error.StateCorrupt, r.int(u32));
    r = .{ .buf = &.{ 1, 2 } };
    _ = try r.int(u8);
    try std.testing.expectError(error.StateCorrupt, r.end());
}

test "arrays of wide elements round-trip" {
    const src = [_]f32{ 1.5, -2.25, 0 };
    var buf: [12]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try w.array(&src);
    var dst: [3]f32 = undefined;
    var r = stream.Reader{ .buf = &buf };
    try r.array(&dst);
    try std.testing.expectEqualSlices(f32, &src, &dst);
}

test "patchU32 rewrites in place and is a no-op when counting" {
    var buf: [8]u8 = [_]u8{0} ** 8;
    var w = stream.Writer{ .buf = &buf };
    try w.int(@as(u32, 0));
    try w.int(@as(u32, 9));
    w.patchU32(0, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, buf[0..4]);
    var counting = stream.Writer{};
    try counting.int(@as(u32, 0));
    counting.patchU32(0, 5); // must not crash
}
```

In `build.zig`, add `"ps1-core/tests/savestate_test.zig",` as the last entry of `unit_test_files`. In `ps1-core/src/root.zig`, add:

```zig
pub const savestate_stream = @import("savestate/stream.zig");
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test -- --test-filter "wire width"` (or `zig build test` if filters are not wired — the binary must fail to compile)
Expected: FAIL — `unable to load 'ps1-core/src/savestate/stream.zig'`.

- [ ] **Step 3: Implement `stream.zig`**

```zig
//! The byte stream a savestate is written to and read from.
//!
//! Integers go out at the next whole-byte width of their type, little-endian;
//! `usize` always goes out as u64 so a state does not depend on the pointer
//! width of the build that wrote it. Arrays go out as their in-memory bytes,
//! which is the same little-endian wire format on every host this ships on —
//! the comptime check below makes any other host a compile error rather than
//! a silently byte-swapped state.
//!
//! Every read is checked. A value that does not fit its field (a 32 in a u5,
//! a 2 in a bool, an enum tag no variant carries) is `StateCorrupt`, never an
//! `@intCast` panic: the bytes come from a file on disk.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("savestates assume a little-endian host");
}

pub const Error = error{ StateBadMagic, StateVersion, StateBios, StateDisc, StateCorrupt, NoSpace };

fn WireInt(comptime T: type) type {
    if (T == usize) return u64;
    const info = @typeInfo(T).int;
    const bits = if (info.bits <= 8) 8 else if (info.bits <= 16) 16 else if (info.bits <= 32) 32 else 64;
    return std.meta.Int(info.signedness, bits);
}

pub const Writer = struct {
    /// Null counts without writing; that is how a caller sizes its buffer.
    buf: ?[]u8 = null,
    len: usize = 0,

    pub fn bytes(w: *Writer, b: []const u8) Error!void {
        if (w.buf) |buf| {
            if (b.len > buf.len - w.len) return error.NoSpace;
            @memcpy(buf[w.len..][0..b.len], b);
        }
        w.len += b.len;
    }

    pub fn int(w: *Writer, v: anytype) Error!void {
        const Wire = WireInt(@TypeOf(v));
        var tmp: [@sizeOf(Wire)]u8 = undefined;
        std.mem.writeInt(Wire, &tmp, v, .little);
        try w.bytes(&tmp);
    }

    pub fn flag(w: *Writer, v: bool) Error!void {
        try w.int(@as(u8, @intFromBool(v)));
    }

    pub fn tag(w: *Writer, v: anytype) Error!void {
        try w.int(@as(u32, @intFromEnum(v)));
    }

    /// `a` is a pointer to an array (of any element type, nested arrays included).
    pub fn array(w: *Writer, a: anytype) Error!void {
        try w.bytes(std.mem.sliceAsBytes(a[0..]));
    }

    /// Rewrites a u32 already written at `at` — the section and header
    /// lengths are only known after their contents.
    pub fn patchU32(w: *Writer, at: usize, v: u32) void {
        const buf = w.buf orelse return;
        std.mem.writeInt(u32, buf[at..][0..4], v, .little);
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.buf.len - r.pos) return error.StateCorrupt;
        defer r.pos += n;
        return r.buf[r.pos..][0..n];
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const Wire = WireInt(T);
        const raw = std.mem.readInt(Wire, (try r.bytes(@sizeOf(Wire)))[0..@sizeOf(Wire)], .little);
        return std.math.cast(T, raw) orelse error.StateCorrupt;
    }

    pub fn flag(r: *Reader) Error!bool {
        return switch (try r.int(u8)) {
            0 => false,
            1 => true,
            else => error.StateCorrupt,
        };
    }

    pub fn tag(r: *Reader, comptime E: type) Error!E {
        const v = try r.int(u32);
        inline for (@typeInfo(E).@"enum".fields) |f| {
            if (v == f.value) return @enumFromInt(f.value);
        }
        return error.StateCorrupt;
    }

    pub fn array(r: *Reader, a: anytype) Error!void {
        const dst = std.mem.sliceAsBytes(a[0..]);
        @memcpy(dst, try r.bytes(dst.len));
    }

    /// A section must be consumed exactly: a reader that stops short of the
    /// writer's length is reading a different layout than was written.
    pub fn end(r: *const Reader) Error!void {
        if (r.pos != r.buf.len) return error.StateCorrupt;
    }
};
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS (all 18 test binaries).

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/savestate/stream.zig ps1-core/tests/savestate_test.zig ps1-core/src/root.zig build.zig
git add ps1-core/src/savestate/stream.zig ps1-core/tests/savestate_test.zig ps1-core/src/root.zig build.zig
git commit -m "feat(core): savestate byte stream"
```

---

### Task 2: CPU, bus-memory and small-device sections

**Files:**
- Create: `ps1-core/src/savestate/cpu_state.zig`
- Create: `ps1-core/src/savestate/io_state.zig`
- Modify: `ps1-core/src/root.zig` (temporary exports, replaced in Task 4)
- Test: `ps1-core/tests/savestate_test.zig`

**Interfaces:**
- Consumes: `stream.Writer`, `stream.Reader`, `stream.Error` (Task 1).
- Produces — every section function has ONE of these two shapes, so Task 4 can put them in a table:
  - `pub fn saveX(cpu: *const Cpu, w: *Writer) Error!void`
  - `pub fn loadX(cpu: *Cpu, r: *Reader, version: u32) Error!void`
  - `cpu_state.zig`: `saveCpu`/`loadCpu`
  - `io_state.zig`: `saveBus`/`loadBus`, `saveIrq`/`loadIrq`, `saveTimers`/`loadTimers`, `saveDma`/`loadDma`, `saveSio`/`loadSio`, `saveMdec`/`loadMdec`

Before writing, re-derive each field list from the structs, not from this plan, and confirm they agree:
`grep -nE '^    [a-z_][a-z_0-9]*: ' ps1-core/src/cpu/cpu.zig ps1-core/src/cop0.zig ps1-core/src/cop2/cop2.zig ps1-core/src/interrupt.zig ps1-core/src/timer.zig ps1-core/src/dma.zig ps1-core/src/sio.zig ps1-core/src/mdec/mdec.zig`
Any field neither listed below nor in the Global Constraints' "Not in a state" list must be ADDED to the section, and reported.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/savestate_test.zig`. One helper builds a machine; each test pokes NON-default values into every saved field of one section, round-trips it into a fresh machine, and compares.

```zig
const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const cpu_state = ps1.savestate_cpu;
const io_state = ps1.savestate_io;

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init() !Machine {
        const bus = try Bus.init(std.testing.allocator);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(std.testing.allocator);
    }
};

fn roundTrip(
    src: *Machine,
    dst: *Machine,
    comptime save: fn (*const Cpu, *stream.Writer) stream.Error!void,
    comptime load: fn (*Cpu, *stream.Reader, u32) stream.Error!void,
) !void {
    var counter = stream.Writer{};
    try save(&src.cpu, &counter);
    const buf = try std.testing.allocator.alloc(u8, counter.len);
    defer std.testing.allocator.free(buf);
    var w = stream.Writer{ .buf = buf };
    try save(&src.cpu, &w);
    var r = stream.Reader{ .buf = buf };
    try load(&dst.cpu, &r, 1);
    try r.end();
}

test "cpu section restores registers, pipeline, load delay, icache, cop0 and cop2" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    a.cpu.regs[5] = 0x12345678;
    a.cpu.pipeline.pc = 0x80010000;
    a.cpu.pipeline.next_pc = 0x80010004;
    a.cpu.pipeline.current_pc = 0x8000FFFC;
    a.cpu.pipeline.is_delay_slot = true;
    a.cpu.pipeline.next_is_delay_slot = true;
    a.cpu.load_delay.load_r = 7;
    a.cpu.load_delay.load_v = 0xAA;
    a.cpu.load_delay.delay_r = 9;
    a.cpu.load_delay.delay_v = 0xBB;
    a.cpu.hi = 1;
    a.cpu.lo = 2;
    a.cpu.cycles = 123456789;
    a.cpu.gpu_clock_frac = 5;
    a.cpu.icache[3].tag = 0x40;
    a.cpu.icache[3].data[2] = 0x99;
    a.cpu.cop0.regs[12] = 0x10000;
    a.cpu.cop2.data_regs[1] = 77;
    a.cpu.cop2.ctrl_regs[31] = 0x80000000;
    a.cpu.cop2.macs[2] = -40000000000;

    try roundTrip(&a, &b, cpu_state.saveCpu, cpu_state.loadCpu);

    try std.testing.expectEqualDeep(a.cpu.regs, b.cpu.regs);
    try std.testing.expectEqualDeep(a.cpu.pipeline, b.cpu.pipeline);
    try std.testing.expectEqualDeep(a.cpu.load_delay, b.cpu.load_delay);
    try std.testing.expectEqual(a.cpu.hi, b.cpu.hi);
    try std.testing.expectEqual(a.cpu.lo, b.cpu.lo);
    try std.testing.expectEqual(a.cpu.cycles, b.cpu.cycles);
    try std.testing.expectEqual(a.cpu.gpu_clock_frac, b.cpu.gpu_clock_frac);
    try std.testing.expectEqualDeep(a.cpu.icache, b.cpu.icache);
    try std.testing.expectEqualDeep(a.cpu.cop0.regs, b.cpu.cop0.regs);
    try std.testing.expectEqualDeep(a.cpu.cop2.data_regs, b.cpu.cop2.data_regs);
    try std.testing.expectEqualDeep(a.cpu.cop2.ctrl_regs, b.cpu.cop2.ctrl_regs);
    try std.testing.expectEqualDeep(a.cpu.cop2.macs, b.cpu.cop2.macs);
}

test "bus section restores RAM, scratchpad, io ports, expansion 2/3 and the clocks" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    a.bus.ram[0x1234] = 0x5A;
    a.bus.scratchpad[10] = 0x11;
    a.bus.io_ports[0x100] = 0x22;
    a.bus.expansion_2[3] = 0x33;
    a.bus.expansion_3[4] = 0x44;
    a.bus.expansion_3_last_write_width = 2;
    a.bus.cache_control[0] = 0x55;
    a.bus.wait_cycles = 6;
    a.bus.sys_clock = 987654321;

    try roundTrip(&a, &b, io_state.saveBus, io_state.loadBus);

    try std.testing.expectEqualSlices(u8, &a.bus.ram, &b.bus.ram);
    try std.testing.expectEqualSlices(u8, &a.bus.scratchpad, &b.bus.scratchpad);
    try std.testing.expectEqualSlices(u8, &a.bus.io_ports, &b.bus.io_ports);
    try std.testing.expectEqualSlices(u8, &a.bus.expansion_2, &b.bus.expansion_2);
    try std.testing.expectEqualSlices(u8, &a.bus.expansion_3, &b.bus.expansion_3);
    try std.testing.expectEqual(a.bus.expansion_3_last_write_width, b.bus.expansion_3_last_write_width);
    try std.testing.expectEqualSlices(u8, &a.bus.cache_control, &b.bus.cache_control);
    try std.testing.expectEqual(a.bus.wait_cycles, b.bus.wait_cycles);
    try std.testing.expectEqual(a.bus.sys_clock, b.bus.sys_clock);
}

test "interrupt, timer and dma sections restore every field" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    a.bus.interrupts.stat = 0x5;
    a.bus.interrupts.mask = 0x7FF;
    for (&a.bus.timers, 0..) |*t, i| {
        const n: u32 = @intCast(i + 1);
        t.counter = n;
        t.mode = n * 2;
        t.target = n * 3;
        t.prescale_counter = n * 4;
        t.pending_ticks = n * 5;
        t.event_countdown = -@as(i64, n);
    }
    a.bus.dma.dpcr = 0x12345678;
    a.bus.dma.dicr = 0x00FF0000;
    a.bus.dma.busy_hint = true;
    const c = &a.bus.dma.channels[2];
    c.base_addr = 1;
    c.block_control = 2;
    c.control = 3;
    c.transfer_active = true;
    c.words_remaining = 4;
    c.linked_list_next = 5;
    c.ll_nodes = 6;
    c.chop_dma_window = 7;
    c.chop_cpu_window = 8;
    c.chop_is_cpu_turn = true;
    c.chop_counter = 9;
    c.block_words = 10;
    c.block_word_progress = 11;
    c.block_cycles = 12;
    c.block_gap_counter = 13;

    try roundTrip(&a, &b, io_state.saveIrq, io_state.loadIrq);
    try roundTrip(&a, &b, io_state.saveTimers, io_state.loadTimers);
    try roundTrip(&a, &b, io_state.saveDma, io_state.loadDma);

    try std.testing.expectEqualDeep(a.bus.interrupts, b.bus.interrupts);
    try std.testing.expectEqualDeep(a.bus.timers, b.bus.timers);
    try std.testing.expectEqualDeep(a.bus.dma, b.bus.dma);
}

test "sio section restores protocol state but never the card images" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const io = &a.bus.sio;
    io.stat = 0x123;
    io.mode = 0x4D;
    io.ctrl = 0x1003;
    io.baud = 0x88;
    io.rx_data = 0x41;
    io.ack = true;
    io.irq = true;
    io.irq_timer = 450;
    io.buttons = 0xFFFE;
    io.analog_enabled = true;
    io.port = 1;
    io.joy_rx = 1;
    io.joy_ry = 2;
    io.joy_lx = 3;
    io.joy_ly = 4;
    io.motor_right_small = 5;
    io.motor_left_large = 6;
    io.memcard_staging[1][7] = 0x77;
    io.memcard_address[1] = 0x3F;
    io.memcard_checksum[1] = 0x12;
    io.memcard_step[1] = 9;
    io.memcard_is_write[1] = true;
    io.memcard_flag[1] = 0;
    io.memcard_status[1] = 'E';
    io.memcard_data[0][0] = 0xEE; // must NOT travel
    io.memcard_dirty[0] = true; // must NOT travel

    try roundTrip(&a, &b, io_state.saveSio, io_state.loadSio);

    const got = &b.bus.sio;
    try std.testing.expectEqual(io.stat, got.stat);
    try std.testing.expectEqual(io.mode, got.mode);
    try std.testing.expectEqual(io.ctrl, got.ctrl);
    try std.testing.expectEqual(io.baud, got.baud);
    try std.testing.expectEqual(io.rx_data, got.rx_data);
    try std.testing.expectEqual(io.ctrl_state, got.ctrl_state);
    try std.testing.expectEqual(io.ack, got.ack);
    try std.testing.expectEqual(io.irq, got.irq);
    try std.testing.expectEqual(io.irq_timer, got.irq_timer);
    try std.testing.expectEqual(io.buttons, got.buttons);
    try std.testing.expectEqual(io.analog_enabled, got.analog_enabled);
    try std.testing.expectEqual(io.port, got.port);
    try std.testing.expectEqual(io.joy_ly, got.joy_ly);
    try std.testing.expectEqual(io.motor_left_large, got.motor_left_large);
    try std.testing.expectEqualDeep(io.memcard_staging, got.memcard_staging);
    try std.testing.expectEqualDeep(io.memcard_address, got.memcard_address);
    try std.testing.expectEqualDeep(io.memcard_checksum, got.memcard_checksum);
    try std.testing.expectEqualDeep(io.memcard_step, got.memcard_step);
    try std.testing.expectEqualDeep(io.memcard_is_write, got.memcard_is_write);
    try std.testing.expectEqualDeep(io.memcard_flag, got.memcard_flag);
    try std.testing.expectEqualDeep(io.memcard_status, got.memcard_status);
    try std.testing.expect(got.memcard_data[0][0] != 0xEE);
    try std.testing.expect(!got.memcard_dirty[0]);
}

test "mdec section restores tables, fifos and the block in progress" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const m = &a.bus.mdec;
    m.status = 0x80040000;
    m.quant_luminance[3] = 9;
    m.quant_color[4] = 8;
    m.scale_table[5] = -7;
    m.current_cmd = 0x30000000;
    m.words_remaining = 100;
    m.input_fifo[6] = 0xFE00;
    m.input_len = 7;
    m.y_blocks[2][8] = -300;
    m.cb_block[9] = 1;
    m.cr_block[10] = 2;
    m.output_fifo[11] = 0xABCDEF;
    m.output_ptr = 12;
    m.output_len = 13;
    m.output_depth = 2;
    m.output_set_bit15 = true;

    try roundTrip(&a, &b, io_state.saveMdec, io_state.loadMdec);
    try std.testing.expectEqualDeep(a.bus.mdec, b.bus.mdec);
}
```

Temporary exports in `root.zig` (Task 4 replaces them):

```zig
pub const savestate_cpu = @import("savestate/cpu_state.zig");
pub const savestate_io = @import("savestate/io_state.zig");
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `unable to load 'ps1-core/src/savestate/cpu_state.zig'`.

- [ ] **Step 3: Implement `cpu_state.zig`**

```zig
//! The CPU section: R3000A, COP0 and the GTE's registers.
//!
//! Written field by field for the reason `ps1-golden/src/state_hash.zig`
//! gives — a reflected dump would silently follow a refactor. The PGXP
//! shadows are deliberately absent: they are a cache the game rebuilds within
//! a frame or two, and the identity check reads a missing value as "no PGXP".

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveCpu(cpu: *const Cpu, w: *Writer) Error!void {
    try w.array(&cpu.regs);
    try w.int(cpu.pipeline.pc);
    try w.int(cpu.pipeline.next_pc);
    try w.int(cpu.pipeline.current_pc);
    try w.flag(cpu.pipeline.is_delay_slot);
    try w.flag(cpu.pipeline.next_is_delay_slot);
    try w.int(cpu.load_delay.load_r);
    try w.int(cpu.load_delay.load_v);
    try w.int(cpu.load_delay.delay_r);
    try w.int(cpu.load_delay.delay_v);
    try w.int(cpu.hi);
    try w.int(cpu.lo);
    try w.int(cpu.cycles);
    try w.int(cpu.gpu_clock_frac);
    for (&cpu.icache) |*line| {
        try w.int(line.tag);
        try w.array(&line.data);
    }
    try w.array(&cpu.cop0.regs);
    try w.array(&cpu.cop2.data_regs);
    try w.array(&cpu.cop2.ctrl_regs);
    try w.array(&cpu.cop2.macs);
}

pub fn loadCpu(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    try r.array(&cpu.regs);
    cpu.pipeline.pc = try r.int(u32);
    cpu.pipeline.next_pc = try r.int(u32);
    cpu.pipeline.current_pc = try r.int(u32);
    cpu.pipeline.is_delay_slot = try r.flag();
    cpu.pipeline.next_is_delay_slot = try r.flag();
    cpu.load_delay.load_r = try r.int(u5);
    cpu.load_delay.load_v = try r.int(u32);
    cpu.load_delay.delay_r = try r.int(u5);
    cpu.load_delay.delay_v = try r.int(u32);
    cpu.hi = try r.int(u32);
    cpu.lo = try r.int(u32);
    cpu.cycles = try r.int(u64);
    cpu.gpu_clock_frac = try r.int(u32);
    for (&cpu.icache) |*line| {
        line.tag = try r.int(u32);
        try r.array(&line.data);
    }
    try r.array(&cpu.cop0.regs);
    try r.array(&cpu.cop2.data_regs);
    try r.array(&cpu.cop2.ctrl_regs);
    try r.array(&cpu.cop2.macs);
}
```

- [ ] **Step 4: Implement `io_state.zig`**

```zig
//! Sections for the memory regions `Bus` owns directly and the small devices:
//! interrupt controller, root counters, DMA, SIO and MDEC.
//!
//! The SIO section carries the pad and card PROTOCOL, never the card images
//! or their dirty flags. The cards are one pair shared by every game, so a
//! state that restored them would roll back saves made in other games.

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Sio = @import("../sio.zig").Sio;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveBus(cpu: *const Cpu, w: *Writer) Error!void {
    const bus = cpu.bus;
    try w.array(&bus.ram);
    try w.array(&bus.scratchpad);
    try w.array(&bus.io_ports);
    try w.array(&bus.expansion_2);
    try w.array(&bus.expansion_3);
    try w.int(bus.expansion_3_last_write_width);
    try w.array(&bus.cache_control);
    try w.int(bus.wait_cycles);
    try w.int(bus.sys_clock);
}

pub fn loadBus(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const bus = cpu.bus;
    try r.array(&bus.ram);
    try r.array(&bus.scratchpad);
    try r.array(&bus.io_ports);
    try r.array(&bus.expansion_2);
    try r.array(&bus.expansion_3);
    bus.expansion_3_last_write_width = try r.int(u8);
    try r.array(&bus.cache_control);
    bus.wait_cycles = try r.int(u32);
    bus.sys_clock = try r.int(u64);
}

pub fn saveIrq(cpu: *const Cpu, w: *Writer) Error!void {
    try w.int(cpu.bus.interrupts.stat);
    try w.int(cpu.bus.interrupts.mask);
}

pub fn loadIrq(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    cpu.bus.interrupts.stat = try r.int(u32);
    cpu.bus.interrupts.mask = try r.int(u32);
}

pub fn saveTimers(cpu: *const Cpu, w: *Writer) Error!void {
    for (&cpu.bus.timers) |*t| {
        try w.int(t.counter);
        try w.int(t.mode);
        try w.int(t.target);
        try w.int(t.prescale_counter);
        try w.int(t.pending_ticks);
        try w.int(t.event_countdown);
    }
}

pub fn loadTimers(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    for (&cpu.bus.timers) |*t| {
        t.counter = try r.int(u32);
        t.mode = try r.int(u32);
        t.target = try r.int(u32);
        t.prescale_counter = try r.int(u32);
        t.pending_ticks = try r.int(u32);
        t.event_countdown = try r.int(i64);
    }
}

pub fn saveDma(cpu: *const Cpu, w: *Writer) Error!void {
    const d = &cpu.bus.dma;
    try w.int(d.dpcr);
    try w.int(d.dicr);
    try w.flag(d.busy_hint);
    for (&d.channels) |*c| {
        try w.int(c.base_addr);
        try w.int(c.block_control);
        try w.int(c.control);
        try w.flag(c.transfer_active);
        try w.int(c.words_remaining);
        try w.int(c.linked_list_next);
        try w.int(c.ll_nodes);
        try w.int(c.chop_dma_window);
        try w.int(c.chop_cpu_window);
        try w.flag(c.chop_is_cpu_turn);
        try w.int(c.chop_counter);
        try w.int(c.block_words);
        try w.int(c.block_word_progress);
        try w.int(c.block_cycles);
        try w.int(c.block_gap_counter);
    }
}

pub fn loadDma(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const d = &cpu.bus.dma;
    d.dpcr = try r.int(u32);
    d.dicr = try r.int(u32);
    d.busy_hint = try r.flag();
    for (&d.channels) |*c| {
        c.base_addr = try r.int(u32);
        c.block_control = try r.int(u32);
        c.control = try r.int(u32);
        c.transfer_active = try r.flag();
        c.words_remaining = try r.int(u32);
        c.linked_list_next = try r.int(u32);
        c.ll_nodes = try r.int(u32);
        c.chop_dma_window = try r.int(u32);
        c.chop_cpu_window = try r.int(u32);
        c.chop_is_cpu_turn = try r.flag();
        c.chop_counter = try r.int(u32);
        c.block_words = try r.int(u32);
        c.block_word_progress = try r.int(u32);
        c.block_cycles = try r.int(u32);
        c.block_gap_counter = try r.int(u32);
    }
}

pub fn saveSio(cpu: *const Cpu, w: *Writer) Error!void {
    const io = &cpu.bus.sio;
    try w.int(io.stat);
    try w.int(io.mode);
    try w.int(io.ctrl);
    try w.int(io.baud);
    try w.int(io.rx_data);
    try w.tag(io.ctrl_state);
    try w.flag(io.ack);
    try w.flag(io.irq);
    try w.int(io.irq_timer);
    try w.int(io.buttons);
    try w.flag(io.analog_enabled);
    try w.int(io.port);
    try w.int(io.joy_rx);
    try w.int(io.joy_ry);
    try w.int(io.joy_lx);
    try w.int(io.joy_ly);
    try w.int(io.motor_right_small);
    try w.int(io.motor_left_large);
    for (0..Sio.memcard_slots) |i| {
        try w.array(&io.memcard_staging[i]);
        try w.int(io.memcard_address[i]);
        try w.int(io.memcard_checksum[i]);
        try w.int(io.memcard_step[i]);
        try w.flag(io.memcard_is_write[i]);
        try w.int(io.memcard_flag[i]);
        try w.int(io.memcard_status[i]);
    }
}

pub fn loadSio(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const io = &cpu.bus.sio;
    io.stat = try r.int(u32);
    io.mode = try r.int(u32);
    io.ctrl = try r.int(u32);
    io.baud = try r.int(u32);
    io.rx_data = try r.int(u8);
    io.ctrl_state = try r.tag(Sio.SioState);
    io.ack = try r.flag();
    io.irq = try r.flag();
    io.irq_timer = try r.int(u32);
    io.buttons = try r.int(u16);
    io.analog_enabled = try r.flag();
    io.port = try r.int(u1);
    io.joy_rx = try r.int(u8);
    io.joy_ry = try r.int(u8);
    io.joy_lx = try r.int(u8);
    io.joy_ly = try r.int(u8);
    io.motor_right_small = try r.int(u8);
    io.motor_left_large = try r.int(u8);
    for (0..Sio.memcard_slots) |i| {
        try r.array(&io.memcard_staging[i]);
        io.memcard_address[i] = try r.int(u16);
        io.memcard_checksum[i] = try r.int(u8);
        io.memcard_step[i] = try r.int(u32);
        io.memcard_is_write[i] = try r.flag();
        io.memcard_flag[i] = try r.int(u8);
        io.memcard_status[i] = try r.int(u8);
    }
}

pub fn saveMdec(cpu: *const Cpu, w: *Writer) Error!void {
    const m = &cpu.bus.mdec;
    try w.int(m.status);
    try w.array(&m.quant_luminance);
    try w.array(&m.quant_color);
    try w.array(&m.scale_table);
    try w.int(m.current_cmd);
    try w.int(m.words_remaining);
    try w.array(&m.input_fifo);
    try w.int(m.input_len);
    try w.array(&m.y_blocks);
    try w.array(&m.cb_block);
    try w.array(&m.cr_block);
    try w.array(&m.output_fifo);
    try w.int(m.output_ptr);
    try w.int(m.output_len);
    try w.int(m.output_depth);
    try w.flag(m.output_set_bit15);
}

pub fn loadMdec(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const m = &cpu.bus.mdec;
    m.status = try r.int(u32);
    try r.array(&m.quant_luminance);
    try r.array(&m.quant_color);
    try r.array(&m.scale_table);
    m.current_cmd = try r.int(u32);
    m.words_remaining = try r.int(u32);
    try r.array(&m.input_fifo);
    m.input_len = try r.int(usize);
    try r.array(&m.y_blocks);
    try r.array(&m.cb_block);
    try r.array(&m.cr_block);
    try r.array(&m.output_fifo);
    m.output_ptr = try r.int(usize);
    m.output_len = try r.int(usize);
    m.output_depth = try r.int(u3);
    m.output_set_bit15 = try r.flag();
}
```

If `Sio.SioState` is not `pub` from outside the struct, use whatever path the hash file uses for `io.ctrl_state`'s type (`@TypeOf(io.ctrl_state)` is acceptable as the argument to `r.tag`).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/savestate ps1-core/tests/savestate_test.zig ps1-core/src/root.zig
git add ps1-core/src/savestate ps1-core/tests/savestate_test.zig ps1-core/src/root.zig
git commit -m "feat(core): savestate sections for cpu, bus memory and small devices"
```

---

### Task 3: GPU, SPU and CD-ROM sections

**Files:**
- Create: `ps1-core/src/savestate/gpu_state.zig`
- Create: `ps1-core/src/savestate/spu_state.zig`
- Create: `ps1-core/src/savestate/cdrom_state.zig`
- Modify: `ps1-core/src/root.zig` (temporary exports)
- Test: `ps1-core/tests/savestate_test.zig`

**Interfaces:**
- Consumes: Task 1's stream; Task 2's section shape and the `Machine`/`roundTrip` test helpers.
- Produces: `saveGpu`/`loadGpu`, `saveSpu`/`loadSpu`, `saveCdrom`/`loadCdrom` with the Task 2 shape.

Re-derive the field lists first, as in Task 2:
`grep -nE '^    [a-z_][a-z_0-9]*: ' ps1-core/src/gpu/gpu.zig ps1-core/src/gpu/gp0.zig ps1-core/src/gpu/vram.zig ps1-core/src/gpu/registers.zig ps1-core/src/spu/spu.zig ps1-core/src/spu/voice.zig ps1-core/src/cdrom/cdrom.zig ps1-core/src/cdrom/fifo.zig ps1-core/src/cdrom/xa.zig`

- [ ] **Step 1: Write the failing tests**

```zig
const gpu_state = ps1.savestate_gpu;
const spu_state = ps1.savestate_spu;
const cdrom_state = ps1.savestate_cdrom;

test "gpu section restores vram, transfers, environments, gp0 and the fifo" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const g = &a.bus.gpu;
    g.vram.data[1024 * 100 + 5] = 0x7FFF;
    g.vram.write_active = true;
    g.vram.write_x = 1;
    g.vram.write_y = 2;
    g.vram.write_w = 3;
    g.vram.write_h = 4;
    g.vram.write_curr_x = 5;
    g.vram.write_curr_y = 6;
    g.vram.write_remaining = 7;
    g.vram.read_active = true;
    g.vram.read_x = 8;
    g.vram.read_y = 9;
    g.vram.read_w = 10;
    g.vram.read_h = 11;
    g.vram.read_curr_x = 12;
    g.vram.read_curr_y = 13;
    g.vram.read_remaining = 14;
    g.draw_env.draw_mode = 0x20F;
    g.draw_env.tex_window = 1;
    g.draw_env.area_top_left = 2;
    g.draw_env.area_bot_right = 3;
    g.draw_env.offset = 4;
    g.draw_env.mask_bit = 3;
    g.draw_env.texture_disable_allowed = true;
    g.disp_env.vram_x_start = 320;
    g.disp_env.vram_y_start = 240;
    g.disp_env.screen_x1 = 1;
    g.disp_env.screen_x2 = 2;
    g.disp_env.screen_y1 = 3;
    g.disp_env.screen_y2 = 4;
    g.disp_env.display_mode = 0x11;
    g.disp_env.display_disabled = false;
    g.gp0.cmd_buffer[2] = 0x38000000;
    g.gp0.words_remaining = 5;
    g.gp0.words_read = 3;
    g.gp0.polyline_active = true;
    g.gp0.polyline_shaded = true;
    g.gp0.polyline_count = 4;
    g.gp0.polyline_transparent = true;
    g.gp0.polyline_prev_x = -10;
    g.gp0.polyline_prev_y = 20;
    g.gp0.polyline_prev_color = 0xFF;
    g.gp0.polyline_next_color = 0xFF00;
    g.gpu_read_data = 0x1234;
    g.dma_direction = 2;
    g.interrupt_flag = true;
    g.is_vblank = true;
    g.is_ntsc = false;
    g.h_count = 100;
    g.v_count = 200;
    g.dotclock_count = 300;
    g.prev_interrupt_flag = true;
    g.is_even_field = true;
    g.fifo[3] = 0xCAFE;
    g.fifo_head = 3;
    g.fifo_tail = 4;
    g.fifo_count = 1;
    g.cycle_debt = -50;
    g.pending_cycles = 60;
    g.event_countdown = 70;
    g.eager = true;

    try roundTrip(&a, &b, gpu_state.saveGpu, gpu_state.loadGpu);

    const got = &b.bus.gpu;
    try std.testing.expectEqualSlices(u16, &g.vram.data, &got.vram.data);
    try std.testing.expectEqual(g.vram.write_remaining, got.vram.write_remaining);
    try std.testing.expectEqual(g.vram.read_remaining, got.vram.read_remaining);
    try std.testing.expectEqual(g.vram.read_curr_y, got.vram.read_curr_y);
    try std.testing.expectEqualDeep(g.draw_env, got.draw_env);
    try std.testing.expectEqualDeep(g.disp_env, got.disp_env);
    try std.testing.expectEqualDeep(g.gp0.cmd_buffer, got.gp0.cmd_buffer);
    try std.testing.expectEqual(g.gp0.words_remaining, got.gp0.words_remaining);
    try std.testing.expectEqual(g.gp0.polyline_prev_x, got.gp0.polyline_prev_x);
    try std.testing.expectEqual(g.gp0.polyline_next_color, got.gp0.polyline_next_color);
    try std.testing.expectEqual(g.gpu_read_mode, got.gpu_read_mode);
    try std.testing.expectEqual(g.dma_direction, got.dma_direction);
    try std.testing.expectEqual(g.is_ntsc, got.is_ntsc);
    try std.testing.expectEqual(g.dotclock_count, got.dotclock_count);
    try std.testing.expectEqualDeep(g.fifo, got.fifo);
    try std.testing.expectEqual(g.fifo_count, got.fifo_count);
    try std.testing.expectEqual(g.cycle_debt, got.cycle_debt);
    try std.testing.expectEqual(g.pending_cycles, got.pending_cycles);
    try std.testing.expectEqual(g.event_countdown, got.event_countdown);
    try std.testing.expectEqual(g.eager, got.eager);
}

test "spu section restores sram, voices, reverb, noise, mix and the output ring" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const s = &a.bus.spu;
    s.sram[1000] = 0x42;
    s.main_vol_l = -1;
    s.main_vol_r = 2;
    s.reverb_vol_l = 3;
    s.reverb_vol_r = 4;
    s.spu_cnt = 0xC000;
    s.spu_stat = 5;
    s.sram_addr = 6;
    s.sram_read_buffer = 7;
    s.dtc = 8;
    s.pmon = 9;
    s.non = 10;
    s.von = 11;
    s.noise.timer = -12;
    s.noise.lfsr = 13;
    s.noise.level = 14;
    s.mix.cd_vol_l = 15;
    s.mix.cd_vol_r = 16;
    s.mix.ext_vol_l = 17;
    s.mix.ext_vol_r = 18;
    s.mix.current_cd_l = 19;
    s.mix.current_cd_r = 20;
    s.mix.current_ext_l = 21;
    s.mix.current_ext_r = 22;
    s.irq_addr = 23;
    s.irq_flag = true;
    s.reverb.regs[4] = -24;
    s.reverb.base = 25;
    s.reverb.curr_addr = 26;
    s.reverb.counter = 27;
    s.reverb.out_l = 28;
    s.reverb.out_r = 29;
    const v = &s.voices[7];
    v.regs.vol_l = 30;
    v.regs.pitch = 0x1000;
    v.regs.adsr_vol = -31;
    v.adpcm.current_addr = 32;
    v.adpcm.current_fraction = 33;
    v.adpcm.old = 34;
    v.adpcm.older = 35;
    v.adpcm.decoded_buffer[3] = 36;
    v.adpcm.history[1] = 37;
    v.adpcm.buffer_index = 4;
    v.is_on = true;
    v.ignore_samples = true;
    v.has_reached_endx = true;
    v.env.current_ad_vol = 38;
    v.env.cycles = 39;
    s.output_buffer[40] = 0.5;
    s.write_idx = 41;
    s.read_idx = 42;
    s.cycle_accumulator = 43;

    try roundTrip(&a, &b, spu_state.saveSpu, spu_state.loadSpu);

    const got = &b.bus.spu;
    try std.testing.expectEqualSlices(u8, &s.sram, &got.sram);
    try std.testing.expectEqualDeep(s.noise, got.noise);
    try std.testing.expectEqualDeep(s.mix, got.mix);
    try std.testing.expectEqualDeep(s.reverb, got.reverb);
    try std.testing.expectEqualDeep(s.voices, got.voices);
    try std.testing.expectEqualSlices(f32, &s.output_buffer, &got.output_buffer);
    try std.testing.expectEqual(s.main_vol_l, got.main_vol_l);
    try std.testing.expectEqual(s.dtc, got.dtc);
    try std.testing.expectEqual(s.von, got.von);
    try std.testing.expectEqual(s.irq_flag, got.irq_flag);
    try std.testing.expectEqual(s.write_idx, got.write_idx);
    try std.testing.expectEqual(s.read_idx, got.read_idx);
    try std.testing.expectEqual(s.cycle_accumulator, got.cycle_accumulator);
}

test "cdrom section restores drive, fifos, irq queue, audio and xa state" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const cd = &a.bus.cdrom;
    cd.regs.index = 2;
    cd.regs.irq_enable = 7;
    cd.regs.busy_for = -3;
    cd.regs.last_response_byte = 4;
    cd.regs.volume_ll = 5;
    cd.regs.volume_lr = 6;
    cd.regs.volume_rl = 7;
    cd.regs.volume_rr = 8;
    cd.fifos.parameter_fifo[1] = 9;
    cd.fifos.parameter_len = 2;
    cd.fifos.irq_line = true;
    cd.fifos.last_raw_sector[100] = 10;
    cd.fifos.sector_buffer[200] = 11;
    cd.fifos.sector_buffer_ptr = 12;
    cd.fifos.sector_buffer_len = 2340;
    cd.fifos.data_fifo_empty = false;
    cd.fifos.irq_queue.head = 1;
    cd.fifos.irq_queue.tail = 2;
    cd.fifos.irq_queue.count = 1;
    cd.fifos.irq_queue.overflow_count = 3;
    cd.fifos.irq_queue.items[1] = .{ .irq = 3, .response_len = 1, .response_ptr = 0, .delay = 50000, .ack = true, .triggered = true, .auto_status = true };
    cd.fifos.irq_queue.items[1].response[0] = 0x22;
    cd.drive.drive_state = .Reading;
    cd.drive.sector_timer = 13;
    cd.drive.seek_timer = 14;
    cd.drive.read_after_seek = true;
    cd.drive.status = 0x22;
    cd.drive.mode = 0x80;
    cd.drive.seek_target = .{ .m = 0x01, .s = 0x02, .f = 0x03 };
    cd.drive.current_pos = .{ .m = 0x04, .s = 0x05, .f = 0x06 };
    cd.drive.loc_l_valid = true;
    cd.drive.muted = true;
    cd.drive.shell_open = true;
    cd.drive.shell_changed = true;
    cd.drive.shell_close_timer = 15;
    cd.drive.last_sector_header[2] = 16;
    cd.drive.last_subchannel_q[3] = 17;
    cd.drive.sectors_delivered = 18;
    cd.drive.previous_track = 2;
    cd.audio.audio_fifo_l[5] = -19;
    cd.audio.audio_fifo_r[6] = 20;
    cd.audio.audio_fifo_read = 21;
    cd.audio.audio_fifo_write = 22;
    cd.audio.audio_tick_counter = 23;
    cd.xa.xa_filter_file = 1;
    cd.xa.xa_filter_channel = 2;
    cd.xa.xa_old_l = 24;
    cd.xa.xa_older_l = 25;
    cd.xa.xa_old_r = 26;
    cd.xa.xa_older_r = 27;
    cd.xa.xa_ringbuf[1][4] = 28;
    cd.xa.xa_ring_p = .{ 29, 30 };
    cd.xa.xa_sixstep = .{ 3, 4 };
    cd.pending_command = 0x1B;
    cd.pending_command_delay = 31;
    cd.pending_cycles = 32;
    cd.event_countdown = 33;

    try roundTrip(&a, &b, cdrom_state.saveCdrom, cdrom_state.loadCdrom);

    const got = &b.bus.cdrom;
    try std.testing.expectEqualDeep(cd.regs, got.regs);
    try std.testing.expectEqualDeep(cd.fifos, got.fifos);
    try std.testing.expectEqualDeep(cd.drive, got.drive);
    try std.testing.expectEqualDeep(cd.audio, got.audio);
    try std.testing.expectEqualDeep(cd.xa, got.xa);
    try std.testing.expectEqual(cd.pending_command, got.pending_command);
    try std.testing.expectEqual(cd.pending_command_delay, got.pending_command_delay);
    try std.testing.expectEqual(cd.pending_cycles, got.pending_cycles);
    try std.testing.expectEqual(cd.event_countdown, got.event_countdown);
}
```

If `DriveState` has no `.Reading` variant, use any non-default variant it has (check `cdrom.zig:28`).

Temporary exports in `root.zig`:

```zig
pub const savestate_gpu = @import("savestate/gpu_state.zig");
pub const savestate_spu = @import("savestate/spu_state.zig");
pub const savestate_cdrom = @import("savestate/cdrom_state.zig");
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `unable to load 'ps1-core/src/savestate/gpu_state.zig'`.

- [ ] **Step 3: Implement `gpu_state.zig`**

```zig
//! The GPU section: VRAM, the transfer windows, both environments, the GP0
//! command engine, the 16-word FIFO and the deferred-tick bookkeeping.
//!
//! The deferral fields are saved as they are rather than settled first, so a
//! state can be taken at any instruction and resumed bit-for-bit. Absent on
//! purpose: the PGXP depth plane and every `pgxp`/weld/vertex-cache field
//! (caches, rebuilt within a frame or two), and `sink` (host capture state —
//! the app re-adopts core VRAM into Metal when a new display claims the
//! stream).

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Gpu = @import("../gpu/gpu.zig").Gpu;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveGpu(cpu: *const Cpu, w: *Writer) Error!void {
    const g = &cpu.bus.gpu;
    const v = &g.vram;
    try w.array(&v.data);
    try w.flag(v.write_active);
    try w.int(v.write_x);
    try w.int(v.write_y);
    try w.int(v.write_w);
    try w.int(v.write_h);
    try w.int(v.write_curr_x);
    try w.int(v.write_curr_y);
    try w.int(v.write_remaining);
    try w.flag(v.read_active);
    try w.int(v.read_x);
    try w.int(v.read_y);
    try w.int(v.read_w);
    try w.int(v.read_h);
    try w.int(v.read_curr_x);
    try w.int(v.read_curr_y);
    try w.int(v.read_remaining);

    try w.int(g.draw_env.draw_mode);
    try w.int(g.draw_env.tex_window);
    try w.int(g.draw_env.area_top_left);
    try w.int(g.draw_env.area_bot_right);
    try w.int(g.draw_env.offset);
    try w.int(g.draw_env.mask_bit);
    try w.flag(g.draw_env.texture_disable_allowed);

    try w.int(g.disp_env.vram_x_start);
    try w.int(g.disp_env.vram_y_start);
    try w.int(g.disp_env.screen_x1);
    try w.int(g.disp_env.screen_x2);
    try w.int(g.disp_env.screen_y1);
    try w.int(g.disp_env.screen_y2);
    try w.int(g.disp_env.display_mode);
    try w.flag(g.disp_env.display_disabled);

    try w.array(&g.gp0.cmd_buffer);
    try w.int(g.gp0.words_remaining);
    try w.int(g.gp0.words_read);
    try w.flag(g.gp0.polyline_active);
    try w.flag(g.gp0.polyline_shaded);
    try w.int(g.gp0.polyline_count);
    try w.flag(g.gp0.polyline_transparent);
    try w.int(g.gp0.polyline_prev_x);
    try w.int(g.gp0.polyline_prev_y);
    try w.int(g.gp0.polyline_prev_color);
    try w.int(g.gp0.polyline_next_color);

    try w.tag(g.gpu_read_mode);
    try w.int(g.gpu_read_data);
    try w.int(g.dma_direction);
    try w.flag(g.interrupt_flag);
    try w.flag(g.is_vblank);
    try w.flag(g.is_ntsc);
    try w.int(g.h_count);
    try w.int(g.v_count);
    try w.int(g.dotclock_count);
    try w.flag(g.prev_interrupt_flag);
    try w.flag(g.is_even_field);
    try w.array(&g.fifo);
    try w.int(g.fifo_head);
    try w.int(g.fifo_tail);
    try w.int(g.fifo_count);
    try w.int(g.cycle_debt);
    try w.int(g.pending_cycles);
    try w.int(g.event_countdown);
    try w.flag(g.eager);
}

pub fn loadGpu(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const g = &cpu.bus.gpu;
    const v = &g.vram;
    try r.array(&v.data);
    v.write_active = try r.flag();
    v.write_x = try r.int(usize);
    v.write_y = try r.int(usize);
    v.write_w = try r.int(usize);
    v.write_h = try r.int(usize);
    v.write_curr_x = try r.int(usize);
    v.write_curr_y = try r.int(usize);
    v.write_remaining = try r.int(usize);
    v.read_active = try r.flag();
    v.read_x = try r.int(usize);
    v.read_y = try r.int(usize);
    v.read_w = try r.int(usize);
    v.read_h = try r.int(usize);
    v.read_curr_x = try r.int(usize);
    v.read_curr_y = try r.int(usize);
    v.read_remaining = try r.int(usize);

    g.draw_env.draw_mode = try r.int(u32);
    g.draw_env.tex_window = try r.int(u32);
    g.draw_env.area_top_left = try r.int(u32);
    g.draw_env.area_bot_right = try r.int(u32);
    g.draw_env.offset = try r.int(u32);
    g.draw_env.mask_bit = try r.int(u32);
    g.draw_env.texture_disable_allowed = try r.flag();

    g.disp_env.vram_x_start = try r.int(u16);
    g.disp_env.vram_y_start = try r.int(u16);
    g.disp_env.screen_x1 = try r.int(u16);
    g.disp_env.screen_x2 = try r.int(u16);
    g.disp_env.screen_y1 = try r.int(u16);
    g.disp_env.screen_y2 = try r.int(u16);
    g.disp_env.display_mode = try r.int(u32);
    g.disp_env.display_disabled = try r.flag();

    try r.array(&g.gp0.cmd_buffer);
    g.gp0.words_remaining = try r.int(usize);
    g.gp0.words_read = try r.int(usize);
    g.gp0.polyline_active = try r.flag();
    g.gp0.polyline_shaded = try r.flag();
    g.gp0.polyline_count = try r.int(usize);
    g.gp0.polyline_transparent = try r.flag();
    g.gp0.polyline_prev_x = try r.int(i16);
    g.gp0.polyline_prev_y = try r.int(i16);
    g.gp0.polyline_prev_color = try r.int(u32);
    g.gp0.polyline_next_color = try r.int(u32);

    g.gpu_read_mode = try r.tag(Gpu.ReadMode);
    g.gpu_read_data = try r.int(u32);
    g.dma_direction = try r.int(u2);
    g.interrupt_flag = try r.flag();
    g.is_vblank = try r.flag();
    g.is_ntsc = try r.flag();
    g.h_count = try r.int(u32);
    g.v_count = try r.int(u32);
    g.dotclock_count = try r.int(u32);
    g.prev_interrupt_flag = try r.flag();
    g.is_even_field = try r.flag();
    try r.array(&g.fifo);
    g.fifo_head = try r.int(u4);
    g.fifo_tail = try r.int(u4);
    g.fifo_count = try r.int(u5);
    g.cycle_debt = try r.int(i32);
    g.pending_cycles = try r.int(u32);
    g.event_countdown = try r.int(i64);
    g.eager = try r.flag();
}
```

- [ ] **Step 4: Implement `spu_state.zig`**

```zig
//! The SPU section: sound RAM, every voice, reverb, noise, the CD/external
//! mix and the output ring.
//!
//! The output ring is saved so a restored machine is bit-identical to one
//! that never saved; on a resume the app drains the few milliseconds it
//! holds like any other samples. `reverb_enable` is a host isolation switch
//! with no setter, and is not machine state.

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const AdsrState = @import("../spu/adsr.zig").AdsrState;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveSpu(cpu: *const Cpu, w: *Writer) Error!void {
    const s = &cpu.bus.spu;
    try w.array(&s.sram);
    try w.int(s.main_vol_l);
    try w.int(s.main_vol_r);
    try w.int(s.reverb_vol_l);
    try w.int(s.reverb_vol_r);
    try w.int(s.spu_cnt);
    try w.int(s.spu_stat);
    try w.int(s.sram_addr);
    try w.int(s.sram_read_buffer);
    try w.int(s.dtc);
    try w.int(s.pmon);
    try w.int(s.non);
    try w.int(s.von);
    try w.int(s.noise.timer);
    try w.int(s.noise.lfsr);
    try w.int(s.noise.level);
    try w.int(s.mix.cd_vol_l);
    try w.int(s.mix.cd_vol_r);
    try w.int(s.mix.ext_vol_l);
    try w.int(s.mix.ext_vol_r);
    try w.int(s.mix.current_cd_l);
    try w.int(s.mix.current_cd_r);
    try w.int(s.mix.current_ext_l);
    try w.int(s.mix.current_ext_r);
    try w.int(s.irq_addr);
    try w.flag(s.irq_flag);
    try w.array(&s.reverb.regs);
    try w.int(s.reverb.base);
    try w.int(s.reverb.curr_addr);
    try w.int(s.reverb.counter);
    try w.int(s.reverb.out_l);
    try w.int(s.reverb.out_r);
    for (&s.voices) |*v| {
        try w.int(v.regs.vol_l);
        try w.int(v.regs.vol_r);
        try w.int(v.regs.pitch);
        try w.int(v.regs.start_addr);
        try w.int(v.regs.adsr1);
        try w.int(v.regs.adsr2);
        try w.int(v.regs.adsr_vol);
        try w.int(v.regs.loop_addr);
        try w.int(v.adpcm.current_addr);
        try w.int(v.adpcm.current_fraction);
        try w.int(v.adpcm.old);
        try w.int(v.adpcm.older);
        try w.array(&v.adpcm.decoded_buffer);
        try w.array(&v.adpcm.history);
        try w.int(v.adpcm.buffer_index);
        try w.flag(v.is_on);
        try w.flag(v.ignore_samples);
        try w.flag(v.has_reached_endx);
        try w.tag(v.env.state);
        try w.int(v.env.current_ad_vol);
        try w.int(v.env.cycles);
    }
    try w.array(&s.output_buffer);
    try w.int(s.write_idx);
    try w.int(s.read_idx);
    try w.int(s.cycle_accumulator);
}

pub fn loadSpu(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const s = &cpu.bus.spu;
    try r.array(&s.sram);
    s.main_vol_l = try r.int(i16);
    s.main_vol_r = try r.int(i16);
    s.reverb_vol_l = try r.int(i16);
    s.reverb_vol_r = try r.int(i16);
    s.spu_cnt = try r.int(u16);
    s.spu_stat = try r.int(u16);
    s.sram_addr = try r.int(u32);
    s.sram_read_buffer = try r.int(u16);
    s.dtc = try r.int(u16);
    s.pmon = try r.int(u32);
    s.non = try r.int(u32);
    s.von = try r.int(u32);
    s.noise.timer = try r.int(i32);
    s.noise.lfsr = try r.int(u32);
    s.noise.level = try r.int(i32);
    s.mix.cd_vol_l = try r.int(i16);
    s.mix.cd_vol_r = try r.int(i16);
    s.mix.ext_vol_l = try r.int(i16);
    s.mix.ext_vol_r = try r.int(i16);
    s.mix.current_cd_l = try r.int(i16);
    s.mix.current_cd_r = try r.int(i16);
    s.mix.current_ext_l = try r.int(i16);
    s.mix.current_ext_r = try r.int(i16);
    s.irq_addr = try r.int(u16);
    s.irq_flag = try r.flag();
    try r.array(&s.reverb.regs);
    s.reverb.base = try r.int(u16);
    s.reverb.curr_addr = try r.int(u32);
    s.reverb.counter = try r.int(u32);
    s.reverb.out_l = try r.int(i32);
    s.reverb.out_r = try r.int(i32);
    for (&s.voices) |*v| {
        v.regs.vol_l = try r.int(i16);
        v.regs.vol_r = try r.int(i16);
        v.regs.pitch = try r.int(u16);
        v.regs.start_addr = try r.int(u16);
        v.regs.adsr1 = try r.int(u16);
        v.regs.adsr2 = try r.int(u16);
        v.regs.adsr_vol = try r.int(i16);
        v.regs.loop_addr = try r.int(u16);
        v.adpcm.current_addr = try r.int(u32);
        v.adpcm.current_fraction = try r.int(u16);
        v.adpcm.old = try r.int(i32);
        v.adpcm.older = try r.int(i32);
        try r.array(&v.adpcm.decoded_buffer);
        try r.array(&v.adpcm.history);
        v.adpcm.buffer_index = try r.int(usize);
        v.is_on = try r.flag();
        v.ignore_samples = try r.flag();
        v.has_reached_endx = try r.flag();
        v.env.state = try r.tag(AdsrState);
        v.env.current_ad_vol = try r.int(i32);
        v.env.cycles = try r.int(u32);
    }
    try r.array(&s.output_buffer);
    s.write_idx = try r.int(usize);
    s.read_idx = try r.int(usize);
    s.cycle_accumulator = try r.int(u32);
}
```

- [ ] **Step 5: Implement `cdrom_state.zig`**

```zig
//! The CD-ROM section: registers, the parameter/response/data FIFOs and the
//! IRQ queue, the drive mechanism (position, every timer `nextDeadline` reads,
//! the shell latch), the shared audio FIFO and the XA decoder's history.
//!
//! The disc itself is not here: its bytes are reloaded from the library and
//! the header's serial proves it is the same disc. `debug_enable` and
//! `trace_commands` are host logging switches.

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const cdrom = @import("../cdrom/cdrom.zig");

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveCdrom(cpu: *const Cpu, w: *Writer) Error!void {
    const cd = &cpu.bus.cdrom;
    try w.int(cd.regs.index);
    try w.int(cd.regs.irq_enable);
    try w.int(cd.regs.busy_for);
    try w.int(cd.regs.last_response_byte);
    try w.int(cd.regs.volume_ll);
    try w.int(cd.regs.volume_lr);
    try w.int(cd.regs.volume_rl);
    try w.int(cd.regs.volume_rr);

    const f = &cd.fifos;
    try w.array(&f.parameter_fifo);
    try w.int(f.parameter_len);
    const q = &f.irq_queue;
    for (&q.items) |*item| {
        try w.int(item.irq);
        try w.array(&item.response);
        try w.int(item.response_len);
        try w.int(item.response_ptr);
        try w.int(item.delay);
        try w.flag(item.ack);
        try w.flag(item.triggered);
        try w.tag(item.action);
        try w.flag(item.auto_status);
    }
    try w.int(q.head);
    try w.int(q.tail);
    try w.int(q.count);
    try w.int(q.overflow_count);
    try w.flag(f.irq_line);
    try w.array(&f.last_raw_sector);
    try w.array(&f.sector_buffer);
    try w.int(f.sector_buffer_ptr);
    try w.int(f.sector_buffer_len);
    try w.flag(f.data_fifo_empty);

    const d = &cd.drive;
    try w.tag(d.drive_state);
    try w.int(d.sector_timer);
    try w.int(d.seek_timer);
    try w.flag(d.read_after_seek);
    try w.int(d.status);
    try w.int(d.mode);
    try w.int(d.seek_target.m);
    try w.int(d.seek_target.s);
    try w.int(d.seek_target.f);
    try w.int(d.current_pos.m);
    try w.int(d.current_pos.s);
    try w.int(d.current_pos.f);
    try w.flag(d.loc_l_valid);
    try w.flag(d.muted);
    try w.flag(d.shell_open);
    try w.flag(d.shell_changed);
    try w.int(d.shell_close_timer);
    try w.array(&d.last_sector_header);
    try w.array(&d.last_subchannel_q);
    try w.int(d.sectors_delivered);
    try w.int(d.previous_track);

    try w.array(&cd.audio.audio_fifo_l);
    try w.array(&cd.audio.audio_fifo_r);
    try w.int(cd.audio.audio_fifo_read);
    try w.int(cd.audio.audio_fifo_write);
    try w.int(cd.audio.audio_tick_counter);

    try w.int(cd.xa.xa_filter_file);
    try w.int(cd.xa.xa_filter_channel);
    try w.int(cd.xa.xa_old_l);
    try w.int(cd.xa.xa_older_l);
    try w.int(cd.xa.xa_old_r);
    try w.int(cd.xa.xa_older_r);
    try w.array(&cd.xa.xa_ringbuf);
    try w.array(&cd.xa.xa_ring_p);
    try w.array(&cd.xa.xa_sixstep);

    try w.flag(cd.pending_command != null);
    try w.int(cd.pending_command orelse 0);
    try w.int(cd.pending_command_delay);
    try w.int(cd.pending_cycles);
    try w.int(cd.event_countdown);
}

pub fn loadCdrom(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const cd = &cpu.bus.cdrom;
    cd.regs.index = try r.int(u2);
    cd.regs.irq_enable = try r.int(u8);
    cd.regs.busy_for = try r.int(i32);
    cd.regs.last_response_byte = try r.int(u8);
    cd.regs.volume_ll = try r.int(u8);
    cd.regs.volume_lr = try r.int(u8);
    cd.regs.volume_rl = try r.int(u8);
    cd.regs.volume_rr = try r.int(u8);

    const f = &cd.fifos;
    try r.array(&f.parameter_fifo);
    f.parameter_len = try r.int(usize);
    const q = &f.irq_queue;
    for (&q.items) |*item| {
        item.irq = try r.int(u8);
        try r.array(&item.response);
        item.response_len = try r.int(usize);
        item.response_ptr = try r.int(usize);
        item.delay = try r.int(i64);
        item.ack = try r.flag();
        item.triggered = try r.flag();
        item.action = try r.tag(cdrom.IrqAction);
        item.auto_status = try r.flag();
    }
    q.head = try r.int(usize);
    q.tail = try r.int(usize);
    q.count = try r.int(usize);
    q.overflow_count = try r.int(u32);
    f.irq_line = try r.flag();
    try r.array(&f.last_raw_sector);
    try r.array(&f.sector_buffer);
    f.sector_buffer_ptr = try r.int(usize);
    f.sector_buffer_len = try r.int(usize);
    f.data_fifo_empty = try r.flag();

    const d = &cd.drive;
    d.drive_state = try r.tag(cdrom.DriveState);
    d.sector_timer = try r.int(i64);
    d.seek_timer = try r.int(i64);
    d.read_after_seek = try r.flag();
    d.status = try r.int(u8);
    d.mode = try r.int(u8);
    d.seek_target.m = try r.int(u8);
    d.seek_target.s = try r.int(u8);
    d.seek_target.f = try r.int(u8);
    d.current_pos.m = try r.int(u8);
    d.current_pos.s = try r.int(u8);
    d.current_pos.f = try r.int(u8);
    d.loc_l_valid = try r.flag();
    d.muted = try r.flag();
    d.shell_open = try r.flag();
    d.shell_changed = try r.flag();
    d.shell_close_timer = try r.int(i64);
    try r.array(&d.last_sector_header);
    try r.array(&d.last_subchannel_q);
    d.sectors_delivered = try r.int(u64);
    d.previous_track = try r.int(u8);

    try r.array(&cd.audio.audio_fifo_l);
    try r.array(&cd.audio.audio_fifo_r);
    cd.audio.audio_fifo_read = try r.int(usize);
    cd.audio.audio_fifo_write = try r.int(usize);
    cd.audio.audio_tick_counter = try r.int(u32);

    cd.xa.xa_filter_file = try r.int(u8);
    cd.xa.xa_filter_channel = try r.int(u8);
    cd.xa.xa_old_l = try r.int(i32);
    cd.xa.xa_older_l = try r.int(i32);
    cd.xa.xa_old_r = try r.int(i32);
    cd.xa.xa_older_r = try r.int(i32);
    try r.array(&cd.xa.xa_ringbuf);
    try r.array(&cd.xa.xa_ring_p);
    try r.array(&cd.xa.xa_sixstep);

    const has_pending = try r.flag();
    const pending = try r.int(u8);
    cd.pending_command = if (has_pending) pending else null;
    cd.pending_command_delay = try r.int(u32);
    cd.pending_cycles = try r.int(u32);
    cd.event_countdown = try r.int(i64);
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/savestate ps1-core/tests/savestate_test.zig ps1-core/src/root.zig
git add ps1-core/src/savestate ps1-core/tests/savestate_test.zig ps1-core/src/root.zig
git commit -m "feat(core): savestate sections for gpu, spu and cdrom"
```

---

### Task 4: The container — header, section table, save/peek/load

**Files:**
- Create: `ps1-core/src/savestate/savestate.zig`
- Modify: `ps1-core/src/root.zig` (replace the five temporary exports with one)
- Modify: `ps1-core/tests/savestate_test.zig` (update imports; add container tests)

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces (`ps1_core.savestate`):
  - `pub const stream`, `cpu_state`, `io_state`, `gpu_state`, `spu_state`, `cdrom_state` (re-exported modules)
  - `pub const Error = stream.Error;`
  - `pub const Identity = struct { bios_sha256: [32]u8, serial: [16]u8 };`
  - `pub const header_len: usize = 64;` `pub const format_version: u32 = 1;`
  - `pub fn identityOf(bus: *const Bus) Identity`
  - `pub fn save(cpu: *const Cpu, dst: ?[]u8) Error!usize` — `null` returns the exact size without writing
  - `pub fn peek(src: []const u8) Error!Identity`
  - `pub fn load(cpu: *Cpu, src: []const u8) Error!void` — writes into `cpu`/`cpu.bus`; the CALLER owns atomicity (it passes a scratch machine)

Wire format (all little-endian):

```
0   magic "SBST"
4   format_version u32
8   crc32 u32 (std.hash.Crc32 over bytes [64..])
12  body_len u32
16  bios_sha256 [32]u8
48  serial [16]u8, zero-padded
64  sections: tag [4]u8 | version u32 | len u32 | payload
```

- [ ] **Step 1: Write the failing tests**

In `savestate_test.zig`, replace the temporary aliases with:

```zig
const savestate = ps1.savestate;
const stream = savestate.stream;
const cpu_state = savestate.cpu_state;
const io_state = savestate.io_state;
const gpu_state = savestate.gpu_state;
const spu_state = savestate.spu_state;
const cdrom_state = savestate.cdrom_state;
```

and append:

```zig
fn saveAlloc(m: *Machine) ![]u8 {
    const n = try savestate.save(&m.cpu, null);
    const buf = try std.testing.allocator.alloc(u8, n);
    errdefer std.testing.allocator.free(buf);
    try std.testing.expectEqual(n, try savestate.save(&m.cpu, buf));
    return buf;
}

test "a whole state round-trips and peeks its identity" {
    var a = try Machine.init();
    defer a.deinit();
    @memset(&a.bus.bios, 0x5A);
    a.bus.ram[42] = 42;
    a.cpu.regs[3] = 3;
    a.bus.gpu.vram.data[7] = 7;

    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualSlices(u8, "SBST", buf[0..4]);

    const id = try savestate.peek(buf);
    try std.testing.expectEqualDeep(savestate.identityOf(a.bus), id);

    var b = try Machine.init();
    defer b.deinit();
    @memset(&b.bus.bios, 0x5A);
    try savestate.load(&b.cpu, buf);
    try std.testing.expectEqual(@as(u8, 42), b.bus.ram[42]);
    try std.testing.expectEqual(@as(u32, 3), b.cpu.regs[3]);
    try std.testing.expectEqual(@as(u16, 7), b.bus.gpu.vram.data[7]);
}

test "hostile states are refused with their own error" {
    var a = try Machine.init();
    defer a.deinit();
    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);

    var b = try Machine.init();
    defer b.deinit();

    const copy = try std.testing.allocator.dupe(u8, buf);
    defer std.testing.allocator.free(copy);

    // Bad magic.
    @memcpy(copy, buf);
    copy[0] = 'X';
    try std.testing.expectError(error.StateBadMagic, savestate.load(&b.cpu, copy));

    // A newer container version.
    @memcpy(copy, buf);
    std.mem.writeInt(u32, copy[4..8], savestate.format_version + 1, .little);
    try std.testing.expectError(error.StateVersion, savestate.load(&b.cpu, copy));

    // One flipped body byte fails the CRC.
    @memcpy(copy, buf);
    copy[savestate.header_len + 100] ^= 0xFF;
    try std.testing.expectError(error.StateCorrupt, savestate.load(&b.cpu, copy));

    // Truncation, at every one of a spread of points.
    var cut: usize = 1;
    while (cut < buf.len) : (cut += buf.len / 17) {
        // A cut into the header reads as no state at all; anywhere else, as corrupt.
        if (savestate.load(&b.cpu, buf[0 .. buf.len - cut])) |_| {
            return error.TestUnexpectedSuccess;
        } else |e| {
            try std.testing.expect(e == error.StateCorrupt or e == error.StateBadMagic);
        }
    }

    // A different BIOS.
    @memset(&b.bus.bios, 0x01);
    try std.testing.expectError(error.StateBios, savestate.load(&b.cpu, buf));
}

test "a section version newer than this build knows is StateVersion" {
    var a = try Machine.init();
    defer a.deinit();
    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);

    // The first section's version sits right after its 4-byte tag.
    const at = savestate.header_len + 4;
    std.mem.writeInt(u32, buf[at..][0..4], 99, .little);
    // Re-seal the CRC so the version check is what fires.
    std.mem.writeInt(u32, buf[8..12], std.hash.Crc32.hash(buf[savestate.header_len..]), .little);

    var b = try Machine.init();
    defer b.deinit();
    try std.testing.expectError(error.StateVersion, savestate.load(&b.cpu, buf));
}

test "save into a buffer one byte short is NoSpace" {
    var a = try Machine.init();
    defer a.deinit();
    const n = try savestate.save(&a.cpu, null);
    const buf = try std.testing.allocator.alloc(u8, n - 1);
    defer std.testing.allocator.free(buf);
    try std.testing.expectError(error.NoSpace, savestate.save(&a.cpu, buf));
}
```

In `root.zig`, remove the five `savestate_*` lines and add:

```zig
pub const savestate = @import("savestate/savestate.zig");
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `unable to load 'ps1-core/src/savestate/savestate.zig'`.

- [ ] **Step 3: Implement `savestate.zig`**

```zig
//! Savestates: the whole emulated machine as a versioned, sectioned blob.
//!
//! Each device's section is written by hand in this directory and carries its
//! OWN version. When a device's state changes, bump that section's version in
//! `sections` and teach its `load` to read the old layout too, supplying the
//! new field's power-on value — that is what lets a state survive an update.
//! A tag or a section version this build does not know is refused outright:
//! a newer build's state is never half-read.
//!
//! `load` writes straight into the machine it is given. Atomicity is the
//! caller's: hand it a scratch `Bus`, and swap that in only on success.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Bus = @import("../memory.zig").Bus;
const discid = @import("../discid.zig");

pub const stream = @import("stream.zig");
pub const cpu_state = @import("cpu_state.zig");
pub const io_state = @import("io_state.zig");
pub const gpu_state = @import("gpu_state.zig");
pub const spu_state = @import("spu_state.zig");
pub const cdrom_state = @import("cdrom_state.zig");

const Writer = stream.Writer;
const Reader = stream.Reader;
pub const Error = stream.Error;

pub const header_len: usize = 64;
pub const format_version: u32 = 1;
const magic = "SBST";

/// What a state must be resumed against: the BIOS image it ran (by hash —
/// the bytes are the user's file and never travel) and the disc in the tray.
pub const Identity = struct {
    bios_sha256: [32]u8,
    serial: [16]u8,
};

pub fn identityOf(bus: *const Bus) Identity {
    var id = Identity{ .bios_sha256 = undefined, .serial = [_]u8{0} ** 16 };
    std.crypto.hash.sha2.Sha256.hash(&bus.bios, &id.bios_sha256, .{});
    if (bus.cdrom.disc) |d| id.serial = discid.identify(d).serial.buf;
    return id;
}

const Section = struct {
    tag: [4]u8,
    version: u32,
    save: *const fn (*const Cpu, *Writer) Error!void,
    load: *const fn (*Cpu, *Reader, u32) Error!void,
};

const sections = [_]Section{
    .{ .tag = "BUS ".*, .version = 1, .save = io_state.saveBus, .load = io_state.loadBus },
    .{ .tag = "CPU ".*, .version = 1, .save = cpu_state.saveCpu, .load = cpu_state.loadCpu },
    .{ .tag = "IRQ ".*, .version = 1, .save = io_state.saveIrq, .load = io_state.loadIrq },
    .{ .tag = "TMR ".*, .version = 1, .save = io_state.saveTimers, .load = io_state.loadTimers },
    .{ .tag = "DMA ".*, .version = 1, .save = io_state.saveDma, .load = io_state.loadDma },
    .{ .tag = "GPU ".*, .version = 1, .save = gpu_state.saveGpu, .load = gpu_state.loadGpu },
    .{ .tag = "SPU ".*, .version = 1, .save = spu_state.saveSpu, .load = spu_state.loadSpu },
    .{ .tag = "CDR ".*, .version = 1, .save = cdrom_state.saveCdrom, .load = cdrom_state.loadCdrom },
    .{ .tag = "MDEC".*, .version = 1, .save = io_state.saveMdec, .load = io_state.loadMdec },
    .{ .tag = "SIO ".*, .version = 1, .save = io_state.saveSio, .load = io_state.loadSio },
};

/// With `dst == null`, returns the exact size without writing anything.
pub fn save(cpu: *const Cpu, dst: ?[]u8) Error!usize {
    const id = identityOf(cpu.bus);
    var w = Writer{ .buf = dst };
    try w.bytes(magic);
    try w.int(format_version);
    try w.int(@as(u32, 0)); // crc32, patched below
    try w.int(@as(u32, 0)); // body_len, patched below
    try w.bytes(&id.bios_sha256);
    try w.bytes(&id.serial);
    std.debug.assert(w.len == header_len);

    for (sections) |s| {
        try w.bytes(&s.tag);
        try w.int(s.version);
        const len_at = w.len;
        try w.int(@as(u32, 0));
        const start = w.len;
        try s.save(cpu, &w);
        w.patchU32(len_at, @intCast(w.len - start));
    }

    if (w.buf) |buf| {
        w.patchU32(12, @intCast(w.len - header_len));
        w.patchU32(8, std.hash.Crc32.hash(buf[header_len..w.len]));
    }
    return w.len;
}

/// Validates the header and the checksum and returns what the state must be
/// resumed against. Needs no machine — the app reads it for its launch prompt.
pub fn peek(src: []const u8) Error!Identity {
    if (src.len < header_len or !std.mem.eql(u8, src[0..4], magic)) return error.StateBadMagic;
    var r = Reader{ .buf = src[4..header_len] };
    if (try r.int(u32) != format_version) return error.StateVersion;
    const crc = try r.int(u32);
    const body_len = try r.int(u32);
    if (body_len != src.len - header_len) return error.StateCorrupt;
    if (std.hash.Crc32.hash(src[header_len..]) != crc) return error.StateCorrupt;
    var id: Identity = undefined;
    @memcpy(&id.bios_sha256, try r.bytes(32));
    @memcpy(&id.serial, try r.bytes(16));
    return id;
}

pub fn load(cpu: *Cpu, src: []const u8) Error!void {
    const id = try peek(src);
    const want = identityOf(cpu.bus);
    if (!std.mem.eql(u8, &id.bios_sha256, &want.bios_sha256)) return error.StateBios;
    if (!std.mem.eql(u8, &id.serial, &want.serial)) return error.StateDisc;

    var r = Reader{ .buf = src[header_len..] };
    var seen = [_]bool{false} ** sections.len;
    while (r.pos < r.buf.len) {
        const tag = (try r.bytes(4))[0..4].*;
        const version = try r.int(u32);
        const len = try r.int(u32);
        var sub = Reader{ .buf = try r.bytes(len) };
        const i = indexOfTag(tag) orelse return error.StateVersion;
        if (seen[i]) return error.StateCorrupt;
        if (version == 0 or version > sections[i].version) return error.StateVersion;
        try sections[i].load(cpu, &sub, version);
        try sub.end();
        seen[i] = true;
    }
    for (seen) |s| if (!s) return error.StateCorrupt;
}

fn indexOfTag(tag: [4]u8) ?usize {
    for (sections, 0..) |s, i| {
        if (std.mem.eql(u8, &s.tag, &tag)) return i;
    }
    return null;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/savestate ps1-core/tests/savestate_test.zig ps1-core/src/root.zig
git add ps1-core/src/savestate ps1-core/tests/savestate_test.zig ps1-core/src/root.zig
git commit -m "feat(core): savestate container with per-section versions"
```

---

### Task 5: The equivalence gates — BIOS round trip, `trace-golden -- savestate`, the v1 fixture

**Files:**
- Create: `ps1-golden/src/savestate_roundtrip_test.zig`
- Create: `ps1-core/tests/goldens/savestate/v1-synthetic.state` (generated by the test, then committed)
- Modify: `ps1-golden/src/golden_test.zig:5-8` (pull the new test file in)
- Modify: `ps1-golden/src/main.zig` (new `savestate` mode)
- Modify: `docs/superpowers/specs/2026-10-02-resume-savestates-design.md` (record deviations 1-5 from this plan's header)

**Interfaces:**
- Consumes: `ps1_core.savestate.{save, load}` (Task 4), `state_hash.hashAll` and `golden.region_count` (existing).

- [ ] **Step 1: Write the failing round-trip and fixture tests**

`ps1-golden/src/savestate_roundtrip_test.zig`:

```zig
//! The gate that a savestate captures the WHOLE machine: two machines, one of
//! which saved and was restored into a fresh `Bus`, must then run to the same
//! hash in every region. A field a section forgets fails here as soon as it
//! matters — unless it still holds its power-on value at the save point,
//! which is what `trace-golden -- savestate` (mid-game, every workload) is for.

const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const savestate = ps1.savestate;

const bios_path = "SCPH-1001_BIOS_1995_US.bin";
const fixture_path = "ps1-core/tests/goldens/savestate/v1-synthetic.state";

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init(bios: []const u8) !Machine {
        const bus = try Bus.init(std.testing.allocator);
        @memcpy(&bus.bios, bios);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(std.testing.allocator);
    }

    fn run(m: *Machine, n: u64) void {
        for (0..n) |_| m.cpu.step();
    }

    /// Settles the deferred devices first, exactly as `ps1-golden` does
    /// before every sample.
    fn hashes(m: *Machine) [golden.region_count]u64 {
        m.bus.cdrom.catchUp();
        m.bus.gpu.catchUp();
        for (&m.bus.timers) |*t| t.catchUp();
        var out: [golden.region_count]u64 = undefined;
        state_hash.hashAll(&m.cpu, &out);
        return out;
    }

    fn saveAlloc(m: *Machine) ![]u8 {
        const n = try savestate.save(&m.cpu, null);
        const buf = try std.testing.allocator.alloc(u8, n);
        _ = try savestate.save(&m.cpu, buf);
        return buf;
    }
};

fn readBios() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, bios_path, std.testing.allocator, .limited(1 << 20)) catch
        return error.SkipZigTest; // BIOS images are gitignored
}

test "a restored machine runs on to the same hash in every region" {
    const bios = try readBios();
    defer std.testing.allocator.free(bios);

    var a = try Machine.init(bios);
    defer a.deinit();
    a.run(8_000_000); // well into the BIOS logo: GPU, SPU, timers and DMA all live

    const state = try a.saveAlloc();
    defer std.testing.allocator.free(state);

    var b = try Machine.init(bios);
    defer b.deinit();
    try savestate.load(&b.cpu, state);

    a.run(2_000_000);
    b.run(2_000_000);
    const want = a.hashes();
    const got = b.hashes();
    for (want, got, golden.region_names) |w, g, name| {
        if (w != g) std.debug.print("region {s} diverged after restore\n", .{name});
    }
    try std.testing.expectEqualSlices(u64, &want, &got);
}

test "a refused load leaves the machine it was handed byte-identical" {
    const bios = try readBios();
    defer std.testing.allocator.free(bios);

    var a = try Machine.init(bios);
    defer a.deinit();
    a.run(1_000_000);
    const state = try a.saveAlloc();
    defer std.testing.allocator.free(state);
    state[savestate.header_len + 10] ^= 0xFF;

    var b = try Machine.init(bios);
    defer b.deinit();
    b.run(500_000);
    const before = b.hashes();
    try std.testing.expectError(error.StateCorrupt, savestate.load(&b.cpu, state));
    try std.testing.expectEqualSlices(u64, &before, &b.hashes());
}

/// Deterministic, BIOS-free, and touches at least one field of every section,
/// so the committed fixture exercises every section's v1 reader. NO BIOS code
/// is involved — the BIOS is all zeros — so the fixture carries nothing
/// copyrighted into the repository.
fn buildFixtureMachine() !Machine {
    const zeros = [_]u8{0} ** (512 * 1024);
    var m = try Machine.init(&zeros);
    m.bus.ram[0x10] = 0xA1;
    m.cpu.regs[4] = 0xA2;
    m.cpu.cop2.ctrl_regs[26] = 0xA3;
    m.bus.interrupts.mask = 0xA4;
    m.bus.timers[1].target = 0xA5;
    m.bus.dma.channels[6].base_addr = 0xA6;
    m.bus.gpu.vram.data[0] = 0xA7;
    m.bus.spu.voices[23].regs.pitch = 0xA8;
    m.bus.cdrom.drive.mode = 0xA9;
    m.bus.mdec.quant_color[0] = 0xAA;
    m.bus.sio.baud = 0xAB;
    return m;
}

test "the committed v1 state still loads, into exactly the machine that wrote it" {
    const file = std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, std.testing.allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            // First run only: write it, and fail so it is noticed and committed.
            var m = try buildFixtureMachine();
            defer m.deinit();
            const state = try m.saveAlloc();
            defer std.testing.allocator.free(state);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, "ps1-core/tests/goldens/savestate");
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture_path, .data = state });
            std.debug.print("wrote {s}; commit it\n", .{fixture_path});
            return error.FixtureWritten;
        },
        else => return err,
    };
    defer std.testing.allocator.free(file);

    var want = try buildFixtureMachine();
    defer want.deinit();
    const zeros = [_]u8{0} ** (512 * 1024);
    var got = try Machine.init(&zeros);
    defer got.deinit();
    try savestate.load(&got.cpu, file);
    try std.testing.expectEqualSlices(u64, &want.hashes(), &got.hashes());
}
```

In `golden_test.zig`'s existing `test { ... }` block, add `_ = @import("savestate_roundtrip_test.zig");`.

- [ ] **Step 2: Run the tests**

Run: `zig build test`
Expected: the round-trip tests PASS if Tasks 2-4 are complete. If one FAILS, the printed region names the section with the missing field: fix that section (re-check its struct with the Task 2/3 grep) and re-run. The fixture test FAILS once with `FixtureWritten`.

- [ ] **Step 3: Re-run so the fixture test passes against the file it wrote**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Add the `savestate` mode to `ps1-golden`**

In `ps1-golden/src/main.zig`:

1. Extend the usage text after the `stream-capture` line:

```
\\  savestate       verify, but save at the run's midpoint and finish it on a
\\                  machine restored from that state into a fresh Bus
```

2. `const Mode = enum { capture, verify, stream_verify, stream_capture, pgxp, savestate };`
3. In `parseArgs`, alongside the other mode names: `else if (std.mem.eql(u8, mode, "savestate")) .savestate`
4. In `main`'s final `switch (opts.mode)`, verify the same way: replace `.verify =>` with `.verify, .savestate =>`.
5. In `runWorkload`, make the bus re-assignable and restore at the midpoint. Replace

```zig
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
```

with

```zig
    var bus = try ps1.memory.Bus.init(a);
    // Reads `bus` at scope exit, so it frees whichever machine is live then.
    defer bus.deinit(a);
    // A multiple of the interval, so the restore lands right after a sample.
    const restore_at = (opts.instructions / opts.interval / 2) * opts.interval;
```

and after `try samples.append(a, s);` inside the sampling block add:

```zig
            if (opts.mode == .savestate and i + 1 == restore_at) bus = try saveAndRestore(a, &cpu);
```

6. Add the helper below `runWorkload`:

```zig
/// Saves `cpu`'s machine, restores it into a FRESH `Bus` the way the app
/// resumes (BIOS and disc re-attached from outside, everything else from the
/// state), points `cpu` at it and frees the old one. `expansion_1` is
/// deliberately not carried: it is not in a state, so if the game wrote it
/// `hashStatic` fails the run, which is the point.
fn saveAndRestore(a: std.mem.Allocator, cpu: *ps1.cpu.Cpu) !*ps1.memory.Bus {
    const old = cpu.bus;
    const len = try ps1.savestate.save(cpu, null);
    const buf = try a.alloc(u8, len);
    defer a.free(buf);
    _ = try ps1.savestate.save(cpu, buf);

    const fresh = try ps1.memory.Bus.init(a);
    errdefer fresh.deinit(a);
    @memcpy(&fresh.bios, &old.bios);
    if (old.cdrom.disc) |d| fresh.cdrom.setDisc(d);
    var restored = ps1.cpu.Cpu.init(fresh);
    try ps1.savestate.load(&restored, buf);
    cpu.* = restored;
    old.deinit(a);
    return fresh;
}
```

- [ ] **Step 5: Run the new gate and the old one**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- savestate`
Expected: every workload reports as `verify` does, all matching. A divergence names its first region: that section is missing a field that is non-default mid-game (a seek timer, a DMA chain, a half-built GP0 command, a voice mid-release). Fix it in `ps1-core/src/savestate/`, re-run Task 2/3/4's tests, then this.

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify`
Expected: unchanged, all green (no golden moves — this task changes no emulated behaviour).

- [ ] **Step 6: Amend the spec**

In the spec, replace the "Deferred ticks" subsection's body with deviation 1's text from this plan's header, remove `deflate(...)` from the container diagram and the "Size" paragraph's deflate sentence (say the app compresses with LZFSE), replace `disc_index u8` with nothing in the header diagram and replace each later mention of `disc_index` with "the header's serial", and add deviation 5 under "What is NOT in a state".

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src ps1-core/tests/goldens/savestate/v1-synthetic.state docs/superpowers/specs/2026-10-02-resume-savestates-design.md
git commit -m "test(golden): savestate round-trip gate and trace-golden savestate mode"
```

---

### Task 6: The C ABI

**Files:**
- Modify: `ps1-capi/src/root.zig` (error codes; extract `installHost`, `HostSettings`, `snapshotCards`/`restoreDirty` out of `buildMachine`/`ps1_reset`; four new exports)
- Modify: `ps1-capi/include/ps1.h`
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `ps1_core.savestate.{save, load, peek, Error}`.
- Produces (C):

```c
#define PS1_ERR_STATE_BAD_MAGIC  (-8)
#define PS1_ERR_STATE_VERSION    (-9)
#define PS1_ERR_STATE_BIOS       (-10)
#define PS1_ERR_STATE_DISC       (-11)
#define PS1_ERR_STATE_CORRUPT    (-12)
#define PS1_ERR_STATE_NO_SPACE   (-13)

typedef struct {
    char    serial[16];        /* NUL-padded; all zero for a disc with none */
    uint8_t bios_sha256[32];
} Ps1StateInfo;

size_t  ps1_save_state_size(Ps1*);
int32_t ps1_save_state(Ps1*, uint8_t* dst, size_t cap, size_t* out_len);
int32_t ps1_load_state(Ps1*, const uint8_t* src, size_t len);
int32_t ps1_peek_state(const uint8_t* src, size_t len, Ps1StateInfo* out);
```

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
fn bootHandle(fill: u8) !*capi.Handle {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    errdefer capi.ps1_destroy(h);
    const bios = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(bios);
    @memset(bios, fill);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, bios.ptr, bios.len));
    return h;
}

fn saveState(h: *capi.Handle) ![]u8 {
    const cap = capi.ps1_save_state_size(h);
    const buf = try std.testing.allocator.alloc(u8, cap);
    errdefer std.testing.allocator.free(buf);
    var len: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_save_state(h, buf.ptr, buf.len, &len));
    try std.testing.expectEqual(cap, len);
    return buf;
}

test "save then load restores the machine" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    h.cpu.bus.ram[0x2000] = 0x77;
    h.cpu.regs[8] = 0xBEEF;
    const state = try saveState(h);
    defer std.testing.allocator.free(state);

    h.cpu.bus.ram[0x2000] = 0;
    h.cpu.regs[8] = 0;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expectEqual(@as(u8, 0x77), h.cpu.bus.ram[0x2000]);
    try std.testing.expectEqual(@as(u32, 0xBEEF), h.cpu.regs[8]);
    try std.testing.expect(h.cpu.bus == h.bus);
}

test "a refused load leaves the running machine untouched" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);
    state[100] ^= 0xFF;

    const bus_before = h.bus;
    h.cpu.bus.ram[0x3000] = 0x42;
    try std.testing.expectEqual(capi.PS1_ERR_STATE_CORRUPT, capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expect(h.bus == bus_before);
    try std.testing.expectEqual(@as(u8, 0x42), h.cpu.bus.ram[0x3000]);
}

test "a state from a different BIOS is refused" {
    const a = try bootHandle(0x11);
    defer capi.ps1_destroy(a);
    const state = try saveState(a);
    defer std.testing.allocator.free(state);

    const b = try bootHandle(0x22);
    defer capi.ps1_destroy(b);
    try std.testing.expectEqual(capi.PS1_ERR_STATE_BIOS, capi.ps1_load_state(b, state.ptr, state.len));
}

test "save into a short buffer is NO_SPACE" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    var tiny: [16]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(capi.PS1_ERR_STATE_NO_SPACE, capi.ps1_save_state(h, &tiny, tiny.len, &len));
}

test "peek reads the identity without a machine" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);
    var info: capi.Ps1StateInfo = undefined;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_peek_state(state.ptr, state.len, &info));
    try std.testing.expectEqual(@as(u8, 0), info.serial[0]); // no disc
    try std.testing.expectEqual(capi.PS1_ERR_STATE_BAD_MAGIC, capi.ps1_peek_state(state.ptr, 3, &info));
}

test "a load keeps the player's settings and an undrained card write" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);

    capi.ps1_set_pgxp(h, 1);
    capi.ps1_set_pgxp_texture_correction(h, 0);
    h.cpu.bus.sio.memcard_dirty[0] = true;

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expect(h.bus.pgxp_enabled);
    try std.testing.expect(!h.bus.pgxp_texture_correction);
    try std.testing.expect(h.bus.sio.memcard_dirty[0]);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `ps1_save_state_size` not found in `capi`.

- [ ] **Step 3: Refactor `buildMachine` and `ps1_reset` into reusable pieces**

In `ps1-capi/src/root.zig`, add the error codes beside the others:

```zig
pub const PS1_ERR_STATE_BAD_MAGIC: i32 = -8;
pub const PS1_ERR_STATE_VERSION: i32 = -9;
pub const PS1_ERR_STATE_BIOS: i32 = -10;
pub const PS1_ERR_STATE_DISC: i32 = -11;
pub const PS1_ERR_STATE_CORRUPT: i32 = -12;
pub const PS1_ERR_STATE_NO_SPACE: i32 = -13;
```

Split `buildMachine` so its host half can target any bus (keep every existing comment, moved into `installHost`):

```zig
fn buildMachine(h: *Handle) void {
    h.cpu = Cpu.init(h.bus);
    installHost(h, h.bus);
}

/// What the HOST owns and a rebuilt `Bus` must get back: the recorder's arm,
/// the BIOS image, the disc and the cards. Shared by a reset and by a state
/// load, which both build a fresh `Bus`.
fn installHost(h: *Handle, bus: *Bus) void {
    if (comptime ps1.gpu.Sink.kind == .dual) bus.gpu.sink.rec.arm();
    if (h.bios_loaded) @memcpy(bus.bios[0..], h.bios[0..]);
    if (h.disc) |d| bus.cdrom.setDisc(d);
    for (0..Sio.memcard_slots) |i| bus.sio.setMemoryCardData(i, &h.memcard[i]);
}
```

Lift `ps1_reset`'s anonymous settings struct into a named type (the existing comments about `pgxp_texture_correction` move with it):

```zig
/// The renderer settings that live on `Bus`. They are the player's choice, not
/// machine state, so every rebuild of `Bus` carries them across.
const HostSettings = struct {
    on: bool,
    cpu: bool,
    culling: bool,
    tolerance: f32,
    cache: bool,
    texture: bool,
    color: bool,
    depth: bool,
    transparent_depth: bool,
    disable_2d: bool,
    preserve_projection: bool,

    fn capture(bus: *const Bus) HostSettings {
        return .{
            .on = bus.pgxp_enabled,
            .cpu = bus.pgxp_cpu,
            .culling = bus.pgxp_culling,
            .tolerance = bus.pgxp_tolerance,
            .cache = bus.pgxp_vertex_cache != null,
            .texture = bus.pgxp_texture_correction,
            .color = bus.pgxp_color_correction,
            .depth = bus.pgxp_depth_buffer,
            .transparent_depth = bus.pgxp_transparent_depth,
            .disable_2d = bus.pgxp_disable_2d,
            .preserve_projection = bus.pgxp_preserve_projection,
        };
    }

    fn apply(s: HostSettings, bus: *Bus) void {
        bus.pgxp_cpu = s.cpu;
        bus.pgxp_culling = s.culling;
        bus.setPgxpTolerance(s.tolerance);
        bus.setPgxpVertexCache(allocator, s.cache) catch {};
        bus.pgxp_texture_correction = s.texture;
        bus.pgxp_color_correction = s.color;
        bus.pgxp_depth_buffer = s.depth;
        bus.pgxp_transparent_depth = s.transparent_depth;
        bus.pgxp_disable_2d = s.disable_2d;
        bus.pgxp_preserve_projection = s.preserve_projection;
        // Last, because it is what mirrors the rest onto the GPU.
        bus.setPgxp(s.on);
    }
};

/// Copies the LIVE card images into the handle and returns their dirty
/// flags, so a rebuilt `Bus` gets the player's latest save rather than the
/// last one the frontend loaded. (Reasoning: see `ps1_reset`.)
fn snapshotCards(h: *Handle) [Sio.memcard_slots]bool {
    var dirty: [Sio.memcard_slots]bool = undefined;
    for (0..Sio.memcard_slots) |i| {
        @memcpy(h.memcard[i][0..], h.bus.sio.getMemoryCardData(i));
        dirty[i] = h.bus.sio.isMemoryCardDirty(i);
    }
    return dirty;
}

fn restoreDirty(bus: *Bus, dirty: [Sio.memcard_slots]bool) void {
    for (0..Sio.memcard_slots) |i| {
        if (dirty[i]) bus.sio.memcard_dirty[i] = true;
    }
}
```

`ps1_reset` becomes (its long comments stay, above the matching lines):

```zig
pub export fn ps1_reset(h: *Handle) void {
    const dirty = snapshotCards(h);
    const settings = HostSettings.capture(h.bus);
    h.bus.deinit(allocator);
    h.bus = Bus.init(allocator) catch {
        @panic("ps1_reset: out of memory rebuilding Bus");
    };
    buildMachine(h);
    settings.apply(h.bus);
    restoreDirty(h.bus, dirty);
}
```

Run `zig build test` now: every pre-existing `capi_test` must still pass (the refactor changes no behaviour).

- [ ] **Step 4: Add the four exports**

```zig
fn stateCode(err: ps1.savestate.Error) i32 {
    return switch (err) {
        error.StateBadMagic => PS1_ERR_STATE_BAD_MAGIC,
        error.StateVersion => PS1_ERR_STATE_VERSION,
        error.StateBios => PS1_ERR_STATE_BIOS,
        error.StateDisc => PS1_ERR_STATE_DISC,
        error.StateCorrupt => PS1_ERR_STATE_CORRUPT,
        error.NoSpace => PS1_ERR_STATE_NO_SPACE,
    };
}

/// The exact size `ps1_save_state` will write for the machine as it is now.
pub export fn ps1_save_state_size(h: *Handle) usize {
    return ps1.savestate.save(&h.cpu, null) catch 0;
}

pub export fn ps1_save_state(h: *Handle, dst: [*]u8, cap: usize, out_len: *usize) i32 {
    out_len.* = ps1.savestate.save(&h.cpu, dst[0..cap]) catch |err| return stateCode(err);
    return PS1_OK;
}

/// All-or-nothing: the state is decoded into a scratch `Bus` carrying this
/// handle's BIOS, disc and cards, and swapped in only once every section has
/// parsed. A refusal leaves the running machine exactly as it was. The
/// player's settings and an undrained card write are carried across, exactly
/// as `ps1_reset` carries them.
pub export fn ps1_load_state(h: *Handle, src: [*]const u8, len: usize) i32 {
    const fresh = Bus.init(allocator) catch return PS1_ERR_OOM;
    const dirty = snapshotCards(h);
    installHost(h, fresh);
    var cpu = Cpu.init(fresh);
    ps1.savestate.load(&cpu, src[0..len]) catch |err| {
        fresh.deinit(allocator);
        return stateCode(err);
    };
    const settings = HostSettings.capture(h.bus);
    h.bus.deinit(allocator);
    h.bus = fresh;
    h.cpu = cpu;
    settings.apply(h.bus);
    restoreDirty(h.bus, dirty);
    return PS1_OK;
}

pub const Ps1StateInfo = extern struct {
    serial: [16]u8,
    bios_sha256: [32]u8,
};

pub export fn ps1_peek_state(src: [*]const u8, len: usize, out: *Ps1StateInfo) i32 {
    const id = ps1.savestate.peek(src[0..len]) catch |err| return stateCode(err);
    out.* = .{ .serial = id.serial, .bios_sha256 = id.bios_sha256 };
    return PS1_OK;
}
```

- [ ] **Step 5: Declare them in `ps1.h`**

After the `PS1_ERR_BAD_SLOT` define, add the six `PS1_ERR_STATE_*` defines from the Interfaces block. After `ps1_read_audio`'s declaration, add:

```c
/* ---- Savestates -----------------------------------------------------------
 *
 * A state is the whole emulated machine, versioned per device so a state
 * survives an update of this library. It does NOT contain the BIOS, the disc
 * or the memory cards: load the same BIOS and disc first (the state records
 * the BIOS's SHA-256 and the disc's serial, and refuses a mismatch with
 * PS1_ERR_STATE_BIOS / PS1_ERR_STATE_DISC), then call ps1_load_state.
 *
 * ps1_load_state is all-or-nothing: on any error the running machine is
 * untouched. Renderer settings and an undrained memory-card write survive it.
 * A state from a NEWER library is PS1_ERR_STATE_VERSION. */
typedef struct {
    char    serial[16];        /* NUL-padded; all zero for a disc with none */
    uint8_t bios_sha256[32];
} Ps1StateInfo;

size_t  ps1_save_state_size(Ps1*);
int32_t ps1_save_state(Ps1*, uint8_t* dst, size_t cap, size_t* out_len);
int32_t ps1_load_state(Ps1*, const uint8_t* src, size_t len);
int32_t ps1_peek_state(const uint8_t* src, size_t len, Ps1StateInfo* out);
```

- [ ] **Step 6: Run the tests and rebuild the library**

Run: `zig build test && zig build capi-lib`
Expected: PASS; `zig-out/lib/libps1core.a` rebuilt.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-capi/src
git add ps1-capi
git commit -m "feat(capi): save, load and peek savestates"
```

---

### Task 7: Swift core wrappers and the thumbnail

**Files:**
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift`
- Create: `ps1-macos/Sources/PS1/ResumeThumbnail.swift`
- Test: `ps1-macos/Tests/PS1Tests/ResumeThumbnailTests.swift`
- Test: `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`

**Interfaces:**
- Consumes: Task 6's C functions (through `CPs1`, which includes `ps1.h`).
- Produces:
  - `Ps1Error` gains `.stateBadMagic, .stateVersion, .stateBIOS, .stateDisc, .stateCorrupt, .stateNoSpace`
  - `Ps1Core.saveState() throws -> Data`
  - `Ps1Core.loadState(_ data: Data) throws`
  - `static Ps1Core.peekStateSerial(_ data: Data) throws -> String?` (nil for a disc with no serial)
  - `enum ResumeThumbnail { static let size = CGSize(width: 320, height: 240); static func png(vram: UnsafeBufferPointer<UInt16>, display: Ps1Display) -> Data? }`

- [ ] **Step 1: Write the failing tests**

`ps1-macos/Tests/PS1Tests/ResumeThumbnailTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PS1

private let vramWidth = 1024
private let vramHeight = 512

/// Decodes the PNG and returns the RGB of one pixel.
private func pixel(_ png: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let ctx = CGContext(data: &buf, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let i = ((image.height - 1 - y) * image.width + x) * 4
    return (buf[i], buf[i + 1], buf[i + 2])
}

private func display(x: UInt32, y: UInt32, w: UInt32, h: UInt32, depth24: Bool) -> Ps1Display {
    var d = Ps1Display()
    d.vram_x = x; d.vram_y = y; d.width = w; d.height = h
    d.depth24 = depth24 ? 1 : 0
    d.enabled = 1
    return d
}

@Test func a15bppDisplayIsCroppedAndExpanded() throws {
    // Blue everywhere, pure red inside the 320x240 display area at (64, 32).
    var vram = [UInt16](repeating: 0x1F << 10, count: vramWidth * vramHeight)
    for y in 32..<(32 + 240) { for x in 64..<(64 + 320) { vram[y * vramWidth + x] = 0x1F } }
    let png = try #require(vram.withUnsafeBufferPointer {
        ResumeThumbnail.png(vram: $0, display: display(x: 64, y: 32, w: 320, h: 240, depth24: false))
    })
    let p = try #require(pixel(png, x: 160, y: 120))
    #expect(p.r == 255 && p.g == 0 && p.b == 0)
    let corner = try #require(pixel(png, x: 2, y: 2))
    #expect(corner.b < 32) // the blue outside the crop never reaches the picture
}

@Test func a24bppDisplayIsUnpackedAcrossWords() throws {
    // R=10, G=200, B=30 packed three bytes per pixel across 16-bit words.
    var vram = [UInt16](repeating: 0, count: vramWidth * vramHeight)
    let rgb: [UInt8] = [10, 200, 30]
    for y in 0..<240 {
        for byte in 0..<(320 * 3) {
            let word = y * vramWidth + byte / 2
            let value = UInt16(rgb[byte % 3])
            vram[word] |= byte % 2 == 0 ? value : value << 8
        }
    }
    let png = try #require(vram.withUnsafeBufferPointer {
        ResumeThumbnail.png(vram: $0, display: display(x: 0, y: 0, w: 320, h: 240, depth24: true))
    })
    let p = try #require(pixel(png, x: 160, y: 120))
    #expect(p.r == 10 && p.g == 200 && p.b == 30)
}

@Test func theThumbnailIsAlways320By240() throws {
    let vram = [UInt16](repeating: 0x7FFF, count: vramWidth * vramHeight)
    let png = try #require(vram.withUnsafeBufferPointer {
        ResumeThumbnail.png(vram: $0, display: display(x: 0, y: 0, w: 640, h: 480, depth24: false))
    })
    let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(image.width == 320 && image.height == 240)
}

@Test func aDisabledDisplayHasNoThumbnail() {
    let vram = [UInt16](repeating: 0, count: vramWidth * vramHeight)
    var d = display(x: 0, y: 0, w: 320, h: 240, depth24: false)
    d.enabled = 0
    #expect(vram.withUnsafeBufferPointer { ResumeThumbnail.png(vram: $0, display: d) } == nil)
}
```

Append to `Ps1CoreTests.swift`:

```swift
@Test func aStateRoundTripsThroughTheCore() throws {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let state = try core.saveState()
    #expect(state.count > 1_000_000)
    #expect(try Ps1Core.peekStateSerial(state) == nil)
    try core.loadState(state)
}

@Test func aDamagedStateIsRefusedAsCorrupt() throws {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    var state = try core.saveState()
    state[100] ^= 0xFF
    #expect(throws: Ps1Error.stateCorrupt) { try core.loadState(state) }
}

@Test func aStateFromAnotherBIOSIsRefused() throws {
    let a = try Ps1Core()
    try a.loadBIOS(Data(repeating: 0, count: 524288))
    let state = try a.saveState()
    let b = try Ps1Core()
    try b.loadBIOS(Data(repeating: 1, count: 524288))
    #expect(throws: Ps1Error.stateBIOS) { try b.loadState(state) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: FAIL to build — `ResumeThumbnail` and `saveState` not found.

- [ ] **Step 3: Extend `Ps1Error` and `Ps1Core`**

In `Ps1Error`, add the cases and the mapping:

```swift
    case stateBadMagic
    case stateVersion
    case stateBIOS
    case stateDisc
    case stateCorrupt
    case stateNoSpace
```

```swift
        case -8: return .stateBadMagic
        case -9: return .stateVersion
        case -10: return .stateBIOS
        case -11: return .stateDisc
        case -12: return .stateCorrupt
        case -13: return .stateNoSpace
```

In `Ps1Core`, after `takeMemcard`:

```swift
    /// The whole machine. Call from the thread that owns the core.
    func saveState() throws -> Data {
        var data = Data(count: ps1_save_state_size(handle))
        var written = 0
        let code = data.withUnsafeMutableBytes { raw in
            ps1_save_state(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &written)
        }
        if let e = Ps1Error.from(code) { throw e }
        return data.prefix(written)
    }

    /// All-or-nothing in the core: a throw leaves the machine as it was.
    /// Load the BIOS and the disc first — the state records both and refuses
    /// a mismatch.
    func loadState(_ data: Data) throws {
        let code = data.withUnsafeBytes { raw in
            ps1_load_state(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let e = Ps1Error.from(code) { throw e }
    }

    /// The serial of the disc that was in the tray, read from the header
    /// alone. Nil for a disc that names none.
    static func peekStateSerial(_ data: Data) throws -> String? {
        var info = Ps1StateInfo()
        let code = data.withUnsafeBytes { raw in
            ps1_peek_state(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &info)
        }
        if let e = Ps1Error.from(code) { throw e }
        let bytes = withUnsafeBytes(of: info.serial) { Array($0) }.prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
```

- [ ] **Step 4: Implement `ResumeThumbnail.swift`**

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The picture on the resume prompt, taken from CORE VRAM at the instant of
/// the save so it shows exactly the saved frame.
///
/// Never from the Metal drawable: that may be upscaled, a frame later, or
/// under the HUD. The display area is cropped and decoded here the way
/// `DisplayShader.metal` scans it out — 15 bpp, or 24 bpp packed three bytes
/// per pixel across 16-bit words — with the same `c << 3 | c >> 2` expansion,
/// then drawn at 4:3 whatever the display's pixel size, which is how the game
/// is shown.
enum ResumeThumbnail {
    static let size = CGSize(width: 320, height: 240)
    private static let vramWidth = 1024
    private static let vramHeight = 512

    static func png(vram: UnsafeBufferPointer<UInt16>, display d: Ps1Display) -> Data? {
        let w = Int(d.width), h = Int(d.height)
        guard d.enabled != 0, w > 0, h > 0,
              vram.count == vramWidth * vramHeight else { return nil }

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let row = ((Int(d.vram_y) + y) & (vramHeight - 1)) * vramWidth
            for x in 0..<w {
                let o = (y * w + x) * 4
                if d.depth24 != 0 {
                    // Byte k of the row lives in halfword (vram_x + k/2), low byte first.
                    func byte(_ k: Int) -> UInt8 {
                        let word = vram[row + ((Int(d.vram_x) + k / 2) & (vramWidth - 1))]
                        return UInt8(truncatingIfNeeded: k % 2 == 0 ? word : word >> 8)
                    }
                    rgba[o] = byte(x * 3)
                    rgba[o + 1] = byte(x * 3 + 1)
                    rgba[o + 2] = byte(x * 3 + 2)
                } else {
                    let p = vram[row + ((Int(d.vram_x) + x) & (vramWidth - 1))]
                    rgba[o] = expand(p & 0x1F)
                    rgba[o + 1] = expand((p >> 5) & 0x1F)
                    rgba[o + 2] = expand((p >> 10) & 0x1F)
                }
            }
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let source = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// 5 -> 8 bits by replicating the high bits, so 31 maps to 255 — the one
    /// expansion every display path in the app uses.
    private static func expand(_ c: UInt16) -> UInt8 {
        UInt8((c << 3) | (c >> 2))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build capi-lib metallib && pkill -x Substation; ps1-macos/test.sh`
Expected: PASS, with the new thumbnail and core tests in the list.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/Ps1Core.swift ps1-macos/Sources/PS1/ResumeThumbnail.swift ps1-macos/Tests/PS1Tests/ResumeThumbnailTests.swift ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift
git commit -m "feat(macos): savestate wrappers and resume thumbnail"
```

---

### Task 8: Resume storage and the exit setting

**Files:**
- Create: `ps1-macos/Sources/PS1/ResumeStateStore.swift`
- Create: `ps1-macos/Sources/PS1/ResumeOnExitSetting.swift`
- Modify: `ps1-macos/Sources/PS1/GameEntry.swift` (add `pathKey`)
- Modify: `ps1-macos/Sources/PS1/CoverStore.swift:94-96` (use `entry.pathKey`, delete its private copy)
- Test: `ps1-macos/Tests/PS1Tests/ResumeStateStoreTests.swift`

**Interfaces:**
- Produces:
  - `GameEntry.pathKey: String` — SHA-256 hex of `id`
  - `final class ResumeStateStore: Sendable` with
    - `init(directory: URL? = nil)` (default `AppSupport.directory("ResumeStates")`)
    - `static func key(for game: GameEntry) -> String` — `game.serial ?? game.pathKey`
    - `func info(_ key: String) -> ResumeStateStore.Info?` where `struct Info { let savedAt: Date; let thumbnail: URL? }`
    - `func load(_ key: String) -> Data?` (decompressed; nil when absent or undecodable)
    - `func save(state: Data, thumbnail: Data?, key: String) throws`
    - `func remove(_ key: String)`
  - `struct ResumeOnExitSetting { static let defaultsKey = "saveStateOnExit"; init(key:defaults:); private(set) var enabled: Bool; mutating func set(_:) }`

- [ ] **Step 1: Write the failing tests**

`ps1-macos/Tests/PS1Tests/ResumeStateStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

private func makeStore() -> ResumeStateStore {
    ResumeStateStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("resume-\(UUID().uuidString)"))
}

private func entry(_ path: String, serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), isCue: true,
              identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

@Test func aStateReadsBackByteForByteThroughCompression() throws {
    let store = makeStore()
    let state = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 / 1000) })
    try store.save(state: state, thumbnail: Data([1, 2, 3]), key: "SLUS-00001")
    #expect(store.load("SLUS-00001") == state)
    let info = try #require(store.info("SLUS-00001"))
    #expect(info.thumbnail != nil)
    #expect(abs(info.savedAt.timeIntervalSinceNow) < 60)
}

@Test func aGameWithNoStateHasNoInfo() {
    #expect(makeStore().info("nothing") == nil)
    #expect(makeStore().load("nothing") == nil)
}

@Test func savingWithoutAThumbnailDropsTheOldOne() throws {
    let store = makeStore()
    try store.save(state: Data([1]), thumbnail: Data([9]), key: "k")
    try store.save(state: Data([2]), thumbnail: nil, key: "k")
    #expect(store.info("k")?.thumbnail == nil)
}

@Test func removeDeletesStateAndThumbnail() throws {
    let store = makeStore()
    try store.save(state: Data([1]), thumbnail: Data([9]), key: "k")
    store.remove("k")
    #expect(store.info("k") == nil)
}

@Test func anUndecodableFileLoadsAsNilButStillHasInfo() throws {
    // So the prompt still appears and Delete & Boot stays reachable.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
    let store = ResumeStateStore(directory: dir)
    try store.save(state: Data([1]), thumbnail: nil, key: "k")
    try Data("garbage".utf8).write(to: dir.appendingPathComponent("k.state"))
    #expect(store.load("k") == nil)
    #expect(store.info("k") != nil)
}

@Test func theKeyIsTheSerialElseThePathHash() {
    #expect(ResumeStateStore.key(for: entry("/g/a.cue", serial: "SCUS-94163")) == "SCUS-94163")
    let unnamed = entry("/g/b.cue", serial: nil)
    #expect(ResumeStateStore.key(for: unnamed) == unnamed.pathKey)
    #expect(unnamed.pathKey.count == 64)
}

@Test func saveOnExitDefaultsOnAndPersists() {
    let defaults = UserDefaults(suiteName: "resume-\(UUID().uuidString)")!
    var setting = ResumeOnExitSetting(key: "k", defaults: defaults)
    #expect(setting.enabled)
    setting.set(false)
    #expect(!ResumeOnExitSetting(key: "k", defaults: defaults).enabled)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: FAIL to build — `ResumeStateStore` not found.

- [ ] **Step 3: Move the path key onto `GameEntry`**

In `GameEntry.swift`, add `import CryptoKit` at the top and inside the struct:

```swift
    /// The fallback key for a disc that names no serial. Hashed rather than
    /// escaped: a path can be any length and hold any character, and a
    /// fixed-width hex name is a filename on every volume.
    var pathKey: String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
```

In `CoverStore.swift`, delete `private static func pathKey(_:)` (and its doc comment) and replace its two call sites `Self.pathKey(entry)` with `entry.pathKey`. Remove `import CryptoKit` from `CoverStore.swift` only if nothing else there uses it.

- [ ] **Step 4: Implement `ResumeOnExitSetting.swift`**

```swift
import Foundation

/// Whether leaving a game saves a resume state. The checkbox on the exit
/// sheet IS this setting: unticking it once keeps it unticked.
///
/// Defaults to TRUE, so — as `MultiDiscSetting` explains — absence is probed
/// with `object(forKey:)`; `bool(forKey:)` would ship it off on first launch.
struct ResumeOnExitSetting {
    static let defaultsKey = "saveStateOnExit"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = ResumeOnExitSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? true
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
```

- [ ] **Step 5: Implement `ResumeStateStore.swift`**

```swift
import Foundation

/// One resume state per GAME, on disk: `<key>.state` (LZFSE-compressed core
/// state) and `<key>.png` (its thumbnail), under
/// `Application Support/Substation/ResumeStates/`.
///
/// Keyed on the game's FIRST disc — so a multi-disc game has one slot, and
/// the state's own header says which disc was in the tray. Serial first,
/// path hash for a disc that names none: the `CoverStore` rule, so a rip
/// that is moved or renamed keeps its state.
///
/// Writes are atomic (`.atomic` writes a temporary file and renames it), so a
/// crash mid-save leaves the previous state rather than a torn one to be
/// offered. The thumbnail is written first: a crash between the two leaves a
/// new picture over the old state, never a state with no picture at all.
final class ResumeStateStore: Sendable {
    struct Info: Equatable {
        let savedAt: Date
        let thumbnail: URL?
    }

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? AppSupport.directory("ResumeStates")
    }

    static func key(for game: GameEntry) -> String {
        game.serial ?? game.pathKey
    }

    func info(_ key: String) -> Info? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL(key).path)
        guard let savedAt = attrs?[.modificationDate] as? Date else { return nil }
        let png = thumbnailURL(key)
        return Info(savedAt: savedAt,
                    thumbnail: FileManager.default.fileExists(atPath: png.path) ? png : nil)
    }

    func load(_ key: String) -> Data? {
        guard let packed = try? Data(contentsOf: stateURL(key)) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzfse) as Data
    }

    func save(state: Data, thumbnail: Data?, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let thumbnail {
            try thumbnail.write(to: thumbnailURL(key), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: thumbnailURL(key))
        }
        let packed = try (state as NSData).compressed(using: .lzfse) as Data
        try packed.write(to: stateURL(key), options: .atomic)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: stateURL(key))
        try? FileManager.default.removeItem(at: thumbnailURL(key))
    }

    private func stateURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).state")
    }

    private func thumbnailURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: PASS, including every pre-existing `CoverStoreTests`.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1 ps1-macos/Tests/PS1Tests/ResumeStateStoreTests.swift
git commit -m "feat(macos): per-game resume state store"
```

---

### Task 9: Runner save requests, the exit gate and the resume offer

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift` (save request slot, `serviceSaveRequest`, call in `runLoop`)
- Create: `ps1-macos/Sources/PS1/ExitGate.swift` (`ExitIntent`, `ExitGate`, `ExitCompletion`)
- Create: `ps1-macos/Sources/PS1/ResumeOffer.swift` (`ResumeOffer`, `ResumeChoice`)
- Test: `ps1-macos/Tests/PS1Tests/ExitGateTests.swift`
- Test: `ps1-macos/Tests/PS1Tests/ResumeOfferTests.swift`
- Test: `ps1-macos/Tests/PS1Tests/EmulatorRunnerSaveStateTests.swift`

**Interfaces:**
- Consumes: `Ps1Core.saveState/peekStateSerial`, `ResumeThumbnail.png`, `ResumeStateStore` (Tasks 7-8).
- Produces:
  - `struct ResumeSnapshot: Sendable { let state: Data; let thumbnail: Data? }`
  - `EmulatorRunner.requestSaveState(_ completion: @escaping @Sendable (Result<ResumeSnapshot, Error>) -> Void)`
  - `EmulatorRunner.serviceSaveRequest()` (internal, called by `runLoop` and tests)
  - `enum ExitIntent: Equatable { case quit, closeWindow, eject, open(URL); var question: String }`
  - `enum ExitDecision { case proceed, prompted, busy }`
  - `struct ExitGate { private(set) var pending: ExitIntent?; mutating func request(_:playing:) -> ExitDecision; mutating func take() -> ExitIntent?; mutating func cancel() -> ExitIntent? }`
  - `final class ExitCompletion { init(_ body: @escaping () -> Void); func fire() }` — runs `body` at most once
  - `enum ResumeChoice { case resume, freshBoot, deleteAndBoot, cancel }`
  - `struct ResumeOffer: Identifiable { let id: UUID; let title: String; let key: String; let launching: GameEntry; let resumeDisc: GameEntry?; let info: ResumeStateStore.Info; static func make(launching:siblings:store:) -> ResumeOffer? }`

- [ ] **Step 1: Write the failing tests**

`ps1-macos/Tests/PS1Tests/ExitGateTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

@Test func nothingRunningProceedsAtOnce() {
    var gate = ExitGate()
    #expect(gate.request(.quit, playing: false) == .proceed)
    #expect(gate.pending == nil)
}

@Test func aRunningGamePromptsOnce() {
    var gate = ExitGate()
    #expect(gate.request(.eject, playing: true) == .prompted)
    #expect(gate.pending == .eject)
}

@Test func aSecondRequestWhileThePromptIsUpIsBusyAndChangesNothing() {
    // ⌘Q while the Eject sheet is up must be answered .terminateCancel by the
    // caller, never left as a .terminateLater nobody replies to.
    var gate = ExitGate()
    _ = gate.request(.eject, playing: true)
    #expect(gate.request(.quit, playing: true) == .busy)
    #expect(gate.pending == .eject)
}

@Test func takeAndCancelBothClearThePrompt() {
    var gate = ExitGate()
    _ = gate.request(.quit, playing: true)
    #expect(gate.take() == .quit)
    #expect(gate.pending == nil)
    _ = gate.request(.closeWindow, playing: true)
    #expect(gate.cancel() == .closeWindow)
    #expect(gate.pending == nil)
}

@MainActor @Test func anExitCompletionRunsAtMostOnce() {
    // The save's completion and the 3-second fallback both call fire().
    var count = 0
    let done = ExitCompletion { count += 1 }
    done.fire()
    done.fire()
    #expect(count == 1)
}

@Test func theQuestionNamesWhatIsBeingLeft() {
    #expect(ExitIntent.quit.question == "Are you sure you want to exit the application?")
    #expect(ExitIntent.closeWindow.question == "Are you sure you want to exit the application?")
    #expect(ExitIntent.eject.question == "Are you sure you want to exit the game?")
    #expect(ExitIntent.open(URL(fileURLWithPath: "/x.cue")).question == "Are you sure you want to exit the game?")
}
```

`ps1-macos/Tests/PS1Tests/ResumeOfferTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

private func disc(_ path: String, _ serial: String?) -> GameEntry {
    GameEntry(url: URL(fileURLWithPath: path), isCue: true,
              identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

private func makeStore() -> ResumeStateStore {
    ResumeStateStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("offer-\(UUID().uuidString)"))
}

/// A real state with no disc (empty serial), from a BIOS of zeros.
private func biosOnlyState() throws -> Data {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    return try core.saveState()
}

@Test func noStateMeansNoOffer() {
    let d1 = disc("/g/Game (Disc 1).cue", "SCUS-1")
    #expect(ResumeOffer.make(launching: d1, siblings: [d1], store: makeStore()) == nil)
}

@Test func theOfferIsKeyedOnTheFirstDiscWhicheverDiscIsLaunched() throws {
    let d1 = disc("/g/Game (Disc 1).cue", "SCUS-1")
    let d2 = disc("/g/Game (Disc 2).cue", "SCUS-2")
    let store = makeStore()
    try store.save(state: try biosOnlyState(), thumbnail: nil, key: "SCUS-1")
    let offer = try #require(ResumeOffer.make(launching: d2, siblings: [d1, d2], store: store))
    #expect(offer.key == "SCUS-1")
    #expect(offer.launching == d2)
}

@Test func theResumeDiscIsTheOneWhoseSerialTheStateNames() {
    let d1 = disc("/g/Game (Disc 1).cue", "SCUS-1")
    let d2 = disc("/g/Game (Disc 2).cue", "SCUS-2")
    #expect(ResumeOffer.disc(forSerial: "SCUS-2", in: [d1, d2]) == d2)
    // A state for a disc that names no serial resumes on the first disc.
    #expect(ResumeOffer.disc(forSerial: nil, in: [d1, d2]) == d1)
    // A disc that is no longer in the library cannot be resumed.
    #expect(ResumeOffer.disc(forSerial: "SCUS-3", in: [d1, d2]) == nil)
}

@Test func aDamagedStateStillProducesAnOffer() throws {
    // So Delete & Boot stays reachable; Resume then explains the damage.
    let d1 = disc("/g/Game.cue", "SLUS-9")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offer-\(UUID().uuidString)")
    let store = ResumeStateStore(directory: dir)
    try store.save(state: Data([1]), thumbnail: nil, key: "SLUS-9")
    try Data("garbage".utf8).write(to: dir.appendingPathComponent("SLUS-9.state"))
    let offer = try #require(ResumeOffer.make(launching: d1, siblings: [d1], store: store))
    #expect(offer.resumeDisc == d1)
}
```

`ps1-macos/Tests/PS1Tests/EmulatorRunnerSaveStateTests.swift`:

```swift
import Testing
import Foundation
import Synchronization
@testable import PS1

@Test func aSaveRequestIsServicedWithAStateThatLoadsBack() throws {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("save-\(UUID().uuidString)")))
    let got = Mutex<Result<ResumeSnapshot, Error>?>(nil)
    runner.requestSaveState { result in got.withLock { $0 = result } }
    runner.serviceSaveRequest()

    let snapshot = try #require(got.withLock { $0 }).get()
    let other = try Ps1Core()
    try other.loadBIOS(Data(repeating: 0, count: 524288))
    try other.loadState(snapshot.state)
}

@Test func withNoRequestServicingDoesNothing() throws {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
    let runner = EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                                cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("save-\(UUID().uuidString)")))
    runner.serviceSaveRequest() // must not crash or call anything
}
```

(If `EmulatorRunner`'s initializer differs, copy the construction from `EmulatorRunnerMemoryCardTests.swift`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: FAIL to build — `ExitGate`, `ResumeOffer`, `requestSaveState` not found.

- [ ] **Step 3: Implement `ExitGate.swift`**

```swift
import Foundation

/// Every way of leaving a running game, and the question the exit sheet asks
/// for each.
enum ExitIntent: Equatable {
    case quit
    case closeWindow
    case eject
    case open(URL)

    var question: String {
        switch self {
        case .quit, .closeWindow: "Are you sure you want to exit the application?"
        case .eject, .open: "Are you sure you want to exit the game?"
        }
    }
}

enum ExitDecision {
    /// Nothing is running: the caller goes ahead at once.
    case proceed
    /// The sheet is now up; the caller waits for Yes or No.
    case prompted
    /// A sheet is ALREADY up. Nothing changed. For ⌘Q the caller must answer
    /// `.terminateCancel` — a `.terminateLater` here would never be replied to.
    case busy
}

/// Which leave-request the exit sheet is answering. A value type so the
/// one-sheet-at-a-time rule is reachable from a test without a window.
struct ExitGate {
    private(set) var pending: ExitIntent?

    mutating func request(_ intent: ExitIntent, playing: Bool) -> ExitDecision {
        guard playing else { return .proceed }
        guard pending == nil else { return .busy }
        pending = intent
        return .prompted
    }

    /// Yes: hands back what to finish.
    mutating func take() -> ExitIntent? {
        defer { pending = nil }
        return pending
    }

    /// No: hands back what was declined (a declined ⌘Q needs its reply).
    mutating func cancel() -> ExitIntent? {
        defer { pending = nil }
        return pending
    }
}

/// Finishes an exit exactly once. The save's completion and a fallback timer
/// both fire it, so a save the emulator thread never services — a wedged
/// frame — still lets the app quit.
@MainActor
final class ExitCompletion {
    private var body: (() -> Void)?

    init(_ body: @escaping () -> Void) { self.body = body }

    func fire() {
        let run = body
        body = nil
        run?()
    }
}
```



- [ ] **Step 4: Implement `ResumeOffer.swift`**

```swift
import Foundation

enum ResumeChoice {
    case resume, freshBoot, deleteAndBoot, cancel
}

/// What the launch sheet shows: there IS a state for the game being opened.
struct ResumeOffer: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let key: String
    /// The disc the player clicked; Fresh Boot and Delete & Boot boot it.
    let launching: GameEntry
    /// The disc that was in the tray when the state was saved, or nil when
    /// that disc is no longer in the library — Resume is then disabled rather
    /// than booting a disc the core would refuse.
    let resumeDisc: GameEntry?
    let info: ResumeStateStore.Info

    /// Nil when the game has no state. A state that cannot be decoded still
    /// produces an offer — so Delete & Boot is reachable — resuming on the
    /// launching disc, where the core's refusal then explains the damage.
    static func make(launching: GameEntry, siblings: [GameEntry],
                     store: ResumeStateStore) -> ResumeOffer? {
        let first = siblings.first ?? launching
        let key = ResumeStateStore.key(for: first)
        guard let info = store.info(key) else { return nil }

        // `peekStateSerial` THROWS for an unreadable header and returns nil
        // for a readable one whose disc names no serial — two different
        // answers, so they are not collapsed with `try?`.
        var resumeDisc: GameEntry? = launching
        if let state = store.load(key) {
            do {
                resumeDisc = disc(forSerial: try Ps1Core.peekStateSerial(state), in: siblings)
            } catch {
                resumeDisc = launching
            }
        }
        return ResumeOffer(title: DiscGrouping.baseTitle(first.title), key: key,
                           launching: launching, resumeDisc: resumeDisc, info: info)
    }

    static func disc(forSerial serial: String?, in siblings: [GameEntry]) -> GameEntry? {
        guard let serial else { return siblings.first }
        return siblings.first { $0.serial == serial }
    }

    static func == (a: ResumeOffer, b: ResumeOffer) -> Bool { a.id == b.id }
}
```

`DiscGrouping.baseTitle(_:)` is whatever `DiscGrouping` already names its disc-token-stripping function (it strips `(Disc N)` at `DiscGrouping.swift:40`); use that function, or `first.title` if it is private and not worth exposing.

- [ ] **Step 5: Add the save request to `EmulatorRunner`**

Beside `PendingSwap`:

```swift
struct ResumeSnapshot: Sendable {
    let state: Data
    let thumbnail: Data?
}
```

Beside `pendingSwap`:

```swift
    private var pendingSave: (@Sendable (Result<ResumeSnapshot, Error>) -> Void)?
```

Beside `requestDiscSwap`:

```swift
    /// Asks the emulator thread to snapshot the machine between frames. The
    /// completion runs ON THE EMULATOR THREAD; hop to the main actor yourself.
    func requestSaveState(_ completion: @escaping @Sendable (Result<ResumeSnapshot, Error>) -> Void) {
        pacing.lock()
        pendingSave = completion
        // The loop may be parked on the pause or the audio high-water mark.
        pacing.signal()
        pacing.unlock()
    }

    /// The state and its thumbnail, taken in one go so the picture is exactly
    /// the saved frame. Called from `runLoop` only — this thread owns the
    /// core — and `internal` so a test can drive it.
    func serviceSaveRequest() {
        pacing.lock()
        let completion = pendingSave
        pendingSave = nil
        pacing.unlock()
        guard let completion else { return }

        completion(Result {
            let state = try core.saveState()
            var vram = [UInt16](repeating: 0, count: 1024 * 512)
            vram.withUnsafeMutableBufferPointer { core.copyVRAM(into: $0.baseAddress!) }
            let display = core.display()
            let thumbnail = vram.withUnsafeBufferPointer { ResumeThumbnail.png(vram: $0, display: display) }
            return ResumeSnapshot(state: state, thumbnail: thumbnail)
        })
    }
```

In `runLoop`, directly under `serviceMemoryCards()`:

```swift
            // Also above the paused early-out: the exit sheet PAUSES the game,
            // and a save parked behind the pause would never run.
            serviceSaveRequest()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1 ps1-macos/Tests/PS1Tests
git commit -m "feat(macos): save requests on the emulator thread, exit gate and resume offer"
```

---

### Task 10: The sheets and their wiring

**Files:**
- Create: `ps1-macos/Sources/PS1/ConfirmExitSheet.swift`
- Create: `ps1-macos/Sources/PS1/ResumePromptSheet.swift`
- Create: `ps1-macos/Sources/PS1/CloseInterceptor.swift`
- Create: `ps1-macos/Sources/PS1App/AppDelegate.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift`
- Modify: `ps1-macos/Sources/PS1/ContentView.swift`
- Modify: `ps1-macos/Sources/PS1App/PS1App.swift`
- Test: `ps1-macos/Tests/PS1Tests/EmulatorViewModelStageTests.swift`

**Interfaces:**
- Consumes: everything in Tasks 7-9.
- Produces on `EmulatorViewModel`:
  - `var exitPrompt: ExitIntent?` (read-only outside; mirrors `exitGate.pending`)
  - `var resumeOffer: ResumeOffer?`
  - `var resumeFailure: ResumeFailure?` where `struct ResumeFailure: Identifiable { let id = UUID(); let message: String; let freshBoot: URL }`
  - `var saveStateOnExit: Bool { get set }`
  - `func requestExit(_ intent: ExitIntent) -> ExitDecision`
  - `func confirmExit()`, `func cancelExit()`
  - `func chooseResume(_ choice: ResumeChoice)`
  - `func launch(_ url: URL)`
  - `var terminateReply: ((Bool) -> Void)?` (set by the app delegate)

- [ ] **Step 1: Write the failing tests**

Append to `EmulatorViewModelStageTests.swift` (match that file's `@MainActor` usage):

```swift
@MainActor @Test func leavingTheLibraryNeedsNoPrompt() {
    let model = EmulatorViewModel()
    #expect(model.requestExit(.quit) == .proceed)
    #expect(model.exitPrompt == nil)
}

@MainActor @Test func theSaveOnExitCheckboxIsTheSetting() {
    let model = EmulatorViewModel()
    let was = model.saveStateOnExit
    defer { model.saveStateOnExit = was }
    model.saveStateOnExit = !was
    #expect(ResumeOnExitSetting().enabled == !was)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: FAIL to build — `requestExit` not found.

- [ ] **Step 3: View-model state and the exit flow**

In `EmulatorViewModel`, beside `cards`:

```swift
    /// One resume slot per game. Outlives every disc, like `cards`.
    let resumeStates = ResumeStateStore()
    private var resumeOnExit = ResumeOnExitSetting()
    private var exitGate = ExitGate()
    private var pausedBeforePrompt = false
    /// The key the running game saves under — its first disc's.
    private var resumeKey: String?

    private(set) var exitPrompt: ExitIntent?
    var resumeOffer: ResumeOffer?
    var resumeFailure: ResumeFailure?
    /// Set by the app delegate while ⌘Q waits on the sheet.
    var terminateReply: ((Bool) -> Void)?

    var saveStateOnExit: Bool {
        get { resumeOnExit.enabled }
        set { resumeOnExit.set(newValue) }
    }
```

Add (near `eject()`):

```swift
    /// Every way of leaving a running game comes through here. `.prompted`
    /// pauses the game and raises the sheet; the caller then waits.
    func requestExit(_ intent: ExitIntent) -> ExitDecision {
        let decision = exitGate.request(intent, playing: stage == .playing && runner != nil)
        if decision == .prompted {
            pausedBeforePrompt = isPaused
            isPaused = true
            exitPrompt = intent
        }
        return decision
    }

    func cancelExit() {
        let intent = exitGate.cancel()
        exitPrompt = nil
        isPaused = pausedBeforePrompt
        if intent == .quit { replyToTerminate(false) }
    }

    func confirmExit() {
        guard let intent = exitGate.take() else { return }
        exitPrompt = nil
        let finish = ExitCompletion { [weak self] in self?.finishExit(intent) }
        guard saveStateOnExit, let runner, let key = resumeKey else { return finish.fire() }

        let store = resumeStates
        runner.requestSaveState { result in
            Task { @MainActor in
                switch result {
                case .success(let snap):
                    do { try store.save(state: snap.state, thumbnail: snap.thumbnail, key: key) }
                    catch { NSLog("Substation: resume state failed to write: \(error)") }
                case .failure(let error):
                    NSLog("Substation: resume state failed to save: \(error)")
                }
                finish.fire()
            }
        }
        // A save the emulator thread never services must not hold the exit
        // hostage. Three seconds is a hundred-odd frames.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            finish.fire()
        }
    }

    private func finishExit(_ intent: ExitIntent) {
        switch intent {
        case .quit:
            replyToTerminate(true)
        case .closeWindow:
            exitConfirmed = true
            NSApp.terminate(nil)
        case .eject:
            ejectNow()
        case .open(let url):
            launch(url)
        }
    }

    private func replyToTerminate(_ yes: Bool) {
        if yes { exitConfirmed = true }
        terminateReply?(yes)
        terminateReply = nil
    }

    /// Set once an exit has been confirmed, so the `terminate` that follows
    /// is not asked again.
    private(set) var exitConfirmed = false
```

Change `eject()`:

```swift
    public func eject() {
        if requestExit(.eject) == .proceed { ejectNow() }
    }

    private func ejectNow() {
        teardownRunningMachine()
        currentDiscs = []
        currentDiscIndex = nil
        stage = .library
    }
```

Change `openDisc()`'s last line from `load(disc: url)` to:

```swift
        if requestExit(.open(url)) == .proceed { launch(url) }
```

Change `play(_:)`:

```swift
    func play(_ entry: GameEntry) {
        launch(entry.url)
    }
```

- [ ] **Step 4: Launch, resume and the failure alert**

Add:

```swift
    struct ResumeFailure: Identifiable {
        let id = UUID()
        let message: String
        let freshBoot: URL
    }

    /// Opens a game, offering its resume state first when it has one.
    func launch(_ url: URL) {
        let siblings = Self.siblingDiscs(of: url, entries: library.entries)
        let launching = siblings.first { Self.canonicalPath($0.url) == Self.canonicalPath(url) }
            ?? GameEntry(url: url, isCue: url.pathExtension.lowercased() == "cue")
        if let offer = ResumeOffer.make(launching: launching, siblings: siblings, store: resumeStates) {
            resumeOffer = offer
        } else {
            load(disc: url)
        }
    }

    func chooseResume(_ choice: ResumeChoice) {
        guard let offer = resumeOffer else { return }
        resumeOffer = nil
        switch choice {
        case .resume:
            guard let disc = offer.resumeDisc else { return }
            guard let state = resumeStates.load(offer.key) else {
                resumeFailure = ResumeFailure(message: Self.resumeMessage(Ps1Error.stateCorrupt),
                                              freshBoot: offer.launching.url)
                return
            }
            load(disc: disc.url, resume: state, freshBoot: offer.launching.url)
        case .freshBoot:
            load(disc: offer.launching.url)
        case .deleteAndBoot:
            resumeStates.remove(offer.key)
            load(disc: offer.launching.url)
        case .cancel:
            break
        }
    }

    private static func resumeMessage(_ error: Error) -> String {
        switch error as? Ps1Error {
        case .stateVersion: "This state was saved by a newer version of Substation."
        case .stateBIOS: "This state was saved with a different BIOS."
        case .stateDisc: "This state belongs to a different disc."
        default: "The saved state is damaged."
        }
    }
```

Change `load(disc:)`'s signature to `func load(disc url: URL, resume: Data? = nil, freshBoot: URL? = nil)`. Directly after `try core.loadDisc(...)` (still BEFORE the teardown, so a refusal leaves the running game alone):

```swift
            if let resume {
                do {
                    try core.loadState(resume)
                } catch {
                    resumeFailure = ResumeFailure(message: Self.resumeMessage(error),
                                                  freshBoot: freshBoot ?? url)
                    return
                }
            }
```

Directly after `currentDiscIndex = …` in the success path, record the save key:

```swift
            resumeKey = ResumeStateStore.key(for: currentDiscs.first
                ?? GameEntry(url: url, isCue: isCue))
```

and in `teardownRunningMachine()` add `resumeKey = nil`.

No explicit `requestResync` is needed after a resume: the new runner gets a new `MetalDisplayView`, whose `claimConsumer()` raises the resync that adopts core VRAM — which by then is the restored VRAM. Say so in a one-line comment beside the `loadState` call.

- [ ] **Step 5: The two sheets**

`ConfirmExitSheet.swift`:

```swift
import SwiftUI

struct ConfirmExitSheet: View {
    let intent: ExitIntent
    @Binding var saveState: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm Exit").font(.headline)
            Text(intent.question)
            Toggle("Save State For Resume", isOn: $saveState)
                .toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Button(action: cancel) { Text("No").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button(action: confirm) { Text("Yes").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 320)
    }
}
```

`ResumePromptSheet.swift`:

```swift
import SwiftUI

struct ResumePromptSheet: View {
    let offer: ResumeOffer
    let choose: (ResumeChoice) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Resume \(offer.title)?").font(.headline)
            thumbnail
                .frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Saved \(offer.info.savedAt.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
            if offer.resumeDisc == nil {
                Text("The disc this state was saved on is no longer in the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Cancel") { choose(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete & Boot", role: .destructive) { choose(.deleteAndBoot) }
                Button("Fresh Boot") { choose(.freshBoot) }
                Button("Resume") { choose(.resume) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(offer.resumeDisc == nil)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = offer.info.thumbnail, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Rectangle().fill(.black)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
```

In `ContentView.body`, after the last `.alert(...)`:

```swift
        .sheet(isPresented: .init(
            get: { model.exitPrompt != nil },
            set: { if !$0 && model.exitPrompt != nil { model.cancelExit() } }
        )) {
            if let intent = model.exitPrompt {
                ConfirmExitSheet(intent: intent,
                                 saveState: $model.saveStateOnExit,
                                 cancel: { model.cancelExit() },
                                 confirm: { model.confirmExit() })
            }
        }
        .sheet(item: $model.resumeOffer) { offer in
            ResumePromptSheet(offer: offer) { model.chooseResume($0) }
        }
        .alert("Could not resume", isPresented: .init(
            get: { model.resumeFailure != nil },
            set: { if !$0 { model.resumeFailure = nil } }
        )) {
            Button("Fresh Boot") {
                if let url = model.resumeFailure?.freshBoot { model.load(disc: url) }
                model.resumeFailure = nil
            }
            Button("Cancel", role: .cancel) { model.resumeFailure = nil }
        } message: {
            Text(model.resumeFailure?.message ?? "")
        }
```

Add `.background(CloseInterceptor(shouldClose: { model.requestExit(.closeWindow) == .proceed }))` beside the existing `.background(WindowConfigurator(...))`.

- [ ] **Step 6: ⌘Q and the close button**

`CloseInterceptor.swift`:

```swift
import AppKit
import SwiftUI

/// Routes the window's close button and ⌘W through the exit sheet.
///
/// SwiftUI owns the window's delegate and offers no `windowShouldClose`, so
/// this installs a proxy that answers that one question and forwards every
/// other delegate message to SwiftUI's own delegate untouched. The proxy is
/// re-installed whenever SwiftUI puts its delegate back.
struct CloseInterceptor: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> Proxy { Proxy() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== context.coordinator else { return }
            context.coordinator.original = window.delegate
            window.delegate = context.coordinator
        }
    }

    final class Proxy: NSObject, NSWindowDelegate {
        /// Strong: `NSWindow.delegate` is weak, and this is now the only
        /// reference the window path holds to SwiftUI's delegate.
        var original: NSWindowDelegate?
        var shouldClose: () -> Bool = { true }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : nil
        }
    }
}
```

`ps1-macos/Sources/PS1App/AppDelegate.swift`:

```swift
import AppKit
import PS1

/// ⌘Q while a game runs asks first. `.terminateLater` holds the quit open
/// until the exit sheet answers through `terminateReply`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EmulatorViewModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.exitConfirmed else { return .terminateNow }
        switch model.requestExit(.quit) {
        case .proceed:
            return .terminateNow
        case .busy:
            return .terminateCancel
        case .prompted:
            model.terminateReply = { NSApp.reply(toApplicationShouldTerminate: $0) }
            return .terminateLater
        }
    }
}
```

`requestExit`, `exitConfirmed`, `terminateReply`, `ExitDecision` are used from `Sources/PS1App` — the same module (see the `ps1-macos-app` skill: `Sources/PS1App` is NOT a separate module), so no `public` is required; follow the file's existing convention.

In `PS1App.swift`:

```swift
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

and give the delegate the model in `body`'s `Window` content: `ContentView(model: model).onAppear { appDelegate.model = model }`.

- [ ] **Step 7: Run the tests**

Run: `zig build capi-lib metallib && pkill -x Substation; ps1-macos/test.sh`
Expected: PASS.

- [ ] **Step 8: Verify by hand**

Run: `zig build macos && open zig-out/Substation.app`

1. Library → ⌘Q quits at once, with no sheet.
2. Open Crash Bandicoot, play into a level, ⌘Q → "Confirm Exit", "…exit the application?", box ticked. **No** → the game resumes where it was (paused if it was paused before).
3. ⌘Q → **Yes** → the app quits within ~1 s. `~/Library/Application Support/Substation/ResumeStates/` holds `<serial>.state` and `<serial>.png`.
4. Relaunch, click Crash → the resume sheet shows that frame. **Resume** → the level continues from that spot, with audio and correct textures.
5. Eject → "…exit the game?" sheet. Untick the box, **Yes** → library. Relaunch the app: the box is still unticked on the next exit sheet.
6. Click Crash → **Delete & Boot** → BIOS boot; the two files are gone.
7. FF7: play disc 2 → close the window with the red button → sheet → **Yes** → app quits. Relaunch, click FF7 → the sheet offers the disc-2 frame → **Resume** lands on disc 2.
8. While the Eject sheet is up, press ⌘Q → nothing happens (no second sheet, the app stays).
9. Corrupt a state (`printf 'x' | dd of=<serial>.state bs=1 seek=10 conv=notrunc`) → click the game → sheet appears → **Resume** → "Could not resume / The saved state is damaged." → **Fresh Boot** boots.

Write down any step that fails, with what you saw, before fixing it.

- [ ] **Step 9: Commit**

```bash
git add ps1-macos/Sources ps1-macos/Tests
git commit -m "feat(macos): confirm-exit and resume sheets"
```

---

### Task 11: Documentation

**Files:**
- Modify: `CLAUDE.md` (Quick commands table; Rules)
- Modify: `.claude/skills/ps1-core-subsystems/SKILL.md`
- Modify: `.claude/skills/ps1-macos-app/SKILL.md`
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md`

- [ ] **Step 1: `CLAUDE.md`**

In the Quick commands table, add a row after `trace-golden -- pgxp`:

| `zig build trace-golden -- savestate` | `verify`, but every workload saves at its midpoint and finishes on a machine restored into a fresh `Bus`. The gate that a savestate captures the whole machine — a missed field fails here. Run it `-Doptimize=ReleaseFast`. |

Update the `zig build test` row's count from 17 to 18 test binaries' worth of description only if the count actually changed (the savestate unit file joins `unit_test_files`, so the count of that list becomes 13 — update "the 11 `unit_test_files`" accordingly after checking the real number).

Add a new rules block under "Rules that must not be broken":

```markdown
**Savestates** (`ps1-core-subsystems`)

- **A new device field is a FORMAT change.** Add it to its section in
  `ps1-core/src/savestate/`, bump that section's version in
  `savestate.zig`'s `sections`, and teach its `load` to read the old version
  with the field's power-on value. Skipping the bump breaks every existing
  player's resume state; skipping the field fails `trace-golden -- savestate`.
- **Sections are hand-written, never reflected**, for `state_hash.zig`'s reason.
- **The cards, the BIOS bytes, the disc bytes and every PGXP cache stay out of a
  state.** The cards are shared across games; restoring them rolls back other
  games' saves.
- **A load is all-or-nothing**: `ps1_load_state` decodes into a scratch `Bus`.
```

Add `ps1-core/src/savestate/` to the repository layout block, after `pgxp.zig` or near `memory.zig`, with: `savestate/        versioned machine state: stream.zig, savestate.zig (container), one *_state.zig per device group`.

- [ ] **Step 2: Skills**

- `ps1-core-subsystems`: a "Savestates" section — the wire format table from Task 4, the section list, the version-bump procedure with a worked example (adding a `u32` to `Timer`: bump `TMR ` to 2, `if (version >= 2) t.new = try r.int(u32) else t.new = 0`), the deferred-tick decision (deviation 1), and the "not in a state" list.
- `ps1-macos-app`: a "Resume states" section — store layout and key, LZFSE, atomic writes, the exit gate (`.busy` → `.terminateCancel`), the 3 s fallback, the `CloseInterceptor` proxy and why it holds SwiftUI's delegate strongly, the cards-read-as-fresh rule (deviation 5), and that no explicit resync is needed.
- `ps1-test-harnesses`: the `savestate` mode, what it proves (mid-game in-flight state) and what it does not (a field still at its power-on value at every workload's midpoint), and the committed `v1-synthetic.state` fixture: it must never be regenerated — a new format version adds a NEW fixture beside it.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md .claude/skills
git commit -m "docs: savestate rules and resume-state notes"
```
