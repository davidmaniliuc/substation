# PGXP in emitted code (roadmap item 6)

Date: 2026-10-15. Status: design, approved in conversation as option B.
Roadmap: `2026-10-09-core-performance-roadmap.md`, item 6.

## Goal

Cut what PGXP's shadow work costs the JIT in the configuration players get
when they turn PGXP on: `.jit`, CPU mode ON (it ships on). Every shadow the
emitted code writes stays **byte-identical** to what the shim writes today,
so `.jit` still equals `.cached` field for field, floats included.

## Measured first (2026-10-15)

Spyro, 4000 frames, `ps1-bench-dual --engine=jit threaded pgxp`,
ReleaseFast, xctrace, the emulator thread partitioned by the outermost shim
on each stack:

| Shim | Share of the thread |
|---|---|
| `Hooked(ops.addi)` | 6.8% |
| `loadShim` | 5.3% |
| `Hooked(ops.add)` | 4.2% |
| `Hooked(shift.srl)` | 3.2% |
| `Hooked(ops.sub)` | 2.8% |
| `storeShim` | 2.3% |
| `Hooked(exact)` (`lui`, `slti`, `sltiu`, `slt`, `sltu`) | 2.0% |
| `Hooked(shift.left)` | 2.0% |
| `sra`, `andi`, `bitwise`, `move`, `srav`, `bitwiseImm` | ~2.6% |

About 31% in all, against the roadmap's ~17%. `opShim` (7.7%) is mostly
`opCop` (GTE) and is not PGXP's.

Counts over 3000 frames (temporary probe, reverted):

| | Spyro | Crash Warped | Croc |
|---|---|---|---|
| Hooked calls / result valid | 283M / 87% | 274M / 91% | 268M / 95% |
| `ops.source` reads / valid | 269M / 68% | 245M / 80% | 246M / 74% |
| Word loads / shadow valid | 129M / 85% | 126M / 92% | 108M / 85% |
| Half loads | 6.4M | 5.8M | 23.6M |
| Word stores / shadow valid | 57M / 81% | 52M / 89% | 14M / 95% |
| Half / byte stores | 2.6M / 2.3M | 0.9M / 1.9M | 5.7M / 3.2M |

The shadows are mostly live, so a "skip when invalid" fast path gains
nothing: the cost is the rules' real work. Making `ops.source` inline in the
shims measured as noise. Spyro's fps for scale (noisy, load ~19): PGXP off
~486, base tier ~420, CPU tier ~300.

## Scope

Two steps, each its own commit, each measured:

1. **Pure data movement, inline in every tier.** No PGXP rule is restated,
   only copies and `exactValue`'s integer-to-float conversion.
   - `lw` (inline RAM and scratchpad paths): the table slot copied into the
     load's `Pins.load_shadows` slot (`Bus.shadowLoad`).
   - `sw`: `gpr_shadow[rt]` copied into the table slot AND into
     `Bus.pgxp_pending` (`exec.storeShadow`'s `.Word` arm).
   - `sb`: the table slot and `pgxp_pending` cleared (`.Byte` arm,
     `shadowInvalidate`).
   - The register-move idiom (`addu`/`or rd, rs, $zero`, both tiers):
     `ops.source`'s validation written back to `rs`'s slot, then the copy
     to `rd`.
   - `exact` (CPU tier): `lui`, `slti`, `sltiu`, `slt`, `sltu` write
     `exactValue(result)`.
   - `lh`/`lhu`/`sh` keep their shims: `shadowLoadHalf` mutates the slot
     and both are rare (under 24M per 3000 frames even on Croc).
2. **`addi`/`addiu` in arm64 (CPU tier).** `ops.addi`'s rule emitted with
   the same IEEE operations in the same order.

Out of scope: `add`/`sub`/shifts/`andi`/`bitwise` (option C). They are
reconsidered only from a profile taken after step 2.

## Design

### Reaching the tables

`Pins` gains `ram_shadow: [*]Value`, `scratch_shadow: [*]Value` and
`pgxp_pending: *Value`, set where `BlockCache` builds `Pins` from `Bus`.
The emitted code loads them from x22. Offsets join `layout.zig`'s comptime
checks.

The inline paths already hold the physical address in w10 (RAM, first
2 MB) or the scratchpad offset in w11, so a slot is `table + (offset >> 2)
* 20`. That is the same index `Bus.shadowSlot` computes for those two
ranges. `Bus.shadowLoad`/`shadowStore` gate on `pgxp_enabled`, which is
true whenever a block's tier is not `off` (`Bus.setPgxp` flushes on
change), so the emitted code needs no gate.

The RAM and scratchpad paths currently join at `done`. Each sets a scratch
register to its slot's address before joining, so the shadow work after
`done` is one sequence.

### Ordering

The store copy runs before the op retires, as `afterStore` does now: a
load landing in `rt` has not landed, so `gpr_shadow[rt]` in memory is
`rt`'s old shadow. The emitted code reads memory, never `Pins.load_shadows`.
The load copy goes into `Pins.load_shadows[slot]` exactly where `loadShim`
writes today.

### `exactValue` inline

`{ x = f32(i16(result)), y = f32(i16(result >> 16)), z = 0, word = result,
flags = valid_xy }`: `sxth`/`asr #16`, `scvtf s`, five word stores, from
the result in w9 for every one of the five ops (`lui`'s result is known at
compile time, but one path for all five is simpler and costs a few words).

### The move idiom inline

`source(rs)` writes the validated value back: if `gpr_shadow[rs].word !=
regs[rs]`, store 0 to `gpr_shadow[rs].flags`. Then copy the 20 bytes to
`rd` (skipped when `rd == 0`, as the shim skips it), and store the result
register. `rs == rd` needs no special case: the validation is stored first.

### `addi`/`addiu` inline

`ops.addi(cpu, rs, imm, result)`, with `rs` and `imm` known at compile time:

- **`rs == $zero`:** `gpr_shadow[0]` is always `none` and `regs[0]` is 0.
  The result is a compile-time constant: `none` when `imm == 0`, otherwise
  `{ lowHalf(imm), highHalf(imm), 0, result, valid_xy | tainted_z }`.
- **`imm == 0`:** the validated source with `word = result`.
- **Otherwise:** validate (store `flags = 0` on a word mismatch, as
  `source` writes the table), then branch at run time on `regs[rs] == 0`:
  - zero: the validated source with `x`, `y` set to the two halves of
    `imm` (constants), `flags |= valid_xy | tainted_z`, `word = result`;
  - non-zero, in f64 throughout:
    - `vx = flags & valid_x ? x : f32(i16(rs_val))`, then `x = unsign(f64(vx)) + u16(imm)`
    - `carry = x > 65535 ? 1 : x < 0 ? -1 : 0`
    - `out.x = f32(signFold(x))`
    - `vy = flags & valid_y ? y : f32(i16(rs_val >> 16))`
    - `out.y = f32(foldHigh((f64(vy) + highHalf(imm)) + carry))`
    - `flags = src.flags | tainted_z`, `z = src.z`, `word = result`.

`signFold` is `fmul` by 65536, `fcvtzs x` (which IS `lossyCast(i64, ·)`:
NaN to 0, saturating, truncating toward zero), the low 32 bits sign-
extended, `scvtf d`, and a divide by 65536. `@floatCast` to f32 is `fcvt
s, d` (round to nearest even), as Zig emits it. Zig's default float mode is
strict, so the reference is the same IEEE sequence, not a reassociated one.
The comparisons in `unsign`, the carry and `foldHigh` are `fcmp` plus
`fcsel` against constants, which keeps NaN behaviour as Zig's `<`/`>`/`>=`
(false on NaN).

This needs FP encoders `emit.zig` does not have: `fmov` (general register
to FP and back), `scvtf`, `fcvtzs`, `fcvt`, `fadd`, `fsub`, `fmul`, `fdiv`,
`fcmp`, `fcsel` and `ldr`/`str` of an `s` register, each with a test
against the assembler's encoding as the existing encoders have. Scratch FP
registers are d0-d7, which `Emitter.call`'s callees may clobber and which
nothing in emitted code keeps live across an op.

### Where the code lives

`shadow.zig` keeps the memory side (copies, `afterLoad`, `afterStore`, the
remaining shims). A new `recompiler/arm64/shadow_alu.zig` holds the ALU
side (`move`, `exact`, `addi`) so neither file passes ~300 lines.
`lower_alu.zig`'s `retire` picks the inline form for the hooks it has and
`shadow.hooked` for the rest.

## Gates

- **A differential test of the emitted `addi` against `ops.addi`**: one
  `addiu`/`addi` block run on `.jit` and `.cached` over a table of source
  shadows and immediates, compared byte for byte. The cases are: valid,
  stale and none shadows; `rs_val` zero; `imm` zero, positive and negative;
  halves at 0x7FFF, 0x8000 and 0xFFFF so the carry, the borrow and both
  `foldHigh` arms fire; fractions within 2^-16 of a grid point; and
  magnitudes past 2^47 so `fcvtzs` saturates. Each arm is verified to fail
  with its emitted counterpart deliberately broken.
- `jit_test`'s existing PGXP cases, with `calls` still 0 and new cases for
  the `sw` → `pgxp_pending` copy, an `sb` invalidate, a move whose source is
  stale and `rd == rs`.
- `fuzzLinked` under both tiers (it already compares every shadow byte,
  `pgxp_pending` included). Widen `live`'s seed range so `x` reaches the
  carry boundary.
- `trace-golden -- pgxp --engine=jit`: output byte-identical to the parent
  commit. It fails its floors on master already (roadmap: known nuisance),
  so the comparison is against the parent, not the floors. `pgxp
  --snapshot --engine=jit` likewise.
- `verify --engine=jit`, `lockstep --engine=jit`: unchanged (PGXP off; a
  regression here means the tier-off path was touched).
- `zig build test`.

## Measurement

`ps1-bench-dual … 3000 --engine=jit threaded pgxp` on Spyro, Crash Warped
and Croc. Interleaved, best of three, against a parent build made in a
scratchpad worktree, with `uptime` load checked first. Recorded after each
step in the roadmap's item 6. Step 2 also records a fresh profile, which is
what decides whether option C is worth taking.
