# Boot Real Games From Disc — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model CUE-described multi-track discs in the core and get the BIOS to boot a real game's data track (Silent Hill, SOTN) instead of looping forever.

**Architecture:** Phase A enriches `disc.zig` with a CUE parser that builds a real TOC over a concatenated `.bin` image (data plane unchanged: `sector N == byte N*2352`), plus a browser directory picker that feeds cue-text + concatenated data to wasm. Phase B is an evidence-driven debug loop: reproduce the disc boot headlessly in `ps1-debug`, instrument the CDROM command flow, then fix the single root cause the trace reveals.

**Tech Stack:** Zig 0.16.0, `zig build` / `zig build test`, wasm32-freestanding browser frontend, vanilla JS in `ps1-wasm/www/index.html`.

## Global Constraints

- Zig version is **0.16.0** — use the std API already present in the repo (`std.mem.tokenizeAny`, `std.ArrayList(...).empty`, etc.).
- **The user performs all git commits.** Do NOT run `git commit`. At each "Commit" step, `git add` the listed files, then STOP and report the staged changes so the user can commit. Treat the commit step as a review checkpoint.
- **BCD/MSF discipline:** CUE `INDEX mm:ss:ff` values are file-relative frame offsets (NOT lead-in adjusted). `frames = ((m*60)+s)*75 + f`. Absolute disc LBA = `file_base_lba + frames`. Do not `binaryToBcd` an already-BCD field.
- Disc data is a borrowed slice owned by the caller (wasm `cd_buffer` / harness buffer); `Disc` must not free it.
- Match surrounding style: inline struct field defaults, flat modules, devices expose `init()`.
- ROM tests self-skip under `zig build test`; do not rely on them for Phase A.

---

## File Structure

- `ps1-core/src/disc.zig` — **modify.** `Track` gains `type`/`start_lba`/`pregap_lba`; add `TrackType`, `initFromCue`; update `trackForLba`/`trackStart`/`getSubchannelQ` to use `start_lba`.
- `ps1-core/tests/disc_test.zig` — **create.** Unit tests for CUE parsing + TOC.
- `build.zig` — **modify.** Add `disc_test.zig` to `test_files`.
- `ps1-wasm/src/main.zig` — **modify.** Add `cue_buffer`, `allocCueBuffer`, build disc via `initFromCue` when cue present.
- `ps1-wasm/www/index.html` — **modify.** Directory picker; parse cue, order/concatenate `.bin`s, emit `REM FILESIZE` lines, stage cue + data.
- `ps1-debug/src/main.zig` — **modify (Phase B).** Optional CLI disc path → `setDisc`, CD boot, gated CDROM trace.
- `ps1-core/src/cdrom.zig` — **modify (Phase B).** Replace unconditional `std.log.warn` spam with `debug_enable`-gated tracing; the eventual root-cause fix.

---

## PHASE A — CUE/TOC + multi-track disc model

### Task A1: `TrackType` + richer `Track`, keep single-track `init` working

**Files:**
- Modify: `ps1-core/src/disc.zig` (Track struct ~48-51, `init` ~69-77, `trackForLba` ~97-104, `trackStart` ~89-95, `getSubchannelQ` ~111-129)
- Test: `ps1-core/tests/disc_test.zig` (create)

**Interfaces:**
- Produces:
  - `pub const TrackType = enum { data, audio };`
  - `Track = struct { number: u8, type: TrackType = .data, start_lba: i32, pregap_lba: ?i32 = null }`
  - `Disc.init(data: []const u8) Disc` — unchanged signature, now builds the new Track shape (single MODE2 data track, `start_lba = 0`).

- [ ] **Step 1: Add the failing test file**

Create `ps1-core/tests/disc_test.zig`:

```zig
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const disc = ps1_core.disc;

test "bare init builds one MODE2 data track at lba 0" {
    var data = [_]u8{0} ** (2352 * 4); // 4 sectors
    const d = disc.Disc.init(&data);
    try expectEqual(@as(u8, 1), d.track_count);
    try expectEqual(@as(u8, 1), d.tracks[0].number);
    try expectEqual(disc.TrackType.data, d.tracks[0].type);
    try expectEqual(@as(i32, 0), d.tracks[0].start_lba);
    try expectEqual(@as(?i32, null), d.tracks[0].pregap_lba);
}
```

- [ ] **Step 2: Wire the test into the build, run it, watch it fail to compile**

Edit `build.zig`: add `"ps1-core/tests/disc_test.zig",` as the first entry of the `test_files` array (build.zig:51).

Run: `zig build test`
Expected: FAIL — `TrackType`/`start_lba` don't exist yet (compile error).

- [ ] **Step 3: Implement the new Track shape**

In `ps1-core/src/disc.zig`, replace the `Track` struct (lines ~48-51) with:

```zig
pub const TrackType = enum { data, audio };

pub const Track = struct {
    number: u8,
    type: TrackType = .data,
    start_lba: i32 = 0,
    pregap_lba: ?i32 = null,
};
```

Update `Disc.init` (lines ~69-77) to:

```zig
pub fn init(data: []const u8) Disc {
    var d = Disc{ .data = data };
    d.tracks[0] = .{ .number = 1, .type = .data, .start_lba = 0 };
    d.track_count = 1;
    return d;
}
```

Update `trackForLba` (the `entry.start.toLba()` compare, ~line 100) to use `entry.start_lba`:

```zig
if (entry.start_lba > lba) break;
```

Update `trackStart` (~89-95) to return MSF from the LBA:

```zig
pub fn trackStart(self: Disc, track_bcd: u8) ?MSF {
    const track = bcdToBinary(track_bcd);
    for (self.tracks[0..self.track_count]) |entry| {
        if (entry.number == track) return MSF.fromLba(entry.start_lba);
    }
    return null;
}
```

Update `getSubchannelQ` (~111-129): replace `const track_lba = current_track.start.toLba();` with `const track_lba = current_track.start_lba;`.

- [ ] **Step 4: Run the test, watch it pass**

Run: `zig build test`
Expected: PASS (all existing tests + the new one).

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/disc.zig ps1-core/tests/disc_test.zig build.zig
# then STOP — report staged changes for the user to commit
```

---

### Task A2: CUE parser — single-FILE single-track (`initFromCue`)

**Files:**
- Modify: `ps1-core/src/disc.zig`
- Test: `ps1-core/tests/disc_test.zig`

**Interfaces:**
- Produces: `pub fn initFromCue(cue_text: []const u8, data: []const u8) Disc`
  - Parses lines `REM FILESIZE <bytes>`, `FILE "..." BINARY`, `TRACK nn MODE2/2352|MODE1/2352|AUDIO`, `INDEX 00 mm:ss:ff`, `INDEX 01 mm:ss:ff`. Ignores all other lines.
  - Each `REM FILESIZE` precedes its `FILE`; advances `file_base_lba` bookkeeping by `bytes/2352`.

- [ ] **Step 1: Write the failing test (Silent Hill shape)**

Append to `ps1-core/tests/disc_test.zig`:

```zig
test "initFromCue single data track" {
    var data = [_]u8{0} ** (2352 * 8);
    const cue =
        "REM FILESIZE 18816\n" ++ // 8 sectors * 2352
        "FILE \"Silent Hill (USA).bin\" BINARY\n" ++
        "  TRACK 01 MODE2/2352\n" ++
        "    INDEX 01 00:00:00\n";
    const d = disc.Disc.initFromCue(cue, &data);
    try expectEqual(@as(u8, 1), d.track_count);
    try expectEqual(@as(u8, 1), d.tracks[0].number);
    try expectEqual(disc.TrackType.data, d.tracks[0].type);
    try expectEqual(@as(i32, 0), d.tracks[0].start_lba);
    try expectEqual(@as(?i32, null), d.tracks[0].pregap_lba);
}
```

- [ ] **Step 2: Run it, watch it fail**

Run: `zig build test`
Expected: FAIL — `initFromCue` not defined.

- [ ] **Step 3: Implement `initFromCue`**

Add to `ps1-core/src/disc.zig` inside `pub const Disc` (after `init`):

```zig
pub fn initFromCue(cue_text: []const u8, data: []const u8) Disc {
    var d = Disc{ .data = data };
    d.track_count = 0;

    var file_base_lba: i32 = 0; // absolute LBA where the current FILE begins
    var next_file_base: i32 = 0; // accumulator for the next FILE
    var pending_file_sectors: i32 = 0; // from the most recent REM FILESIZE

    var lines = std.mem.tokenizeAny(u8, cue_text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (matchKeyword(line, "REM FILESIZE")) |rest| {
            const bytes = parseFirstInt(rest);
            pending_file_sectors = @intCast(@divTrunc(bytes, 2352));
        } else if (matchKeyword(line, "FILE")) |_| {
            file_base_lba = next_file_base;
            next_file_base += pending_file_sectors;
            pending_file_sectors = 0;
        } else if (matchKeyword(line, "TRACK")) |rest| {
            const number = @as(u8, @intCast(parseFirstInt(rest)));
            const ttype: TrackType = if (std.mem.indexOf(u8, rest, "AUDIO") != null) .audio else .data;
            d.tracks[d.track_count] = .{ .number = number, .type = ttype };
            d.track_count += 1;
        } else if (matchKeyword(line, "INDEX")) |rest| {
            if (d.track_count == 0) continue;
            const idx = parseFirstInt(rest); // 0 or 1
            const frames = parseMsfFrames(rest);
            const abs = file_base_lba + frames;
            const t = &d.tracks[d.track_count - 1];
            if (idx == 0) t.pregap_lba = abs else if (idx == 1) t.start_lba = abs;
        }
    }

    if (d.track_count == 0) {
        // Malformed/empty cue: fall back to a single data track.
        d.tracks[0] = .{ .number = 1, .type = .data, .start_lba = 0 };
        d.track_count = 1;
    }
    return d;
}
```

Add these free helpers at module scope (near `bcdToBinary`, ~line 46):

```zig
/// Returns the remainder of `line` after `kw` if `line` starts with `kw`, else null.
fn matchKeyword(line: []const u8, kw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, kw)) return null;
    return std.mem.trim(u8, line[kw.len..], " \t");
}

/// First base-10 integer found in `s` (skips leading non-digits). 0 if none.
fn parseFirstInt(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and (s[i] < '0' or s[i] > '9')) : (i += 1) {}
    var v: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
    }
    return v;
}

/// Parses the trailing `mm:ss:ff` of an INDEX line into absolute frame count.
fn parseMsfFrames(s: []const u8) i32 {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return 0;
    // find the second-to-last colon to bound mm:ss:ff
    const head = s[0..colon];
    const colon2 = std.mem.lastIndexOfScalar(u8, head, ':') orelse return 0;
    // back up over digits to find start of mm
    var start = colon2;
    while (start > 0 and s[start - 1] >= '0' and s[start - 1] <= '9') : (start -= 1) {}
    const m = parseFirstInt(s[start..colon2]);
    const sec = parseFirstInt(s[colon2 + 1 .. colon]);
    const f = parseFirstInt(s[colon + 1 ..]);
    return @intCast(((m * 60) + sec) * 75 + f);
}
```

- [ ] **Step 4: Run the test, watch it pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/disc.zig ps1-core/tests/disc_test.zig
# STOP — report staged changes
```

---

### Task A3: CUE parser — multi-FILE multi-track (SOTN shape) + pregap

**Files:**
- Test: `ps1-core/tests/disc_test.zig`
- (No core change expected — this verifies A2 handles SOTN. If a test fails, fix `initFromCue`.)

**Interfaces:**
- Consumes: `Disc.initFromCue` from A2.

- [ ] **Step 1: Write the failing/confirming test (SOTN shape)**

Append to `ps1-core/tests/disc_test.zig`. File 1 = 100 sectors, file 2 = 50 sectors:

```zig
test "initFromCue two files, data + audio with pregap" {
    var data = [_]u8{0} ** (2352 * 150);
    const cue =
        "REM FILESIZE 235200\n" ++ // 100 sectors
        "FILE \"SOTN (Track 1).bin\" BINARY\n" ++
        "  TRACK 01 MODE2/2352\n" ++
        "    INDEX 01 00:00:00\n" ++
        "REM FILESIZE 117600\n" ++ // 50 sectors
        "FILE \"SOTN (Track 2).bin\" BINARY\n" ++
        "  TRACK 02 AUDIO\n" ++
        "    INDEX 00 00:00:00\n" ++
        "    INDEX 01 00:02:00\n";
    const d = disc.Disc.initFromCue(cue, &data);

    try expectEqual(@as(u8, 2), d.track_count);

    // Track 1: data, starts at LBA 0
    try expectEqual(disc.TrackType.data, d.tracks[0].type);
    try expectEqual(@as(i32, 0), d.tracks[0].start_lba);

    // Track 2: audio, file 2 begins at LBA 100.
    // pregap (INDEX 00) at 100; INDEX 01 at 100 + 150 frames (00:02:00).
    try expectEqual(disc.TrackType.audio, d.tracks[1].type);
    try expectEqual(@as(?i32, 100), d.tracks[1].pregap_lba);
    try expectEqual(@as(i32, 250), d.tracks[1].start_lba);

    // firstTrack/lastTrack reflect the TOC
    try expectEqual(@as(u8, 1), d.firstTrack());
    try expectEqual(@as(u8, 2), d.lastTrack());
}
```

- [ ] **Step 2: Run it**

Run: `zig build test`
Expected: PASS if A2 is correct. If FAIL, fix `initFromCue` (likely the `file_base_lba`/`next_file_base` bookkeeping) until green — do not change the test's expected values.

- [ ] **Step 3: Add a subchannel-Q pregap test**

Append:

```zig
test "getSubchannelQ reports index 00 inside pregap, 01 after" {
    var data = [_]u8{0} ** (2352 * 150);
    const cue =
        "REM FILESIZE 235200\n" ++
        "FILE \"t1.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n" ++
        "REM FILESIZE 117600\n" ++
        "FILE \"t2.bin\" BINARY\n  TRACK 02 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:02:00\n";
    const d = disc.Disc.initFromCue(cue, &data);

    const q_pregap = d.getSubchannelQ(120); // within [100,250)
    try expectEqual(@as(u8, disc.binaryToBcd(2)), q_pregap.track);
    try expectEqual(@as(u8, 0x00), q_pregap.index);

    const q_track = d.getSubchannelQ(260); // past INDEX 01
    try expectEqual(@as(u8, disc.binaryToBcd(2)), q_track.track);
    try expectEqual(@as(u8, 0x01), q_track.index);
}
```

This requires `getSubchannelQ`'s index decision to honor `pregap_lba`. Update `getSubchannelQ` in `disc.zig` (the `index` line ~115):

```zig
const track_lba = current_track.start_lba;
const index: u8 = if (lba < track_lba) 0x00 else 0x01;
```

Since `trackForLba` selects a track when `start_lba <= lba`, a sector in `[pregap_lba, start_lba)` would select the *previous* track. Fix `trackForLba` to select by the earliest meaningful position (pregap if present):

```zig
pub fn trackForLba(self: Disc, lba: i32) Track {
    var current = self.tracks[0];
    for (self.tracks[0..self.track_count]) |entry| {
        const entry_start = entry.pregap_lba orelse entry.start_lba;
        if (entry_start > lba) break;
        current = entry;
    }
    return current;
}
```

- [ ] **Step 4: Run the tests, watch them pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/disc.zig ps1-core/tests/disc_test.zig
# STOP — report staged changes
```

---

### Task A4: wasm exports — stage cue text, build disc via `initFromCue`

**Files:**
- Modify: `ps1-wasm/src/main.zig`

**Interfaces:**
- Produces (wasm ABI): `allocCueBuffer(size: usize) [*]u8`; `loadCdFromBuffer()` unchanged name, now cue-aware.
- Consumes: `disc.Disc.initFromCue` (A2).

- [ ] **Step 1: Add `cue_buffer` state + reset**

In `ps1-wasm/src/main.zig`, add after `var cd_buffer` (line 14):

```zig
var cue_buffer: []u8 = &[_]u8{};
```

In `export fn init()` (after `cd_buffer = ...;`, line 25) add:

```zig
cue_buffer = &[_]u8{};
```

- [ ] **Step 2: Add `allocCueBuffer`**

After `allocCdBuffer` (line 78):

```zig
export fn allocCueBuffer(size: usize) [*]u8 {
    if (cue_buffer.len > 0) {
        std.heap.wasm_allocator.free(cue_buffer);
        cue_buffer = &[_]u8{};
    }
    cue_buffer = std.heap.wasm_allocator.alloc(u8, size) catch @panic("Failed to allocate CUE buffer");
    return cue_buffer.ptr;
}
```

- [ ] **Step 3: Make `loadCdFromBuffer` cue-aware**

Replace `loadCdFromBuffer` (lines 80-85):

```zig
export fn loadCdFromBuffer() void {
    if (cd_buffer.len == 0) return;

    const d = if (cue_buffer.len > 0)
        ps1_core.disc.Disc.initFromCue(cue_buffer, cd_buffer)
    else
        ps1_core.disc.Disc.init(cd_buffer);
    bus.cdrom.setDisc(d);
}
```

- [ ] **Step 4: Build the wasm target**

Run: `zig build`
Expected: builds `ps1-debug` and the wasm `emulator` with no errors.

- [ ] **Step 5: Commit**

```bash
git add ps1-wasm/src/main.zig
# STOP — report staged changes
```

---

### Task A5: browser directory picker — parse cue, order/concat bins, emit FILESIZE

**Files:**
- Modify: `ps1-wasm/www/index.html` (game input ~line 52; the load handler ~lines 230-242)

**Interfaces:**
- Consumes (wasm ABI): `allocCdBuffer`, `allocCueBuffer`, `loadCdFromBuffer`, `getBiosPtr`/`setBiosLoaded` (existing).

- [ ] **Step 1: Switch the game input to a directory picker**

Change the game `<input>` (index.html:52) to:

```html
<label>2. Game folder (.cue + .bin) or single .bin:</label><br/>
<input type="file" id="game-upload" webkitdirectory directory multiple />
```

- [ ] **Step 2: Add a cue-aware folder loader**

Locate the existing game-upload change/handler that calls `allocCdBuffer`/`loadCdFromBuffer` (around index.html:230-242). Replace its body with logic that handles a FileList:

```js
async function loadGameFiles(fileList) {
  const files = Array.from(fileList);
  const cueFile = files.find(f => f.name.toLowerCase().endsWith('.cue'));
  const bins = new Map(files.filter(f => f.name.toLowerCase().endsWith('.bin'))
                            .map(f => [f.name, f]));

  // Determine ordered bin list.
  let orderedBins = [];
  let augmentedCue = '';
  if (cueFile) {
    const cueText = await cueFile.text();
    for (const line of cueText.split(/\r?\n/)) {
      const m = line.match(/FILE\s+"([^"]+)"/i);
      if (m) {
        const bin = bins.get(m[1]) || bins.get(m[1].split(/[\\/]/).pop());
        if (!bin) { alert('Missing .bin referenced by cue: ' + m[1]); return; }
        orderedBins.push(bin);
        augmentedCue += 'REM FILESIZE ' + bin.size + '\n';
      }
      augmentedCue += line + '\n';
    }
  } else {
    // No cue: take the single largest .bin as a raw single-track image.
    const all = files.filter(f => f.name.toLowerCase().endsWith('.bin'));
    if (all.length === 0) { alert('No .bin found'); return; }
    orderedBins = [all.sort((a, b) => b.size - a.size)[0]];
  }

  // Concatenate bins in order into wasm memory.
  const total = orderedBins.reduce((n, f) => n + f.size, 0);
  const cdPtr = wasmExports.allocCdBuffer(total);
  const heap = new Uint8Array(wasmExports.memory.buffer);
  let off = cdPtr;
  for (const f of orderedBins) {
    const buf = new Uint8Array(await f.arrayBuffer());
    heap.set(buf, off);
    off += buf.length;
  }

  // Stage cue text (if any).
  if (augmentedCue) {
    const enc = new TextEncoder().encode(augmentedCue);
    const cuePtr = wasmExports.allocCueBuffer(enc.length);
    new Uint8Array(wasmExports.memory.buffer).set(enc, cuePtr);
  }

  wasmExports.loadCdFromBuffer();
}
```

Wire the input's `change` event to call `loadGameFiles(e.target.files)`. Keep the existing BIOS-load flow untouched.

> **Note:** re-fetch `new Uint8Array(wasmExports.memory.buffer)` AFTER each `alloc*` call — wasm memory growth detaches old views.

- [ ] **Step 3: Manual smoke test in the browser**

Run: `zig build`, serve `ps1-wasm/www/` (e.g. `python3 -m http.server` from that dir), open it, load the BIOS, then pick the SOTN folder.
Expected: no JS errors in console; `loadCdFromBuffer` runs; emulator continues (boot behavior verified in Phase B).

- [ ] **Step 4: Commit**

```bash
git add ps1-wasm/www/index.html
# STOP — report staged changes
```

---

### Task A6: Phase A self-check

- [ ] **Step 1: Full test run**

Run: `zig build test`
Expected: PASS — all suites including the new `disc_test`.

- [ ] **Step 2: Full build**

Run: `zig build`
Expected: native + wasm build clean.

---

## PHASE B — Make the data track readable through to boot (evidence-driven)

> Phase B is a debug loop, not a pre-planned fix. Tasks B1–B2 are fully specified (reproduction + instrumentation). Task B3 is a **diagnosis gate**: run the trace, identify the single root cause with systematic-debugging, THEN write the fix (with a failing test first). Do not guess a fix before B2's evidence.

### Task B1: headless CD-boot reproduction in `ps1-debug`

**Files:**
- Modify: `ps1-debug/src/main.zig`

**Interfaces:**
- Consumes: `disc.Disc.init` / `initFromCue`, `cpu.bus.cdrom.setDisc`.

- [ ] **Step 1: Accept an optional disc path and boot from CD**

In `ps1-debug/src/main.zig`, after the BIOS `@memcpy` (line 18) and before the run loop, add CLI handling: if `std.process.argsAlloc` yields a second arg, read that file (`.bin`) into an allocated buffer, build a `Disc` (use `init`; cue support optional), and `cpu.bus.cdrom.setDisc(d)`. Do **not** call `loadExe` — this exercises the real CD-boot path.

```zig
var args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);
if (args.len >= 2) {
    const path = args[1];
    const file = try std.Io.Dir.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1 << 31); // up to 2 GiB
    const d = ps1_core.disc.Disc.init(bytes);
    cpu.bus.cdrom.setDisc(d);
    std.debug.print("Disc loaded: {} sectors\n", .{bytes.len / 2352});
}
```

(Confirm the exact 0.16 file-read API against `rom_test.zig`'s BIOS loader and match it.)

- [ ] **Step 2: Build and run against Silent Hill's data track**

Run: `zig build && ./zig-out/bin/ps1-debug "/Users/david/Downloads/Silent Hill (USA)/Silent Hill (USA)/Silent Hill (USA).bin"`
Expected: it boots the BIOS and (currently) loops; capture the final PC / BIOS-hit count for a baseline.

- [ ] **Step 3: Commit**

```bash
git add ps1-debug/src/main.zig
# STOP — report staged changes
```

---

### Task B2: gated CDROM tracing (replace warn spam)

**Files:**
- Modify: `ps1-core/src/cdrom.zig` (`queueIrq` ~744, `pushAction` ~42, `executeCommand` ~491-497, the existing `std.log.warn` calls ~41/46/493)

- [ ] **Step 1: Add a `debug_enable` gate and trace points**

Add a `debug_enable: bool = false` field to `CdRom` (near other fields ~122). Replace the three unconditional `std.log.warn(...)` calls (`queueIrq`/`pushAction`/`executeCommand`) with:

```zig
if (self.debug_enable) std.log.info("CDROM <message>", .{...});
```

Add a trace at command receipt and at each INT fire in `step()` (the `item.triggered` block ~282) logging: command byte, irq number, response bytes, and `drive_state`.

- [ ] **Step 2: Enable tracing from the harness and capture the boot sequence**

In `ps1-debug/src/main.zig`, set `cpu.bus.cdrom.debug_enable = true;` after `setDisc`. Rebuild and run against Silent Hill, redirecting output to a log.

Run: `zig build && ./zig-out/bin/ps1-debug "<silent hill bin>" 2> cd_trace.log`
Expected: `cd_trace.log` shows the BIOS command sequence (GetID → SetMode → SetLoc → ReadN → … ) and where it stops progressing.

- [ ] **Step 3: Commit**

```bash
git add ps1-core/src/cdrom.zig ps1-debug/src/main.zig
# STOP — report staged changes
```

---

### Task B3: DIAGNOSIS GATE → root-cause fix

> **STOP and use superpowers:systematic-debugging here.** Do not write a fix before completing the trace analysis.

- [ ] **Step 1: Analyze `cd_trace.log`** — identify the exact command/step where boot stalls. Compare the responses against `avocado_ref/src/device/cdrom/` and the expected BIOS boot flow (GetID region/flags → ISO9660 PVD at sector 16 → SYSTEM.CNF → main EXE).

- [ ] **Step 2: Form ONE hypothesis** for the single root cause. Likely suspects (verify, do not assume): `irq_queue.clear()` on every command write (`cdrom.zig:198`) wiping a pending INT1 data interrupt; GetID region/flags (`0x1A`); data-sector delivery size/offset in `readNextSector`; or bad ISO data from sector mapping.

- [ ] **Step 3: Write a focused failing test** in `ps1-core/tests/cdrom_test.zig` reproducing only that failure (per systematic-debugging Phase 4 + TDD).

- [ ] **Step 4: Implement the minimal fix; run the test; verify green.**

- [ ] **Step 5: Re-run the harness** against Silent Hill — confirm it advances past the prior stall point (ideally to its executable / first GPU activity). If a NEW stall appears, return to Step 1 (new hypothesis). If 3+ fixes fail, STOP and question the CDROM architecture with the user.

- [ ] **Step 6: Commit each fix separately.**

```bash
git add <changed files>
# STOP — report staged changes
```

---

### Task B4: end-to-end verification

- [ ] **Step 1:** `zig build test` — all green, no regressions.
- [ ] **Step 2:** Native harness boots Silent Hill past the BIOS shell.
- [ ] **Step 3:** Browser: load BIOS + SOTN folder; GetTN reports tracks 1–2; data track boots. (In-game CD audio explicitly out of scope.)
- [ ] **Step 4:** Disable `debug_enable` by default; ensure no log spam remains in normal runs.

---

## Self-Review notes

- **Spec coverage:** CUE parse in core (A2/A3), data-plane unchanged (A1–A3), directory picker (A5), `REM FILESIZE` contract (A2/A5), bare-`.bin` fallback (A1/A4/A5), disc unit tests (A1–A3), headless reproduction + instrumentation + evidence-driven fix (B1–B3), SH/SOTN success criteria (B4). All spec sections map to tasks.
- **Type consistency:** `Track.start_lba: i32`, `pregap_lba: ?i32`, `TrackType{ data, audio }` used identically across A1/A2/A3 and consumers. `initFromCue(cue_text, data)` signature stable A2→A4.
- **Phase B placeholders are intentional diagnosis gates**, not lazy TODOs — the fix is undefined by design until B2's trace exists; B3 carries the full systematic-debugging process as its content.
