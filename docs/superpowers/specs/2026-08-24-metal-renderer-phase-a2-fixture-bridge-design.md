# Metal Renderer Phase A2 — The Fixture Bridge

**Goal:** define the on-disk fixture format for a recorded GP0 command stream,
and build both ends of it — a Zig capture tool and a Swift loader — so that
Phase B has a runnable gate before any Metal rasterization exists to confound
it.

**Parent spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`,
§ Phase A2. This document supersedes that section's sketch where the two differ;
the differences are called out in § Departures from the parent spec.

**Prerequisite:** Phase A is landed (`d6ecd4f`, `c92447d`). `command.Command` is
an `extern struct` pinned at 72 bytes, `command.replay` exists, and
`trace-golden -- stream-verify` proves the stream lossless across 23,449 frames
of ten workloads.

---

## Why this phase exists

The parent spec's rationale is that Metal runs only under `ps1-macos/test.sh`
while the ROM suites run only in Zig, so no Swift test can boot a ROM and no Zig
test can run Metal. That is true, but it is **not sufficient** to justify a file
format, and the plan should not rest on it.

The alternative it does not consider is to skip the file entirely: extend the C
ABI so a Swift test drives the core in-process, boots a PL ROM, takes the frame
stream live, and compares. That tests the transport **production actually
uses** — `ps1_take_frame_stream`, in-process, live — whereas a fixture file
tests a transport production never touches. For the PL ROMs it is even viable:
25M instructions of BIOS boot plus a 10M-instruction run, six times over, is
seconds.

It dies on real-game content. A Swift unit test cannot boot the ~300M
instructions it takes to reach Croc's FMV, and Debug is the default optimize
mode for `libps1core.a`, where the core runs at roughly 0.45x real time. So:

> **The fixture file exists because a Swift test cannot generate real-game
> frames in-process.** Everything else about it follows from that one
> constraint. Once the file exists for Croc, carrying the PL ROMs in it too is
> free.

This narrower rationale also constrains the phase honestly. See the next
section.

## What A2 proves, and what it merely banks

The parent spec's gate — "a Swift test loads a fixture, replays it through a
stub backend that simply applies the stream to a CPU VRAM array, and matches the
recorded hashes" — is not achievable as written. Matching a **full-VRAM** hash
requires rasterizing: edge functions, texture decode, CLUT, blending, dithering.
That is Phase B's entire job, and writing it twice would create exactly the
second transcription of "what a textured triangle means" that Phase A's Decision
3 was built to prevent.

A2 therefore has a **split gate**.

**Proved by execution, in Swift:**

1. The byte format round-trips — a fixture written by Zig decodes in Swift with
   the same record count, kinds and field values.
2. The hash convention agrees across the two languages.
3. The memory-mover commands agree: `fill_rect`, `copy_rect`,
   `vram_write_setup`, `vram_write_data`, `vram_write_abort`, and the `E6` mask
   they read.

All three are proved by **one small synthetic fixture** containing only
memory-mover commands. No rasterizer is needed to verify it, and its VRAM hashes
are genuinely checked.

**Banked for Phase B, structurally checked only:**

The PL ROM fixtures and the Croc window decode and are asserted well-formed
(counts consistent, offsets in range, kinds valid), but their per-frame VRAM
hashes are **not verified in A2** — nothing on the Swift side can yet produce a
rasterized frame to compare against. Phase B is where those hashes become live.

Stating this plainly is the point. A2 is a bridge phase; it must not be written
up as though it validates real-game rendering.

---

## The record type lives in `ps1.h`

The fixture's record is `command.Command` verbatim. Its Apple-side definition
belongs in **`ps1-capi/include/ps1.h`**, not in a Swift struct.

Swift does not guarantee C-compatible layout for its own structs. A raw 72-byte
read into a Swift struct would rely on something the language does not promise,
guarded only by a stride assertion that catches size drift but not field
reordering. Declaring it in C and importing it through the existing `CPs1`
module makes the layout a fact rather than a coincidence — and `ps1.h` is
already the file CLAUDE.md describes as the reviewable contract that a rename in
Zig cannot silently break.

```c
typedef struct {
    int16_t  x, y;
    uint8_t  u, v;
    uint16_t _pad;
    uint32_t color;      /* 24-bit BGR as it arrives on the wire */
} Ps1GpuVertex;          /* 12 bytes */

typedef struct {
    uint8_t  kind;       /* Ps1GpuCommandKind */
    uint8_t  opcode;
    uint8_t  transparent;
    uint8_t  _pad0;
    uint32_t value;
    uint16_t clut;
    uint16_t tpage;
    int32_t  x, y, x2, y2, w, h;
    Ps1GpuVertex v[3];
} Ps1GpuCommand;         /* 72 bytes */
```

The `kind` enumeration is mirrored as `#define`s or a C enum in the same header,
in the same order as `command.Kind`.

**This touches `ps1-capi`, which Phase A's Decision 5 deliberately left
alone.** That decision deferred `ps1-capi` because flipping it to `gpu_sink =
.dual` would add ~6.5 MB to the app's `Bus` for no consumer. A2 adds a **type**,
not the function and not the sink switch: `ps1_take_frame_stream` and the
`.dual` build remain Phase B. Decision 5 is narrowed here, not overturned.

Phase B benefits directly — it needs this C type for the ABI handoff and for the
Metal shader's buffer layout, so A2 writes it once rather than twice.

---

## The fixture format (`.p1fx`)

Little-endian throughout, three regions after a fixed header, no compression.
Both producers and consumers assert little-endianness rather than assuming it.

```
offset  size                      field
------  ------------------------  -----------------------------------------
0       8                         magic "PS1FIXT\0"
8       4                         version u32 (currently 1)
12      4                         record_stride u32 (72)
16      4                         kind_count u32 (17)
20      4                         frame_count u32
24      8                         total_records u64
32      8                         total_payload_words u64
40      8                         reserved u64 (zero)
48      24 * frame_count          frame table
...     72 * total_records        records
...     4  * total_payload_words  payload
```

Frame table entry, 24 bytes:

```
0   4   record_off    u32   index into the records region
4   4   record_count  u32
8   4   payload_off   u32   index into the payload region, in WORDS
12  4   payload_count u32
16  8   vram_hash     u64   FNV-1a 64 over full VRAM after this frame
```

### Two guards that earn their place

`record_stride` is checked against `sizeof(Ps1GpuCommand)` on load. A field added
to `command.Command` then fails the Swift test loudly instead of silently
shearing every record in the file.

`kind_count` is checked against the consumer's own enumeration size. That covers
the other half: a new `Kind` added in Zig with no mirror in `ps1.h` is caught at
load rather than surfacing in Phase B as an unrecognised record.

### Payload offsets stay frame-relative

A `vram_write_data` record's `.x` field indexes into **its own frame's** payload
run, which is exactly what `command.replay` already assumes. The frame table
carries the base into the concatenated region; a consumer slices
`payload[payload_off ..< payload_off + payload_count]` and hands that slice over
unchanged.

Neither side rebases anything. This is deliberate: rebasing is arithmetic, and
arithmetic done twice in two languages is arithmetic that can disagree.

### Reproducibility

The same tree, the same BIOS and the same disc must produce a **byte-identical**
fixture. `ps1-golden`'s button schedule is instruction-indexed and
deterministic, and the core has no VRAM-touching randomness, so this holds
today; the capture tool must not introduce timestamps, paths or hash-map
iteration order into the file.

---

## The hash: FNV-1a 64

```
h = 0xcbf29ce484222325
for each byte b:  h ^= b;  h *= 0x100000001b3   (mod 2^64)
```

VRAM is hashed as its 524,288 `u16` pixels in **little-endian byte order**,
row-major, the full 1024x512 — not the display window.

### Why not Wyhash

`ps1-golden/src/state_hash.zig` uses `std.hash.Wyhash`, and reusing it here would
be a mistake on two counts. It is a standard-library implementation that may
change across Zig releases, so a fixture format pinned to it breaks silently on
a toolchain upgrade — and the failure would present as "Swift disagrees with
Zig", which is the single most confusing shape a bridge bug can take.
Reimplementing it in Swift is also roughly sixty subtle lines. FNV-1a 64 is six
lines in either language and is frozen by definition.

The trace harness keeps Wyhash. The two hashes serve different masters and there
is no value in sharing one.

### Test vectors

Each side is pinned against these independently, so neither is verified only
against the other:

| Input | FNV-1a 64 |
|---|---|
| `""` (empty) | `0xcbf29ce484222325` |
| `"a"` | `0xaf63dc4c8601ec8c` |
| `"foobar"` | `0x85944171f73967e8` |
| `u16[] { 0x0000, 0x7FFF, 0x8001, 0x1234 }` LE | `0x1b86415c70511fc8` |
| an all-zero 1024x512 VRAM | `0xa96777069d622325` |

The fourth vector pins the byte order the third cannot, and the fifth pins the
extent.

---

## Capture: `trace-golden -- stream-capture`

A fourth mode on `ps1-golden`, alongside `capture`, `verify` and
`stream-verify`. It reuses `loadMachine`, the workload table, BIOS
auto-selection, `--filter`, and the armed recorder — `stream-verify` already is
this minus the writing.

It needs one addition: an **EXE-sideload workload kind** for the PL ROMs, which
today only `peterlemon_test.zig` knows how to load. `loadMachine` gains a branch
that calls `cpu.loadExe` after the BIOS boot instead of attaching a disc.

New flags:

- `--out=<dir>` — where fixtures are written. Defaults to `zig-out/fixtures`.
- `--capture-from=<instr>` — begin recording frames once the instruction
  counter reaches this value.
- `--frames=<n>` — stop after this many frames.

**The window is pinned by instruction count, not by frame number.** The button
schedule is instruction-indexed, so an instruction is reproducible in a way a
frame ordinal is not.

### Risk to the standing gate

`ps1-golden` is the regression gate for the whole core, so a change to it is a
change to the thing that would notice a regression. The mitigation is the one
Task 7 of Phase A already used successfully for a change of this same shape:
`verify`'s path must be untouched, and `zig build trace-golden -- verify` must
report 10/10 in the same commit.

### PL cycle budgets are not shared

The capture tool picks its **own** instruction budget for the PL ROMs rather
than mirroring `peterlemon_test.zig`'s. The fixture does not need to match the
test's budget — it needs only to be deterministic — so the only thing duplicated
between the two files is six file paths, and a divergence in budgets becomes
harmless rather than silent. The tool asserts each path exists.

---

## The fixture set

| Fixture | Source | Committed? |
|---|---|---|
| `synthetic-movers.p1fx` | built in-tool, no BIOS or disc | **yes** |
| `pl-<name>.p1fx` x6 | the six PeterLemon ROMs | no |
| `croc-window.p1fx` | Croc, a measured window | no |

The synthetic fixture is committed, unlike the rest. It is a few kilobytes, it
needs neither a BIOS nor a disc, and it is the **only** fixture whose hashes A2
actually verifies — so committing it makes the executable gate runnable on a
fresh clone with zero prerequisites, and gives the format a checked-in example
that would catch an accidental format change during review. The parent spec's
"fixtures must be generated rather than committed" is a rule about gigabytes of
real-game frames; it does not reach this case.

### The synthetic fixture's content

Several frames of memory-mover commands only, chosen to cover the traps Phase A
had to get right:

- `fill_rect` **unmasked**, over pixels whose bit 15 is set — hardware ignores
  `E6` for fills, and this is the one write that must ignore it.
- `copy_rect` **masked**, including a source and destination that overlap in
  both directions.
- `vram_write_setup` with `w == 0` and `h == 0`, which mean the whole axis
  rather than an empty rectangle.
- A payload run interrupted by `vram_write_abort` mid-transfer.
- `set_draw_env` `E6` toggling both mask bits between the above.

### The Croc window is a measured value, not a chosen one

Croc is in the set because it exercises FMV — large `A0` payloads and 24bpp
uploads that the PL ROMs never produce. The window must therefore sit where that
traffic is heaviest, and **this document does not name an instruction, because
it is not yet known.** The implementation plan carries a measurement step: dump
per-frame payload-word counts across a full Croc run, pick the densest window,
and pin that number.

This project's rule is verify, don't guess. A frame number written from
intuition here would be a number nobody could later defend.

### A fresh clone has no `games/`

`games/` is gitignored, so `croc-window.p1fx` cannot be generated on a machine
without the disc. The Swift test must **skip with a clear reason** when a
fixture is absent, never fail — matching how the ROM suites self-skip under
`enable_rom_tests = false`. Absent tools are not failures; absent *results*
claimed as passes are.

---

## The Swift side

Two files in `Sources/PS1`, not in the test target, because Phase B consumes
both:

- **`FixtureFile.swift`** — parses the format, exposes frames as slices over the
  records and payload regions, and performs the `record_stride` and `kind_count`
  checks on load.
- **`ShadowVram.swift`** — a `[UInt16]` of 1024x512 plus the memory movers:
  `fill`, `copy` (overlap-aware), `setupWrite`, `writeData`, `abort`, and the
  masked-store rule they share.

`ShadowVram` is a second transcription, and A2 accepts it knowingly. It
duplicates the **memory movers only** — roughly 120 lines mirroring
`vram.zig:51-198` — and never the rasterizer. It is also not scaffolding: those
are precisely the `02`/`80`/`A0` passes Phase B has to build anyway, so A2
writes them one phase early and puts a hash gate on them.

The record type itself is imported from `CPs1`; nothing in Swift redeclares it.

One test file, `Tests/PS1Tests/FixtureBridgeTests.swift`, covering the hash
vectors, the synthetic fixture's executable gate, the structural checks on the
banked fixtures, and the skip-when-absent behaviour.

---

## Running the gates

Fixtures are generated into `zig-out/fixtures/`, which is already gitignored via
`/zig-out/`.

`zig build fixtures` wraps the capture invocation. `ps1-macos/test.sh` grows a
third prerequisite check in the same shape as the two it already has for
`libps1core.a` and `libps1shaders.a` — but it must **warn rather than exit**,
since the committed synthetic fixture is enough to run the executable gate and
the rest legitimately cannot exist on every machine.

---

## Gates

| Check | Command | Expected |
|---|---|---|
| Core unchanged | `zig build trace-golden -Doptimize=ReleaseFast -- verify` | 10/10 OK |
| Stream unchanged | `zig build trace-golden -Doptimize=ReleaseFast -- stream-verify` | 10/10 OK |
| Unit tests | `zig build test` | green |
| ROM ratchet unmoved | `zig build test-roms-pl -Doptimize=ReleaseFast` | green, floors unmoved |
| Fixtures generate | `zig build fixtures` | 7 files, plus `croc-window.p1fx` where `games/` exists; every one reproducible byte-for-byte on a second run |
| The bridge | `ps1-macos/test.sh` | green, incl. the new fixture tests |
| ABI still builds | `zig build capi-lib` | builds |

A2 changes no emulated behaviour, so the first four are freeze checks: a moved
golden or floor is a bug in the capture tool, not a baseline to update.

---

## Departures from the parent spec

1. **The gate is split.** The parent's single gate is not achievable as written;
   § What A2 proves replaces it.
2. **The rationale is narrower.** The parent's test-environment argument is true
   but insufficient; the real constraint is that a Swift test cannot generate
   real-game frames in-process.
3. **`ps1-capi` is touched.** Phase A's Decision 5 is narrowed to permit the
   record *type* in `ps1.h`, while `ps1_take_frame_stream` and the `.dual` build
   stay in Phase B.
4. **One fixture is committed.** The generated-not-committed rule is about
   real-game volume and does not reach the few-kilobyte synthetic fixture.

---

## What A2 deliberately does not do

- No Metal, no shader, no rasterization of any kind in Swift.
- No `ps1_take_frame_stream`, and no `gpu_sink = .dual` for `ps1-capi`. Phase B.
- No verification of the PL or Croc fixtures' VRAM hashes — nothing exists yet
  to check them against.
- No fixture for every disc. One real-game window is enough to prove the format
  survives real payload sizes; breadth is `stream-verify`'s job, in Zig.
- No compression, no versioning migration path. Version 1 is the only version;
  a format change bumps it and regenerates, because fixtures are artifacts.
