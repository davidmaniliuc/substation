# CPU recompiler, Plan 7: the app. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the block engines in front of the player: a C ABI to choose the
CPU engine, a Settings picker that persists the choice, the Recompiler as the
shipped default once it has been smoke-tested in the app, a wider speed range
where the measurement shows the headroom, and a battery measurement.

**Architecture:** The engine is a HOST setting, like `pgxp_*`: the C ABI
handle remembers the chosen engine and re-applies it to every `Bus` it
rebuilds (`ps1_reset`, `ps1_load_state`), because a fresh `Bus` comes up on
the interpreter. `ps1_run_frame` switches from `Cpu.run()` to
`Cpu.runFor(maxInt)` so `.jit` chains its linked blocks in the app as it
does in `ps1-bench`. In Swift the choice is a `PersistedChoice` like
`DitherSetting`, crosses to the emulator thread through an `Atomic` like the
PGXP vertex cache (applied on change only), and is set on the core before a
resume state loads.

**Tech Stack:** Zig 0.17.0 (`ps1-capi`), C (`ps1.h`), Swift 6 / SwiftUI
(`ps1-macos`), xcodebuild, `ps1-bench`, `powermetrics`.

**Spec:** `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`.
Before starting, read "Frontends, savestates and the app" (all four
subsections), "As built (Plan 3)" item 5 (the FF7 memory-card checks that
moved here), and "As built (Plan 6)" → the bench table. Then read
`ps1-capi/src/root.zig` (`Handle`, `buildMachine`, `installHost`,
`HostSettings`, `ps1_reset`, `ps1_load_state`, `ps1_run_frame`),
`ps1-core/src/recompiler/run.zig` (`Engine`, `setEngine`, `engineOf`) and
`ps1-core/src/cpu/cpu.zig` (`run`, `runFor`). For the Swift tasks invoke the
`ps1-macos-app` skill first and read `Ps1Core.swift`, `PersistedChoice.swift`,
`DitherMode.swift` (the `DitherSetting` shape), `EmulatorRunner.swift`
(`runLoop`, `appliedVertexCache`), `EmulatorViewModel.swift` (the PGXP
properties, `load(disc:)`, `applySpeed`), `SpeedSetting.swift` and
`Settings/GeneralSettingsPane.swift`.

## Global Constraints

- `zig version` is **0.17.0**. `zig fmt` rewrites `@intFromEnum` to
  `@backingInt`; run `zig fmt` on every Zig file you touch.
- **The JIT exists only on `aarch64-macos`.** `ps1.recompiler.jit.available`
  is the comptime answer. `zig build` builds the wasm target too, and that
  build is the check that nothing in `ps1-capi` names JIT-only code
  unconditionally. Run it in Task 1.
- **The C engine numbering is ps1-wasm's**: 0 interpreter, 1 cached, 2 JIT
  (`ps1-wasm/src/main.zig`'s `setCpuEngine`). Swift's `CpuEngine` raw values
  are the same three numbers.
- **The engine is not part of a savestate** (spec: "The engine is a host
  setting like `pgxp_*` and is not part of a savestate"). No savestate
  section changes; no golden is recaptured; `ps1-core/src` is not edited by
  this plan at all.
- **A state restored under a block engine selects the engine BEFORE
  `savestate.load`** (CLAUDE.md, Harnesses). `ps1_load_state` must follow it.
- **The emulator thread owns the core.** No Swift code calls
  `ps1_set_cpu_engine` on a running core from the main actor; it crosses
  through the runner, as the PGXP settings do. The one exception is a core
  no runner owns yet (`load(disc:)`, before the runner is built).
- **`Ps1Core.swift` is the only Swift file that touches the C ABI.**
- The app is **not sandboxed and `ENABLE_HARDENED_RUNTIME = NO`**
  (`PS1.xcodeproj/project.pbxproj`), so `MAP_JIT` needs no entitlement. Do
  not turn the hardened runtime on in this plan: it would need
  `com.apple.security.cs.allow-jit`, and `setEngine(.jit)` would then fail
  with `EngineUnavailable`.
- Settings copy follows `SettingsCopyTests`: no em or en dashes, every
  sentence finished. Every new `SettingInfo` joins `SettingsCopy.allInfo`.
- **Commits are a title line only**: no body, no trailer. One commit per
  task, directly on `master`. **Never `git push`.**
- `pkill -x Substation` before `ps1-macos/test.sh`.
- The working tree may carry an unrelated `prettier`-style diff of the spec
  file. Do not stage it with your changes; ask before touching it.

## Review Focus

1. **A reset or a resume silently drops the player back to the
   interpreter.** Both rebuild `Bus`, whose `blocks` starts null. Expected:
   the engine survives `ps1_reset` and `ps1_load_state`. Pinned in Task 1.
2. **A state saved under one engine is loaded under another.** Expected: it
   loads and runs, and the machine keeps the engine the HANDLE chose, not
   the one that saved. Pinned in Task 1.
3. **The engine is changed mid-game, more than once.** Expected: the game
   keeps running across interpreter → cached → JIT → interpreter between
   frames. Pinned in Task 1.
4. **A stored engine this build cannot run** (the JIT on an Intel build, or
   a raw value no case matches). Expected: the app runs the cached
   interpreter (or the default for garbage) and does not forget the stored
   choice. Pinned in Task 2.
5. **8x on the existing 32,768-float ring.** `waterMarks(speed: 8).high` is
   47,040, above the ring's capacity, so the runner would never pace and 8x
   would run unbounded. Expected: the top speed's high-water mark, plus one
   frame of audio, fits the ring. Pinned in Task 4.

---

### Task 1: The C ABI: choose an engine, keep it across rebuilds, link in `ps1_run_frame`

**Files:**
- Modify: `ps1-capi/src/root.zig` (error code, `Handle.engine`,
  `buildMachine`, `ps1_load_state`, `ps1_run_frame`, three new exports)
- Modify: `ps1-capi/include/ps1.h` (error code, engine constants, three
  prototypes, the `ps1_run_frame` comment)
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `ps1.recompiler.Engine` (`enum { interpreter, cached, jit }`),
  `ps1.recompiler.setEngine(cpu: *Cpu, allocator, Engine) error{OutOfMemory, EngineUnavailable}!void`,
  `ps1.recompiler.engineOf(bus: *const Bus) Engine`,
  `ps1.recompiler.jit.available` (comptime bool), `Cpu.runFor(budget: u32) u32`.
- Produces (C): `PS1_ERR_ENGINE_UNAVAILABLE` (-14), `PS1_ENGINE_INTERPRETER`
  (0), `PS1_ENGINE_CACHED` (1), `PS1_ENGINE_JIT` (2),
  `int32_t ps1_set_cpu_engine(Ps1*, int engine)`,
  `int ps1_get_cpu_engine(const Ps1*)`,
  `int ps1_cpu_engine_available(int engine)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`:

```zig
/// A BIOS that branches to itself forever (`b .`, then its delay-slot nop),
/// so every engine runs the same two-instruction block frame after frame.
fn loadSpinBios(h: *capi.Handle) !void {
    const bios = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(bios);
    @memset(bios, 0);
    std.mem.writeInt(u32, bios[0..4], 0x1000_FFFF, .little);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_bios(h, bios.ptr, bios.len));
}

test "a new handle runs on the interpreter" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(c_int, 0), capi.ps1_get_cpu_engine(h));
}

test "set_cpu_engine refuses a number that names no engine and keeps the current one" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, 1));
    try std.testing.expectEqual(capi.PS1_ERR_ENGINE_UNAVAILABLE, capi.ps1_set_cpu_engine(h, 3));
    try std.testing.expectEqual(capi.PS1_ERR_ENGINE_UNAVAILABLE, capi.ps1_set_cpu_engine(h, -1));
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_get_cpu_engine(h));
    try std.testing.expectEqual(@as(c_int, 0), capi.ps1_cpu_engine_available(3));
}

test "set_cpu_engine selects the JIT exactly where this build has one" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_cpu_engine_available(0));
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_cpu_engine_available(1));
    if (ps1_core.recompiler.jit.available) {
        try std.testing.expectEqual(@as(c_int, 1), capi.ps1_cpu_engine_available(2));
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, 2));
        try std.testing.expectEqual(@as(c_int, 2), capi.ps1_get_cpu_engine(h));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), capi.ps1_cpu_engine_available(2));
        try std.testing.expectEqual(capi.PS1_ERR_ENGINE_UNAVAILABLE, capi.ps1_set_cpu_engine(h, 2));
        try std.testing.expectEqual(@as(c_int, 0), capi.ps1_get_cpu_engine(h));
    }
}

test "the engine survives a reset, which rebuilds Bus" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try loadSpinBios(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, 1));
    capi.ps1_reset(h);
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_get_cpu_engine(h));
    capi.ps1_run_frame(h);
    try std.testing.expect(h.cpu.bus.gpu.is_vblank);
}

test "a state saved on the interpreter loads under the engine the loading handle chose" {
    const a = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(a);
    try loadSpinBios(a);
    capi.ps1_run_frame(a);
    capi.ps1_run_frame(a);

    const size = capi.ps1_save_state_size(a);
    const buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buf);
    var len: usize = 0;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_save_state(a, buf.ptr, buf.len, &len));

    const b = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(b);
    try loadSpinBios(b);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(b, 1));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_state(b, buf.ptr, len));
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_get_cpu_engine(b));
    try std.testing.expectEqual(a.cpu.cycles, b.cpu.cycles);
    capi.ps1_run_frame(b);
    try std.testing.expect(b.cpu.bus.gpu.is_vblank);
}

test "switching engines between frames keeps the machine running" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try loadSpinBios(h);
    const order = [_]c_int{ 1, 2, 0, 1, 0 };
    for (order) |e| {
        if (capi.ps1_cpu_engine_available(e) == 0) continue;
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, e));
        const before = h.cpu.cycles;
        capi.ps1_run_frame(h);
        try std.testing.expect(h.cpu.bus.gpu.is_vblank);
        try std.testing.expect(h.cpu.cycles > before);
    }
}

test "run_frame under the JIT ends where the cached interpreter does" {
    if (!ps1_core.recompiler.jit.available) return error.SkipZigTest;
    var ends: [2]u64 = undefined;
    for (.{ @as(c_int, 1), @as(c_int, 2) }, 0..) |e, i| {
        const h = capi.ps1_create() orelse return error.CreateFailed;
        defer capi.ps1_destroy(h);
        try loadSpinBios(h);
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, e));
        for (0..3) |_| capi.ps1_run_frame(h);
        ends[i] = h.cpu.cycles;
    }
    try std.testing.expectEqual(ends[0], ends[1]);
}
```

If `h.cpu.cycles` is not a `u64`, match its type in `ends`. If
`ps1_save_state` refuses a disc-less machine, give both handles the same
one-sector raw `.bin` with `ps1_load_disc` (see the existing test
"load_disc with no cue takes the raw .bin fallback" for the call).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -E "error|ps1_set_cpu_engine" | head`
Expected: compile errors naming `ps1_get_cpu_engine`, `ps1_set_cpu_engine`,
`ps1_cpu_engine_available` and `PS1_ERR_ENGINE_UNAVAILABLE`.

- [ ] **Step 3: Implement the C ABI side in `root.zig`**

After `PS1_ERR_STATE_NO_SPACE`:

```zig
pub const PS1_ERR_ENGINE_UNAVAILABLE: i32 = -14;
```

Beside the other aliases (`const Sio = ...`):

```zig
const Engine = ps1.recompiler.Engine;

/// ps1-wasm's numbering, which ps1.h's PS1_ENGINE_* constants spell out.
fn engineFromC(engine: c_int) ?Engine {
    return switch (engine) {
        0 => .interpreter,
        1 => .cached,
        2 => .jit,
        else => null,
    };
}
```

Add a field to `Handle`, after `memcard`:

```zig
    /// The CPU engine the host chose. A host setting, like the PGXP flags:
    /// a block cache lives on `Bus`, and every `Bus` this file builds comes
    /// up on the interpreter, so each rebuild puts this back.
    engine: Engine = .interpreter,
```

A helper below `installHost`:

```zig
/// Puts the host's engine on a machine just built on a fresh `Bus`. A
/// failure (out of memory, or MAP_JIT refused) leaves that machine on the
/// interpreter, which `ps1_get_cpu_engine` then reports: it reads the
/// machine, not this field.
fn installEngine(h: *const Handle, cpu: *Cpu) void {
    ps1.recompiler.setEngine(cpu, allocator, h.engine) catch {};
}
```

In `buildMachine`, after `installHost(h, h.bus);`:

```zig
    installEngine(h, &h.cpu);
```

In `ps1_load_state`, directly after `var cpu = Cpu.init(fresh);` and before
`ps1.savestate.load`:

```zig
    // BEFORE the load: it restores the I-cache lines as the saving machine
    // held them, and selecting an engine afterwards would flush them.
    installEngine(h, &cpu);
```

Replace the body of `ps1_run_frame`:

```zig
pub export fn ps1_run_frame(h: *Handle) void {
    if (!h.bios_loaded) return;
    // `runFor`, not `run`: under the JIT, `run` is one block and never
    // follows a link. The vblank flag is a GPU deadline, so `runFor` stops
    // on it exactly as stepping would; on the interpreter it is one step.
    const budget = std.math.maxInt(u32);
    while (h.cpu.bus.gpu.is_vblank) _ = h.cpu.runFor(budget);
    while (!h.cpu.bus.gpu.is_vblank) _ = h.cpu.runFor(budget);
}
```

After `ps1_set_pgxp_preserve_projection`:

```zig
/// Selects the CPU engine. Between `ps1_run_frame` calls, on the thread that
/// makes them. Re-selecting the current engine keeps its compiled blocks. On
/// any error the current engine stays selected.
pub export fn ps1_set_cpu_engine(h: *Handle, engine: c_int) i32 {
    const e = engineFromC(engine) orelse return PS1_ERR_ENGINE_UNAVAILABLE;
    ps1.recompiler.setEngine(&h.cpu, allocator, e) catch |err| return switch (err) {
        error.OutOfMemory => PS1_ERR_OOM,
        error.EngineUnavailable => PS1_ERR_ENGINE_UNAVAILABLE,
    };
    h.engine = e;
    return PS1_OK;
}

/// The engine the machine is running on now.
pub export fn ps1_get_cpu_engine(h: *const Handle) c_int {
    return switch (ps1.recompiler.engineOf(h.bus)) {
        .interpreter => 0,
        .cached => 1,
        .jit => 2,
    };
}

/// 1 if this build has the engine. The JIT exists only on arm64 macOS; a
/// MAP_JIT refusal at run time still surfaces from `ps1_set_cpu_engine`.
pub export fn ps1_cpu_engine_available(engine: c_int) c_int {
    const e = engineFromC(engine) orelse return 0;
    return @intFromBool(e != .jit or ps1.recompiler.jit.available);
}
```

- [ ] **Step 4: Mirror it in `ps1.h`**

After `#define PS1_ERR_STATE_NO_SPACE   (-13)`:

```c
#define PS1_ERR_ENGINE_UNAVAILABLE (-14)

/* CPU engines, numbered as ps1-wasm's setCpuEngine numbers them. */
#define PS1_ENGINE_INTERPRETER 0
#define PS1_ENGINE_CACHED      1
#define PS1_ENGINE_JIT         2
```

After the `ps1_set_pgxp_preserve_projection` prototype:

```c
/* The CPU engine. A HOST setting like the PGXP ones: it is not part of a
 * savestate, and it survives ps1_reset and ps1_load_state, which select it
 * on the machine they rebuild. Call between ps1_run_frame calls, from the
 * thread that makes them. Re-selecting the current engine is free.
 *
 * Returns PS1_ERR_ENGINE_UNAVAILABLE for a number that names no engine or
 * an engine this build lacks (the JIT exists only on arm64 macOS), and
 * PS1_ERR_OOM. On any error the current engine stays selected. */
int32_t ps1_set_cpu_engine(Ps1*, int engine);

/* The engine the machine is running on now. */
int     ps1_get_cpu_engine(const Ps1*);

/* 1 if this build has the engine, 0 if not. Needs no handle. */
int     ps1_cpu_engine_available(int engine);
```

Match the return type spelling the header already uses for
`ps1_load_bios` (`int32_t` or `int`). Extend the `ps1_run_frame` comment
with one sentence: "Under the JIT, linked blocks run back to back inside
the frame."

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig fmt ps1-capi/src && zig build test 2>&1 | tail -5 && zig build`
Expected: all tests pass (the JIT-only test runs on this machine; on a
non-arm64 host it reports skipped); `zig build` (which includes the wasm
target) succeeds.

- [ ] **Step 6: Confirm the shipped library carries the symbols**

Run: `zig build capi-lib && nm zig-out/lib/libps1core.a | grep -E "ps1_(set|get)_cpu_engine|ps1_cpu_engine_available"`
Expected: three `T` lines.

- [ ] **Step 7: Commit**

```bash
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-capi/include/ps1.h
git commit -m "feat(capi): choose the CPU engine, keep it across rebuilds, link in run_frame"
```

---

### Task 2: The CPU engine setting in the app

**Files:**
- Create: `ps1-macos/Sources/PS1/CpuEngine.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift` (`Ps1Error.engineUnavailable`,
  `setCpuEngine`, `cpuEngine`, `isCpuEngineAvailable`)
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift` (atomic + apply on change)
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (property; set on
  the new core before `loadState`; hand to the runner beside the PGXP settings)
- Modify: `ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift`
- Modify: `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift`
- Test: `ps1-macos/Tests/PS1Tests/CpuEngineSettingTests.swift` (new),
  `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`

**Interfaces:**
- Consumes: Task 1's three C functions and `PS1_ERR_ENGINE_UNAVAILABLE`.
- Produces: `enum CpuEngine: Int { interpreter = 0, cachedInterpreter = 1, recompiler = 2 }`
  with `title`, `isAvailable`, `static let menuOrder`;
  `struct CpuEngineSetting` with `static let defaultsKey = "cpuEngine"`,
  `static let defaultEngine`, `var stored: CpuEngine`, `var engine: CpuEngine`,
  `mutating func set(_:)`; `Ps1Core.setCpuEngine(_:) throws`,
  `Ps1Core.cpuEngine`, `static Ps1Core.isCpuEngineAvailable(_:)`;
  `EmulatorRunner.setCpuEngine(_:)`; `EmulatorViewModel.cpuEngine`;
  `SettingsCopy.cpuEngine`. Task 3 changes only `defaultEngine`.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/CpuEngineSettingTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test: these write to the real `UserDefaults`.
private func uniqueKey() -> String { "test-cpu-engine-\(UUID().uuidString)" }

private func setting(_ key: String,
                     available: @escaping (CpuEngine) -> Bool = { _ in true }) -> CpuEngineSetting {
    CpuEngineSetting(key: key, defaults: .standard, isAvailable: available)
}

@Test func anUnusedKeyLoadsTheDefaultEngine() {
    #expect(setting(uniqueKey()).engine == CpuEngineSetting.defaultEngine)
}

@Test func theEngineRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = setting(key)
    written.set(.cachedInterpreter)
    #expect(setting(key).engine == .cachedInterpreter)
}

@Test func aStoredValueNoEngineMatchesLoadsTheDefault() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set(7, forKey: key)
    #expect(setting(key).engine == CpuEngineSetting.defaultEngine)
}

/// The JIT on a build without one: run the cached interpreter, but keep the
/// stored choice, so the same preferences on an Apple silicon build get it back.
@Test func anUnavailableEngineRunsTheCachedInterpreterAndIsNotForgotten() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = setting(key)
    written.set(.recompiler)

    let noJit = setting(key, available: { $0 != .recompiler })
    #expect(noJit.engine == .cachedInterpreter)
    #expect(noJit.stored == .recompiler)
    #expect(UserDefaults.standard.integer(forKey: key) == CpuEngine.recompiler.rawValue)
}

@Test func cpuEngineRawValuesMatchTheCAbi() {
    #expect(CpuEngine.interpreter.rawValue == 0)
    #expect(CpuEngine.cachedInterpreter.rawValue == 1)
    #expect(CpuEngine.recompiler.rawValue == 2)
}
```

Append to `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`:

```swift
@Test func aNewCoreRunsOnTheInterpreter() throws {
    #expect(try Ps1Core().cpuEngine == .interpreter)
}

@Test func setCpuEngineSelectsEveryEngineThisBuildHas() throws {
    let core = try Ps1Core()
    for engine in CpuEngine.allCases where Ps1Core.isCpuEngineAvailable(engine) {
        try core.setCpuEngine(engine)
        #expect(core.cpuEngine == engine)
    }
}

@Test func theRecompilerIsAvailableOnAppleSilicon() {
    #if arch(arm64)
    #expect(Ps1Core.isCpuEngineAvailable(.recompiler))
    #else
    #expect(!Ps1Core.isCpuEngineAvailable(.recompiler))
    #endif
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -20`
Expected: build failure naming `CpuEngineSetting`, `CpuEngine` and
`Ps1Core.cpuEngine`.

- [ ] **Step 3: Add the ABI seam to `Ps1Core.swift`**

Add `case engineUnavailable` to `Ps1Error` (after `stateNoSpace`) and
`case -14: return .engineUnavailable` to `Ps1Error.from`. Then, beside the
PGXP setters in `Ps1Core`:

```swift
    /// Between frames, from the thread that runs them: the runner's, or a
    /// core no runner owns yet. The choice survives `reset` and `loadState`.
    func setCpuEngine(_ engine: CpuEngine) throws {
        if let e = Ps1Error.from(ps1_set_cpu_engine(handle, Int32(engine.rawValue))) { throw e }
    }

    /// The engine the machine is running on now.
    var cpuEngine: CpuEngine {
        CpuEngine(rawValue: Int(ps1_get_cpu_engine(handle))) ?? .interpreter
    }

    /// Whether this build has the engine: the recompiler is arm64 only.
    static func isCpuEngineAvailable(_ engine: CpuEngine) -> Bool {
        ps1_cpu_engine_available(Int32(engine.rawValue)) != 0
    }
```

- [ ] **Step 4: Create `CpuEngine.swift`**

```swift
import Foundation

/// How the PlayStation's CPU is emulated. The raw values are the C ABI's
/// `PS1_ENGINE_*` numbers.
public enum CpuEngine: Int, CaseIterable, Identifiable, Sendable {
    case interpreter = 0
    case cachedInterpreter = 1
    case recompiler = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .interpreter: return "Interpreter"
        case .cachedInterpreter: return "Cached Interpreter"
        case .recompiler: return "Recompiler"
        }
    }

    /// Fastest first, as the Settings picker lists them.
    static let menuOrder: [CpuEngine] = [.recompiler, .cachedInterpreter, .interpreter]

    var isAvailable: Bool { Ps1Core.isCpuEngineAvailable(self) }
}

/// The persisted engine choice, shaped after `DitherSetting`: `init`
/// resolves, `set` persists, and the load rejects a value no case matches.
///
/// `stored` is what the player chose; `engine` is what runs. They differ only
/// where this build lacks the stored engine (the recompiler off Apple
/// silicon), which runs the cached interpreter and leaves the choice in
/// place for a build that has it.
struct CpuEngineSetting {
    static let defaultsKey = "cpuEngine"
    static let defaultEngine = CpuEngine.interpreter

    private var choice: PersistedChoice<CpuEngine>
    private let isAvailable: (CpuEngine) -> Bool

    var stored: CpuEngine { choice.value }
    var engine: CpuEngine { isAvailable(stored) ? stored : .cachedInterpreter }

    init(key: String = CpuEngineSetting.defaultsKey,
         defaults: UserDefaults = .standard,
         isAvailable: @escaping (CpuEngine) -> Bool = Ps1Core.isCpuEngineAvailable) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultEngine)
        self.isAvailable = isAvailable
    }

    mutating func set(_ value: CpuEngine) { choice.set(value) }
}
```

- [ ] **Step 5: Cross the setting to the emulator thread in `EmulatorRunner.swift`**

Beside the PGXP atomics:

```swift
    /// The CPU engine, applied by `runLoop` on CHANGE only, as the vertex
    /// cache is: a switch to a block engine allocates its cache. Starts at
    /// the interpreter for the reason `pgxp` starts false: `play()` hands
    /// over the player's choice.
    private let cpuEngine = Atomic<Int>(CpuEngine.interpreter.rawValue)
```

Beside `setPgxpPreserveProjection`:

```swift
    func setCpuEngine(_ engine: CpuEngine) {
        cpuEngine.store(engine.rawValue, ordering: .releasing)
    }
```

In `runLoop`, beside `var appliedVertexCache = false`:

```swift
        var appliedEngine: Int?
```

and directly after the `if wantCache != appliedVertexCache { … }` block:

```swift
            // Recorded even when the core refuses it, so a refusal is not
            // retried at 60 Hz; the core then stays on the engine it had.
            let wantEngine = cpuEngine.load(ordering: .acquiring)
            if wantEngine != appliedEngine, let engine = CpuEngine(rawValue: wantEngine) {
                try? core.setCpuEngine(engine)
                appliedEngine = wantEngine
            }
```

- [ ] **Step 6: The view model property and its two hand-offs**

In `EmulatorViewModel.swift`, after the PGXP properties:

```swift
    /// The CPU engine: persisted, applied by the runner between frames.
    private var cpuEngineSetting = CpuEngineSetting()

    public var cpuEngine: CpuEngine {
        get { cpuEngineSetting.engine }
        set {
            cpuEngineSetting.set(newValue)
            runner?.setCpuEngine(cpuEngineSetting.engine)
        }
    }
```

In `load(disc:)`, directly after `let core = try Ps1Core()` and before any
`core.loadState`:

```swift
            // On the core before a resume state loads: the load restores the
            // I-cache as the saving machine held it, and a later switch
            // would flush it. No runner owns this core yet.
            try? core.setCpuEngine(cpuEngine)
```

Beside `runner.setPgxp(pgxpSetting.enabled)` (around line 778):

```swift
            runner.setCpuEngine(cpuEngine)
```

- [ ] **Step 7: The Settings row**

In `SettingsCopy.swift`, after `saveOnExit`:

```swift
    static let cpuEngine = SettingInfo(
        title: "CPU Engine",
        summary: "How the PlayStation's processor is emulated. The recompiler is the fastest.",
        details: "Recompiler translates the game's code into native code for your Mac. Cached Interpreter is slower and works on every Mac. Interpreter is the slowest and the most exact: it handles interrupts and timing one instruction at a time, where the other two handle them between short runs of code. A change applies straight away, without restarting the game.",
        helps: "If a game misbehaves, try Interpreter. If that fixes it, the difference is worth reporting."
    )
```

and add `cpuEngine` to `allInfo` after `saveOnExit`.

In `GeneralSettingsPane.swift`, a new section after "Emulation Speed":

```swift
            Section("Processor") {
                SettingRow(SettingsCopy.cpuEngine) {
                    Picker(SettingsCopy.cpuEngine.title, selection: $model.cpuEngine) {
                        ForEach(CpuEngine.menuOrder.filter(\.isAvailable)) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
```

Check `SettingInfo`'s initializer for the `helps:` label spelling before
using it.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "Test run|failed|passed after" | tail -5`
Expected: the suite passes, with eight more tests than before this task.

- [ ] **Step 9: Build the app**

Run: `zig build macos 2>&1 | tail -3`
Expected: `zig-out/Substation.app` builds.

- [ ] **Step 10: Commit**

```bash
git add ps1-macos/Sources/PS1/CpuEngine.swift ps1-macos/Sources/PS1/Ps1Core.swift \
  ps1-macos/Sources/PS1/EmulatorRunner.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift \
  ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift ps1-macos/Sources/PS1/Settings/SettingsCopy.swift \
  ps1-macos/Tests/PS1Tests/CpuEngineSettingTests.swift ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift
git commit -m "feat(macos): a persisted CPU engine setting, applied between frames"
```

---

### Task 3: Smoke-test the Recompiler in the app, then make it the default

The spec makes the flip conditional: "The default stays Interpreter until
Stage 3's gates are green, then becomes Recompiler." The gates went green in
Plan 6. What has NOT been done is running real games through the app on the
JIT, and the FF7 memory-card read and save checks that Plan 3 deferred here.
Steps 1 to 3 need a person at the app; an agent executing this plan stops
and asks for them.

**Files:**
- Modify: `ps1-macos/Sources/PS1/CpuEngine.swift` (`defaultEngine`)
- Test: `ps1-macos/Tests/PS1Tests/CpuEngineSettingTests.swift`
- Modify: `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md` (the
  smoke results go in "As built (Plan 7)", which Task 5 completes; start the
  section here)

**Interfaces:**
- Consumes: Task 2's `CpuEngineSetting.defaultEngine`.
- Produces: `CpuEngineSetting.defaultEngine == .recompiler`.

- [ ] **Step 1: [person] Boot and play each game under Recompiler**

`open zig-out/Substation.app`, Settings ▸ General ▸ CPU Engine ▸
Recompiler. For each of Croc, Crash Bandicoot, Spyro, Silent Hill and
Tekken 3: boot from the library, reach gameplay, play about a minute. Note
the FPS readout at 1x. Record pass/fail per game.

- [ ] **Step 2: [person] FF7 memory card: read, then save and reload**

Under Recompiler: boot FF7 disc 1, Continue, confirm the existing save
LISTS and LOADS (the read check). In game, save to a slot. Quit the app
(⌘Q, decline the resume save), relaunch, boot FF7 again, and confirm the new
save lists and loads (the save check: it crossed the card file on disk).

- [ ] **Step 3: [person] Resume and switching**

In one game: switch the engine twice mid-game through Settings (the game
keeps running); leave with Save, reopen, Resume (it continues under
Recompiler); Machine ▸ Reset (it reboots, and the FPS readout shows it is
still on the fast engine).

- [ ] **Step 4: Stop if any check failed**

A failure here is a bug to debug (invoke `ps1-debugging-real-games`, and
retry the same check under Cached Interpreter to tell a JIT bug from a
block-engine one) before the default moves. Do not flip the default over
a failure.

- [ ] **Step 5: Write the failing test**

Append to `CpuEngineSettingTests.swift`:

```swift
/// Spec: "The default stays Interpreter until Stage 3's gates are green, then
/// becomes Recompiler." Plan 7's smoke test is what this rests on.
@Test func theRecompilerIsTheDefault() {
    #expect(CpuEngineSetting.defaultEngine == .recompiler)
}
```

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "theRecompilerIsTheDefault|failed" | head`
Expected: `theRecompilerIsTheDefault` fails.

- [ ] **Step 6: Flip it**

In `CpuEngine.swift`: `static let defaultEngine = CpuEngine.recompiler`.

Run the suite again. Expected: everything passes. A player who never opened
Settings now gets the recompiler; one who chose an engine keeps it.

- [ ] **Step 7: Record the smoke results and commit**

Add a `### As built (Plan 7, 2026-10-05)` section after "As built (Plan 6)"
in the spec, with one bullet carrying the per-game results and FPS from
Steps 1 to 3.

```bash
git add ps1-macos/Sources/PS1/CpuEngine.swift ps1-macos/Tests/PS1Tests/CpuEngineSettingTests.swift \
  docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md
git commit -m "feat(macos): the recompiler is the default CPU engine"
```

`git add -p` is interactive and unavailable here. If the spec still carries
the unrelated formatter diff (Global Constraints), ask how to handle it
before staging the spec.

---

### Task 4: Widen the speed range, if the measurement shows the headroom

The spec: "`SpeedSetting.choices` widens (e.g. 1…8 plus "Max", meaning no
frame pacing) only after a measured `ps1-bench` run shows the headroom."
Plan 6 measured `.jit` at 10.83x real time with PGXP off and 4.95x with
PGXP and CPU mode on (core only, Crash). The app also pays for Metal and
audio, and measured 1.73x to 2.04x on the interpreter (2026-10-01).

**"Max" is not in this task.** Unpaced running has no audio clock to follow
(`TempoControl` settles on a rate below the target, and an unbounded target
has no low-water mark), so it needs its own decision: mute or not, and what
the runner sleeps on. That is a follow-up, recorded in Task 5.

**Files:**
- Modify: `ps1-macos/Sources/PS1/SpeedSetting.swift` (`choices`)
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift` (`ringCapacity`)
- Modify: `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift` (`speed.details`)
- Test: `ps1-macos/Tests/PS1Tests/SpeedSettingTests.swift`

**Interfaces:**
- Consumes: `EmulatorRunner.waterMarks(speed:)`, `EmulatorRunner.ringCapacity`.
- Produces: `SpeedSetting.choices == 1...8`.

- [ ] **Step 1: [person] Measure the app's sustained speed**

Recompiler, PGXP off (the shipped default), Machine ▸ Speed ▸ 4x. In Crash
Bandicoot (gameplay, not a menu) and Silent Hill (walking in town), read the
FPS readout for ten seconds each. Then the same with PGXP on. Record the
four numbers.

- [ ] **Step 2: Decide**

If neither game sustains more than 4x (about 240 fps) with PGXP off, the
range does not widen: record the numbers in the spec's Plan 7 section, skip
to Task 5, and say so in the summary. Otherwise continue.

- [ ] **Step 3: Write the failing tests**

Append to `SpeedSettingTests.swift`:

```swift
@Test func theRangeReachesEightTimes() {
    #expect(SpeedSetting.choices == 1...8)
}

/// The runner pauses once the ring holds more than the high-water mark, and
/// a frame's audio can land on top of that. A ring smaller than the top
/// speed's mark never fills, so that speed would run unpaced.
@Test func theTopSpeedsHighWaterMarkFitsTheRing() {
    let oneFrame = 1470
    let high = EmulatorRunner.waterMarks(speed: SpeedSetting.choices.upperBound).high
    #expect(high + oneFrame < EmulatorRunner.ringCapacity)
}
```

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "theRangeReachesEightTimes|theTopSpeedsHighWaterMarkFitsTheRing|failed" | head`
Expected: `theRangeReachesEightTimes` fails. Then change only `choices` to
`1...8`, rerun, and confirm `theTopSpeedsHighWaterMarkFitsTheRing` now
FAILS (47,040 + 1,470 against 32,768): that is the trap this test exists for.

- [ ] **Step 4: Grow the ring**

In `EmulatorRunner.swift`: `static let ringCapacity = 1 << 16`, and extend
its comment: "Room for the 8x high-water mark (47,040 floats) plus a frame;
`1 << 15` held only up to 5x." Check `AudioRing` still requires a power of
two (`mask`), which `1 << 16` is.

- [ ] **Step 5: The copy and the shortcuts**

`SettingsCopy.speed.details`: replace "(⌥⌘1 to ⌥⌘4)" with "(⌥⌘1 to ⌥⌘8)".
The menu's `keyboardShortcut` already derives from `n`, so ⌥⌘5 to ⌥⌘8 appear
on their own; confirm nothing else binds them:
`grep -rn "option\]" ps1-macos/Sources | grep -v MachineCommands` prints
nothing. Update `SpeedSetting`'s and `cycleBase`'s doc comments ("1x, 2x,
3x, 4x, then back to 1x" becomes "1x up to 8x, then back to 1x").

- [ ] **Step 6: Run the suite**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "Test run|failed" | tail -3`
Expected: everything passes, including the existing clamp test (it sets 9
and expects the upper bound).

- [ ] **Step 7: [person] Listen at 8x**

`zig build macos`, run Crash at 8x for thirty seconds: sound is
time-stretched and continuous (no stutter), the badge reads 8x, and the FPS
readout shows what was reached.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Sources/PS1/SpeedSetting.swift ps1-macos/Sources/PS1/EmulatorRunner.swift \
  ps1-macos/Sources/PS1/Settings/SettingsCopy.swift ps1-macos/Tests/PS1Tests/SpeedSettingTests.swift
git commit -m "feat(macos): emulation speeds up to 8x"
```

---

### Task 5: The battery measurement, the as-built notes and the final gates

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md`
  ("As built (Plan 7)")
- Modify: `CLAUDE.md` (the Swift test count; the C ABI's engine in the JIT
  rules)
- Modify: `.claude/skills/ps1-macos-app/SKILL.md` (a CPU engine paragraph)

- [ ] **Step 1: [person] Battery: `powermetrics` before and after**

On battery, display brightness fixed, nothing else running. For each of
Interpreter, Cached Interpreter and Recompiler, run Crash Bandicoot at 1x in
gameplay and, after thirty seconds, in a terminal:

```bash
sudo powermetrics --samplers cpu_power -i 1000 -n 60 | grep "Combined Power"
```

(From this session: `! sudo powermetrics --samplers cpu_power -i 1000 -n 60 | grep "Combined Power"`.)
Average the sixty samples per engine.

- [ ] **Step 2: Final gates**

```bash
zig build test 2>&1 | tail -3
zig build 2>&1 | tail -3
zig build capi-lib && zig build metallib && zig build macos 2>&1 | tail -3
pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -E "Test run|failed" | tail -3
```

Expected: all green; note the new Swift test count. `trace-golden` is not
re-run: no task edited `ps1-core/src` or `ps1-golden`, and `ps1_run_frame`
is not on any golden's path. Say so in the notes rather than running it.

- [ ] **Step 3: Write "As built (Plan 7)"**

Under the section Task 3 started, add bullets for: the ABI as built (three
functions, `-14`, the engine kept on the handle and installed before a
state load, `ps1_run_frame` now `runFor`); the setting (key `cpuEngine`,
default Recompiler, the unavailable fallback); the smoke results; the speed
measurement and whether the range widened; the battery table (engine, mW,
change against Interpreter); the gates with the Swift count; and "Left
open": "Max" speed (no audio clock to follow; needs a mute-or-not decision
and a runner sleep source), and inline ALU under the `cpu` tier (from Plan 6).
Update the "Plans" list item 7 to note it is done.

- [ ] **Step 4: CLAUDE.md and the skill**

`CLAUDE.md`: the `ps1-macos/test.sh` row's test count; and under **JIT**,
one rule: "**`ps1_run_frame` calls `runFor`, not `run`.** Under `.jit`,
`run` is one block and never follows a link; the app would lose the
linking win silently. The engine lives on the C ABI handle and is
re-installed on every `Bus` it rebuilds, BEFORE a state loads."
`ps1-macos-app` skill: a paragraph after the speed paragraph covering
`CpuEngineSetting` (`stored` vs `engine`, the cached fallback off Apple
silicon), the change-only apply in `runLoop`, the set-before-`loadState` in
`load(disc:)`, and, if Task 4 widened the range, the ring-capacity trap.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md .claude/skills/ps1-macos-app/SKILL.md docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md
git commit -m "docs: Plan 7 as built, the CPU engine in the app"
```
