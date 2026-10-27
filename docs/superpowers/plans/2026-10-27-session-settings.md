# Session Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The host hands the session one settings value, at creation and on every change. The session folds in both per-game tables (the PGXP preset and the VRAM readbacks list) for the disc in the tray, and ten per-setting C calls leave the ABI.

**Architecture:** A new pure `ps1-session/src/settings.zig` holds the Zig settings value and the fold: player values + preset + readbacks table → effective PGXP, vertex cache and VRAM mode. `Session` keeps the value the host last sent, plus the disc's serial and readbacks choice, under its existing `settings_lock`. It refolds when the host sends a change, and when the emulator thread answers a swap (through a hook `RunLoop` calls after `swapDisc` succeeds). The C ABI gains `Ps1SessionSettings` (it carries its own `size`), `ps1_session_set_settings`, a `settings` pointer in the config, and a readbacks parameter on `ps1_session_request_swap`. Swift builds the struct in one computed property and sends it from one place.

**Tech Stack:** Zig 0.17.0 (`ps1-session`), C header `ps1-capi/include/ps1_session.h`, Swift/SwiftUI (`ps1-macos`).

**Spec:** `docs/superpowers/specs/2026-10-26-session-ghostty-parity-design.md`, section 3 "Settings are one value" and Order item 2. Plan 1 (events) is done; Plan 3 (disc by path, identify by path, output size) is not part of this one.

## Global Constraints

- Zig 0.17.0; `ps1_session.h` rules 1-6 hold for everything added.
- No core change: nothing in `ps1-core` moves, no golden, floor or fixture. The session READS `ps1_core.pgxp_presets` and `ps1_core.vram_readbacks`; the core applies neither.
- A settings struct whose `size` the session does not know is refused with `PS1_ERR_SETTINGS_SIZE` (-26), never read; the session is left as it was.
- Controls that change at input rate stay their own calls: buttons, sticks, the Analog press, paused, rewinding, the speed, size, occlusion and the band.
- `transparent_depth` is never a preset field: it is always the player's.
- The vertex cache, the CPU engine and the rewind budget still cross to the machine only on change (`RunLoop.applied_*` already does this; nothing may defeat it).
- `controls.zig`'s rule holds: a Zig default is the "off" value, so a forgotten field shows. `Settings.vram_readbacks` defaults to `.on` (dual), the mode a bare session boots in today, and `use_presets` defaults to false.
- The machine's PGXP is stored before the renderer's depth flag is posted (`Session.setPgxp`'s existing order, pinned by `theDepthBufferReachesTheMachineBeforeTheRenderer`).
- Every C callback in Swift is a `nonisolated static`; every completion hops to the main actor with `async`.
- Commit messages are a title line only (no body), on master.
- Swift: `pkill -x Substation` before `ps1-macos/test.sh`.

## Review Focus

1. **A stale readbacks choice sent after an answered swap.** Between the session answering a swap and Swift's completion updating `discSerial`, any settings change (a volume drag) re-sends the OLD disc's `vram_readbacks`. That must not switch the new disc's VRAM mode. The session takes `vram_readbacks` only when it differs from the value the host last sent. Pinned in Task 2 (`aStaleReadbacksChoiceAfterASwapChangesNothing`).
2. **A volume drag sends dozens of identical-but-for-gain values a second.** It must not flush the JIT, reallocate the 83 MB vertex cache or rebuild the renderer's VRAM. Pinned in Task 2 (`aGainOnlyChangeTouchesNoOtherControl`).
3. **A disc with no serial** (the BIOS shell, homebrew, an audio CD) under Automatic must run GPU-only with no preset, as the app does today. Pinned in Task 1 (`noSerialIsAutomaticOverAnUnlistedGame`).
4. **Per-Game Fixes off** must hand the machine exactly the player's values, even for a listed game. Pinned in Task 1 (`presetsOffIgnoresTheRow`).
5. **The menu agrees with the session on a refused swap.** The preset footer and the readbacks title must keep naming the old disc until a swap succeeds. Pinned in Task 4 (`aRefusedSwapKeepsTheOldDiscsPreset`).

---

## File Structure

- Create `ps1-session/src/settings.zig`: `VramReadbacks`, `Settings`, `Folded`, `Serial`, `fold`, `forSerial`, `serialOf`. Pure, no threads.
- Create `ps1-session/tests/settings_test.zig`; register it in `ps1-session/pure_test.zig`.
- Modify `ps1-session/src/root.zig` (export `settings`), `session.zig`, `run_loop.zig`, `requests.zig`, `abi.zig`.
- Modify `ps1-capi/include/ps1_session.h`, `ps1-capi/include/ps1.h` (the error code, the two lookup comments), `build.zig` (the `nm` check).
- Modify Swift: `Sources/PS1/GameSession.swift`, `Sources/PS1/Ps1Core.swift` (`Ps1Error`), `Sources/PS1/EmulatorViewModel.swift`, `Sources/PS1/GameWindowView.swift`, `Sources/PS1/VramReadbacks.swift`, `Sources/PS1/PgxpPreset.swift` (doc comment), `Tests/PS1Tests/ScriptedSession.swift`, `Tests/PS1Tests/VramReadbacksTests.swift`, `Tests/PS1Tests/SaveStateViewModelTests.swift`, a new `Tests/PS1Tests/SessionSettingsTests.swift`.
- Docs: `CLAUDE.md` (two rules), `.claude/skills/ps1-macos-app/SKILL.md`.

---

### Task 1: The fold, pure

**Files:**
- Create: `ps1-session/src/settings.zig`
- Modify: `ps1-session/src/root.zig`
- Test: `ps1-session/tests/settings_test.zig` (add to `ps1-session/pure_test.zig`)

**Interfaces:**
- Produces:
  - `pub const VramReadbacks = enum(u8) { automatic = 0, on = 1, off = 2 }`, the C `PS1_READBACKS_*` numbering.
  - `pub const Serial = [16]u8` (NUL-padded, as `Ps1DiscId.serial`), plus `pub fn serialSlice(s: *const Serial) []const u8` (up to the first NUL).
  - `pub const Settings = struct { gain: f32 = 0, engine: machine.Engine = .interpreter, runahead: u32 = 0, rewind_budget: usize = 0, scale: u32 = 1, dither: pi.DitherMode = .off, texture_filter: pi.TextureFilter = .nearest, sprite_filter: pi.TextureFilter = .nearest, pgxp: machine.Pgxp = .{}, vertex_cache: bool = false, use_presets: bool = false, vram_readbacks: VramReadbacks = .on }`.
  - `pub const Folded = struct { pgxp: machine.Pgxp, vertex_cache: bool, vram: capi.VramMode }`.
  - `pub fn fold(s: Settings, readbacks: VramReadbacks, preset: ?ps1_core.pgxp_presets.Preset, needs_dual: bool) Folded`. `readbacks` is passed separately because the session's choice for the disc can differ from `s.vram_readbacks` (Task 2). It applies the preset field over the player's field wherever the preset names one: `enabled, cpu, culling, vertex_cache, texture_correction, color_correction, depth_buffer, disable_2d, preserve_projection, tolerance`. `transparent_depth` always stays the player's. `preset` is ignored when `s.use_presets` is false. VRAM: `.on → .dual`, `.off → .gpu`, `.automatic → if (needs_dual) .dual else .gpu`.
  - `pub fn forSerial(s: Settings, readbacks: VramReadbacks, serial: []const u8) Folded`: `fold` with `ps1_core.pgxp_presets.lookup(serial)` (null for an empty serial) and `ps1_core.vram_readbacks.needsDual(serial)`.
  - `pub fn serialOf(bin: []const u8) Serial`: `capi.ps1_identify_disc` over the bytes; all zeros when it fails or names no serial.

- [ ] **Step 1: Write the failing tests** in `settings_test.zig`, one per behaviour. Build presets as `ps1_core.pgxp_presets.Preset` literals, so the fields with no row in the table (`depth_buffer`, `texture_correction`) are covered too:
  - `aPresetFieldOverridesThePlayers`: one `inline for` over the nine bool fields plus `vertex_cache`. Player all false and `use_presets = true`; a preset naming only that field `= true` → the folded field is true, and every other folded field is false.
  - `aPresetToleranceReplacesThePlayers`: player tolerance `-1`, preset `.tolerance = 2.0` → `2.0`; preset with no tolerance → `-1`.
  - `transparentDepthIsAlwaysThePlayers`: player `transparent_depth = true`, preset `.enabled = false` → folded `transparent_depth` true (the preset type has no such field; assert the copy is untouched).
  - `presetsOffIgnoresTheRow`: `use_presets = false`, preset `.cpu = true, .disable_2d = true` → `folded.pgxp` equals `s.pgxp` exactly (`std.meta.eql`).
  - `eachReadbacksChoiceResolvesTheMode`: the six cases of (`automatic`/`on`/`off`) × `needs_dual` → `gpu`/`dual`, `dual`/`dual`, `gpu`/`gpu`.
  - `forSerialReadsBothTables`: `forSerial(.{ .use_presets = true }, .automatic, "SCES-00010")` → `pgxp.cpu` and `pgxp.disable_2d` true, `vram == .gpu`; `forSerial(.{}, .automatic, "SLES-02089")` → `vram == .dual`.
  - `noSerialIsAutomaticOverAnUnlistedGame`: `forSerial(.{ .use_presets = true }, .automatic, "")` → `vram == .gpu` and `folded.pgxp` equal to the player's.
  - `aZeroImageHasNoSerial`: `serialOf` of 32 zeroed 2352-byte sectors → `serialSlice` is empty.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test 2>&1 | grep -A3 settings_test`
Expected: a compile error, `settings.zig` not found.

- [ ] **Step 3: Implement `settings.zig`** with the declarations above, and export it from `root.zig` as `pub const settings = @import("src/settings.zig");` next to `events`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all 29 binaries pass.

- [ ] **Step 5: Commit**

```bash
git add ps1-session/src/settings.zig ps1-session/src/root.zig ps1-session/tests/settings_test.zig ps1-session/pure_test.zig
git commit -m "feat: the session folds the per-game tables into its settings"
```

### Task 2: The session takes one settings value and refolds on a swap

**Files:**
- Modify: `ps1-session/src/session.zig`, `ps1-session/src/run_loop.zig`, `ps1-session/src/requests.zig`
- Test: `ps1-session/tests/run_loop_requests_test.zig`, `ps1-session/tests/session_test.zig` (and every existing test that sets `Config.engine` or `Config.vram`)

**Interfaces:**
- Consumes: Task 1's `Settings`, `VramReadbacks`, `Serial`, `forSerial`, `serialOf`, `serialSlice`.
- Produces:
  - `Config.settings: settings.Settings = .{}` replaces `Config.engine` and `Config.vram`. The machine boots with `cfg.settings.engine`, and in `chooseVram(forSerial(cfg.settings, cfg.settings.vram_readbacks, serial).vram, debug)`, where `serial = serialOf(disc.bin)` (zeros for no disc). The renderer is built with the folded initial `RenderSettings` (scale, dither, both filters, `depth_buffer = pgxp.enabled and pgxp.depth_buffer`), so the first frame rebuilds nothing. Every `Controls` field the settings name is stored before any thread exists.
  - `Session.setSettings(self: *Session, s: settings.Settings) void`. Under `settings_lock`: if `s.vram_readbacks != self.player.vram_readbacks`, set `self.disc_readbacks = s.vram_readbacks`. Then `self.player = s`, refold, and store into `Controls`, the mixer and `RenderSettings` only the fields that differ from what they hold. Post the renderer settings only if one of its fields changed. Bump the pacer once.
  - `Session.discChanged(self: *Session, serial: settings.Serial, readbacks: settings.VramReadbacks) void`. Under `settings_lock`: adopt both, refold, and store what changed (PGXP, vertex cache, VRAM mode, the depth flag). It runs on the emulator thread.
  - Session fields: `player: settings.Settings`, `disc_serial: settings.Serial`, `disc_readbacks: settings.VramReadbacks`, all guarded by `settings_lock`.
  - `requests.Swap` gains `serial: settings.Serial` and `readbacks: settings.VramReadbacks`. `Requests.setSwap(disc, serial, readbacks, done, ctx)`.
  - `Session.requestSwap(self, disc: DiscBytes, readbacks: settings.VramReadbacks, done, ctx)` computes `serialOf(disc.bin)` on the caller's thread and queues it.
  - `RunLoop.on_disc: ?DiscHook = null`, `pub const DiscHook = struct { f: *const fn (ctx: *anyopaque, serial: settings.Serial, readbacks: settings.VramReadbacks) void, ctx: *anyopaque }`. `serviceSwap` calls it after `swapDisc` succeeds and before `s.done(…, PS1_OK)`, and never on a refusal. `Session.create` sets it to a trampoline over `discChanged`.
  - `Session.setPgxp`, `setVertexCache`, `setEngine`, `setRewindBudget`, `setRunahead`, `setVramMode`, `setGain`, `setDither`, `setTextureFilter`, `setSpriteFilter`, `setScale` become private helpers that `setSettings`/`discChanged` use, or go. Tests drive `setSettings` instead.

- [ ] **Step 1: Write the failing tests**
  - `run_loop_requests_test.zig`, `RunLoop: aRefusedSwapCallsNoDiscHook`: give `FakeMachine` a `fail_swap: bool = false` that makes `swapDisc` return `error.BadCue`. With a hook that counts calls, `serviceSwap` → the answer is `PS1_ERR_BAD_CUE` and the hook ran 0 times.
  - `RunLoop: anAcceptedSwapHandsTheHookItsSerialAndChoiceBeforeTheAnswer`: queue a swap with serial `"SCES-00010"` and `.off`. The hook records what it got, plus whether the answer had already run (`Answer.calls`). Expect the serial, `.off`, and `calls == 0` at hook time.
  - `session_test.zig`, `Session: aPresetFieldReachesControls`: `make` a session with `.settings = .{ .use_presets = true }`, then `s.discChanged(serial("SCES-00010"), .on)` → `s.loop.controls.pgxp().cpu` and `.disable_2d` are true. `serial(…)` is a local helper that NUL-pads a string into `Serial`.
  - `Session: eachReadbacksChoiceReachesTheVramMode`: `discChanged(serial("SLES-02089"), .automatic)` → `controls.vram_mode` is `.dual`; with `.off` → `.gpu`; `discChanged(serial("SLUS-00707"), .automatic)` → `.gpu`.
  - `Session: aStaleReadbacksChoiceAfterASwapChangesNothing`: `setSettings(.{ .vram_readbacks = .on })`, then `discChanged(serial("SLUS-00707"), .off)` → `.gpu`. Then `setSettings(.{ .vram_readbacks = .on, .gain = 0.5 })`, the stale value → still `.gpu`.
  - `Session: aGainOnlyChangeTouchesNoOtherControl`: after `setSettings(a)`, read `controls.engine`, `vertex_cache`, `rewind_budget`, `pgxp_flags` and `vram_mode`, and drain `s.renderer.mailbox.take()` (no render thread runs in an unstarted session). `setSettings(a with gain changed)` → all unchanged, and `mailbox.take() == null`.
  - Update `theDepthBufferReachesTheMachineBeforeTheRenderer` to go through `setSettings`, keeping its ordering assertion. Update the GPU-only tests from `.vram = .gpu` to `.settings = .{ .vram_readbacks = .off }`, and every `.engine = x` to `.settings = .{ .engine = x }`.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test` (the RunLoop cases), then `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Session:`
Expected: compile errors on `fail_swap`, `on_disc`, `setSettings`, `discChanged`, `Config.settings`.

- [ ] **Step 3: Implement** the Interfaces above. `abi.zig` still compiles against the old setters: point its exports at the private helpers for now, and give `ps1_session_request_swap` `.on`. Task 3 replaces both. Keep `Session.setPgxp`'s order inside the refold: `controls.setPgxp`, then the depth flag into `RenderSettings`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test && zig build test-metal -Doptimize=ReleaseFast`
Expected: all pass; the four v2 fixtures skip with their printed reason, as before.

- [ ] **Step 5: Commit**

```bash
git add ps1-session
git commit -m "feat: the session takes one settings value and refolds when a swap goes in"
```

### Task 3: The C ABI and the Swift wrapper

**Files:**
- Modify: `ps1-capi/include/ps1_session.h`, `ps1-capi/include/ps1.h`, `ps1-session/src/abi.zig`, `ps1-session/src/machine.zig` (the error), `build.zig`
- Modify: `ps1-macos/Sources/PS1/GameSession.swift`, `Sources/PS1/Ps1Core.swift`, `Sources/PS1/EmulatorViewModel.swift` (the `describe` case and the two call sites below only), `Tests/PS1Tests/ScriptedSession.swift`
- Test: `ps1-session/tests/abi_test.zig`, `ps1-macos/Tests/PS1Tests/SessionSettingsTests.swift`

**Interfaces:**
- Consumes: Task 2's `Session.setSettings`, `Config.settings`, `Session.requestSwap(disc, readbacks, …)`.
- Produces (C), exactly:

```c
#define PS1_READBACKS_AUTO 0
#define PS1_READBACKS_ON   1   /* dual */
#define PS1_READBACKS_OFF  2   /* GPU-only */

typedef struct {
    uint32_t        size;            /* sizeof(Ps1SessionSettings) */
    float           gain;
    int32_t         cpu_engine;      /* PS1_ENGINE_* */
    int32_t         runahead;        /* frames, 0 for off */
    size_t          rewind_budget;   /* bytes, 0 for off */
    int32_t         scale;           /* 1..8 */
    int32_t         dither;          /* PS1_DITHER_* */
    int32_t         texture_filter;  /* PS1_FILTER_* */
    int32_t         sprite_filter;
    Ps1PgxpSettings pgxp;            /* the PLAYER's values */
    uint8_t         pgxp_use_presets;
    uint8_t         vram_readbacks;  /* PS1_READBACKS_*: this disc's choice */
} Ps1SessionSettings;

/* PS1_OK, or PS1_ERR_SETTINGS_SIZE for a size this library does not know
 * (nothing is read then). Applies only what changed. */
int32_t ps1_session_set_settings(Ps1Session*, const Ps1SessionSettings*);
void ps1_session_request_swap(Ps1Session*, const Ps1DiscBytes* disc,
                              uint8_t vram_readbacks, Ps1Done done, void* ctx);
```

  - `Ps1SessionConfig`: `const Ps1SessionSettings* settings;` replaces `cpu_engine`. `ps1_session_new` returns `PS1_ERR_SETTINGS_SIZE` for a null pointer or an unknown size. `ps1.h`: `#define PS1_ERR_SETTINGS_SIZE (-26)` in the session block, its comment extended. A session-only code is not mirrored in `ps1-web/src/errors.ts`, like -21..-25.
  - An out-of-range enum in the struct (engine, dither, filter, readbacks) keeps the held value, as the old setters ignored one. A scale is clamped to 1..8.
  - Rule 5 in `ps1_session.h`: a session boots in the mode its settings fold to; `ps1_session_set_vram_mode` is no longer named. The comments on `ps1_lookup_pgxp_preset` and `ps1_game_needs_dual_vram`: a session folds these in itself; a bare `ps1.h` handle's host folds them.
  - The old ten setters STAY exported in this task, so the app keeps building. Task 5 removes them.
- Produces (Swift):
  - `struct SessionSettings: Equatable, Sendable { var gain: Float; var cpuEngine: CpuEngine; var runaheadFrames: Int; var rewindBudget: Int; var scale: Int; var dither: DitherMode; var textureFilter: TextureFilter; var spriteFilter: TextureFilter; var pgxp: PgxpSettings; var pgxpUsePresets: Bool; var vramReadbacks: VramReadbacks }` in `GameSession.swift`. Its `var c: Ps1SessionSettings` builds the C struct with `size = UInt32(MemoryLayout<Ps1SessionSettings>.size)`. Reuse `PgxpSettings`'s existing conversion, moved into a computed property both paths share.
  - `SessionConfig.settings: SessionSettings` replaces `cpuEngine`.
  - `GameSession.setSettings(_ s: SessionSettings)` and `requestSwap(_ disc: DiscBytes, readbacks: VramReadbacks, _ done:)`. `Session` passes `settings` by pointer in `init`. A refusal in `setSettings` is a header/library mismatch: `assertionFailure` with the code, and nothing else.
  - `Ps1Error.settingsSize` for -26, with a `describe` message: "This copy of Substation and its emulator engine do not match. Reinstall the app."
  - `ScriptedSession.setSettings` appends `"setSettings"` to `calls` and the value to `private(set) var settings: [SessionSettings]`. `pendingSwap` becomes `(disc: DiscBytes, readbacks: VramReadbacks)?`.
  - The view model's two call sites compile: `load(disc:)` passes `settings: sessionSettings` (a computed property in this task: today's values, with `pgxp` still the FOLDED `pgxpSettings`, since the per-setting calls still run after it), and `changeDisc` passes `vramReadbacksSetting.choice(serial: entry.identity.serial)`.

- [ ] **Step 1: Write the failing tests**
  - `abi_test.zig`, `SessionAbi: theSettingsStructIsSixtyFourBytes`: `@sizeOf(abi.Ps1SessionSettings) == 64` and `@offsetOf(…, "pgxp") == 40`.
  - `SessionAbi: anUnknownSettingsSizeIsRefusedAndReadsNothing`: `ps1_session_set_settings` with `size = 63` → `PS1_ERR_SETTINGS_SIZE`, and `s.player` is unchanged.
  - `SessionAbi: aConfigWithNoSettingsIsRefused`: `settings = null` → `PS1_ERR_SETTINGS_SIZE`, `out` untouched.
  - `SessionAbi: aBadEnumInTheSettingsKeepsTheHeldValue`: `dither = 99` → the held dither unchanged; the other fields applied.
  - `SessionSettingsTests.swift`, `theHeaderAgreesOnTheSize`: `MemoryLayout<Ps1SessionSettings>.size == 64`.
  - `aSettingsValueCrossesFieldForField`: a `SessionSettings` with every field off-default → its `c` has each field equal, `size == 64`, `pgxp_use_presets == 1`, `vram_readbacks == 2` for `.off`.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=SessionAbi`
Expected: compile errors on `Ps1SessionSettings`.

- [ ] **Step 3: Implement** the C and Swift interfaces above. In `build.zig`'s `nm` check, add the requirement `' T _ps1_session_set_settings$'`.

- [ ] **Step 4: Run the gates**

Run: `zig build test && zig build test-metal -Doptimize=ReleaseFast && zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh`
Expected: all green; the Swift count is the old 548 plus the new ones.

- [ ] **Step 5: Commit**

```bash
git add ps1-capi ps1-session build.zig ps1-macos
git commit -m "feat: Ps1SessionSettings crosses the session ABI whole"
```

### Task 4: The app sends one value and folds nothing

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift`, `Sources/PS1/GameWindowView.swift`, `Sources/PS1/VramReadbacks.swift`, `Sources/PS1/PgxpPreset.swift`
- Test: `Tests/PS1Tests/VramReadbacksTests.swift`, `Tests/PS1Tests/SaveStateViewModelTests.swift`, `Tests/PS1Tests/SessionSettingsTests.swift`

**Interfaces:**
- Consumes: Task 3's `SessionSettings`, `GameSession.setSettings`, `requestSwap(_:readbacks:_:)`, `ScriptedSession.settings` / `pendingSwap`.
- Produces:
  - `private var sessionSettings: SessionSettings` carries the PLAYER's PGXP values, `pgxpSetting.usePresets`, and `vramReadbacksSetting.choice(serial: discSerial)`.
  - `private func pushSettings() { session?.setSettings(sessionSettings) }` is the one hand-over. It replaces `pushPgxp`, `pushVramMode`, and every setter's own `session?.set…` for gain, engine, runahead, rewind budget, scale, dither and both filters. `internalScale`, `ditherMode`, `textureFilter` and `spriteFilter` call it from their setters. `GameWindowView` drops their four `onChange` hand-overs and keeps the band's.
  - `load(disc:)` sends no setting after `makeSession`: the config carries them. The per-setting block before `start()` keeps only `setSpeed` and `setBandShown`.
  - `changeDisc` no longer sets `discPgxpPreset` or `discSerial`. Its completion sets both when `error == nil`, then calls `pushSettings()`, so the struct's choice catches up with the session's without changing it.
  - Deleted: `pgxpSettings` (the fold), `pushVramMode`, `VramReadbacksSetting.mode` and its test. `PgxpPreset`'s doc comment now says the session folds the preset; Swift reads it for the UI only.

- [ ] **Step 1: Write the failing tests**
  - `SessionSettingsTests.swift`, `aBootCarriesEverySettingInTheConfig`: capture `cfg` in `model.makeSession`, `load(disc:)` → `cfg.settings == model`'s settings (gain, engine, runahead, rewind, scale, dither, filters, player PGXP, use-presets), and `session.calls` has no `"setSettings"` before `"start()"`.
  - `theSettingsCarryThePlayersPgxpNotThePresets`: a running game on `"SCES-00010"` (`installSessionForTesting`, then a swap answered `nil`), player `pgxpCpu = false` → `session.settings.last?.pgxp.cpu == false` and `pgxpUsePresets == true`.
  - `eachSettingChangeSendsOneValue`: setting `internalScale = 3` → `session.settings.last?.scale == 3` and exactly one new `"setSettings"` call. Same for `ditherMode`, `textureFilter`, `spriteFilter`, `pgxpEnabled`, `cpuEngine`, `runaheadFrames`, `rewindMemoryMB` and the volume, in one table-driven test.
  - `aSwapCarriesTheIncomingDiscsChoice` (replaces `aSwapFoldsTheNewDiscsRow`): the choice `.on` stored for `"SLUS-00594"` → `changeDisc` to it → `session.pendingSwap?.readbacks == .on`.
  - `aRefusedSwapKeepsTheOldDiscsPreset`: running `"SLUS-00707"`; `changeDisc` to `"SCES-00010"`; before the answer `model.pgxpPreset == nil`; `answerSwap(.badCue)` → still `nil`, `discSerial == "SLUS-00707"`. Then `changeDisc` again and `answerSwap(nil)` → `model.pgxpPreset?.cpu == true`.
  - `changingTheChoicePushesAtOnce` (updated): `session.settings.last?.vramReadbacks == .on`.
  - Delete `aBootPushesTheFoldedModeBeforeStart` and `theModeFollowsTheChoiceAndOnlyAutomaticReadsTheTable`. The config test and Task 1 cover them. Update `SaveStateViewModelTests`'s "settings before start" test to assert on `cfg.settings` and on `setSpeed`/`setBandShown` before `start()`.

- [ ] **Step 2: Run them to verify they fail**

Run: `pkill -x Substation; ps1-macos/test.sh`
Expected: the new tests fail (no `setSettings` from the setters; the preset set at request time).

- [ ] **Step 3: Implement** the Interfaces above.

- [ ] **Step 4: Run the gates**

Run: `pkill -x Substation; ps1-macos/test.sh && zig build macos`
Expected: green, the app bundle built.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos
git commit -m "feat: the app hands the session one settings value and folds no table"
```

### Task 5: The old setters leave the ABI; docs

**Files:**
- Modify: `ps1-capi/include/ps1_session.h`, `ps1-session/src/abi.zig`, `ps1-session/src/session.zig` (any helper left unused), `build.zig`, `ps1-macos/Sources/PS1/GameSession.swift`, `Tests/PS1Tests/ScriptedSession.swift`
- Modify: `CLAUDE.md`, `.claude/skills/ps1-macos-app/SKILL.md`

**Interfaces:**
- Removed from C, `abi.zig`, `GameSession` (protocol and `Session`) and `ScriptedSession`: `set_pgxp`, `set_cpu_engine`, `set_rewind_budget`, `set_runahead`, `set_vram_mode`, `set_gain`, `set_dither`, `set_texture_filter`, `set_sprite_filter`, `set_scale`. `PS1_VRAM_DUAL`/`PS1_VRAM_GPU` stay if anything still reads them, otherwise they go.

- [ ] **Step 1: Delete** them. `grep -rn 'ps1_session_set_\(pgxp\|cpu_engine\|rewind_budget\|runahead\|vram_mode\|gain\|dither\|texture_filter\|sprite_filter\|scale\)\b' --include='*.zig' --include='*.swift' --include='*.h' --include='*.md' . | grep -v 'docs/superpowers'` → empty.

- [ ] **Step 2: Extend the `nm` check** in `build.zig` with an absence test beside `_ps1_take_frame_stream`'s: `_ps1_session_set_pgxp` must be ABSENT, with the message "libps1core.a still exports _ps1_session_set_pgxp".

- [ ] **Step 3: Reword the two CLAUDE.md rules**:
  - "A per-game preset is FOLDED IN by the session, never applied by the core." `pgxp_presets.zon` is generated, and `ps1-session/src/settings.zig` folds it when a disc goes in: at creation, and when a swap is ANSWERED. The app sends the player's values only. A bare `ps1.h` handle's host folds it itself.
  - "The VRAM readback table is generated and folded in by the session, never applied by the core", exactly as the preset is. The player's per-serial choice crosses in `Ps1SessionSettings.vram_readbacks`, and with a swap as its parameter.
  - In the Quick commands row for `capi-lib`, "unless the per-game table or the Video menu says dual" stays true. Leave it.
  - In `ps1-macos-app/SKILL.md`, replace every mention of the per-setting session calls, `pushPgxp`, `pushVramMode` or `pgxpSettings` with `pushSettings`/`sessionSettings` and the rule that the session folds.

- [ ] **Step 4: Run every gate**

Run: `zig build test && zig build test-metal -Doptimize=ReleaseFast && zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh && zig build macos`
Expected: all green; the `nm` check passes with the new requirement and the new absence.

- [ ] **Step 5: Commit**

```bash
git add -A ps1-capi ps1-session build.zig ps1-macos CLAUDE.md .claude/skills/ps1-macos-app/SKILL.md
git commit -m "refactor: the ten per-setting session calls leave the ABI"
```

### Hand check (the owner, after Task 5)

A game starts with the saved scale, filters, dither, volume and engine. A change to each in Settings takes effect live. WipEout (SCES-00010) with Per-Game Fixes on shows its preset footer and runs with CPU mode on. A listed readbacks game (Automatic) logs `VRAM mode -> dual`, and Video ▸ Accurate VRAM Readbacks ▸ Off switches it live. A disc swap on a multi-disc game keeps working and the footer follows the new disc.
