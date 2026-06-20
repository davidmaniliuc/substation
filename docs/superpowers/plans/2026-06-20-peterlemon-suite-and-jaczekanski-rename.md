# PeterLemon/PSX Suite + JaCzekanski Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the existing ROM suite under `test-roms/jaczekanski/` and add a curated `test-roms/peterlemon/` suite verified by self-pinned VRAM-framebuffer hashes.

**Architecture:** The current TTY-vs-`psx.log` harness in `ps1-core/tests/rom_test.zig` stays for JaCzekanski (paths only change). A new `runPlTest` helper in the same file boots the BIOS, sideloads a PeterLemon PS-X EXE, runs a fixed cycle budget, hashes the 1 MB VRAM via `bus.gpu.getVramPtr()`, and compares against a committed `vram.hash` golden. An env var `PS1_UPDATE_GOLDENS=1` switches the helper from compare-mode to write-mode for one-time pinning.

**Tech Stack:** Zig 0.16.0, `zig build rom-test` (sets `enable_rom_tests=true` via `b.addOptions`), `std.hash.Wyhash`, `std.Io.Dir` file IO.

## Global Constraints

- Zig version MUST be **0.16.0**. Use the 0.16 std API already in this file: `std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(n))` for reads and `std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = d })` for writes.
- ROM tests are gated by the compile-time option `options.enable_rom_tests`. Every test helper MUST begin with `if (!options.enable_rom_tests) return error.SkipZigTest;`.
- `zig build test` hardcodes `enable_rom_tests=false` (rom tests self-skip there); `zig build rom-test` hardcodes it `true`. Do NOT add a `-D` CLI flag.
- All commands run from the **repo root** (`/Users/david/Documents/develop/zzssxx`); the harness reads BIOS and ROMs via CWD-relative paths.
- BIOS file at repo root: `SCPH-1001_BIOS_1995_US.bin` (exactly 512 KB), loaded at runtime.
- PeterLemon executables are stored with the **`.exe`** extension (already their upstream name). Do NOT create `.bin` files (excluded by `.gitignore`) and do NOT edit `.gitignore`.
- **NO git mutations.** The user commits themselves. Do NOT run `git mv`, `git add`, `git commit`, or `git rm`. Use plain `mv` for moves (git detects renames at the user's commit). Read-only git (`status`, `diff`, `check-ignore`) is allowed. Leave all work uncommitted in the working tree.
- Reference images: each PeterLemon ROM's upstream `.png` is 320×224 and is pre-converted to raw RGB24 with `ffmpeg -y -loglevel error -i in.png -f rawvideo -pix_fmt rgb24 out.rgb` (→ exactly `320*224*3 = 215040` bytes). The Zig harness reads only the raw `.rgb`; it has no PNG decoder.
- Match surrounding style: inline struct field defaults, flat modules, `std.testing.allocator` in test bodies.

---

### Task 1: Restructure JaCzekanski suite into a subdirectory

**Files:**
- Move (plain `mv`, NOT `git mv`): all of `test-roms/*` → `test-roms/jaczekanski/`
- Create: `test-roms/README.md`
- Modify: `ps1-core/tests/rom_test.zig` (path literals in the 11 JaCzekanski test cases, lines ~209-305)
- Modify: `build.zig` (rom-test step description, ~line 99)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the directory `test-roms/jaczekanski/` containing the original suite; `test-roms/peterlemon/` does not exist yet (created in Task 2). All JaCzekanski test path literals now begin with `test-roms/jaczekanski/`.

- [ ] **Step 1: Move the suite into a subdirectory (plain `mv`; git detects the renames at the user's commit)**

```bash
cd /Users/david/Documents/develop/zzssxx
mkdir -p test-roms/jaczekanski
mv test-roms/cdrom test-roms/cpu test-roms/dma test-roms/gpu \
   test-roms/gte test-roms/gte-fuzz test-roms/input test-roms/mdec \
   test-roms/spu test-roms/timer-dump test-roms/timers test-roms/tools \
   test-roms/README.md test-roms/CONTRIBUTORS.md \
   test-roms/jaczekanski/
```

- [ ] **Step 2: Verify the move**

Run: `ls test-roms && echo '---' && ls test-roms/jaczekanski`
Expected: top level shows only `jaczekanski`; `jaczekanski/` shows `README.md CONTRIBUTORS.md cdrom cpu dma gpu gte gte-fuzz input mdec spu timer-dump timers tools`.

- [ ] **Step 3: Update all JaCzekanski test path literals in rom_test.zig**

In `ps1-core/tests/rom_test.zig`, every test-case string literal of the form `"test-roms/<category>/..."` (in the 11 `test "ROM: ..."` blocks, both the `.exe` and `psx.log` paths, plus the `io-access-bitwidth` path inside `normalizeKnownRomOutput` at line 65) must become `"test-roms/jaczekanski/<category>/..."`.

Do a literal replace of the substring `test-roms/` → `test-roms/jaczekanski/` for every occurrence EXCEPT any future `test-roms/peterlemon/` paths (none exist yet, so a blanket replace is safe). Use sed:

```bash
sed -i '' 's#"test-roms/#"test-roms/jaczekanski/#g' ps1-core/tests/rom_test.zig
```

- [ ] **Step 4: Verify the replace touched the expected lines**

Run: `grep -c 'test-roms/jaczekanski/' ps1-core/tests/rom_test.zig && grep -n 'test-roms/' ps1-core/tests/rom_test.zig | grep -v jaczekanski`
Expected: a count of 23 (22 in test cases + 1 in `normalizeKnownRomOutput`); the second grep prints nothing (no un-prefixed `test-roms/` remain).

- [ ] **Step 5: Update the rom-test step description in build.zig**

In `build.zig` (~line 99), change:

```zig
    const rom_test_step = b.step("rom-test", "Run JaCzekanski PS1 ROM integration tests");
```

to:

```zig
    const rom_test_step = b.step("rom-test", "Run PS1 ROM integration tests (JaCzekanski + PeterLemon)");
```

- [ ] **Step 6: Create the top-level test-roms README**

Create `test-roms/README.md`:

```markdown
# test-roms

PS1 hardware-conformance and regression ROM suites consumed by
`ps1-core/tests/rom_test.zig` (run via `zig build rom-test`).

## Suites

### `jaczekanski/`
[JaCzekanski/ps1-tests](https://github.com/JaCzekanski/ps1-tests) — hardware
conformance tests that print to TTY. Verified by comparing captured TTY output
against each test's golden `psx.log`. See `jaczekanski/README.md` for the test
catalog.

### `peterlemon/`
Curated demos from [PeterLemon/PSX](https://github.com/PeterLemon/PSX). These
are graphical (no `psx.log`), so they are verified by comparing our rendered
320×224 display region against the demo's upstream **reference image**
(`reference.png`, pre-converted to raw `reference.rgb`). The comparison is
tolerant — our software rasterizer diverges from hardware by design — so each
test counts matching pixels (in 5-bit RGB space) and passes when the count meets
a committed per-ROM floor in `floor.txt` (run with `PS1_UPDATE_GOLDENS=1` to
(re)pin floors to the current value). The reference PNG is the gold standard; the
floor is a regression guard and a visible record of the current conformance gap.
```

- [ ] **Step 7: Verify the build still compiles and rom-test runs**

Run: `zig build && zig build rom-test`
Expected: both succeed. `rom-test` passes — the 11 JaCzekanski bodies are `if (false)` so they execute no file IO; they pass trivially.

- [ ] **Step 8: Do NOT commit**

Leave all changes (moved files, `rom_test.zig`, `build.zig`, new README) in the working tree. The user commits. The controller reviews the working-tree diff.

---

### Task 2: Import the curated PeterLemon ROM set + reference images

**Files (per ROM dir, 6 dirs):** create `<rom>.exe`, `reference.png` (upstream
320×224 image), and `reference.rgb` (ffmpeg-converted raw RGB24). Dirs:
- `test-roms/peterlemon/cpu/add/` (CPUADD)
- `test-roms/peterlemon/hello-world/` (HelloWorld16BPP)
- `test-roms/peterlemon/gpu/render-polygon/` (RenderPolygon16BPP)
- `test-roms/peterlemon/gpu/render-line/` (RenderLine16BPP)
- `test-roms/peterlemon/gpu/render-rectangle/` (RenderRectangle16BPP)
- `test-roms/peterlemon/gpu/render-texture-polygon/` (RenderTexturePolygon15BPP, from the `15BPP/` subdir — the `RenderTexturePolygon/` dir has no flat demo)

**Interfaces:**
- Consumes: `test-roms/peterlemon/` namespace established by Task 1's layout.
- Produces: for each of the 6 dirs, the `.exe` plus `reference.png` and
  `reference.rgb` (exactly `320*224*3 = 215040` bytes). Task 3/4 reference the
  `.exe` and `reference.rgb` paths.

- [ ] **Step 1: Download the six ROMs and their reference PNGs (master branch)**

```bash
cd /Users/david/Documents/develop/zzssxx
BASE=https://raw.githubusercontent.com/PeterLemon/PSX/master
# args: <upstream-dir> <upstream-basename> <local-dir>
fetch() {
  mkdir -p "$3"
  curl -fsSL "$BASE/$1/$2.exe" -o "$3/$2.exe"
  curl -fsSL "$BASE/$1/$2.png" -o "$3/reference.png"
}
fetch CPUTest/CPU/ADD            CPUADD                   test-roms/peterlemon/cpu/add
fetch HelloWorld/16BPP           HelloWorld16BPP          test-roms/peterlemon/hello-world
fetch GPU/16BPP/RenderPolygon    RenderPolygon16BPP       test-roms/peterlemon/gpu/render-polygon
fetch GPU/16BPP/RenderLine       RenderLine16BPP          test-roms/peterlemon/gpu/render-line
fetch GPU/16BPP/RenderRectangle  RenderRectangle16BPP     test-roms/peterlemon/gpu/render-rectangle
fetch GPU/16BPP/RenderTexturePolygon/15BPP RenderTexturePolygon15BPP test-roms/peterlemon/gpu/render-texture-polygon
```

- [ ] **Step 2: Verify each executable is a valid PS-X EXE**

Run:
```bash
for f in $(find test-roms/peterlemon -name '*.exe'); do printf '%s ' "$f"; head -c 8 "$f"; echo; done
```
Expected: six lines, each path followed by `PS-X EXE`.

- [ ] **Step 3: Verify each reference PNG is 320×224**

Run:
```bash
for f in $(find test-roms/peterlemon -name 'reference.png'); do printf '%s  ' "$f"; file "$f" | grep -o '[0-9]* x [0-9]*'; done
```
Expected: six lines, each ending `320 x 224`. (If any differs, STOP and report — the harness assumes 320×224.)

- [ ] **Step 4: Convert each reference PNG to raw RGB24 with ffmpeg**

```bash
for png in $(find test-roms/peterlemon -name 'reference.png'); do
  ffmpeg -y -loglevel error -i "$png" -f rawvideo -pix_fmt rgb24 "${png%.png}.rgb"
done
```

- [ ] **Step 5: Verify every reference.rgb is exactly 215040 bytes**

Run:
```bash
for f in $(find test-roms/peterlemon -name 'reference.rgb'); do printf '%s ' "$f"; wc -c < "$f"; done
```
Expected: six lines, each size `215040` (= 320 × 224 × 3). Any other size means the PNG was not 320×224 — STOP and report.

(Do not commit — the user commits. Confirm nothing is gitignored:
`git check-ignore test-roms/peterlemon/**/* ; echo "exit=$?"` should print no paths and `exit=1`.)

---

### Task 3: Add the reference-image comparison harness and pin the first ROM

**Files:**
- Modify: `ps1-core/tests/rom_test.zig` (add `PL_W`/`PL_H`/`PL_PIXELS` consts, `goldensUpdateMode`, `countReferenceMatches`, `runPlTest`; add one test case)
- Create: `test-roms/peterlemon/hello-world/floor.txt` (generated by the update run)

**Interfaces:**
- Consumes: `options.enable_rom_tests`, `readTestFile`, `Bus`, `Cpu` (already in the file); `bus.gpu.getVramPtr()` (`[*]const u16`, VRAM indexed `vy * 1024 + vx`); `bus.gpu.disp_env.vram_x_start` / `.vram_y_start` (`u16`).
- Produces:
  - `const PL_W: usize = 320; const PL_H: usize = 224; const PL_PIXELS: usize = PL_W * PL_H;`
  - `fn goldensUpdateMode(allocator: std.mem.Allocator) bool`
  - `fn countReferenceMatches(bus: *Bus, ref_rgb: []const u8) usize` — counts display pixels matching the reference in 5-bit RGB space.
  - `fn runPlTest(allocator: std.mem.Allocator, exe_path: []const u8, ref_rgb_path: []const u8, floor_path: []const u8, max_cycles: u64) !void`

- [ ] **Step 1: Add the helper functions to rom_test.zig**

Insert after `runRomTest` (after line ~207, before the first `test "ROM: ..."`):

```zig
const PL_W: usize = 320;
const PL_H: usize = 224;
const PL_PIXELS: usize = PL_W * PL_H; // 71680

fn goldensUpdateMode(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "PS1_UPDATE_GOLDENS") catch return false;
    defer allocator.free(value);
    return value.len > 0;
}

/// Count display-region pixels matching the reference image, comparing in 5-bit
/// RGB space (both sides reduced to RGB555) so the ABGR1555->RGB888 expansion
/// used to make the reference PNG doesn't register as a difference.
fn countReferenceMatches(bus: *Bus, ref_rgb: []const u8) usize {
    const vram = bus.gpu.getVramPtr();
    const ox: usize = bus.gpu.disp_env.vram_x_start;
    const oy: usize = bus.gpu.disp_env.vram_y_start;
    var matches: usize = 0;
    var y: usize = 0;
    while (y < PL_H) : (y += 1) {
        var x: usize = 0;
        while (x < PL_W) : (x += 1) {
            const vx = (ox + x) & 0x3FF;
            const vy = (oy + y) & 0x1FF;
            const px = vram[vy * 1024 + vx];
            const r5: u8 = @intCast(px & 0x1F);
            const g5: u8 = @intCast((px >> 5) & 0x1F);
            const b5: u8 = @intCast((px >> 10) & 0x1F);
            const idx = (y * PL_W + x) * 3;
            if (r5 == (ref_rgb[idx] >> 3) and
                g5 == (ref_rgb[idx + 1] >> 3) and
                b5 == (ref_rgb[idx + 2] >> 3)) matches += 1;
        }
    }
    return matches;
}

fn runPlTest(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    ref_rgb_path: []const u8,
    floor_path: []const u8,
    max_cycles: u64,
) !void {
    if (!options.enable_rom_tests) return error.SkipZigTest;

    const bus = try Bus.init(allocator);
    defer bus.deinit(allocator);

    var cpu = Cpu.init(bus);

    const bios_data = try readTestFile(allocator, "SCPH-1001_BIOS_1995_US.bin", 512 * 1024);
    defer allocator.free(bios_data);
    if (bios_data.len != bus.bios.len) return error.InvalidBiosSize;
    @memcpy(bus.bios[0..], bios_data);

    // Boot the BIOS to init jump tables (same prelude as runRomTestWithMode).
    var boot_cycles: u64 = 0;
    while (boot_cycles < 25_000_000) : (boot_cycles += 1) {
        cpu.step();
    }

    const exe_data = try readTestFile(allocator, exe_path, 10 * 1024 * 1024);
    defer allocator.free(exe_data);
    try cpu.loadExe(exe_data);

    // Graphical demos render in an infinite loop; a fixed cycle budget yields a
    // deterministic frame (no VRAM-touching RNG in the core).
    var cycles: u64 = 0;
    while (cycles < max_cycles) : (cycles += 1) {
        cpu.step();
    }

    // readTestFile panics on FileNotFound (reporting the path); reference.rgb is
    // guaranteed present by Task 2.
    const ref_rgb = try readTestFile(allocator, ref_rgb_path, PL_PIXELS * 3);
    defer allocator.free(ref_rgb);
    if (ref_rgb.len != PL_PIXELS * 3) {
        std.debug.print("\n=== PL TEST: bad reference size {s}: {d} (want {d}) ===\n", .{ ref_rgb_path, ref_rgb.len, PL_PIXELS * 3 });
        return error.RomOutputMismatch;
    }

    const matches = countReferenceMatches(bus, ref_rgb);
    const pct = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(PL_PIXELS)) * 100.0;

    if (goldensUpdateMode(allocator)) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{matches}) catch unreachable;
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = floor_path, .data = text });
        std.debug.print("[PS1_UPDATE_GOLDENS] {s}: {d}/{d} px ({d:.2}%) -> floor {s}\n", .{ exe_path, matches, PL_PIXELS, pct, floor_path });
        return;
    }

    // Compare mode: missing floor.txt panics in readTestFile with the path —
    // re-run with PS1_UPDATE_GOLDENS=1 to pin it.
    const floor_raw = try readTestFile(allocator, floor_path, 32);
    defer allocator.free(floor_raw);
    const floor_text = std.mem.trim(u8, floor_raw, " \r\n\t");
    const floor = std.fmt.parseInt(usize, floor_text, 10) catch {
        std.debug.print("\n=== PL TEST: bad floor file {s}: '{s}' ===\n", .{ floor_path, floor_text });
        return error.RomOutputMismatch;
    };

    std.debug.print("[PL] {s}: {d}/{d} px ({d:.2}%), floor {d}\n", .{ exe_path, matches, PL_PIXELS, pct, floor });
    if (matches < floor) {
        std.debug.print("\n=== PL TEST FAILED: {s} ===\n", .{exe_path});
        std.debug.print("match {d} < floor {d} ({d:.2}%); GPU regression?\n", .{ matches, floor, pct });
        return error.RomOutputMismatch;
    }
}
```

- [ ] **Step 2: Add the hello-world test case**

Add after the `runPlTest` definition (or grouped after the JaCzekanski tests):

```zig
test "PL: HelloWorld 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/hello-world/HelloWorld16BPP.exe",
        "test-roms/peterlemon/hello-world/reference.rgb",
        "test-roms/peterlemon/hello-world/floor.txt",
        10_000_000,
    );
}
```

- [ ] **Step 3: Verify it compiles and fails on the missing floor**

Run: `zig build rom-test`
Expected: build succeeds; `PL: HelloWorld 16BPP` fails (missing `floor.txt` → `readTestFile` panic naming the path). This confirms the harness compiles and runs the ROM. Note the `[PS1_UPDATE_GOLDENS]`/`[PL]` lines are not printed yet because the panic happens before compare-mode prints — that's fine.

- [ ] **Step 4: Pin the floor**

Run: `PS1_UPDATE_GOLDENS=1 zig build rom-test`
Expected: prints `[PS1_UPDATE_GOLDENS] test-roms/peterlemon/hello-world/HelloWorld16BPP.exe: <N>/71680 px (<pct>%) -> floor ...` and the test passes. Confirm:
Run: `cat test-roms/peterlemon/hello-world/floor.txt; echo`
Expected: a single integer (the matching-pixel count, 0..71680). Note the percentage printed — if it is implausibly low (≈0%), the display origin or frame timing may be off; report it as a concern but still pin (the floor records reality).

- [ ] **Step 5: Verify compare-mode now passes**

Run: `zig build rom-test`
Expected: `[PL] ...: N/71680 (pct%), floor N` and `PL: HelloWorld 16BPP` passes (`matches >= floor`, equal since deterministic).

- [ ] **Step 6: Do NOT commit**

Leave the changes (rom_test.zig + `floor.txt`) in the working tree. The user commits. The controller reviews the working-tree diff.

---

### Task 4: Add and pin the remaining five PeterLemon test cases

**Files:**
- Modify: `ps1-core/tests/rom_test.zig` (five more test cases)
- Create: `floor.txt` in each of the five remaining ROM dirs

**Interfaces:**
- Consumes: `runPlTest` from Task 3.
- Produces: five `test "PL: ..."` cases with committed floors. No new functions.

- [ ] **Step 1: Add the five remaining test cases**

Append alongside the hello-world case:

```zig
test "PL: CPU ADD" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/cpu/add/CPUADD.exe",
        "test-roms/peterlemon/cpu/add/reference.rgb",
        "test-roms/peterlemon/cpu/add/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderPolygon 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-polygon/RenderPolygon16BPP.exe",
        "test-roms/peterlemon/gpu/render-polygon/reference.rgb",
        "test-roms/peterlemon/gpu/render-polygon/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderLine 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-line/RenderLine16BPP.exe",
        "test-roms/peterlemon/gpu/render-line/reference.rgb",
        "test-roms/peterlemon/gpu/render-line/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderRectangle 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-rectangle/RenderRectangle16BPP.exe",
        "test-roms/peterlemon/gpu/render-rectangle/reference.rgb",
        "test-roms/peterlemon/gpu/render-rectangle/floor.txt",
        10_000_000,
    );
}

test "PL: GPU RenderTexturePolygon 16BPP" {
    try runPlTest(
        std.testing.allocator,
        "test-roms/peterlemon/gpu/render-texture-polygon/RenderTexturePolygon15BPP.exe",
        "test-roms/peterlemon/gpu/render-texture-polygon/reference.rgb",
        "test-roms/peterlemon/gpu/render-texture-polygon/floor.txt",
        10_000_000,
    );
}
```

- [ ] **Step 2: Pin all floors in one update run**

Run: `PS1_UPDATE_GOLDENS=1 zig build rom-test`
Expected: six `[PS1_UPDATE_GOLDENS] ...` lines (the five new ones plus hello-world re-written identically); all PL tests pass. Eyeball the printed percentages — they record how close each demo currently renders to the real reference.

- [ ] **Step 3: Verify all floors exist**

Run: `find test-roms/peterlemon -name floor.txt | sort && find test-roms/peterlemon -name floor.txt | wc -l`
Expected: six `floor.txt` files listed; count `6`.

- [ ] **Step 4: Verify compare-mode passes for the whole suite**

Run: `zig build rom-test`
Expected: all six `PL: ...` tests pass (`matches >= floor`); JaCzekanski cases unaffected.

- [ ] **Step 5: Confirm determinism — re-pin produces identical floors**

```bash
cp -r test-roms/peterlemon /tmp/pl_before
PS1_UPDATE_GOLDENS=1 zig build rom-test >/dev/null 2>&1
diff -r /tmp/pl_before test-roms/peterlemon && echo "DETERMINISTIC: floors unchanged"
```
Expected: prints `DETERMINISTIC: floors unchanged` (no diff). If floors differ run-to-run, STOP — rendering is not deterministic at the chosen cycle budget; report it before relying on the suite.

- [ ] **Step 6: Verify zig build test still self-skips ROM tests**

Run: `zig build test`
Expected: passes; PL tests self-skip (`enable_rom_tests=false`).

- [ ] **Step 7: Do NOT commit**

Leave all changes in the working tree for the user to commit.

---

## Self-Review notes

- **Spec coverage:** §1 restructure → Task 1. §2 ROM import (`.exe` + `reference.png` + ffmpeg→`reference.rgb`, no `.gitignore` edit) → Task 2. §3 harness (`runPlTest`, display-region 5-bit compare vs `reference.rgb`, per-ROM `floor.txt`, `PS1_UPDATE_GOLDENS`, determinism) → Tasks 3-4. §4 path + build description → Task 1 steps 3-5. §5 one-time pin + verification → Tasks 3-4 update/compare steps + Task 4 steps 5-6.
- **Curated set:** 6 ROMs (1 CPU, 1 hello-world sanity, 4 GPU primitives incl. textured), within the spec's "~5-8".
- **Real gold standard:** comparison target is each demo's upstream `reference.png` (via `reference.rgb`); `floor.txt` is the regression guard pinned to the measured match count, not a self-image.
- **Open risks checked, not assumed:** (a) determinism — Task 4 Step 5; (b) display-origin/timing correctness — Task 3 Step 4 flags an implausibly-low % as a concern.
- **No git:** all `git mv`/`git add`/`git commit` steps are replaced by plain `mv` and "leave in working tree"; the user commits.
