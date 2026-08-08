# SPU Reverb — Design

**Date:** 2026-08-08
**Status:** Approved, ready for planning
**Scope:** `ps1-core` SPU only. No frontend, ABI or build-graph changes.

---

## Problem

`Spu.doReverb` (`ps1-core/src/spu.zig:521`) is fully written and has **no call
sites**. `generateSample` accumulates `left_reverb_mix` / `right_reverb_mix`
(`spu.zig:748-751`) and discards them. Reverb therefore affects nothing, and the
~90 lines of fixed-point DSP have never executed — they are unverified, not
merely unused.

Diffing against `avocado_ref/src/device/spu/{spu.cpp,reverb.cpp}` — the
authoritative reference for this port — finds five gaps:

| # | Gap | Avocado reference |
|---|---|---|
| 1 | No call site. | `spu.cpp:115-119` |
| 2 | No half-rate tick. Reverb runs at 22.05 kHz: `doReverb` is invoked on every *other* 44.1 kHz sample and the previous output is **re-added** on the odd sample. We have no counter and no persisted output. | `spu.cpp:115-119` |
| 3 | No master-reverb gate. SPUCNT bit 7 gates the reverb SRAM **writes only** — reads still happen, the output is still produced, and `reverb_curr_addr` still advances. We have no bit-7 check, so enabling reverb would scribble into SPU RAM even for a game that has reverb off. | `reverb.cpp:39-43` (the `W` lambda) |
| 4 | `reverb_curr_addr` is never reset. Avocado resets it to `reverbBase * 8` on a write to 0x1F801DA2. `spu.zig:451` only latches `reverb_base`, so the write cursor stays wherever it drifted to. | `spu.cpp:429-431` |
| 5 | No CD-audio reverb send. SPUCNT bit 2 routes CD audio into the reverb bus (bit 3 does the same for external audio). Only the voice sends via `von` are accumulated. | `spu.cpp:103-108` |

The DSP math itself checks out on inspection: our `>>15`-plus-clamp translation
matches Avocado's `Sample` operators, and `(Lout * reverb_vol_l) >> 15` correctly
matches their **plain** (non-sweep) `reverbVolume.getLeft()`. That is an
inspection result, not a verified one — hence the golden-test requirement below.

**There is no reverb test ROM.** `test-roms/jaczekanski/spu/` contains
memory-transfer, stereo, playback, ram-sandbox and toolbox; none exercises reverb
and none has a golden that would catch a defect here.

## Non-goals

Explicitly out of scope, to be taken up separately if ever:

- **SPU capture buffers** (CD L/R and voice 1/3 mirrored into SPU RAM
  0x000-0xFFF, `spu.cpp:135-140`). A distinct feature; some games read them.
- **SPUCNT bit 14 (unmute)** gating the voice sum. Real behaviour we lack, but it
  is independent of reverb and can silence currently-working audio.
- **Volume sweeps** (bit 15 of the volume registers), still masked off.
- **The `left_mix` / `right_mix` accumulation width.** Avocado saturates the main
  sum to i16 on every `+=`; we accumulate in unclamped i32. This is the same
  divergence being fixed for the reverb *send*, but the main mix is existing,
  working code, and changing it is a different project with a different blast
  radius. Deliberately left alone.

---

## Design

### Core changes — `ps1-core/src/spu.zig`

**New state on `Spu`.** All plain POD, so the future save-state work captures
them for free:

```zig
reverb_enable: bool = true,   // host toggle, not hardware
reverb_counter: u32 = 0,      // half-rate divider
reverb_out_l: i32 = 0,        // last doReverb output, held across the sample pair
reverb_out_r: i32 = 0,
```

`reverb_enable` has no hardware counterpart. It exists because reverb currently
affects nothing, real-game audio has no automated coverage, and one field flip
must be able to isolate a regression without a code edit. It is also a plausible
user-facing setting in the eventual SwiftUI frontend.

**Change 1 — reset the write cursor.** `spu.zig:451`, the 0x1DA2 write, becomes:

```zig
0x1DA2 => {
    self.reverb_base = value;
    self.reverb_curr_addr = @as(u32, value) * 8;
},
```

**Change 2 — the master-reverb write gate.** Placed inside `writeReverbSram`
(`spu.zig:514`), *not* at its call sites — this mirrors Avocado's `W` lambda and
covers all six write sites in one place:

```zig
fn writeReverbSram(self: *Self, address: u32, sample: i32) void {
    if ((self.spu_cnt & (1 << 7)) == 0) return;   // masterReverb
    ...unchanged...
}
```

`readReverbSram` stays ungated and the `reverb_curr_addr` advance at the end of
`doReverb` stays unconditional. That asymmetry is the hardware behaviour, not an
oversight; test 3 pins it.

**Change 3 — the sends.** The existing voice send (`spu.zig:748-751`) accumulates
into an unclamped i32; Avocado accumulates into `Sample`, which saturates to i16
on every `+=`. Clamp each contribution to `[-32768, 32767]` as it is added, so
the reverb send matches. Then add the two missing sends immediately after their
respective mixes in `generateSample`:

- CD → reverb send when SPUCNT **bit 0** (cdEnable) **and bit 2** (cdReverb) are
  both set, using the same `cd_vol_*`-scaled values already added to `left_mix`.
- Ext → reverb send when SPUCNT **bit 1** **and bit 3** are both set, likewise.
  Avocado has no external-audio path at all; this mirrors the CD case because we
  do maintain `current_ext_l/r`.

**Change 4 — the call site.** Placed after the external-audio mix and **before**
main volume, matching `spu.cpp:115-119`:

```zig
if (self.reverb_enable) {
    if (self.reverb_counter % 2 == 0) {
        const r = self.doReverb(left_reverb_mix, right_reverb_mix);
        self.reverb_out_l = r.l;
        self.reverb_out_r = r.r;
    }
    self.reverb_counter +%= 1;
    left_mix += self.reverb_out_l;
    right_mix += self.reverb_out_r;
} else {
    self.reverb_out_l = 0;   // so a later re-enable starts clean
    self.reverb_out_r = 0;
}
```

Re-adding the *same* value on the odd sample is the 22.05 kHz rate, not a bug.

### Data flow

Unchanged except for the one new stage:

```
voices ──> left_mix / right_mix
      └──> left_reverb_mix / right_reverb_mix   (if von bit set)
CD    ──> left_mix          (if SPUCNT bit 0)
      └──> reverb send      (if SPUCNT bits 0 and 2)
Ext   ──> left_mix          (if SPUCNT bit 1)
      └──> reverb send      (if SPUCNT bits 1 and 3)
                    │
              REVERB, half-rate, writes gated on SPUCNT bit 7   <-- new
                    │
              main volume ──> output_buffer
```

---

## Verification

### Golden generator

`avocado_ref/src/platform/headless/reverb_golden.cpp`, alongside the existing
`gte_golden.cpp`, built by an added `clang++` target in
`avocado_ref/build_headless.sh` (which today produces only `avocado_headless`;
`gte_golden` was built by the same pattern). It instantiates Avocado's real `SPU`
class, so the reference is the reference implementation rather than a
transcription of it.

**The generator configures the SPU through its register write path**
(0x1F801DC0..0x1F801DFF for the 32 reverb registers, 0x1F801DA2 for the base,
0x1F801D84/86 for the reverb volume, 0x1F801DAA for SPUCNT) rather than poking
members directly, so it exercises the same path a game would.

Common fixture state for both cases: SPU RAM zeroed, reverb volume
`0x7FFF/0x7FFF`, SPUCNT bit 7 set, and the **Hall** preset from the PSX-SPX
reverb-preset table loaded into the 32 reverb registers.

To guarantee the two sides cannot drift, the Hall preset is transcribed **once**
into `ps1-core/tests/goldens/reverb_preset_hall.zig` as a `[32]i16` array, and
the generator reads the identical 32 values. Any change to the preset must change
that one file and regenerate the goldens.

Two cases, 512 `doReverb` invocations each:

1. **Impulse** — a single input pair of `0x4000/0x4000`, then silence. The
   impulse response is the sharpest available detector: a wrong register index, a
   swapped L/R, or an off-by-one shift moves or rescales a tap and shows up
   immediately.
2. **Pseudo-random** — a fixed LCG (seed and constants recorded in the generator
   and mirrored in the Zig fixture) driving both channels. The impulse never
   approaches saturation; this case does, so it reaches the clamp and overflow
   behaviour the impulse cannot.

Each case emits 512 little-endian i16 pairs to
`ps1-core/tests/goldens/reverb_impulse.bin` and `reverb_noise.bin`.

**The goldens are committed; the generator cannot be** — `avocado_ref/` is
gitignored. The rebuild recipe therefore lives in this spec and in the
implementation plan, following the precedent set by the GTE Avocado replay
harness.

### Tests — `ps1-core/tests/spu_test.zig`

Reuse the file's existing `TestSystem`, which heap-allocates a `Bus`. `Spu` is
larger than 512 KB (the SRAM array) and must never be stack-allocated in a test.

| # | Test | Catches |
|---|---|---|
| 1 | Impulse response matches `reverb_impulse.bin` exactly, all 512 pairs | Wrong tap, shift or register index in the DSP math |
| 2 | Pseudo-random response matches `reverb_noise.bin` exactly | Clamp and saturation divergence |
| 3 | Pre-seed the reverb SRAM region with known non-zero data, then clear SPUCNT bit 7 and run `doReverb`: SPU RAM is byte-for-byte unchanged, yet `reverb_curr_addr` advances by 2 and the returned output is non-zero (derived from the seeded reads) | Gap 3, including the read/write asymmetry |
| 4 | Writing 0x1F801DA2 sets `reverb_curr_addr` to `value * 8` | Gap 4 |
| 5 | Two consecutive `generateSample` calls advance `reverb_curr_addr` by exactly 2, and add the same reverb output twice | Gap 2 |
| 6 | CD audio reaches the reverb send only when SPUCNT bits 0 **and** 2 are both set | Gap 5 |
| 7 | With `reverb_enable = false`, N `generateSample` calls leave `reverb_out_l`/`reverb_out_r` at 0, `reverb_curr_addr` unmoved and SPU RAM unchanged — i.e. the reverb stage contributes exactly nothing, which is today's behaviour | Regression guard on the toggle |

Test 5 needs no test hook: `reverb_curr_addr` advances by 2 per `doReverb` call
and is therefore the observable for "the reverb ran".

Tests 1 and 2 drive `doReverb` directly (matching how the generator produces the
goldens) so the DSP core is compared in isolation. Tests 3-7 go through
`generateSample` and cover the plumbing.

### Risks

- **The goldens cover the DSP core only.** The generator calls `doReverb` with
  i16 inputs, so it cannot exercise the send accumulation. Test 6 and the
  per-contribution clamp cover that side.
- **Enabling reverb changes the audio of most games, with no automated
  coverage.** Test 7 plus default-on `reverb_enable` means a single field flip
  isolates any regression found by ear.
- **`build_headless.sh` currently produces one binary.** Adding a second target
  must not disturb `avocado_headless` or `gte_golden`.

---

## Files touched

| File | Change |
|---|---|
| `ps1-core/src/spu.zig` | 4 new fields, the 0x1DA2 cursor reset, the bit-7 write gate, clamped sends + CD/ext sends, the call site |
| `ps1-core/tests/spu_test.zig` | 7 new tests |
| `ps1-core/tests/goldens/reverb_impulse.bin` | New — 512 i16 pairs |
| `ps1-core/tests/goldens/reverb_noise.bin` | New — 512 i16 pairs |
| `ps1-core/tests/goldens/reverb_preset_hall.zig` | New — the shared `[32]i16` preset |
| `avocado_ref/src/platform/headless/reverb_golden.cpp` | New, gitignored; recipe recorded here |
| `avocado_ref/build_headless.sh` | New target, gitignored |
| `AGENTS.md` | §3 "Reverb & Delay" checkbox |
| `CLAUDE.md` | SPU cheat-sheet: "reverb is fully implemented but never called" becomes false |

## Definition of done

`zig build test` passes with the 7 new tests green, `AGENTS.md` and `CLAUDE.md`
reflect the new state, and `reverb_enable = false` demonstrably reproduces the
old output.
