# Trace-Equivalence Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `zig build trace-golden`, a harness that hashes full PS1 machine state at fixed instruction intervals across seven fixed workloads and diffs against checked-in goldens, so the core-wide refactor can prove it changed no behaviour.

**Architecture:** A fifth frontend, `ps1-golden`, structured like the existing `ps1-trace`: a native executable that owns a `Cpu`/`*Bus`, boots a BIOS plus a disc, steps the CPU in a loop, and every N instructions folds machine state into twelve per-region 64-bit hashes. Hashing is hand-written field-by-field (never reflection) so that a refactor moving a field forces a visible update to the dump rather than silently changing what is covered. Goldens are line-oriented text, checked into git.

**Tech Stack:** Zig 0.16.0, `std.hash.Wyhash`, `std.Io.Dir`. No new dependencies. **`ps1-core` is not modified by any task in this plan.**

## Global Constraints

- Zig **0.16.0** exactly. `std.Io.Dir.cwd()`, `std.process.Init`, `std.ArrayList(T).empty`, `writeFile(io, .{ .sub_path, .data })`.
- **No file under `ps1-core/` is modified**, except adding goldens under `ps1-core/tests/goldens/trace/`. The harness reads core state from outside; all needed fields are already accessible.
- Run the harness at `-Doptimize=ReleaseFast`. A Debug core is ~0.45x real-time.
- All commands run from the **repo root**.
- `zig fmt` clean before every commit.
- Match surrounding style: inline field defaults, `init()` on structs, flat modules.
- Hashing is **hand-written per field**. `std.meta.fields` reflection is banned — it would make the check follow a refactor instead of policing it.

### Correction to the spec's figures

The spec specifies 240M instructions at a 125,000 (later 1,000,000) instruction interval. That budget is wrong: a real PS1 retires roughly 11.7M instructions/second, so 240M is about **20 seconds of console time**, and CLAUDE.md puts BIOS boot alone at ~23 seconds. No workload would reach a title screen.

This plan uses **600,000,000 instructions** (~51 emulated seconds — BIOS boot, intro, FMV, title, and the first autostart presses) at a **2,500,000-instruction interval**, giving 240 samples per workload and ~53 KB per golden. Expect ~29s per workload at ReleaseFast, ~3.5 minutes for the full seven-workload sweep. Task 9 updates the spec to match.

---

## File Structure

| File | Responsibility |
|---|---|
| `ps1-golden/src/main.zig` | CLI parsing, emulator setup, run loop, capture/verify orchestration |
| `ps1-golden/src/state_hash.zig` | `Sink` + the twelve hand-written per-region hashers |
| `ps1-golden/src/golden.zig` | Golden record format (serialize/parse), workload discovery, name sanitisation |
| `ps1-golden/src/golden_test.zig` | Unit tests for `golden.zig` and `state_hash.zig` |
| `ps1-core/tests/goldens/trace/*.txt` | The checked-in goldens (created in Task 8) |
| `build.zig` | Adds the `ps1-golden` artifact, the `trace-golden` step, and the new test |
| `CLAUDE.md` | Documents the harness (Task 9) |

---

## Task 1: Executable skeleton and build wiring

**Files:**
- Create: `ps1-golden/src/main.zig`
- Modify: `build.zig` (after the `ps1-trace` block, and after `test_step` is declared)

**Interfaces:**
- Consumes: nothing.
- Produces: a `trace-golden` build step that forwards `b.args` to the executable; `ps1-golden/src/main.zig` exporting `pub fn main(init: std.process.Init) !void`.

- [ ] **Step 1: Create the executable skeleton**

Create `ps1-golden/src/main.zig`:

```zig
const std = @import("std");

const usage =
    \\usage: ps1-golden <capture|verify> [options]
    \\
    \\  --filter=<substring>    only run workloads whose key contains this
    \\  --instructions=<n>      instructions per workload (default 600000000)
    \\  --interval=<n>          instructions between samples (default 2500000)
    \\  --bios=<path>           override the auto-selected BIOS
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var it = init.minimal.args.iterate();
    _ = it.skip();
    const mode = it.next() orelse {
        std.debug.print("{s}", .{usage});
        return error.MissingMode;
    };

    if (!std.mem.eql(u8, mode, "capture") and !std.mem.eql(u8, mode, "verify")) {
        std.debug.print("{s}", .{usage});
        return error.UnknownMode;
    }

    std.debug.print("ps1-golden: mode={s}\n", .{mode});
}
```

- [ ] **Step 2: Wire the artifact and step into build.zig**

Insert immediately after the `ps1-trace` `b.installArtifact(trace_exe);` line:

```zig
    // Trace-equivalence golden harness. The behaviour-freeze net for the core
    // refactor: hashes full machine state every N instructions across a fixed
    // set of boots and diffs against checked-in goldens. Run it ReleaseFast.
    const golden_exe = b.addExecutable(.{
        .name = "ps1-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-golden/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    golden_exe.root_module.addImport("ps1_core", core_mod);
    b.installArtifact(golden_exe);

    const golden_run = b.addRunArtifact(golden_exe);
    golden_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| golden_run.addArgs(args);
    const golden_step = b.step("trace-golden", "Capture or verify machine-state trace goldens");
    golden_step.dependOn(&golden_run.step);
```

- [ ] **Step 3: Verify it builds and runs**

Run: `zig build trace-golden -- capture`
Expected: prints `ps1-golden: mode=capture`, exit 0.

Run: `zig build trace-golden -- bogus`
Expected: prints usage, nonzero exit.

- [ ] **Step 4: Commit**

```bash
zig fmt ps1-golden/src/main.zig build.zig
git add ps1-golden/src/main.zig build.zig
git commit -m "feat(golden): scaffold ps1-golden executable and trace-golden step"
```

---

## Task 2: Golden record format

**Files:**
- Create: `ps1-golden/src/golden.zig`
- Create: `ps1-golden/src/golden_test.zig`
- Modify: `build.zig` (add the test to `test_step`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pub const region_names: [12][]const u8`
  - `pub const Sample = struct { instr: u64, hashes: [12]u64 }`
  - `pub const Golden = struct { workload: []const u8, instructions: u64, interval: u64, samples: []Sample }`
  - `pub fn serialize(allocator, g: Golden) ![]u8`
  - `pub fn parse(allocator, text: []const u8) !Golden`

- [ ] **Step 1: Write the failing tests**

Create `ps1-golden/src/golden_test.zig`:

```zig
const std = @import("std");
const golden = @import("golden.zig");

test "serialize then parse round-trips" {
    const a = std.testing.allocator;

    var samples = [_]golden.Sample{
        .{ .instr = 2_500_000, .hashes = [_]u64{1} ** 12 },
        .{ .instr = 5_000_000, .hashes = [_]u64{0xDEADBEEFCAFEF00D} ** 12 },
    };
    const g = golden.Golden{
        .workload = "croc",
        .instructions = 600_000_000,
        .interval = 2_500_000,
        .samples = &samples,
    };

    const text = try golden.serialize(a, g);
    defer a.free(text);

    const back = try golden.parse(a, text);
    defer a.free(back.samples);

    try std.testing.expectEqualStrings("croc", back.workload);
    try std.testing.expectEqual(@as(u64, 600_000_000), back.instructions);
    try std.testing.expectEqual(@as(u64, 2_500_000), back.interval);
    try std.testing.expectEqual(@as(usize, 2), back.samples.len);
    try std.testing.expectEqual(@as(u64, 5_000_000), back.samples[1].instr);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFEF00D), back.samples[1].hashes[11]);
}

test "parse rejects a row with the wrong column count" {
    const a = std.testing.allocator;
    const text =
        \\# ps1-golden v1
        \\workload croc
        \\instructions 600000000
        \\interval 2500000
        \\2500000 1 2 3
        \\
    ;
    try std.testing.expectError(error.MalformedGolden, golden.parse(a, text));
}
```

- [ ] **Step 2: Add the test to build.zig**

Insert after the `unit_test_files` loop, before the ROM-suite block:

```zig
    // Unit tests for the golden harness. It imports ps1_core for the state
    // hashers, so it needs the same module the frontends get.
    const golden_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-golden/src/golden_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    golden_test.root_module.addImport("ps1_core", core_mod);
    test_step.dependOn(&b.addRunArtifact(golden_test).step);
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `golden.zig` does not exist.

- [ ] **Step 4: Implement `golden.zig`**

Create `ps1-golden/src/golden.zig`:

```zig
const std = @import("std");

/// Column order of a golden row. Must stay in lockstep with
/// `state_hash.Region` — `state_hash.zig` has a comptime assertion for it.
pub const region_names = [_][]const u8{
    "ram",   "io",    "vram",  "cpu",
    "cdrom", "spu",   "gpu",   "dma",
    "timer", "sio",   "mdec",  "interrupt",
};

pub const region_count = region_names.len;

pub const Sample = struct {
    instr: u64,
    hashes: [region_count]u64,
};

pub const Golden = struct {
    workload: []const u8,
    instructions: u64,
    interval: u64,
    samples: []Sample,
};

pub const ParseError = error{MalformedGolden} || std.mem.Allocator.Error || std.fmt.ParseIntError;

/// Line-oriented text so goldens diff readably in git and a divergence can be
/// eyeballed without tooling. 240 samples is roughly 53 KB.
pub fn serialize(allocator: std.mem.Allocator, g: Golden) ![]u8 {
    // std.ArrayList in 0.16 is unmanaged and has no `writer()`; `print` takes
    // the allocator directly.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "# ps1-golden v1\n", .{});
    try out.print(allocator, "# columns: instr", .{});
    for (region_names) |n| try out.print(allocator, " {s}", .{n});
    try out.print(allocator, "\n", .{});
    try out.print(allocator, "workload {s}\n", .{g.workload});
    try out.print(allocator, "instructions {d}\n", .{g.instructions});
    try out.print(allocator, "interval {d}\n", .{g.interval});

    for (g.samples) |s| {
        try out.print(allocator, "{d}", .{s.instr});
        for (s.hashes) |h| try out.print(allocator, " {x:0>16}", .{h});
        try out.print(allocator, "\n", .{});
    }

    return out.toOwnedSlice(allocator);
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Golden {
    var workload: []const u8 = "";
    var instructions: u64 = 0;
    var interval: u64 = 0;

    var samples = std.ArrayList(Sample).empty;
    errdefer samples.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "workload ")) {
            workload = line["workload ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "instructions ")) {
            instructions = try std.fmt.parseInt(u64, line["instructions ".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, line, "interval ")) {
            interval = try std.fmt.parseInt(u64, line["interval ".len..], 10);
            continue;
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const instr_text = fields.next() orelse return error.MalformedGolden;
        var s = Sample{
            .instr = try std.fmt.parseInt(u64, instr_text, 10),
            .hashes = [_]u64{0} ** region_count,
        };
        var i: usize = 0;
        while (fields.next()) |tok| : (i += 1) {
            if (i >= region_count) return error.MalformedGolden;
            s.hashes[i] = try std.fmt.parseInt(u64, tok, 16);
        }
        if (i != region_count) return error.MalformedGolden;
        try samples.append(allocator, s);
    }

    return .{
        .workload = workload,
        .instructions = instructions,
        .interval = interval,
        .samples = try samples.toOwnedSlice(allocator),
    };
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS, including the two new golden tests.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-golden/src build.zig
git add ps1-golden/src/golden.zig ps1-golden/src/golden_test.zig build.zig
git commit -m "feat(golden): golden record text format with round-trip tests"
```

---

## Task 3: Workload discovery

**Files:**
- Modify: `ps1-golden/src/golden.zig`
- Modify: `ps1-golden/src/golden_test.zig`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `pub fn sanitiseKey(allocator, name: []const u8) ![]u8`
  - `pub const Workload = struct { key: []const u8, cue_path: ?[]const u8, bios_path: []const u8 }`
  - `pub fn discover(allocator, io: std.Io) ![]Workload`

The `bios-only` workload has `cue_path == null`. A directory whose cue declares more than one `FILE` is skipped with a printed reason — that is how Castlevania excludes itself, as a rule rather than a hardcoded title.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-golden/src/golden_test.zig`:

```zig
test "sanitiseKey turns a rip directory name into a stable slug" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "Crash Bandicoot (Europe) (EDC)", .want = "crash-bandicoot-europe-edc" },
        .{ .in = "TR1 (USA) (v1.1)", .want = "tr1-usa-v1-1" },
        .{ .in = "Croc - Legend of the Gobbos", .want = "croc-legend-of-the-gobbos" },
        .{ .in = "Silent Hill (USA)", .want = "silent-hill-usa" },
    };
    for (cases) |c| {
        const got = try golden.sanitiseKey(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "biosForKey picks a region-matching BIOS" {
    try std.testing.expectEqualStrings(
        "SCPH-7502_BIOS_1997_EU.bin",
        golden.biosForKey("crash-bandicoot-europe-edc"),
    );
    try std.testing.expectEqualStrings(
        "SCPH-1001_BIOS_1995_US.bin",
        golden.biosForKey("silent-hill-usa"),
    );
    try std.testing.expectEqualStrings(
        "SCPH-1001_BIOS_1995_US.bin",
        golden.biosForKey("croc-legend-of-the-gobbos"),
    );
}

test "countCueFiles counts FILE directives" {
    const single = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n";
    const multi = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"b.bin\" BINARY\n  TRACK 02 AUDIO\n";
    try std.testing.expectEqual(@as(usize, 1), golden.countCueFiles(single));
    try std.testing.expectEqual(@as(usize, 2), golden.countCueFiles(multi));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `sanitiseKey`, `biosForKey`, `countCueFiles` undefined.

- [ ] **Step 3: Implement discovery in `golden.zig`**

Append to `ps1-golden/src/golden.zig`:

```zig
pub const games_dir = "games";
pub const bios_eu = "SCPH-7502_BIOS_1997_EU.bin";
pub const bios_us = "SCPH-1001_BIOS_1995_US.bin";
pub const bios_jp = "SCPH-1000_BIOS_1994_JP.bin";

pub const Workload = struct {
    key: []const u8,
    /// null for the disc-less `bios-only` workload.
    cue_path: ?[]const u8,
    bios_path: []const u8,
};

/// "Crash Bandicoot (Europe) (EDC)" -> "crash-bandicoot-europe-edc".
/// Lowercase, every run of non-alphanumeric characters becomes one '-',
/// leading/trailing '-' trimmed. The result is the golden's filename, so it
/// must be stable for as long as the directory keeps its name.
pub fn sanitiseKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pending_dash = false;
    for (name) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_dash and out.items.len > 0) try out.append(allocator, '-');
            pending_dash = false;
            try out.append(allocator, lower);
        } else {
            pending_dash = true;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// A US BIOS in front of a PAL disc stops at the region-lock screen, which
/// wastes the whole workload. Infer the region from the rip's name.
pub fn biosForKey(key: []const u8) []const u8 {
    if (std.mem.indexOf(u8, key, "europe") != null) return bios_eu;
    if (std.mem.indexOf(u8, key, "japan") != null) return bios_jp;
    return bios_us;
}

/// Number of `FILE` directives in a cue sheet. More than one means a
/// per-track .bin layout, which `Disc.initFromCue` cannot load — it takes a
/// single data slice — so such a disc is skipped rather than silently
/// mis-loaded. See the multi-FILE follow-up in the spec.
pub fn countCueFiles(cue_text: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "FILE ")) n += 1;
    }
    return n;
}

/// Scans `games/*/` for exactly one `.cue` per directory. Always yields
/// `bios-only` first, so the harness is useful on a machine with no rips.
pub fn discover(allocator: std.mem.Allocator, io: std.Io) ![]Workload {
    var out = std.ArrayList(Workload).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, .{
        .key = try allocator.dupe(u8, "bios-only"),
        .cue_path = null,
        .bios_path = bios_us,
    });

    var dir = std.Io.Dir.cwd().openDir(io, games_dir, .{ .iterate = true }) catch {
        std.debug.print("[golden] no {s}/ directory — running bios-only\n", .{games_dir});
        return out.toOwnedSlice(allocator);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const key = try sanitiseKey(allocator, entry.name);
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ games_dir, entry.name });
        defer allocator.free(sub_path);

        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch {
            std.debug.print("[golden] skip {s}: cannot open directory\n", .{key});
            continue;
        };
        defer sub.close(io);

        var cue_name: ?[]u8 = null;
        var sub_it = sub.iterate();
        while (try sub_it.next(io)) |f| {
            if (f.kind != .file) continue;
            if (!std.ascii.endsWithIgnoreCase(f.name, ".cue")) continue;
            if (cue_name != null) {
                std.debug.print("[golden] skip {s}: more than one .cue\n", .{key});
                cue_name = null;
                break;
            }
            cue_name = try allocator.dupe(u8, f.name);
        }

        const name = cue_name orelse {
            std.debug.print("[golden] skip {s}: no .cue found\n", .{key});
            continue;
        };

        const cue_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_path, name });

        const cue_text = std.Io.Dir.cwd().readFileAlloc(io, cue_path, allocator, .limited(1 << 20)) catch {
            std.debug.print("[golden] skip {s}: cannot read cue\n", .{key});
            continue;
        };
        defer allocator.free(cue_text);

        const file_count = countCueFiles(cue_text);
        if (file_count != 1) {
            std.debug.print(
                "[golden] skip {s}: cue declares {d} FILEs; Disc.initFromCue takes one data slice\n",
                .{ key, file_count },
            );
            continue;
        }

        try out.append(allocator, .{
            .key = key,
            .cue_path = cue_path,
            .bios_path = biosForKey(key),
        });
    }

    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/golden.zig ps1-golden/src/golden_test.zig
git commit -m "feat(golden): discover games/*/*.cue workloads with region-matched BIOS"
```

---

## Task 4: Per-region state hashing

This is the task the whole harness exists for. Every field is listed by hand.

**Files:**
- Create: `ps1-golden/src/state_hash.zig`
- Modify: `ps1-golden/src/golden_test.zig`

**Interfaces:**
- Consumes: `golden.region_count`, `golden.region_names`.
- Produces:
  - `pub const Sink` with `.bytes/.int/.flag/.tag/.optByte/.final`
  - `pub fn hashAll(cpu: *const ps1.cpu.Cpu, out: *[golden.region_count]u64) void`
  - `pub fn hashStatic(bus: *const ps1.memory.Bus) u64`

- [ ] **Step 1: Write the failing tests**

Append to `ps1-golden/src/golden_test.zig`:

```zig
const ps1 = @import("ps1_core");
const state_hash = @import("state_hash.zig");

test "two freshly initialised machines hash identically" {
    const a = std.testing.allocator;

    const bus_a = try ps1.memory.Bus.init(a);
    defer bus_a.deinit(a);
    const bus_b = try ps1.memory.Bus.init(a);
    defer bus_b.deinit(a);

    var cpu_a = ps1.cpu.Cpu.init(bus_a);
    var cpu_b = ps1.cpu.Cpu.init(bus_b);

    var ha: [golden.region_count]u64 = undefined;
    var hb: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu_a, &ha);
    state_hash.hashAll(&cpu_b, &hb);

    try std.testing.expectEqualSlices(u64, &ha, &hb);
}

test "a RAM byte change moves only the ram region" {
    const a = std.testing.allocator;
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);

    var before: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu, &before);

    bus.ram[0x1234] ^= 0xFF;

    var after: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu, &after);

    for (before, after, 0..) |b, af, i| {
        if (i == @intFromEnum(state_hash.Region.ram)) {
            try std.testing.expect(b != af);
        } else {
            try std.testing.expectEqual(b, af);
        }
    }
}

test "a CDROM register change moves only the cdrom region" {
    const a = std.testing.allocator;
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);

    var before: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu, &before);

    bus.cdrom.mode ^= 0x20;

    var after: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu, &after);

    for (before, after, 0..) |b, af, i| {
        if (i == @intFromEnum(state_hash.Region.cdrom)) {
            try std.testing.expect(b != af);
        } else {
            try std.testing.expectEqual(b, af);
        }
    }
}

test "a queued CDROM interrupt delay moves the cdrom region" {
    const a = std.testing.allocator;
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);

    var before: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu, &before);

    bus.cdrom.irq_queue.items[0].delay = 1234;

    var after: [golden.region_count]u64 = undefined;
    state_hash.hashAll(&cpu, &after);

    try std.testing.expect(
        before[@intFromEnum(state_hash.Region.cdrom)] !=
            after[@intFromEnum(state_hash.Region.cdrom)],
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `state_hash.zig` does not exist.

- [ ] **Step 3: Implement `state_hash.zig`**

Create `ps1-golden/src/state_hash.zig`:

```zig
const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;

/// Column order of a golden row. Kept in lockstep with `golden.region_names`
/// by the comptime check below.
pub const Region = enum(u8) {
    ram,
    io,
    vram,
    cpu,
    cdrom,
    spu,
    gpu,
    dma,
    timer,
    sio,
    mdec,
    interrupt,
};

comptime {
    const fields = @typeInfo(Region).@"enum".fields;
    if (fields.len != golden.region_count) @compileError("Region/region_names length mismatch");
    for (fields, golden.region_names) |f, n| {
        if (!std.mem.eql(u8, f.name, n)) @compileError("Region/region_names order mismatch: " ++ f.name);
    }
}

/// Every integer is widened to 64 bits before hashing, so a refactor that
/// changes a field's width (u8 -> u16, usize -> u32) does not by itself move a
/// hash. Width changes are a legitimate part of this refactor; value changes
/// are not.
pub const Sink = struct {
    w: std.hash.Wyhash,

    pub fn init() Sink {
        return .{ .w = std.hash.Wyhash.init(0) };
    }

    pub fn bytes(self: *Sink, b: []const u8) void {
        self.w.update(b);
    }

    pub fn int(self: *Sink, v: anytype) void {
        const info = @typeInfo(@TypeOf(v)).int;
        if (info.signedness == .signed) {
            const wide = std.mem.nativeToLittle(i64, @as(i64, v));
            self.w.update(std.mem.asBytes(&wide));
        } else {
            const wide = std.mem.nativeToLittle(u64, @as(u64, v));
            self.w.update(std.mem.asBytes(&wide));
        }
    }

    pub fn flag(self: *Sink, v: bool) void {
        self.int(@as(u8, if (v) 1 else 0));
    }

    pub fn tag(self: *Sink, v: anytype) void {
        self.int(@as(u32, @intFromEnum(v)));
    }

    pub fn optByte(self: *Sink, v: ?u8) void {
        self.flag(v != null);
        self.int(v orelse 0);
    }

    pub fn final(self: *Sink) u64 {
        return self.w.final();
    }
};

pub fn hashAll(cpu: *const Cpu, out: *[golden.region_count]u64) void {
    const bus = cpu.bus;
    out[@intFromEnum(Region.ram)] = hashRam(bus);
    out[@intFromEnum(Region.io)] = hashIo(bus);
    out[@intFromEnum(Region.vram)] = hashVram(bus);
    out[@intFromEnum(Region.cpu)] = hashCpu(cpu);
    out[@intFromEnum(Region.cdrom)] = hashCdrom(bus);
    out[@intFromEnum(Region.spu)] = hashSpu(bus);
    out[@intFromEnum(Region.gpu)] = hashGpu(bus);
    out[@intFromEnum(Region.dma)] = hashDma(bus);
    out[@intFromEnum(Region.timer)] = hashTimers(bus);
    out[@intFromEnum(Region.sio)] = hashSio(bus);
    out[@intFromEnum(Region.mdec)] = hashMdec(bus);
    out[@intFromEnum(Region.interrupt)] = hashInterrupt(bus);
}

/// Regions that no workload writes but a refactor could still corrupt. Hashing
/// 10 MB of expansion space 240 times per workload would dominate runtime for
/// no benefit, so these are checked once at start and once at end of a run.
pub fn hashStatic(bus: *const Bus) u64 {
    var s = Sink.init();
    s.bytes(&bus.bios);
    s.bytes(&bus.expansion_1);
    s.bytes(&bus.expansion_2);
    s.bytes(&bus.expansion_3);
    s.int(bus.expansion_3_last_write_width);
    return s.final();
}

fn hashRam(bus: *const Bus) u64 {
    var s = Sink.init();
    s.bytes(&bus.ram);
    s.int(bus.sys_clock);
    s.int(bus.wait_cycles);
    return s.final();
}

fn hashIo(bus: *const Bus) u64 {
    var s = Sink.init();
    s.bytes(&bus.scratchpad);
    s.bytes(&bus.io_ports);
    s.bytes(&bus.cache_control);
    return s.final();
}

fn hashVram(bus: *const Bus) u64 {
    const v = &bus.gpu.vram;
    var s = Sink.init();
    s.bytes(std.mem.asBytes(&v.data));
    s.flag(v.write_active);
    s.int(v.write_x);
    s.int(v.write_y);
    s.int(v.write_w);
    s.int(v.write_h);
    s.int(v.write_curr_x);
    s.int(v.write_curr_y);
    s.int(v.write_remaining);
    s.flag(v.read_active);
    s.int(v.read_x);
    s.int(v.read_y);
    s.int(v.read_w);
    s.int(v.read_h);
    s.int(v.read_curr_x);
    s.int(v.read_curr_y);
    s.int(v.read_remaining);
    return s.final();
}

/// Excludes `bus`, `tty_context` and `tty_write_fn`: host pointers whose values
/// vary between runs and carry no emulated state.
fn hashCpu(cpu: *const Cpu) u64 {
    var s = Sink.init();
    for (cpu.regs) |r| s.int(r);
    s.int(cpu.pc);
    s.int(cpu.next_pc);
    s.int(cpu.current_pc);
    s.flag(cpu.is_delay_slot);
    s.flag(cpu.next_is_delay_slot);
    s.int(cpu.load_r);
    s.int(cpu.load_v);
    s.int(cpu.delay_r);
    s.int(cpu.delay_v);
    s.int(cpu.hi);
    s.int(cpu.lo);
    s.int(cpu.cycles);
    s.int(cpu.gpu_clock_frac);
    for (cpu.cop0.regs) |r| s.int(r);
    for (cpu.cop2.data_regs) |r| s.int(r);
    for (cpu.cop2.ctrl_regs) |r| s.int(r);
    for (cpu.cop2.macs) |m| s.int(m);
    for (cpu.icache) |line| {
        s.int(line.tag);
        for (line.data) |wd| s.int(wd);
    }
    return s.final();
}

/// Excludes `debug_enable` (a host logging toggle) and `disc` (holds a slice
/// into a heap buffer whose address varies per run; the disc is read-only
/// input, identical for every run of a workload).
fn hashCdrom(bus: *const Bus) u64 {
    const cd = &bus.cdrom;
    var s = Sink.init();
    s.int(cd.index);
    s.int(cd.irq_enable);
    s.bytes(&cd.parameter_fifo);
    s.int(cd.parameter_len);
    s.int(cd.last_response_byte);
    s.bytes(&cd.last_raw_sector);
    s.bytes(&cd.sector_buffer);
    s.int(cd.sector_buffer_ptr);
    s.int(cd.sector_buffer_len);
    s.flag(cd.data_fifo_empty);
    s.int(cd.status);
    s.int(cd.mode);
    s.int(cd.seek_target.m);
    s.int(cd.seek_target.s);
    s.int(cd.seek_target.f);
    s.int(cd.current_pos.m);
    s.int(cd.current_pos.s);
    s.int(cd.current_pos.f);
    s.flag(cd.is_reading);
    s.int(cd.busy_for);
    s.flag(cd.loc_l_valid);
    s.flag(cd.muted);
    s.bytes(&cd.last_sector_header);
    s.bytes(&cd.last_subchannel_q);
    s.int(cd.xa_adpcm_filter);
    s.int(cd.xa_filter_file);
    s.int(cd.xa_filter_channel);
    s.int(cd.volume_ll);
    s.int(cd.volume_lr);
    s.int(cd.volume_rl);
    s.int(cd.volume_rr);
    s.optByte(cd.pending_command);
    s.int(cd.pending_command_delay);
    s.bytes(std.mem.asBytes(&cd.audio_fifo_l));
    s.bytes(std.mem.asBytes(&cd.audio_fifo_r));
    s.int(cd.audio_fifo_read);
    s.int(cd.audio_fifo_write);
    s.flag(cd.autoreport_is_absolute);
    s.int(cd.audio_tick_counter);
    s.int(cd.xa_old_l);
    s.int(cd.xa_older_l);
    s.int(cd.xa_old_r);
    s.int(cd.xa_older_r);
    for (&cd.xa_ringbuf) |*ring| s.bytes(std.mem.asBytes(ring));
    for (cd.xa_ring_p) |p| s.int(p);
    for (cd.xa_sixstep) |v| s.int(v);
    s.tag(cd.drive_state);
    s.int(cd.sector_timer);
    s.int(cd.seek_timer);
    s.flag(cd.read_after_seek);

    const q = &cd.irq_queue;
    s.int(q.head);
    s.int(q.tail);
    s.int(q.count);
    s.int(q.overflow_count);
    for (&q.items) |*item| {
        s.int(item.irq);
        s.bytes(&item.response);
        s.int(item.response_len);
        s.int(item.response_ptr);
        s.int(item.delay);
        s.flag(item.ack);
        s.flag(item.triggered);
        s.tag(item.action);
        s.flag(item.auto_status);
    }

    s.flag(cd.irq_line);
    s.int(cd.sectors_delivered);
    return s.final();
}

/// Excludes `reverb_enable`: a host isolation switch with no setter, constant
/// for the lifetime of a run.
fn hashSpu(bus: *const Bus) u64 {
    const spu = &bus.spu;
    var s = Sink.init();
    s.bytes(&spu.sram);
    s.int(spu.main_vol_l);
    s.int(spu.main_vol_r);
    s.int(spu.reverb_vol_l);
    s.int(spu.reverb_vol_r);
    s.int(spu.spu_cnt);
    s.int(spu.spu_stat);
    s.int(spu.sram_addr);
    s.int(spu.sram_read_buffer);
    s.int(spu.dtc);
    s.int(spu.pmon);
    s.int(spu.non);
    s.int(spu.von);
    s.int(spu.noise_timer);
    s.int(spu.noise_lfsr);
    s.int(spu.noise_level);
    s.int(spu.cd_vol_l);
    s.int(spu.cd_vol_r);
    s.int(spu.ext_vol_l);
    s.int(spu.ext_vol_r);
    s.int(spu.current_cd_l);
    s.int(spu.current_cd_r);
    s.int(spu.current_ext_l);
    s.int(spu.current_ext_r);
    s.int(spu.irq_addr);
    s.flag(spu.irq_flag);
    s.bytes(std.mem.asBytes(&spu.reverb_regs));
    s.int(spu.reverb_base);
    s.int(spu.reverb_curr_addr);
    s.int(spu.reverb_counter);
    s.int(spu.reverb_out_l);
    s.int(spu.reverb_out_r);
    for (&spu.voices) |*v| {
        s.int(v.vol_l);
        s.int(v.vol_r);
        s.int(v.pitch);
        s.int(v.start_addr);
        s.int(v.adsr1);
        s.int(v.adsr2);
        s.int(v.adsr_vol);
        s.int(v.loop_addr);
        s.int(v.current_addr);
        s.int(v.current_fraction);
        s.int(v.adpcm_old);
        s.int(v.adpcm_older);
        s.bytes(std.mem.asBytes(&v.decoded_buffer));
        s.bytes(std.mem.asBytes(&v.history));
        s.int(v.buffer_index);
        s.flag(v.is_on);
        s.flag(v.ignore_samples);
        s.flag(v.has_reached_endx);
        s.tag(v.adsr_state);
        s.int(v.current_ad_vol);
        s.int(v.adsr_cycles);
    }
    // The emitted audio itself. f32 bit patterns are deterministic for the
    // same arithmetic on the same target.
    s.bytes(std.mem.asBytes(&spu.output_buffer));
    s.int(spu.write_idx);
    s.int(spu.read_idx);
    s.int(spu.cycle_accumulator);
    return s.final();
}

/// VRAM lives in its own region, so this is the GPU's register and FIFO state.
fn hashGpu(bus: *const Bus) u64 {
    const g = &bus.gpu;
    var s = Sink.init();
    s.int(g.draw_env.draw_mode);
    s.int(g.draw_env.tex_window);
    s.int(g.draw_env.area_top_left);
    s.int(g.draw_env.area_bot_right);
    s.int(g.draw_env.offset);
    s.int(g.draw_env.mask_bit);
    s.flag(g.draw_env.texture_disable_allowed);
    s.int(g.disp_env.vram_x_start);
    s.int(g.disp_env.vram_y_start);
    s.int(g.disp_env.screen_x1);
    s.int(g.disp_env.screen_x2);
    s.int(g.disp_env.screen_y1);
    s.int(g.disp_env.screen_y2);
    s.int(g.disp_env.display_mode);
    s.flag(g.disp_env.display_disabled);
    for (g.gp0.cmd_buffer) |wd| s.int(wd);
    s.int(g.gp0.words_remaining);
    s.int(g.gp0.words_read);
    s.flag(g.gp0.polyline_active);
    s.flag(g.gp0.polyline_shaded);
    s.int(g.gp0.polyline_count);
    s.flag(g.gp0.polyline_transparent);
    s.int(g.gp0.polyline_prev_x);
    s.int(g.gp0.polyline_prev_y);
    s.int(g.gp0.polyline_prev_color);
    s.int(g.gp0.polyline_next_color);
    s.tag(g.gpu_read_mode);
    s.int(g.gpu_read_data);
    s.int(g.dma_direction);
    s.flag(g.interrupt_flag);
    s.flag(g.is_vblank);
    s.flag(g.is_ntsc);
    s.int(g.h_count);
    s.int(g.v_count);
    s.int(g.dotclock_count);
    s.flag(g.prev_interrupt_flag);
    s.flag(g.is_even_field);
    for (g.fifo) |wd| s.int(wd);
    s.int(g.fifo_head);
    s.int(g.fifo_tail);
    s.int(g.fifo_count);
    s.int(g.cycle_debt);
    return s.final();
}

fn hashDma(bus: *const Bus) u64 {
    const d = &bus.dma;
    var s = Sink.init();
    s.int(d.dpcr);
    s.int(d.dicr);
    for (&d.channels) |*c| {
        s.int(c.base_addr);
        s.int(c.block_control);
        s.int(c.control);
        s.flag(c.transfer_active);
        s.int(c.words_remaining);
        s.int(c.linked_list_next);
        s.int(c.chop_dma_window);
        s.int(c.chop_cpu_window);
        s.flag(c.chop_is_cpu_turn);
        s.int(c.chop_counter);
        s.int(c.block_words);
        s.int(c.block_word_progress);
        s.int(c.block_cycles);
        s.int(c.block_gap_counter);
    }
    return s.final();
}

fn hashTimers(bus: *const Bus) u64 {
    var s = Sink.init();
    for (&bus.timers) |*t| {
        s.int(t.counter);
        s.int(t.mode);
        s.int(t.target);
        s.int(t.prescale_counter);
    }
    return s.final();
}

fn hashSio(bus: *const Bus) u64 {
    const io = &bus.sio;
    var s = Sink.init();
    s.int(io.stat);
    s.int(io.mode);
    s.int(io.ctrl);
    s.int(io.baud);
    s.int(io.rx_data);
    s.tag(io.ctrl_state);
    s.flag(io.ack);
    s.flag(io.irq);
    s.int(io.irq_timer);
    s.int(io.buttons);
    s.flag(io.analog_enabled);
    s.int(io.joy_rx);
    s.int(io.joy_ry);
    s.int(io.joy_lx);
    s.int(io.joy_ly);
    s.int(io.motor_right_small);
    s.int(io.motor_left_large);
    s.bytes(&io.memcard_data);
    s.int(io.memcard_address);
    s.int(io.memcard_checksum);
    s.int(io.memcard_step);
    s.flag(io.memcard_is_write);
    s.flag(io.memcard_dirty);
    return s.final();
}

fn hashMdec(bus: *const Bus) u64 {
    const m = &bus.mdec;
    var s = Sink.init();
    s.int(m.status);
    s.bytes(&m.quant_luminance);
    s.bytes(&m.quant_color);
    s.bytes(std.mem.asBytes(&m.scale_table));
    s.int(m.current_cmd);
    s.int(m.words_remaining);
    s.bytes(std.mem.asBytes(&m.input_fifo));
    s.int(m.input_len);
    for (&m.y_blocks) |*blk| s.bytes(std.mem.asBytes(blk));
    s.bytes(std.mem.asBytes(&m.cb_block));
    s.bytes(std.mem.asBytes(&m.cr_block));
    s.bytes(std.mem.asBytes(&m.output_fifo));
    s.int(m.output_ptr);
    s.int(m.output_len);
    s.int(m.output_depth);
    s.flag(m.output_set_bit15);
    return s.final();
}

fn hashInterrupt(bus: *const Bus) u64 {
    var s = Sink.init();
    s.int(bus.interrupts.stat);
    s.int(bus.interrupts.mask);
    return s.final();
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS — all four state-hash tests plus the earlier golden tests.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/state_hash.zig ps1-golden/src/golden_test.zig
git commit -m "feat(golden): hand-written per-region machine state hashing"
```

---

## Task 5: Capture mode

**Files:**
- Modify: `ps1-golden/src/main.zig`

**Interfaces:**
- Consumes: `golden.discover`, `golden.serialize`, `golden.Workload`, `state_hash.hashAll`, `state_hash.hashStatic`.
- Produces: `fn runWorkload(...) !RunResult` where `RunResult = struct { samples: []golden.Sample, static_before: u64, static_after: u64 }`; a `capture` mode that writes `ps1-core/tests/goldens/trace/<key>.txt`.

- [ ] **Step 1: Create the goldens directory**

```bash
mkdir -p ps1-core/tests/goldens/trace
```

- [ ] **Step 2: Replace `ps1-golden/src/main.zig` with the full harness**

```zig
const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");

const default_instructions: u64 = 600_000_000;
const default_interval: u64 = 2_500_000;
const goldens_dir = "ps1-core/tests/goldens/trace";

const usage =
    \\usage: ps1-golden <capture|verify> [options]
    \\
    \\  --filter=<substring>    only run workloads whose key contains this
    \\  --instructions=<n>      instructions per workload (default 600000000)
    \\  --interval=<n>          instructions between samples (default 2500000)
    \\  --bios=<path>           override the auto-selected BIOS
    \\
;

const Options = struct {
    capture: bool,
    filter: ?[]const u8 = null,
    instructions: u64 = default_instructions,
    interval: u64 = default_interval,
    bios_override: ?[]const u8 = null,
};

const RunResult = struct {
    samples: []golden.Sample,
    static_before: u64,
    static_after: u64,
};

/// The same deterministic button script ps1-trace uses: Start, Cross, Circle in
/// rotation so intros, FMVs and title menus are walked past. Driven off the
/// instruction counter, never a wall clock.
const press_period: u64 = 4_000_000;
const press_hold: u64 = 1_000_000;
const released: u16 = 0xFFFF;
const press_seq = [_]u16{
    released & ~@as(u16, 1 << 3), // Start
    released & ~@as(u16, 1 << 14), // Cross
    released & ~@as(u16, 1 << 13), // Circle
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const opts = parseArgs(init) catch {
        std.debug.print("{s}", .{usage});
        return error.BadArguments;
    };

    const workloads = try golden.discover(a, init.io);

    var failures: usize = 0;
    var ran: usize = 0;

    for (workloads) |wl| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, wl.key, f) == null) continue;
        }
        ran += 1;

        const bios_path = opts.bios_override orelse wl.bios_path;
        const result = runWorkload(a, init.io, wl, bios_path, opts) catch |err| {
            std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
            failures += 1;
            continue;
        };

        if (opts.capture) {
            try writeGolden(a, init.io, wl.key, opts, result);
            std.debug.print("  {s: <22} {d}M instr  {d} hashes   CAPTURED\n", .{
                wl.key, opts.instructions / 1_000_000, result.samples.len,
            });
        } else {
            if (try verifyGolden(a, init.io, wl.key, opts, result)) failures += 1;
        }
    }

    if (ran == 0) {
        std.debug.print("no workloads matched\n", .{});
        return error.NoWorkloads;
    }
    if (failures != 0) {
        std.debug.print("\n{d} workload(s) diverged\n", .{failures});
        return error.TraceDivergence;
    }
}

fn parseArgs(init: std.process.Init) !Options {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const mode = it.next() orelse return error.MissingMode;

    var opts = Options{ .capture = std.mem.eql(u8, mode, "capture") };
    if (!opts.capture and !std.mem.eql(u8, mode, "verify")) return error.UnknownMode;

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--instructions=")) {
            opts.instructions = try std.fmt.parseInt(u64, arg["--instructions=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--interval=")) {
            opts.interval = try std.fmt.parseInt(u64, arg["--interval=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--bios=")) {
            opts.bios_override = arg["--bios=".len..];
        } else {
            return error.UnknownOption;
        }
    }
    if (opts.interval == 0) return error.BadArguments;
    return opts;
}

fn runWorkload(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !RunResult {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);

    const bios = try std.Io.Dir.cwd().readFileAlloc(io, bios_path, a, .limited(1 << 20));
    defer a.free(bios);
    if (bios.len != 512 * 1024) return error.BadBiosSize;
    @memcpy(bus.bios[0..], bios);

    if (wl.cue_path) |cue_path| {
        const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1 << 20));
        const bin_path = try std.fmt.allocPrint(a, "{s}.bin", .{cue_path[0 .. cue_path.len - 4]});
        const bin_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, a, .limited(900 * 1024 * 1024));
        bus.cdrom.setDisc(ps1.disc.Disc.initFromCue(cue_text, bin_bytes));
    }

    const static_before = state_hash.hashStatic(bus);

    var samples = std.ArrayList(golden.Sample).empty;
    var press_idx: usize = 0;
    var i: u64 = 0;
    while (i < opts.instructions) : (i += 1) {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[press_idx]);
            press_idx = (press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();

        if ((i + 1) % opts.interval == 0) {
            var s = golden.Sample{ .instr = i + 1, .hashes = undefined };
            state_hash.hashAll(&cpu, &s.hashes);
            try samples.append(a, s);
        }
    }

    return .{
        .samples = try samples.toOwnedSlice(a),
        .static_before = static_before,
        .static_after = state_hash.hashStatic(bus),
    };
}

fn goldenPath(a: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.txt", .{ goldens_dir, key });
}

fn writeGolden(
    a: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    opts: Options,
    result: RunResult,
) !void {
    if (result.static_before != result.static_after) {
        std.debug.print(
            "  {s: <22} WARNING: BIOS/expansion memory changed during the run\n",
            .{key},
        );
    }
    const text = try golden.serialize(a, .{
        .workload = key,
        .instructions = opts.instructions,
        .interval = opts.interval,
        .samples = result.samples,
    });
    defer a.free(text);
    const path = try goldenPath(a, key);
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Replaced wholesale in Task 6. Present now only so `main` compiles.
fn verifyGolden(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    _: Options,
    _: RunResult,
) !bool {
    return false;
}
```

- [ ] **Step 3: Verify capture runs on the disc-less workload**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- capture --filter=bios-only --instructions=10000000 --interval=1000000`
Expected: prints `bios-only  10M instr  10 hashes  CAPTURED`; `ps1-core/tests/goldens/trace/bios-only.txt` exists with 10 sample rows and hex hashes that are not all identical.

The `verifyGolden` stub at the end of the file exists only so `main` compiles; Task 6 replaces it with the real implementation.

- [ ] **Step 4: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/main.zig
git commit -m "feat(golden): capture mode with deterministic autostart input"
```

---

## Task 6: Verify mode and divergence reporting

**Files:**
- Modify: `ps1-golden/src/main.zig`

**Interfaces:**
- Consumes: `golden.parse`, `golden.region_names`, `RunResult`.
- Produces: `fn verifyGolden(a, io, key, opts, result) !bool` — returns `true` when the workload diverged.

- [ ] **Step 1: Implement `verifyGolden`**

Append to `ps1-golden/src/main.zig` (replacing the Task 5 stub if one was added):

```zig
/// Returns true when the workload diverged. Reports the first differing sample
/// and every region that moved in it — "first diff: cdrom" is the whole
/// debugging session, which is why regions are hashed separately.
fn verifyGolden(
    a: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    opts: Options,
    result: RunResult,
) !bool {
    const path = try goldenPath(a, key);
    defer a.free(path);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 << 20)) catch {
        std.debug.print("  {s: <22} NO GOLDEN — run `capture` first\n", .{key});
        return true;
    };
    defer a.free(text);

    const want = try golden.parse(a, text);
    defer a.free(want.samples);

    if (want.instructions != opts.instructions or want.interval != opts.interval) {
        std.debug.print(
            "  {s: <22} SKIP: golden is {d} instr @ {d}, run is {d} @ {d}\n",
            .{ key, want.instructions, want.interval, opts.instructions, opts.interval },
        );
        return true;
    }

    if (want.samples.len != result.samples.len) {
        std.debug.print(
            "  {s: <22} FAIL: {d} samples, golden has {d}\n",
            .{ key, result.samples.len, want.samples.len },
        );
        return true;
    }

    for (want.samples, result.samples) |exp, got| {
        if (std.mem.eql(u64, &exp.hashes, &got.hashes)) continue;

        std.debug.print("  {s: <22} {d}M instr   {d} hashes   FAIL @ instr {d}\n", .{
            key, opts.instructions / 1_000_000, result.samples.len, got.instr,
        });
        for (exp.hashes, got.hashes, golden.region_names) |e, g, name| {
            if (e != g) {
                std.debug.print("                         first diff: {s} (want {x:0>16}, got {x:0>16})\n", .{ name, e, g });
            }
        }
        return true;
    }

    std.debug.print("  {s: <22} {d}M instr   {d} hashes   OK\n", .{
        key, opts.instructions / 1_000_000, result.samples.len,
    });
    return false;
}
```

- [ ] **Step 2: Verify a matching run passes**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=bios-only --instructions=10000000 --interval=1000000`
Expected: `bios-only  10M instr  10 hashes  OK`, exit 0.

- [ ] **Step 3: Verify a mismatched budget is rejected rather than silently passing**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=bios-only --instructions=20000000 --interval=1000000`
Expected: prints `SKIP: golden is 10000000 instr @ 1000000, run is 20000000 @ 1000000`, nonzero exit.

- [ ] **Step 4: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/main.zig
git commit -m "feat(golden): verify mode reporting first divergent sample and region"
```

---

## Task 7: Validate the verifier with an injected bug

A verifier that has never failed is not known to work. This task deliberately breaks behaviour, confirms detection, then reverts. **Nothing is committed from the broken state.**

**Files:**
- Temporarily modify: `ps1-core/src/cdrom.zig` (reverted within this task)

- [ ] **Step 1: Capture a short bios-only golden as the baseline**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- capture --filter=bios-only --instructions=60000000 --interval=2500000`
Expected: 24 samples captured.

- [ ] **Step 2: Confirm it verifies clean**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=bios-only --instructions=60000000 --interval=2500000`
Expected: `OK`, exit 0.

- [ ] **Step 3: Inject a one-value behaviour change**

In `ps1-core/src/cdrom.zig`, find the `ack_delay` constant (currently `50000`, near line 595) and change it to `49999`.

- [ ] **Step 4: Confirm the verifier catches it and names cdrom**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=bios-only --instructions=60000000 --interval=2500000`
Expected: `FAIL @ instr <n>` with at least one `first diff:` line. Exit nonzero.

If it reports OK, the harness is not covering CDROM state during a disc-less boot. In that case re-run this step against a disc workload (`--filter=croc`) before concluding the harness works; a bios-only boot may never exercise the CD ack path.

- [ ] **Step 5: Revert the injected bug**

```bash
git checkout ps1-core/src/cdrom.zig
git diff --stat ps1-core/
```
Expected: no output from `git diff --stat` — `ps1-core/src` is untouched.

- [ ] **Step 6: Confirm clean again**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=bios-only --instructions=60000000 --interval=2500000`
Expected: `OK`, exit 0.

- [ ] **Step 7: Record the result**

No commit for this task — it produces evidence, not code. Note in the Task 8 commit message that the injected-bug check passed.

---

## Task 8: Capture the real goldens

**Files:**
- Create: `ps1-core/tests/goldens/trace/*.txt` (7 files, or fewer if discs are missing)

- [ ] **Step 1: Confirm the workload set**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify --filter=__none__`
Expected: the discovery warnings print, including `skip castlevania-symphony-of-the-night: cue declares 2 FILEs; Disc.initFromCue takes one data slice`, then `no workloads matched`.

- [ ] **Step 2: Capture the full set at production settings**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- capture`
Expected: seven `CAPTURED` lines (bios-only plus six discs), roughly 3–4 minutes total.

- [ ] **Step 3: Sanity-check the goldens are not degenerate**

```bash
wc -l ps1-core/tests/goldens/trace/*.txt
sort -u -k2,2 ps1-core/tests/goldens/trace/croc.txt | wc -l
```
Expected: 244 lines each (4 header + 240 samples). The second command must print well over 1 — identical hashes on every row would mean the machine is frozen and the golden is worthless.

- [ ] **Step 4: Verify the captured goldens reproduce**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify`
Expected: all seven `OK`, exit 0. **A failure here means the emulator is not deterministic** — stop and investigate before proceeding; the whole refactor depends on this property.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/tests/goldens/trace
git commit -m "test(golden): capture trace goldens for bios-only and six discs

Injected-bug check passed: changing cdrom ack_delay 50000 -> 49999 is
detected and attributed to the cdrom region.

Castlevania is skipped by rule, not by name: its cue declares two FILE
directives and Disc.initFromCue takes a single data slice."
```

---

## Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-08-08-core-structural-refactor-design.md`

- [ ] **Step 1: Add a harness section to CLAUDE.md**

Add a row to the Quick commands table:

```markdown
| `zig build trace-golden -- verify` | Machine-state trace equivalence check against `ps1-core/tests/goldens/trace/`. The behaviour-freeze net for refactors. Run it `-Doptimize=ReleaseFast`. |
```

And a section after "Architecture: the CPU is the master clock":

```markdown
## The trace-equivalence harness

`ps1-golden` (a fifth frontend) boots the BIOS plus each disc in `games/` for
600M instructions and hashes full machine state into twelve per-region 64-bit
hashes every 2.5M instructions, diffing against checked-in goldens.

- `zig build trace-golden -- capture` rewrites the goldens. **Only do this when
  an intentional behaviour change lands**, as its own commit, with the diff
  explained in the message.
- `zig build trace-golden -- verify` is the gate. `--filter=<substring>` narrows
  to one workload; `--interval=<n>` tightens sampling to localise a divergence.
- **State dumps in `state_hash.zig` are written by hand, never by reflection.**
  Reflection would make the check follow a refactor instead of policing it. When
  a field moves, update the dump in the same commit — the hashes must still match.
- Excluded on purpose, all documented in-file: host pointers (`cpu.bus`,
  `tty_write_fn`), host toggles (`cdrom.debug_enable`, `spu.reverb_enable`), and
  `cdrom.disc` (a slice whose address varies per run). BIOS and expansion RAM
  are hashed once at start and end rather than per sample.
- Castlevania is skipped by rule: its cue declares two `FILE` directives and
  `Disc.initFromCue` takes a single data slice.
```

- [ ] **Step 2: Correct the spec's instruction budget and flag names**

In `docs/superpowers/specs/2026-08-08-core-structural-refactor-design.md`, make three corrections:

1. Replace every `240M instr` / `240,000,000` with `600M` / `600,000,000`, and `1,000,000`-interval with `2,500,000`. Add the reason inline: *240M instructions is only ~20 seconds of console time at the ~11.7M instr/s a real PS1 retires, against a ~23-second BIOS boot — no workload would reach a title screen.* Sample count per workload stays 240.
2. Replace `-Dtrace-filter=<substring>` and `-Dtrace-samples=<n>` with the runtime flags `--filter=<substring>` and `--interval=<n>`. They are executable arguments, not build options, so changing them does not force a rebuild. (`-Drom-filter` must be a build option because it filters *tests*; this does not.)
3. Add `bios-only` BIOS selection to the workload table note: the harness picks a region-matching BIOS from the rip's name (`(Europe)` → `SCPH-7502`, `(Japan)` → `SCPH-1000`, otherwise `SCPH-1001`), because a US BIOS in front of a PAL disc stops at the region-lock screen and wastes the workload.

- [ ] **Step 3: Verify the full gate is green**

```bash
zig build
zig build test
zig build test-roms-ja -Doptimize=ReleaseFast
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```
Expected: all build; unit tests pass; JA at 12/17 with the same five red; PL green; all seven trace workloads OK.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-08-08-core-structural-refactor-design.md
git commit -m "docs: document the trace-equivalence harness and fix the instruction budget"
```

---

## Definition of done

1. `zig build trace-golden -- capture` and `-- verify` both work, at production settings.
2. Seven goldens committed under `ps1-core/tests/goldens/trace/` (or fewer, with a printed reason per skip).
3. The injected-bug check demonstrably fails and attributes the region.
4. `git diff --stat ps1-core/src` is empty — **no core file was modified**.
5. `zig build test` passes, including the new `golden_test.zig`.
6. `zig build`, `test-roms-ja` (12/17, same five), `test-roms-pl` all unchanged.
7. CLAUDE.md documents the harness; the spec's instruction budget is corrected.
8. `zig fmt` clean.

## What comes next

With goldens captured, write the P1–P8 refactor plan against the real code. That plan's per-phase field groupings (notably how `CdRom`'s 51 fields split across `cdrom/{cdrom,commands,fifo,xa,cdda}.zig`) should be decided with the harness available to validate them, not guessed in advance.
