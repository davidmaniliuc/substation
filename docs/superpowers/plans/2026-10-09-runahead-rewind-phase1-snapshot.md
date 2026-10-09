# Runahead + Rewind, Phase 1: The Trusted Snapshot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fast, in-place snapshot of the running machine (`saveTrusted`/`loadTrusted`, a `Mark` that also carries the memory cards, and `ps1_snapshot_mark`/`ps1_snapshot_return` in the C ABI), with the JIT keeping its blocks across a load and a trace-golden mode that proves a mark/return round trip changes nothing.

**Architecture:** The trusted path reuses the existing hand-written savestate sections and drops only the CRC and the identity. A load writes into the running `Bus`, so the JIT cache, the raster worker and the PGXP shadows survive; the `BUS ` loader now drops exactly the JIT blocks on code pages whose RAM the state changes, instead of flushing the whole cache. A `Mark` adds the two card images and their dirty flags, which no state carries.

**Tech Stack:** Zig 0.17.0, `ps1-core` (savestate, recompiler, gpu), `ps1-capi`, `ps1-golden`, `ps1-bench`, `ps1-wasm` codes, `ps1-web` (TypeScript, Bun).

**Spec:** `docs/superpowers/specs/2026-10-09-runahead-rewind-design.md` (Phase 1 section). Phases 2 (rewind) and 3 (runahead in the app) get their own plans once this one has landed and its numbers are measured.

**One deliberate deviation from the spec:** the spec caches the BIOS identity on `Bus`. This plan writes NO identity at all into a trusted snapshot (both fields zero), because `loadTrusted` never checks it. That removes the ~250 us SHA-256 just the same, and there is no cache to invalidate on a BIOS install, a disc set or a disc swap. Task 6 updates the spec to say so.

## Global Constraints

- `zig version` is 0.17.0. Run `zig fmt` on every touched `.zig` file before committing.
- Commit directly on `master`, one commit per task. Commit messages are a SINGLE title line: no body, no trailer, no Co-Authored-By. Never `git push`.
- Never name DuckStation (or any reference emulator) in code comments or commit messages.
- Match the surrounding style: inline field defaults, hand-written savestate sections (never reflection), module-private `const` blocks, comments that state the rule and its reason.
- No savestate FORMAT change: no section gains or loses a field, so no section version bumps and no golden recapture. A trusted snapshot has the same layout as a file.
- `trace-golden` runs `-Doptimize=ReleaseFast`.
- `zig build test` is slow; run it once per task at the end, and use `-Dtest-filter="<substring>"` while iterating.
- Every new C ABI error code takes the next free value and is mirrored in `ps1-wasm/src/codes.zig` and `ps1-web/src/errors.ts`.

## Review Focus

1. **A mark outliving its machine.** Mark, then `ps1_reset` / `ps1_load_state` / `ps1_load_disc` / `ps1_swap_disc` / `ps1_load_bios`, then `ps1_snapshot_return`: it must refuse with `PS1_ERR_NO_SNAPSHOT`, never restore a different machine or the old disc's drive state. Pinned in Task 5.
2. **The raster worker across an in-place load.** The app always rasterizes on a worker. The worker keeps its own copy of the drawing environment, which an in-place load replaces under it; a stale copy draws wrong pixels with no error. Pinned in Task 1 (unit) and Task 4 (`--threaded=deferred`).
3. **A memory-card write during speculation.** Rolled back, dirty flag included, or a speculative save reaches the player's card file a frame early. Pinned in Tasks 3 and 5.
4. **Audio produced between mark and return.** It must be gone after the return; samples a host drained before the mark must not come back. Pinned in Task 5.
5. **The JIT linking across a load.** A load moves the PC; a pending link site from before it must not link a block's exit to the wrong place. Pinned in Task 2, and by the `--engine=jit` run in Task 4.

---

### Task 1: `saveTrusted` / `loadTrusted`

**Files:**
- Modify: `ps1-core/src/savestate/savestate.zig` (save, peek, load: lines ~77-153)
- Modify: `ps1-core/src/gpu/gpu.zig` (next to `syncRaster`, ~line 125)
- Test: `ps1-core/tests/savestate_test.zig` (append)

**Interfaces:**
- Produces:
  - `pub fn saveTrusted(cpu: *const Cpu, dst: ?[]u8) Error!usize` in `savestate.zig`. Same layout as `save`; CRC field 0; identity fields all zero; drains the raster worker first. With `dst == null` returns the size.
  - `pub fn loadTrusted(cpu: *Cpu, src: []const u8) Error!void` in `savestate.zig`. Checks magic, container version and body length; skips CRC and identity; keeps every section check; drains the worker before and reseats it after.
  - `pub fn reseatRasterWorker(self: *Gpu) void` in `gpu.zig`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/savestate_test.zig`:

```zig
fn saveTrustedAlloc(m: *Machine) ![]u8 {
    const n = try savestate.saveTrusted(&m.cpu, null);
    const buf = try std.testing.allocator.alloc(u8, n);
    errdefer std.testing.allocator.free(buf);
    try std.testing.expectEqual(n, try savestate.saveTrusted(&m.cpu, buf));
    return buf;
}

test "a trusted snapshot round-trips in place with no checksum and no identity" {
    var m = try Machine.init();
    defer m.deinit();
    @memset(&m.bus.bios, 0x5A);
    m.bus.ram[42] = 42;
    m.cpu.regs[3] = 3;
    m.bus.gpu.vram.data[7] = 7;

    const buf = try saveTrustedAlloc(&m);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualSlices(u8, "SBST", buf[0..4]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[8..12], .little));
    try std.testing.expect(std.mem.allEqual(u8, buf[16..savestate.header_len], 0));

    m.bus.ram[42] = 0;
    m.cpu.regs[3] = 0;
    m.bus.gpu.vram.data[7] = 0;
    const bus_before = m.bus;
    try savestate.loadTrusted(&m.cpu, buf);
    try std.testing.expect(m.cpu.bus == bus_before);
    try std.testing.expectEqual(@as(u8, 42), m.bus.ram[42]);
    try std.testing.expectEqual(@as(u32, 3), m.cpu.regs[3]);
    try std.testing.expectEqual(@as(u16, 7), m.bus.gpu.vram.data[7]);

    // It cannot pass for a file: the zero checksum fails `load`.
    try std.testing.expectError(error.StateCorrupt, savestate.load(&m.cpu, buf));
}

test "a trusted load still refuses a damaged container or section" {
    var m = try Machine.init();
    defer m.deinit();
    const buf = try saveTrustedAlloc(&m);
    defer std.testing.allocator.free(buf);
    const copy = try std.testing.allocator.dupe(u8, buf);
    defer std.testing.allocator.free(copy);

    copy[0] = 'X';
    try std.testing.expectError(error.StateBadMagic, savestate.loadTrusted(&m.cpu, copy));

    @memcpy(copy, buf);
    copy[savestate.header_len] = '?'; // the first section's tag
    try std.testing.expectError(error.StateVersion, savestate.loadTrusted(&m.cpu, copy));

    try std.testing.expectError(error.StateCorrupt, savestate.loadTrusted(&m.cpu, buf[0 .. buf.len - 1]));
}

test "a trusted load reseats the raster worker's drawing environment" {
    if (!ps1.gpu.raster_worker_available) return error.SkipZigTest;
    var m = try Machine.init();
    defer m.deinit();
    try m.bus.gpu.attachRasterWorker(std.testing.allocator, std.testing.io, .deferred);

    m.bus.gpu.draw_env.offset = 1;
    m.bus.gpu.sink.worker.?.env.offset = 1;
    const buf = try saveTrustedAlloc(&m);
    defer std.testing.allocator.free(buf);

    m.bus.gpu.draw_env.offset = 2;
    m.bus.gpu.sink.worker.?.env.offset = 2;
    try savestate.loadTrusted(&m.cpu, buf);
    try std.testing.expectEqual(@as(u32, 1), m.bus.gpu.draw_env.offset);
    try std.testing.expect(std.meta.eql(m.bus.gpu.draw_env, m.bus.gpu.sink.worker.?.env));
}
```

If `draw_env.offset` is not a `u32`, use its declared type in the `expectEqual`; check `ps1-core/src/gpu/` for `DrawingEnv`.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="trusted"`
Expected: compile error, `saveTrusted` / `loadTrusted` not declared in `savestate`.

- [ ] **Step 3: Add `reseatRasterWorker` to `gpu.zig`**

Directly after `syncRaster`:

```zig
    /// After a state is loaded IN PLACE (`savestate.loadTrusted`). The worker
    /// keeps its own copy of the drawing environment, applying the same env
    /// records the emulator does; a load replaces `draw_env` without any, so
    /// the copy is put back in step here. VRAM needs nothing: the worker
    /// draws into `vram` itself, and it was drained before the load.
    pub fn reseatRasterWorker(self: *Self) void {
        const w = self.sink.worker orelse return;
        w.sync();
        w.env = self.draw_env;
    }
```

- [ ] **Step 4: Split `savestate.zig`'s save, header check and section reader**

Replace `save`, `peek` and `load` (keep `identityOf`, `sections`, `indexOfTag`, `sectionVersion` as they are) with:

```zig
/// With `dst == null`, returns the exact size without writing anything.
pub fn save(cpu: *const Cpu, dst: ?[]u8) Error!usize {
    return write(cpu, dst, identityOf(cpu.bus), true);
}

/// `save` for bytes that never leave this process: a runahead mark or a
/// rewind snapshot, restored a few frames later by `loadTrusted`. It skips
/// the two costs only a file needs, the checksum and the identity (the BIOS
/// hash alone is ~250 us), and writes both as zero. It drains the raster
/// worker itself, because the GPU section reads VRAM.
pub fn saveTrusted(cpu: *const Cpu, dst: ?[]u8) Error!usize {
    cpu.bus.gpu.syncRaster();
    return write(cpu, dst, .{ .bios_sha256 = @splat(0), .serial = @splat(0) }, false);
}

fn write(cpu: *const Cpu, dst: ?[]u8, id: Identity, checksum: bool) Error!usize {
    // Every device must hold what a per-step tick would have left it; the
    // scheduler's backlog is not part of a state.
    scheduler.sync(cpu.bus);
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
        if (checksum) w.patchU32(8, crc32.hash(buf[header_len..w.len]));
    }
    return w.len;
}

const Header = struct { crc: u32, id: Identity };

/// Everything a header promises except the checksum: magic, container
/// version and body length.
fn header(src: []const u8) Error!Header {
    if (src.len < header_len or !std.mem.eql(u8, src[0..4], magic)) return error.StateBadMagic;
    var r = Reader{ .buf = src[4..header_len] };
    if (try r.int(u32) != format_version) return error.StateVersion;
    const crc = try r.int(u32);
    const body_len = try r.int(u32);
    if (body_len != src.len - header_len) return error.StateCorrupt;
    var h = Header{ .crc = crc, .id = undefined };
    @memcpy(&h.id.bios_sha256, try r.bytes(32));
    @memcpy(&h.id.serial, try r.bytes(16));
    return h;
}

/// Validates the header and the checksum and returns what the state must be
/// resumed against. Needs no machine — the app reads it for its launch prompt.
pub fn peek(src: []const u8) Error!Identity {
    const h = try header(src);
    if (crc32.hash(src[header_len..]) != h.crc) return error.StateCorrupt;
    return h.id;
}

pub fn load(cpu: *Cpu, src: []const u8) Error!void {
    const id = try peek(src);
    const want = identityOf(cpu.bus);
    if (!std.mem.eql(u8, &id.bios_sha256, &want.bios_sha256)) return error.StateBios;
    if (!std.mem.eql(u8, &id.serial, &want.serial)) return error.StateDisc;
    try readSections(cpu, src[header_len..]);
}

/// `load` for `saveTrusted`'s bytes, into the RUNNING machine: no scratch
/// `Bus`, so the block cache, the raster worker and every PGXP shadow
/// survive. A shadow left over from frames the load undid is judged by the
/// word it was recorded against, like any other.
///
/// Only for bytes this process produced moments ago. It skips the checksum
/// and the identity, and a refusal part-way leaves the machine half-written;
/// a file goes through `load` into a scratch `Bus`, always.
pub fn loadTrusted(cpu: *Cpu, src: []const u8) Error!void {
    _ = try header(src);
    cpu.bus.gpu.syncRaster();
    try readSections(cpu, src[header_len..]);
    cpu.bus.gpu.reseatRasterWorker();
}

fn readSections(cpu: *Cpu, body: []const u8) Error!void {
    // Every section below writes the machine directly, RAM included, behind
    // the bus's invalidation hook. The CPU section restores the state's
    // I-cache lines, which a block engine never snoops: the dispatcher
    // invalidates them before its next block.
    if (cpu.bus.blocks) |c| {
        c.flush();
        c.icache_dirty = true;
    }

    var r = Reader{ .buf = body };
    var seen: [sections.len]bool = @splat(false);
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
```

The flush stays for now; Task 2 replaces it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="trusted"`
Expected: PASS (3 tests; the worker one skips only where `raster_worker_available` is false).

Then the whole savestate file: `zig build test -Dtest-filter="state"`
Expected: PASS, including the existing "hostile states", "round-trips and peeks" and checksum tests.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/savestate/savestate.zig ps1-core/src/gpu/gpu.zig ps1-core/tests/savestate_test.zig
git add ps1-core/src/savestate/savestate.zig ps1-core/src/gpu/gpu.zig ps1-core/tests/savestate_test.zig
git commit -m "feat(savestate): trusted in-place snapshot with no checksum or identity"
```

---

### Task 2: A load drops only the changed code pages

**Files:**
- Modify: `ps1-core/src/recompiler/cache.zig` (new pub fn beside `invalidatePage`, ~line 151)
- Modify: `ps1-core/src/savestate/io_state.zig:30-42` (`loadBus`)
- Modify: `ps1-core/src/savestate/savestate.zig` (`readSections`' opening block, from Task 1)
- Test: `ps1-core/tests/recompiler_test.zig` (after "BIOS blocks survive RAM writes; flush frees everything", ~line 245)

**Interfaces:**
- Consumes: `savestate.saveTrusted`, `savestate.loadTrusted` (Task 1); `savestate.save`, `savestate.load`.
- Produces: `pub fn invalidateChanged(self: *BlockCache, old: []const u8, new: []const u8) void` in `cache.zig`. Neither `load` nor `loadTrusted` calls `BlockCache.flush()` any more.

- [ ] **Step 1: Write the failing test**

Add `const savestate = ps1_core.savestate;` beside the other imports at the top of `ps1-core/tests/recompiler_test.zig`, then after the "flush frees everything" test:

```zig
test "a state load drops the blocks of the code pages it changes, and only those" {
    for ([_]bool{ false, true }) |trusted| {
        const bus = try busWithCache();
        defer bus.deinit(alloc);
        var cpu = Cpu.init(bus);
        std.mem.writeInt(u32, bus.bios[0..4], mips.jr(ra), .little);
        poke(bus, 0x1000, &.{ mips.jr(ra), mips.nop });
        poke(bus, 0x9000, &.{ mips.jr(ra), mips.nop });
        const n = try savestate.saveTrusted(&cpu, null);
        const state = try alloc.alloc(u8, n);
        defer alloc.free(state);
        _ = if (trusted) try savestate.saveTrusted(&cpu, state) else try savestate.save(&cpu, state);

        // The game moves on: page 1 is rewritten, then every block compiles.
        poke(bus, 0x1000, &.{ mips.nop, mips.jr(ra), mips.nop });
        _ = try compileInto(bus, 0x1000);
        _ = try compileInto(bus, 0x9000);
        _ = try compileInto(bus, 0xBFC0_0000);
        var word: u32 = 0;
        bus.blocks.?.pins.link_site = @ptrCast(&word);

        if (trusted) try savestate.loadTrusted(&cpu, state) else try savestate.load(&cpu, state);
        try expectEqual(@as(?*block.Block, null), bus.blocks.?.lookup(0x1000)); // its page changed
        try expect(bus.blocks.?.lookup(0x9000) != null); // its page did not
        try expect(bus.blocks.?.lookup(0x1FC0_0000) != null); // the BIOS never changes
        try expect(bus.blocks.?.icache_dirty);
        // The load moved the PC: a link from the block that ran before it
        // would patch an exit to the wrong place.
        try expectEqual(@as(?[*]u32, null), bus.blocks.?.pins.link_site);
        bus.blocks.?.reap();
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="code pages it changes"`
Expected: FAIL at `lookup(0x9000) != null`: the load still flushes everything.

- [ ] **Step 3: Add `invalidateChanged` to `BlockCache`**

In `cache.zig`, directly after `invalidatePage`:

```zig
    /// A state load is about to write `new` over RAM (`old`). Drops the
    /// blocks of every code page whose bytes change and nothing else: a
    /// whole-cache flush here cost ~370 us of recompiling per load, and
    /// runahead loads every frame. Only pages holding code are compared.
    pub fn invalidateChanged(self: *BlockCache, old: []const u8, new: []const u8) void {
        std.debug.assert(old.len == new.len and old.len == ram_pages << block.page_shift);
        const page_bytes = @as(usize, 1) << block.page_shift;
        for (0..ram_pages) |p| {
            const page: u16 = @intCast(p);
            if (!self.hasBit(page)) continue;
            const at = p * page_bytes;
            if (!std.mem.eql(u8, old[at..][0..page_bytes], new[at..][0..page_bytes])) _ = self.invalidatePage(page);
        }
    }
```

- [ ] **Step 4: Use it in `loadBus`**

In `ps1-core/src/savestate/io_state.zig`, replace `try r.array(&bus.ram);` in `loadBus` with:

```zig
    const ram = try r.bytes(bus.ram.len);
    if (bus.blocks) |c| c.invalidateChanged(&bus.ram, ram);
    @memcpy(&bus.ram, ram);
```

- [ ] **Step 5: Stop flushing in `readSections`**

In `savestate.zig`, replace the opening block of `readSections` (the comment and the `if (cpu.bus.blocks) |c| { c.flush(); ... }`) with:

```zig
    // Every section below writes the machine directly, behind the bus's
    // invalidation hook, so the blocks are reconciled here instead: the BUS
    // section drops exactly the code pages whose RAM the state changes, and
    // the BIOS never changes. The CPU section restores the state's I-cache
    // lines, which a block engine never snoops, so the dispatcher flushes
    // them before its next block. The load moves the PC, so a link pending
    // from the block that ran before it is forgotten.
    if (cpu.bus.blocks) |c| {
        c.icache_dirty = true;
        c.pins.link_site = null;
        c.pins.running = null;
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="code pages it changes"`
Expected: PASS.

Then the engines and states together: `zig build test -Dtest-filter="state"` and `zig build test -Dtest-filter="block"`
Expected: PASS.

- [ ] **Step 7: Run the savestate gate on both block engines**

The existing gate restores into a FRESH `Bus` whose cache is empty, so it proves `load` still works without the flush:

Run: `zig build trace-golden -Doptimize=ReleaseFast -- savestate --engine=cached` and the same with `--engine=jit`
Expected: every workload `OK`. A workload with no golden exits non-zero by design (CLAUDE.md, "verify exits non-zero for a disc with no golden"); that is not a regression.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-core/src/recompiler/cache.zig ps1-core/src/savestate/io_state.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/recompiler_test.zig
git add ps1-core/src/recompiler/cache.zig ps1-core/src/savestate/io_state.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/recompiler_test.zig
git commit -m "perf(savestate): a load drops only the code pages it changes, not the whole block cache"
```

---

### Task 3: `savestate.Mark`

**Files:**
- Create: `ps1-core/src/savestate/mark.zig`
- Modify: `ps1-core/src/savestate/savestate.zig` (one re-export beside `stream`/`crc32`)
- Test: `ps1-core/tests/savestate_test.zig` (append)

**Interfaces:**
- Consumes: `savestate.saveTrusted`, `savestate.loadTrusted` (Task 1).
- Produces, as `ps1_core.savestate.Mark`:
  - `pub fn init(allocator: std.mem.Allocator) Mark`
  - `pub fn deinit(m: *Mark) void`
  - `pub fn take(m: *Mark, cpu: *const Cpu) error{OutOfMemory}!void`
  - `pub fn restore(m: *const Mark, cpu: *Cpu) RestoreError!void` where `pub const RestoreError = savestate.Error || error{NoMark}`
  - `pub fn forget(m: *Mark) void`
  - field `held: bool`

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/savestate_test.zig`:

```zig
test "a mark returns the machine and both cards, dirty flags included" {
    var m = try Machine.init();
    defer m.deinit();
    var mark = savestate.Mark.init(std.testing.allocator);
    defer mark.deinit();

    m.bus.ram[100] = 1;
    m.bus.sio.memcard_data[0][5] = 0xAA;
    m.bus.sio.memcard_data[1][6] = 0xBB;
    try mark.take(&m.cpu);

    // A speculative frame writes RAM and saves to both cards.
    m.bus.ram[100] = 2;
    m.bus.sio.memcard_data[0][5] = 0x11;
    m.bus.sio.memcard_data[1][6] = 0x22;
    m.bus.sio.memcard_dirty = .{ true, true };

    try mark.restore(&m.cpu);
    try std.testing.expectEqual(@as(u8, 1), m.bus.ram[100]);
    try std.testing.expectEqual(@as(u8, 0xAA), m.bus.sio.memcard_data[0][5]);
    try std.testing.expectEqual(@as(u8, 0xBB), m.bus.sio.memcard_data[1][6]);
    try std.testing.expectEqual([2]bool{ false, false }, m.bus.sio.memcard_dirty);

    // The mark stays held: a second return is the same machine again.
    m.bus.ram[100] = 3;
    try mark.restore(&m.cpu);
    try std.testing.expectEqual(@as(u8, 1), m.bus.ram[100]);
}

test "returning to no mark, or a forgotten one, is NoMark and changes nothing" {
    var m = try Machine.init();
    defer m.deinit();
    var mark = savestate.Mark.init(std.testing.allocator);
    defer mark.deinit();

    m.bus.ram[7] = 7;
    try std.testing.expectError(error.NoMark, mark.restore(&m.cpu));
    try mark.take(&m.cpu);
    mark.forget();
    m.bus.ram[7] = 8;
    try std.testing.expectError(error.NoMark, mark.restore(&m.cpu));
    try std.testing.expectEqual(@as(u8, 8), m.bus.ram[7]);
}

test "a second take reuses the mark's buffer" {
    var m = try Machine.init();
    defer m.deinit();
    var mark = savestate.Mark.init(std.testing.allocator);
    defer mark.deinit();
    try mark.take(&m.cpu);
    const first = mark.buf.ptr;
    try mark.take(&m.cpu);
    try std.testing.expectEqual(first, mark.buf.ptr);
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="mark"`
Expected: compile error, `Mark` not declared in `savestate`.

- [ ] **Step 3: Write `mark.zig`**

```zig
//! Runahead's mark: one trusted snapshot of the running machine, plus the
//! two memory-card images and their dirty flags, which no state carries.
//!
//! Cards stay out of a state because they are shared across games: a state
//! that restored them would roll back other games' saves. A mark is the
//! opposite case. The machine returns to it within a few frames, and a save
//! made by a speculative frame must not reach the card, or the host's file,
//! ahead of the real one.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Sio = @import("../sio/sio.zig").Sio;
const savestate = @import("savestate.zig");

pub const RestoreError = savestate.Error || error{NoMark};

pub const Mark = struct {
    allocator: std.mem.Allocator,
    /// Sized by the first `take` and reused: a build's state size is fixed.
    buf: []u8 = &.{},
    len: usize = 0,
    held: bool = false,
    cards: [Sio.memcard_slots][Sio.memcard_bytes]u8 = undefined,
    dirty: [Sio.memcard_slots]bool = undefined,

    pub fn init(allocator: std.mem.Allocator) Mark {
        return .{ .allocator = allocator };
    }

    pub fn deinit(m: *Mark) void {
        m.allocator.free(m.buf);
        m.* = undefined;
    }

    pub fn take(m: *Mark, cpu: *const Cpu) error{OutOfMemory}!void {
        // Counting never fails, and the buffer is sized from that count.
        const n = savestate.saveTrusted(cpu, null) catch unreachable;
        if (m.buf.len < n) {
            m.allocator.free(m.buf);
            m.buf = &.{};
            m.buf = try m.allocator.alloc(u8, n);
        }
        m.len = savestate.saveTrusted(cpu, m.buf) catch unreachable;
        m.cards = cpu.bus.sio.memcard_data;
        m.dirty = cpu.bus.sio.memcard_dirty;
        m.held = true;
    }

    /// Returns the machine to the mark, which stays held.
    pub fn restore(m: *const Mark, cpu: *Cpu) RestoreError!void {
        if (!m.held) return error.NoMark;
        try savestate.loadTrusted(cpu, m.buf[0..m.len]);
        cpu.bus.sio.memcard_data = m.cards;
        cpu.bus.sio.memcard_dirty = m.dirty;
    }

    /// The machine the mark was taken from is gone (a reset, a load, a disc
    /// change): returning to it now would restore a different machine.
    pub fn forget(m: *Mark) void {
        m.held = false;
    }
};
```

If `memcard_slots` / `memcard_bytes` are not `pub` on `Sio`, they are: `ps1-capi` already uses `Sio.memcard_slots` and `Sio.memcard_bytes`.

- [ ] **Step 4: Re-export it**

In `savestate.zig`, after `pub const crc32 = @import("crc32.zig");`:

```zig
pub const Mark = @import("mark.zig").Mark;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="mark"`
Expected: PASS (3 tests). The testing allocator fails the run if `deinit` leaks the buffer.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/savestate/mark.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/savestate_test.zig
git add ps1-core/src/savestate/mark.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/savestate_test.zig
git commit -m "feat(savestate): a runahead mark that carries the memory cards"
```

---

### Task 4: `trace-golden -- snapshot` and `pgxp --snapshot`

**Files:**
- Modify: `ps1-golden/src/main.zig`: usage text (~line 23-60), `Mode` (~98), `Options` (~100-155), the result `switch` (~369), `parseArgs` (~395-480), `runWorkload` (~621-688), `runPgxp` (~742-800), plus a new `speculate` fn after `saveAndRestore`.

**Interfaces:**
- Consumes: `ps1.savestate.Mark` (`init`, `deinit`, `take`, `restore`) from Task 3.
- Produces: the `snapshot` mode and the `--snapshot` option (pgxp only).

- [ ] **Step 1: Add the mode, the option and their parsing**

In the usage string, after the `savestate` entry:

```
    \\  snapshot        verify, but at every sample mark the machine, run one
    \\                  interval ahead, and return to the mark before going on
```

and after the `--threaded` entry:

```
    \\  --snapshot              (pgxp) the same detour at every interval, so
    \\                          PGXP is measured across in-place loads
```

Change `Mode` to:

```zig
const Mode = enum { capture, verify, stream_verify, stream_capture, pgxp, savestate, snapshot, lockstep, chd_verify };
```

Add to `Options` after `pgxp_cpu`:

```zig
    /// `pgxp` only: the `snapshot` detour at every interval. The counters
    /// are put back after each one, so the floors keep their meaning.
    snapshot: bool = false,
```

In `parseArgs`, add `"snapshot"` to the mode chain after `"savestate"`:

```zig
    else if (std.mem.eql(u8, mode, "snapshot"))
        .snapshot
```

and in the option loop, beside `--pgxp-no-cpu`:

```zig
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            opts.snapshot = true;
```

(match the loop's existing `if`/`else if` shape and the variable name it uses for the argument). Next to the existing threaded check, change it to admit the new mode, and add the pgxp-only check:

```zig
    if (opts.threaded != null and opts.mode != .verify and opts.mode != .savestate and opts.mode != .snapshot) return error.BadArguments;
    if (opts.snapshot and opts.mode != .pgxp) return error.BadArguments;
```

In the result `switch`, make the verify arm `.verify, .savestate, .snapshot => {`.

- [ ] **Step 2: Add `speculate`**

After `saveAndRestore`:

```zig
/// `snapshot`'s detour: marks the machine, runs `steps` ahead with the pad as
/// it is, and returns to the mark. The run then goes on as if the detour never
/// happened, which is exactly what the goldens check: a mark/return round trip
/// that leaves anything behind, a JIT block included, fails here.
fn speculate(cpu: *ps1.cpu.Cpu, mark: *ps1.savestate.Mark, steps: u64) !void {
    try mark.take(cpu);
    var n: u64 = 0;
    while (n < steps) n += cpu.runFor(@intCast(@min(steps - n, std.math.maxInt(u32))));
    try mark.restore(cpu);
}
```

- [ ] **Step 3: Call it from `runWorkload`**

After `if (opts.jit_dump != null) ps1.recompiler.setJitDump(bus, dump.hook());` near the top of `runWorkload`:

```zig
    // The smp allocator, not the arena: the buffer is 6.9 MB per workload.
    var mark = ps1.savestate.Mark.init(std.heap.smp_allocator);
    defer mark.deinit();
```

and inside `if (sample_at.due(i)) |at| { ... }`, after the `savestate` restore block:

```zig
            if (opts.mode == .snapshot) try speculate(&cpu, &mark, opts.interval);
```

- [ ] **Step 4: Call it from `runPgxp`**

Replace `runPgxp`'s loop with:

```zig
    var mark = ps1.savestate.Mark.init(std.heap.smp_allocator);
    defer mark.deinit();
    var pad = script.Pad{};
    var i: u64 = 0;
    var next_detour = opts.interval;
    while (i < opts.instructions) {
        if (pad.maskAt(i)) |m| bus.sio.setButtons(m);
        i += cpu.run();
        if (opts.snapshot and i >= next_detour) {
            next_detour += opts.interval;
            // The counters are the harness's, not the machine's: a detour
            // must not count its vertices on top of the real run's.
            const stats = bus.gpu.gp0.pgxp;
            try speculate(&cpu, &mark, opts.interval);
            bus.gpu.gp0.pgxp = stats;
        }
    }
```

- [ ] **Step 5: Build**

Run: `zig build -Doptimize=ReleaseFast`
Expected: builds clean.

- [ ] **Step 6: Run the snapshot gate under every engine**

Run each, ReleaseFast:

```bash
zig build trace-golden -Doptimize=ReleaseFast -- snapshot
zig build trace-golden -Doptimize=ReleaseFast -- snapshot --engine=cached
zig build trace-golden -Doptimize=ReleaseFast -- snapshot --engine=jit
zig build trace-golden -Doptimize=ReleaseFast -- snapshot --threaded=deferred
```

Expected: every workload `OK` in all four. A disc with no golden exits non-zero by design, as for `verify`.

If ONLY the block engines diverge, the cause is in Task 2's reconciliation (a block compiled from bytes the load changed, or a stale pin), not in the snapshot: rerun that workload with `-- lockstep --engine=cached --filter=<key>` to name the first disagreeing block. If `--threaded=deferred` alone diverges, something on the emulator thread read VRAM between `syncRaster` and the load (CLAUDE.md: "nothing on the emulator thread reads `vram` without `Gpu.syncRaster` first").

- [ ] **Step 7: Run the PGXP sweep across in-place loads**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- pgxp --snapshot`
Expected: every pass reports within its `floors.txt` ratchets. A counter falling below its floor means PGXP does NOT survive in-place loads as the spec assumes: stop and report the numbers rather than loosening a floor.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-golden/src/main.zig
git add ps1-golden/src/main.zig
git commit -m "test(golden): snapshot mode returns to a mark at every sample, pgxp --snapshot too"
```

---

### Task 5: `ps1_snapshot_mark` / `ps1_snapshot_return` in the C ABI

**Files:**
- Modify: `ps1-capi/src/root.zig`: error constants (~line 33), `Handle` (~55-90), `ps1_destroy` (~168), `ps1_reset` (~246), `ps1_load_state` (~307), `ps1_load_bios` (~340), `ps1_load_disc` (~447), `ps1_swap_disc` (~658); new exports after `ps1_load_state`.
- Modify: `ps1-capi/include/ps1.h` (error defines ~line 46; declarations beside `ps1_load_state` ~line 542)
- Modify: `ps1-wasm/src/codes.zig` (after `bad_chd`)
- Modify: `ps1-web/src/errors.ts`
- Test: `ps1-capi/src/capi_test.zig` (after "a load keeps the player's settings and an undrained card write", ~line 1145)

**Interfaces:**
- Consumes: `ps1.savestate.Mark` (Task 3).
- Produces: `int32_t ps1_snapshot_mark(Ps1*)`, `int32_t ps1_snapshot_return(Ps1*)`, `PS1_ERR_NO_SNAPSHOT == -16`.

- [ ] **Step 1: Write the failing tests**

Add after "a load keeps the player's settings and an undrained card write" in `capi_test.zig`:

```zig
test "snapshot_return without a mark is NO_SNAPSHOT" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(capi.PS1_ERR_NO_SNAPSHOT, capi.ps1_snapshot_return(h));
}

test "snapshot mark and return restore the machine in place" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    h.cpu.bus.ram[0x2000] = 0x77;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    h.cpu.bus.ram[0x2000] = 0;
    const bus_before = h.bus;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(u8, 0x77), h.cpu.bus.ram[0x2000]);
    try std.testing.expect(h.bus == bus_before);
    try std.testing.expect(h.cpu.bus == h.bus);
}

test "a card write between mark and return is rolled back, dirty flag included" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    h.cpu.bus.sio.memcard_data[0][9] = 0x5A;
    h.cpu.bus.sio.memcard_dirty[0] = true;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(u8, 0), h.cpu.bus.sio.memcard_data[0][9]);
    try std.testing.expect(!h.cpu.bus.sio.memcard_dirty[0]);
}

test "audio produced between mark and return is gone after the return" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    pushAudio(h, 4, 1.0);
    var out: [64]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 8), capi.ps1_read_audio(h, &out, out.len));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    pushAudio(h, 4, 100.0);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(usize, 0), capi.ps1_read_audio(h, &out, out.len));
}

test "reset, load_state, load_disc, swap_disc and load_bios each forget the mark" {
    const bin: [2352]u8 = @splat(0);
    const bios: [524288]u8 = @splat(0x11);
    for (0..5) |which| {
        const h = try bootHandle(0x11);
        defer capi.ps1_destroy(h);
        const state = try saveState(h);
        defer std.testing.allocator.free(state);
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
        switch (which) {
            0 => capi.ps1_reset(h),
            1 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_state(h, state.ptr, state.len)),
            2 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0)),
            3 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0)),
            else => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_bios(h, &bios, bios.len)),
        }
        try std.testing.expectEqual(capi.PS1_ERR_NO_SNAPSHOT, capi.ps1_snapshot_return(h));
    }
}
```

`pushAudio`, `bootHandle` and `saveState` already exist in this file. If `ps1_swap_disc` refuses on a handle with no disc loaded, load one first in that arm.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="snapshot"`
Expected: compile error, `ps1_snapshot_mark` / `PS1_ERR_NO_SNAPSHOT` not declared.

- [ ] **Step 3: Add the code, the field and the exports in `root.zig`**

After `pub const PS1_ERR_BAD_CHD: i32 = -15;`:

```zig
pub const PS1_ERR_NO_SNAPSHOT: i32 = -16;
```

In `Handle`, after `engine`:

```zig
    /// Runahead's mark (`ps1_snapshot_mark`). Owned by the handle rather than
    /// a `Bus`, and forgotten by everything that replaces the machine or its
    /// media: returning to it then would restore a different machine.
    mark: ps1.savestate.Mark = .init(allocator),
```

In `ps1_destroy`, before `allocator.destroy(h);`:

```zig
    h.mark.deinit();
```

Add `h.mark.forget();` as the first statement of `ps1_reset`, of `ps1_load_bios` (after its length check), of `ps1_load_disc` and of `ps1_swap_disc` (each after its validation succeeds, immediately before the handle is changed), and in `ps1_load_state` immediately after `h.cpu = cpu;` (a refused load keeps the machine, so it keeps the mark too).

After `ps1_load_state`:

```zig
/// Runahead's mark: snapshots the running machine and both memory cards into
/// a buffer the handle owns and reuses, with no checksum and no identity
/// (~1 ms). Drain `ps1_read_audio` first: the SPU's output ring is part of
/// the snapshot, so the samples read between the mark and the return are
/// exactly the speculative frames'.
pub export fn ps1_snapshot_mark(h: *Handle) i32 {
    h.mark.take(&h.cpu) catch return PS1_ERR_OOM;
    return PS1_OK;
}

/// Returns the machine IN PLACE to the mark, which stays held: the block
/// cache, the raster worker and the PGXP shadows survive. The GP0 recorder
/// is not part of a state; the frames run since the mark are still in it.
pub export fn ps1_snapshot_return(h: *Handle) i32 {
    h.mark.restore(&h.cpu) catch |err| return switch (err) {
        error.NoMark => PS1_ERR_NO_SNAPSHOT,
        // The bytes are the mark's own: only a core bug reaches this.
        else => PS1_ERR_STATE_CORRUPT,
    };
    return PS1_OK;
}
```

If the `.init(allocator)` field default is rejected as not comptime-known, initialise `mark` in `ps1_create`'s `h.* = .{ ... }` with `.mark = .init(allocator)` instead and give the field no default.

- [ ] **Step 4: Declare them in `ps1.h`**

After `#define PS1_ERR_BAD_CHD          (-15)`:

```c
#define PS1_ERR_NO_SNAPSHOT      (-16)
```

After the `ps1_load_state` declaration:

```c
/* Runahead. ps1_snapshot_mark snapshots the running machine and both memory
 * cards into a buffer the handle owns (no checksum, no identity, ~1 ms);
 * ps1_snapshot_return puts the machine back IN PLACE and keeps the mark, so
 * it can be returned to again. Drain ps1_read_audio before marking: the
 * samples read between the two calls are then exactly the speculative
 * frames'. Returning with no mark, or after ps1_reset, ps1_load_state,
 * ps1_load_disc, ps1_swap_disc or ps1_load_bios, is PS1_ERR_NO_SNAPSHOT.
 * Not for persistence: use ps1_save_state for anything that leaves the
 * process. */
int32_t ps1_snapshot_mark(Ps1*);
int32_t ps1_snapshot_return(Ps1*);
```

- [ ] **Step 5: Mirror the code**

`ps1-wasm/src/codes.zig`, after `bad_chd`:

```zig
pub const no_snapshot: i32 = -16;
```

`ps1-web/src/errors.ts`: add `| 'NO_SNAPSHOT'` after `| 'BAD_CHD'` in `Ps1ErrorCode`, `[-16, 'NO_SNAPSHOT'],` after `[-15, 'BAD_CHD'],` in `byValue`, and in `messages`:

```ts
  NO_SNAPSHOT: 'There is no runahead mark to return to',
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="snapshot"`
Expected: PASS (5 tests).

Run: `zig build && (cd ps1-web && bun test)`
Expected: PASS (BIOS-dependent tests self-skip).

- [ ] **Step 7: Run the whole suite once**

Run: `zig build test`
Expected: all 24 test binaries pass.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-wasm/src/codes.zig
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-capi/include/ps1.h ps1-wasm/src/codes.zig ps1-web/src/errors.ts
git commit -m "feat(capi): ps1_snapshot_mark and ps1_snapshot_return for runahead"
```

---

### Task 6: `ps1-bench --runahead=N`, the measurement, and the docs

**Files:**
- Modify: `ps1-bench/main.zig`
- Modify: `CLAUDE.md` (Quick commands table; Rules: "Savestates")
- Modify: `.claude/skills/ps1-core-subsystems/SKILL.md` (the "Savestates" section)
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md` (where `savestate` mode is described)
- Modify: `docs/superpowers/specs/2026-10-09-runahead-rewind-design.md` (status line; Phase 1's identity bullet)

**Interfaces:**
- Consumes: `ps1.savestate.Mark` (Task 3).

- [ ] **Step 1: Add `--runahead=N` to the bench**

In `ps1-bench/main.zig`, add to the option variables `var runahead: u32 = 0;` and to the argument loop:

```zig
        if (std.mem.startsWith(u8, a, "--runahead=")) {
            runahead = try std.fmt.parseInt(u32, a["--runahead=".len..], 10);
        }
```

Move the loop body into a function after `main`:

```zig
fn frame(cpu: *ps1.cpu.Cpu, vram_copy: []u16, copy: bool) void {
    while (cpu.bus.gpu.is_vblank) _ = cpu.runFor(std.math.maxInt(u32));
    while (!cpu.bus.gpu.is_vblank) _ = cpu.runFor(std.math.maxInt(u32));
    cpu.bus.gpu.syncRaster();
    if (copy) @memcpy(vram_copy, cpu.bus.gpu.vram.data[0..]);
    if (comptime ps1.gpu.Sink.kind == .dual) _ = cpu.bus.gpu.sink.rec.takeFrame();
}
```

and make the timed loop:

```zig
    var mark = ps1.savestate.Mark.init(alloc);
    defer mark.deinit();
    const t0 = std.Io.Clock.now(.awake, io);
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        frame(&cpu, vram_copy, !no_copy);
        // Runahead as the app will drive it: mark, N speculative frames,
        // return. `frames` counts displayed frames.
        if (runahead > 0) {
            try mark.take(&cpu);
            var k: u32 = 0;
            while (k < runahead) : (k += 1) frame(&cpu, vram_copy, !no_copy);
            try mark.restore(&cpu);
        }
    }
```

Add `runahead={d}` to the summary `print` (format string and argument list), and add one paragraph to the file's top comment:

```zig
//! `--runahead=N` drives the loop as the app's runahead does: each displayed
//! frame is followed by a mark, N speculative frames and a return, so the
//! cost of the trusted snapshot path is timed where it is paid.
```

- [ ] **Step 2: Measure**

Run: `zig build -Doptimize=ReleaseFast`, let the machine settle, then for each of `games/Crash Bandicoot - Warped/Crash Bandicoot - Warped.cue`, `games/Spyro the Dragon (USA)/Spyro the Dragon (USA).cue`, `games/Silent Hill (USA)/Silent Hill (USA).cue` and each N in 0, 1, 2, 3:

```bash
zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "<cue>" 3000 --engine=jit --runahead=<N> threaded
```

Take the best of three runs per cell (CLAUDE.md: best of several; interleave the N values rather than batching one N). Expected: `realtime=` above 1.0x for every game at N=2. Record the table; if any game is below 1.0x at N=2, stop and report it before Phase 3 is planned.

- [ ] **Step 3: Update the docs**

`CLAUDE.md` Quick commands, a row after `trace-golden -- savestate`:

```
| `zig build trace-golden -- snapshot` | `verify`, but at every sample the machine is marked, run one interval ahead, and returned to the mark before the run goes on. The gate for the trusted in-place snapshot runahead and rewind are built on: anything a mark/return leaves behind, a JIT block included, fails here. Takes `--engine` and `--threaded`; `pgxp --snapshot` measures PGXP across the same detours. Run it `-Doptimize=ReleaseFast`. |
```

`CLAUDE.md` Rules, under **Savestates**, two bullets:

```
- **A trusted snapshot is only for bytes this process produced.**
  `saveTrusted`/`loadTrusted` skip the checksum and the identity and load
  IN PLACE, so a refusal part-way leaves the machine half-written. Anything
  from a file goes through `load` into a scratch `Bus`.
- **A load no longer flushes the block cache.** The `BUS ` loader drops
  exactly the code pages whose RAM the state changes, and the load forgets
  the pending link site. A block engine that compiles from anything else a
  state restores would need that reconciled too: `snapshot --engine=jit` is
  the gate.
```

`.claude/skills/ps1-core-subsystems/SKILL.md`, at the end of the "Savestates" section, a paragraph covering: `saveTrusted`/`loadTrusted` (same layout, CRC and identity zero, in place, drains and reseats the raster worker); `Mark` (cards and dirty flags ride along because no state carries them; `forget` on reset/load/disc/BIOS); `invalidateChanged` replacing the flush; and the measured costs from Step 2.

`.claude/skills/ps1-test-harnesses/SKILL.md`, beside the `savestate` mode: what `snapshot` checks (a detour of one interval at every sample, under each engine and `--threaded=deferred`), that it needs no new goldens, and that `pgxp --snapshot` restores the counters after each detour so the floors keep their meaning.

The spec: change the status line to `Status: Phase 1 implemented <date>; Phases 2 and 3 not started`, and replace the `saveTrusted` identity sentence in Phase 1 with: "`saveTrusted` writes the CRC and both identity fields as zero: `loadTrusted` checks neither, so there is nothing to cache or invalidate."

- [ ] **Step 4: Commit**

```bash
zig fmt ps1-bench/main.zig
git add ps1-bench/main.zig CLAUDE.md .claude/skills/ps1-core-subsystems/SKILL.md .claude/skills/ps1-test-harnesses/SKILL.md docs/superpowers/specs/2026-10-09-runahead-rewind-design.md
git commit -m "feat(bench): --runahead=N, and the trusted snapshot in the docs"
```
