# CHD Disc Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The core, the C ABI, the native harnesses and the macOS app open a `.chd` disc image exactly as they open a `.bin`/`.cue` today.

**Architecture:** A new `ps1-core/src/chd/` reader decodes a CHD v5 on demand: it parses the header and the Huffman-coded hunk map, turns the `CHT2` metadata into the same `Track` table a cue produces, and decompresses 8-sector hunks through a 4-slot cache. `Disc` gets a `source` union (`flat` slice or `chd` reader), and only `leadOut` and `readSector2352` dispatch on it. The C ABI detects the `MComprHD` magic in the `bin` bytes, so no entry point is added.

**Tech Stack:** Zig 0.17.0. Zig's standard library supplies raw deflate (`std.compress.flate`), headerless LZMA (`std.compress.lzma`), zstd (`std.compress.zstd`) and every CRC (`std.hash.crc`). FLAC is written here. The fixtures are made with `chdman` (Homebrew `rom-tools`) and `flac`. The app side is Swift and SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-07-chd-disc-images-design.md`

## Global Constraints

- `zig version` is **0.17.0**. Use `@splat` instead of `**`, `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(n))` for files, and `std.Io.Reader.fixed(bytes)` for an in-memory reader. `zig fmt` rewrites `@intFromEnum` to `@backingInt`; either spelling is fine.
- CHD **v5 only**. Refuse a parent CHD, an uncompressed map, any track type other than `MODE1_RAW`/`MODE2_RAW`/`AUDIO`, metadata other than `CHT2`/`CHTR`, and any codec other than `cdzl`/`cdlz`/`cdzs`/`cdfl`.
- Refusals happen at `Reader.open`. A hunk that fails its CRC16 fails **that read only**, and is logged once.
- Each hunk's CRC16 (`CRC-16/IBM-3740`) covers the **whole** hunk, subcode included. The subcode is therefore decompressed, checked, and then never read.
- An unstored pregap (its `PGTYPE` does not start with `V`) takes **no LBAs**. A stored pregap becomes the track's `pregap_lba`.
- CD audio is stored **big-endian** in a CHD. The reader swaps it back for `AUDIO` tracks only.
- No file in `ps1-core/src` may exceed ~600 lines.
- Every converted copy of a disc in `games/` is deleted as soon as it has been checked. `games/grandtheftauto.chd` belongs to the user and is **never** deleted, moved or rewritten.
- Commits: the title line only, directly on `master`, and **never push**.
- Comments follow `CLAUDE.md`: state the rule, never narrate; no reference emulator named in code or commits.
- Run `zig fmt` on every touched `.zig` file before committing.

## Review Focus

1. **Out-of-order reads across hunks, including self-references.** The drive seeks back and forth between data and CD-DA, and a self-referenced hunk decodes another hunk into its own cache slot. A reverse sweep and an interleaved sweep must read back byte-identical (Task 5).
2. **A truncated or corrupted file.** A partial download or bit rot must fail cleanly and never panic: refused at open, or failing only the affected reads. This holds even inside FLAC, where corrupt residuals could overflow integer arithmetic (Tasks 2, 5).
3. **Swapping or reloading while a CHD is in the drive.** The handle has to close the old reader only after the new disc is installed. A `.bin` loaded after a `.chd` must leave no reader behind (Task 7).
4. **A LibCrypt `.sbi` beside a `.chd`.** `Disc.setSbi` must work on a CHD disc, and the app must find `<stem>.sbi` for a `.chd` URL (Tasks 6, 9).
5. **A CHD the core refuses, met by a library scan.** It must show as an unidentified tile, not crash or vanish, and the C ABI identify must return `PS1_ERR_BAD_CHD` (Tasks 7, 9).

---

## File Structure

| File | Responsibility |
|---|---|
| `ps1-core/src/chd/chd.zig` (create) | `Reader`, `Header`, `parseTrack`, `isChd`; re-exports the submodules |
| `ps1-core/src/chd/bitstream.zig` (create) | MSB-first `BitReader` shared by the map and FLAC |
| `ps1-core/src/chd/flac.zig` (create) | FLAC frame decoder |
| `ps1-core/src/chd/cd.zig` (create) | `Codec`, the CD codec wrapper, ECC regeneration, `Scratch` |
| `ps1-core/src/chd/map.zig` (create) | v5 hunk map decode |
| `ps1-core/src/root.zig` (modify) | `pub const chd = @import("chd/chd.zig");` |
| `ps1-core/src/disc.zig` (modify) | `Source` union, `initFromChd`, `sectorCount` |
| `ps1-core/tests/chd_test.zig` (create) | every core CHD test |
| `ps1-core/tests/chd/` (create) | `make_fixtures.sh` and the fixtures it writes |
| `build.zig` (modify) | `chd_test` in `unit_test_files`; the `cue_files` module |
| `.gitignore` (modify) | un-ignore `ps1-core/tests/chd/*.bin` |
| `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h`, `ps1-capi/src/capi_test.zig` (modify) | detection, handle ownership, `PS1_ERR_BAD_CHD` |
| `ps1-trace/src/cue_files.zig` (create, moved out of `ps1-trace/src/main.zig`) | multi-FILE cue loader shared with `ps1-golden` |
| `ps1-trace/src/main.zig`, `ps1-bench/main.zig` (modify) | open a `.chd` |
| `ps1-golden/src/chd_verify.zig` (create), `ps1-golden/src/main.zig`, `ps1-golden/src/golden.zig` (modify) | `chd-verify`, `verify --cue --chd` |
| `tools/chd-roundtrip.sh` (create) | convert, check, delete, one disc at a time |
| `ps1-macos/Sources/PS1/DiscKind.swift` (create), `GameEntry.swift`, `GameScanner.swift`, `EmulatorViewModel.swift`, `Ps1Core.swift`, `LibraryView.swift`, `OnboardingView.swift`, `ps1-macos/Info.plist` (modify) | the app |
| `ps1-macos/Tests/PS1Tests/DiscKindTests.swift` (create), `GameScannerTests.swift` + every test that passes `isCue:` (modify) | app tests |
| `.claude/skills/ps1-cdrom-disc/SKILL.md`, `CLAUDE.md` (modify) | docs |

---

### Task 1: The bit reader and the `chd` module

**Files:**
- Create: `ps1-core/src/chd/bitstream.zig`
- Create: `ps1-core/src/chd/chd.zig`
- Modify: `ps1-core/src/root.zig` (next to `pub const disc = @import("disc.zig");`, line 12)
- Create: `ps1-core/tests/chd_test.zig`
- Modify: `build.zig:200-218` (`unit_test_files`)

**Interfaces:**
- Produces: `ps1_core.chd.bitstream.BitReader` with `init(bytes)`, `peek(count: u6) u32`, `read(count: u6) u32`, `readSigned(count: u6) i32`, `readUnary() u32`, `skip(count: usize)`, `alignToByte()`, `bytePos() usize`, and the field `overflow: bool`. `count` is 0..32. A read past the end yields zero bits and sets `overflow`.

- [ ] **Step 1: Write the failing tests**

`ps1-core/tests/chd_test.zig`:

```zig
const std = @import("std");
const ps1 = @import("ps1_core");
const chd = ps1.chd;
const BitReader = chd.bitstream.BitReader;

test "the bit reader reads MSB-first across byte boundaries" {
    var br = BitReader.init(&.{ 0b1011_0011, 0b0101_1100, 0xFF });
    try std.testing.expectEqual(@as(u32, 0b101), br.read(3));
    try std.testing.expectEqual(@as(u32, 0b10011_010), br.read(8));
    try std.testing.expectEqual(@as(u32, 0b11100), br.peek(5));
    try std.testing.expectEqual(@as(u32, 0b11100), br.read(5));
    try std.testing.expectEqual(@as(u32, 0xFF), br.read(8));
    try std.testing.expect(!br.overflow);
}

test "the bit reader sign-extends, including a full 32-bit field" {
    var br = BitReader.init(&.{ 0b1110_0000, 0xFF, 0xFF, 0xFF, 0xFE });
    try std.testing.expectEqual(@as(i32, -1), br.readSigned(3));
    try std.testing.expectEqual(@as(i32, 0), br.readSigned(0));
    var full = BitReader.init(&.{ 0xFF, 0xFF, 0xFF, 0xFE });
    try std.testing.expectEqual(@as(i32, -2), full.readSigned(32));
}

test "a unary code counts zeros up to the next one, across a long run" {
    // 70 zero bits then a one: longer than the reader's 57-bit window.
    var bytes: [10]u8 = @splat(0);
    bytes[8] = 0b0000_0010; // bit 70 is the one
    var br = BitReader.init(&bytes);
    try std.testing.expectEqual(@as(u32, 70), br.readUnary());
    try std.testing.expectEqual(@as(usize, 71), br.pos);
}

test "reading past the end yields zeros and flags overflow" {
    var br = BitReader.init(&.{0xFF});
    try std.testing.expectEqual(@as(u32, 0xFF0), br.read(12));
    try std.testing.expect(br.overflow);
}

test "alignToByte skips to the next byte boundary" {
    var br = BitReader.init(&.{ 0xFF, 0xAB });
    _ = br.read(3);
    br.alignToByte();
    try std.testing.expectEqual(@as(usize, 1), br.bytePos());
    try std.testing.expectEqual(@as(u32, 0xAB), br.read(8));
}
```

- [ ] **Step 2: Add the test file to `unit_test_files` in `build.zig`**

Append `"ps1-core/tests/chd_test.zig",` after `"ps1-core/tests/jit_test.zig",`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zig build test -Dtest-filter="bit reader" 2>&1 | tail -5` (if `-Dtest-filter` is not this build's spelling, read `test_filters` in `build.zig` and use that option)
Expected: compile error, `root source file struct 'root' has no member named 'chd'`.

- [ ] **Step 4: Write the implementation**

`ps1-core/src/chd/bitstream.zig`:

```zig
//! MSB-first bit reader for the CHD map and the FLAC decoder. Reading past the
//! end yields zero bits and sets `overflow`, which a caller checks once at a
//! boundary instead of after every field.
const std = @import("std");

/// Bits a single `window` guarantees after the byte-offset shift.
const window_bits = 57;

pub const BitReader = struct {
    bytes: []const u8,
    /// Bit position from the start of `bytes`.
    pos: usize = 0,
    overflow: bool = false,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    /// The next 64 bits from `pos`, left-aligned; bytes past the end read as zero.
    fn window(self: *const BitReader) u64 {
        const start = self.pos >> 3;
        var word: u64 = 0;
        for (0..8) |i| {
            const byte: u64 = if (start + i < self.bytes.len) self.bytes[start + i] else 0;
            word = (word << 8) | byte;
        }
        return word << @intCast(self.pos & 7);
    }

    pub fn peek(self: *const BitReader, count: u6) u32 {
        std.debug.assert(count <= 32);
        if (count == 0) return 0;
        return @intCast(self.window() >> @intCast(64 - @as(u7, count)));
    }

    pub fn skip(self: *BitReader, count: usize) void {
        self.pos += count;
        if (self.pos > self.bytes.len * 8) self.overflow = true;
    }

    pub fn read(self: *BitReader, count: u6) u32 {
        const value = self.peek(count);
        self.skip(count);
        return value;
    }

    pub fn readSigned(self: *BitReader, count: u6) i32 {
        if (count == 0) return 0;
        const shift: u5 = @intCast(32 - @as(u6, count));
        const raw: i32 = @bitCast(self.read(count) << shift);
        return raw >> shift;
    }

    /// FLAC's unary code: the number of zero bits before the next one bit,
    /// consuming both.
    pub fn readUnary(self: *BitReader) u32 {
        var zeros: u32 = 0;
        while (true) {
            const word = self.window();
            if (word != 0) {
                const leading: u32 = @clz(word);
                self.skip(leading + 1);
                return zeros + leading;
            }
            zeros += window_bits - 1;
            self.skip(window_bits - 1);
            if (self.overflow) return zeros;
        }
    }

    pub fn alignToByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    pub fn bytePos(self: *const BitReader) usize {
        return self.pos >> 3;
    }
};
```

`ps1-core/src/chd/chd.zig` (it grows in later tasks):

```zig
//! CHD v5 disc images, read on demand. See `Reader`.
pub const bitstream = @import("bitstream.zig");
```

In `ps1-core/src/root.zig`, add `pub const chd = @import("chd/chd.zig");` beside `disc`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="bit reader" 2>&1 | tail -5`, then the same with `-Dtest-filter="unary"`, `"past the end"` and `"alignToByte"`
Expected: PASS, no output beyond the summary.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/chd ps1-core/tests/chd_test.zig
git add ps1-core/src/chd ps1-core/src/root.zig ps1-core/tests/chd_test.zig build.zig
git commit -m "feat(core): an MSB-first bit reader for the CHD map and FLAC"
```

---

### Task 2: Fixtures and the FLAC decoder

**Files:**
- Create: `ps1-core/tests/chd/make_fixtures.sh`
- Create (generated, committed): `ps1-core/tests/chd/{silence,ramp,music,noise,stereo}.{pcm,flac}`, `disc.bin`, `disc.cue`, `disc-{cdzl,cdlz,cdzs,cdfl,default}.chd`
- Modify: `.gitignore` (after `!ps1-core/tests/goldens/fixtures/*.p1fx`)
- Create: `ps1-core/src/chd/flac.zig`
- Modify: `ps1-core/src/chd/chd.zig`, `ps1-core/tests/chd_test.zig`

**Interfaces:**
- Consumes: `BitReader` (Task 1).
- Produces: `chd.flac.decodeFrames(src: []const u8, out: []u8, stats: ?*Stats) Error!usize`. It fills all of `out` with interleaved stereo 16-bit samples, written **big-endian** (L then R), and returns the bytes of `src` consumed. Also `chd.flac.Stats`, `chd.flac.Error` (`BadFrame`, `BadCrc`, `Unsupported`), `chd.flac.Stereo`, `chd.flac.restoreStereo(mode, a: []i32, b: []i32)`, `chd.flac.decodeResidual(br: *BitReader, block_size: usize, order: usize, residual: []i32, stats: ?*Stats) Error!void`.
- Produces (fixtures): `disc.bin`/`disc.cue` is one FILE holding three tracks:
  - track 1, MODE2/2352, 30 sectors: 22 Mode 2 Form 1 sectors, then 8 Mode 1 sectors, all with valid EDC and ECC;
  - track 2, AUDIO: a 10-sector `INDEX 00` pregap, then 51 sectors (14 silent, 37 sine);
  - track 3, AUDIO: a 2-sector pregap, then 20 sectors of noise.

  That is 113 sectors in all. The `.chd` files are that cue, each forced to one codec, plus `disc-default.chd` with chdman's default codec set.

- [ ] **Step 1: Install the tools**

Run: `brew install rom-tools flac && chdman --help | head -1 && flac --version`
Expected: a `chdman` banner and `flac 1.x`.

- [ ] **Step 2: Write the fixture generator**

`ps1-core/tests/chd/make_fixtures.sh`:

```bash
#!/usr/bin/env bash
# Regenerates every CHD/FLAC fixture in this directory. Needs `chdman`
# (brew install rom-tools) and `flac`. The outputs are committed; nothing in
# the build runs this.
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'EOF'
import math, random, struct

# --- FLAC signals: 4704 stereo frames, two 2352-sample blocks each ---------
N = 4704
def pcm(name, pairs):
    with open(name + ".pcm", "wb") as f:
        f.write(b"".join(struct.pack("<hh", l, r) for l, r in pairs))

rng = random.Random(1)
pcm("silence", [(0, 0)] * N)
pcm("ramp", [((i * 7) % 30000 - 15000, (i * 5) % 30000 - 15000) for i in range(N)])
pcm("music", [(int(12000 * math.sin(i * 0.031) + 6000 * math.sin(i * 0.17)),
               int(11000 * math.sin(i * 0.029 + 1) + 5000 * math.sin(i * 0.13))) for i in range(N)])
pcm("noise", [(rng.randint(-32768, 32767), rng.randint(-32768, 32767)) for _ in range(N)])
pcm("stereo", [(int(15000 * math.sin(i * 0.05)), int(15000 * math.sin(i * 0.05)) + rng.randint(-3, 3))
               for i in range(N)])

# --- disc.bin: raw sectors with valid EDC/ECC so chdman strips the ECC -----
ecc_low = [((i << 1) ^ (0x11D if i & 0x80 else 0)) & 0xFF for i in range(256)]
ecc_high = [0] * 256
for i in range(256):
    ecc_high[ecc_low[i] ^ i] = i

def ecc_pair(sec, count, offset, row, mode2):
    v1 = v2 = 0
    for c in range(count):
        o = offset(row, c)
        b = 0 if (mode2 and o < 4) else sec[12 + o]
        v1 = ecc_low[v1 ^ b]
        v2 ^= b
    v1 = ecc_high[ecc_low[v1] ^ v2]
    return v1, v2 ^ v1

def write_ecc(sec):
    mode2 = sec[15] == 2
    for r in range(86):
        a, b = ecc_pair(sec, 24, lambda r, c: r + 86 * c, r, mode2)
        sec[0x81C + r] = a; sec[0x81C + 86 + r] = b
    for r in range(52):
        a, b = ecc_pair(sec, 43, lambda r, c: (((r >> 1) * 43 + c * 44) % 1118) * 2 + (r & 1), r, mode2)
        sec[0x8C8 + r] = a; sec[0x8C8 + 52 + r] = b

edc_table = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0xD8018001 if c & 1 else c >> 1
    edc_table.append(c)
def edc(data):
    c = 0
    for b in data:
        c = edc_table[(c ^ b) & 0xFF] ^ (c >> 8)
    return c

def bcd(v): return ((v // 10) << 4) | (v % 10)

def data_sector(lba, mode):
    sec = bytearray(2352)
    sec[0:12] = b"\x00" + b"\xFF" * 10 + b"\x00"
    a = lba + 150
    sec[12:16] = bytes([bcd(a // 4500), bcd((a // 75) % 60), bcd(a % 75), mode])
    text = (f"sector {lba} mode {mode} " * 120).encode()
    if mode == 2:
        sec[16:24] = bytes([0, 0, 8, 0, 0, 0, 8, 0])
        sec[24:24 + 2048] = text[:2048]
        sec[2072:2076] = struct.pack("<I", edc(sec[16:2072]))
    else:
        sec[16:16 + 2048] = text[:2048]
        sec[2064:2068] = struct.pack("<I", edc(sec[0:2064]))
    write_ecc(sec)
    return bytes(sec)

def audio(samples):
    return b"".join(struct.pack("<hh", l, r) for l, r in samples)

sectors = []
for lba in range(22):
    sectors.append(data_sector(lba, 2))
for lba in range(22, 30):
    sectors.append(data_sector(lba, 1))
track2_pregap = len(sectors)
sectors += [bytes(2352)] * (10 + 14)
for s in range(37):
    base = s * 588
    sectors.append(audio([(int(9000 * math.sin((base + i) * 0.02)), int(7000 * math.sin((base + i) * 0.03)))
                          for i in range(588)]))
track3_pregap = len(sectors)
sectors += [bytes(2352)] * 2
for _ in range(20):
    sectors.append(bytes(rng.getrandbits(8) for _ in range(2352)))
open("disc.bin", "wb").write(b"".join(sectors))

def msf(lba): return f"{lba // 4500:02d}:{(lba // 75) % 60:02d}:{lba % 75:02d}"
open("disc.cue", "w").write(
    'FILE "disc.bin" BINARY\n'
    "  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
    f"  TRACK 02 AUDIO\n    INDEX 00 {msf(track2_pregap)}\n    INDEX 01 {msf(track2_pregap + 10)}\n"
    f"  TRACK 03 AUDIO\n    INDEX 00 {msf(track3_pregap)}\n    INDEX 01 {msf(track3_pregap + 2)}\n")
EOF

encode() { flac --silent --force --force-raw-format --endian=little --sign=signed \
    --channels=2 --bps=16 --sample-rate=44100 --blocksize=2352 "$2" -o "$1.flac" "$1.pcm"; }
encode silence -0
encode ramp -0
encode noise -0
encode music -8
encode stereo -8

for codec in cdzl cdlz cdzs cdfl; do
    chdman createcd -f -i disc.cue -o "disc-$codec.chd" -c "$codec" >/dev/null
done
chdman createcd -f -i disc.cue -o disc-default.chd >/dev/null
ls -l *.pcm *.flac disc.bin disc.cue *.chd
```

In `.gitignore`, add `!ps1-core/tests/chd/*.bin` after the `!ps1-core/tests/goldens/fixtures/*.p1fx` line.

- [ ] **Step 3: Generate the fixtures**

Run: `chmod +x ps1-core/tests/chd/make_fixtures.sh && ps1-core/tests/chd/make_fixtures.sh`
Expected: 17 files are listed. `disc.bin` is 265,776 bytes (113 × 2352). Every file is under 300 KB.

- [ ] **Step 4: Write the failing FLAC tests**

Append to `ps1-core/tests/chd_test.zig`:

```zig
const flac = chd.flac;

/// The frames of a FLAC file: past "fLaC" and every metadata block.
fn flacFrames(file: []const u8) []const u8 {
    var pos: usize = 4;
    while (true) {
        const last = file[pos] & 0x80 != 0;
        const len = std.mem.readInt(u24, file[pos + 1 ..][0..3], .big);
        pos += 4 + len;
        if (last) return file[pos..];
    }
}

/// Decodes `flac_file` and requires the little-endian `pcm` back, sample for sample.
fn expectDecodes(flac_file: []const u8, pcm: []const u8, stats: *flac.Stats) !void {
    const out = try std.testing.allocator.alloc(u8, pcm.len);
    defer std.testing.allocator.free(out);
    const frames = flacFrames(flac_file);
    try std.testing.expectEqual(frames.len, try flac.decodeFrames(frames, out, stats));
    for (0..pcm.len / 2) |i| {
        try std.testing.expectEqual(pcm[2 * i], out[2 * i + 1]);
        try std.testing.expectEqual(pcm[2 * i + 1], out[2 * i]);
    }
}

test "FLAC silence decodes through constant subframes" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/silence.flac"), @embedFile("chd/silence.pcm"), &s);
    try std.testing.expect(s.constant > 0);
}

test "FLAC ramp decodes through fixed predictors" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/ramp.flac"), @embedFile("chd/ramp.pcm"), &s);
    try std.testing.expect(s.fixed > 0);
}

test "FLAC music decodes through LPC subframes" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/music.flac"), @embedFile("chd/music.pcm"), &s);
    try std.testing.expect(s.lpc > 0);
}

test "FLAC noise decodes through verbatim subframes" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/noise.flac"), @embedFile("chd/noise.pcm"), &s);
    try std.testing.expect(s.verbatim > 0);
}

test "FLAC correlated stereo decodes through a decorrelation mode" {
    var s: flac.Stats = .{};
    try expectDecodes(@embedFile("chd/stereo.flac"), @embedFile("chd/stereo.pcm"), &s);
    try std.testing.expect(s.left_side + s.right_side + s.mid_side > 0);
}

test "FLAC restores left and right from every stereo mode" {
    // left = 100, right = 40 in every mode's own encoding.
    var a = [_]i32{100};
    var b = [_]i32{60}; // side = left - right
    flac.restoreStereo(.left_side, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });

    a = .{60}; // side
    b = .{40}; // right
    flac.restoreStereo(.right_side, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });

    a = .{70}; // mid = (left + right) >> 1
    b = .{60}; // side
    flac.restoreStereo(.mid_side, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });

    a = .{100};
    b = .{40};
    flac.restoreStereo(.independent, &a, &b);
    try std.testing.expectEqual([2]i32{ 100, 40 }, [2]i32{ a[0], b[0] });
}

test "FLAC reads an escaped Rice partition as raw samples" {
    // method 0, partition order 0, parameter 15 (escape), 5-bit width = 4,
    // then four 4-bit samples 3, -2, 0, 7.
    var br = chd.bitstream.BitReader.init(&.{ 0x03, 0xC8, 0x7C, 0x0E });
    var residual: [4]i32 = undefined;
    var s: flac.Stats = .{};
    try flac.decodeResidual(&br, 4, 0, &residual, &s);
    try std.testing.expectEqual([4]i32{ 3, -2, 0, 7 }, residual);
    try std.testing.expectEqual(@as(u32, 1), s.escaped_partitions);
}

test "a corrupted FLAC frame is refused, never decoded or panicked on" {
    const frames = flacFrames(@embedFile("chd/music.flac"));
    const bad = try std.testing.allocator.dupe(u8, frames);
    defer std.testing.allocator.free(bad);
    var out: [4704 * 4]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (0..64) |_| {
        @memcpy(bad, frames);
        bad[rng.random().intRangeLessThan(usize, 16, bad.len)] ^= 0x5A;
        _ = flac.decodeFrames(bad, &out, null) catch continue;
        return error.CorruptionAccepted;
    }
}
```

- [ ] **Step 5: Run the FLAC tests to verify they fail**

Run: `zig build test -Dtest-filter="FLAC" 2>&1 | tail -5`
Expected: compile error, `chd` has no member `flac`.

- [ ] **Step 6: Write the FLAC decoder**

`ps1-core/src/chd/flac.zig`:

```zig
//! FLAC frame decoder for CHD's `cdfl` codec. A CHD stores each hunk's audio
//! as bare FLAC frames with no stream header, so this reads frames only: no
//! metadata blocks, no seeking. It takes anything an encoder can produce for
//! 16-bit stereo and refuses everything else. Every frame's CRC8 and CRC16 are
//! checked, and the arithmetic wraps, so a corrupt frame is an error and never
//! a panic.
const std = @import("std");
const BitReader = @import("bitstream.zig").BitReader;

const Crc8 = std.hash.crc.@"CRC-8/SMBUS";
const Crc16 = std.hash.crc.@"CRC-16/UMTS";

/// The largest block buffered. chdman writes 2352-sample blocks.
pub const max_block = 4608;
const channels = 2;
const sample_bits = 16;
const max_lpc_order = 32;

pub const Error = error{ BadFrame, BadCrc, Unsupported };

/// Counts of what was decoded; tests use it to prove a fixture covers a path.
pub const Stats = struct {
    constant: u32 = 0,
    verbatim: u32 = 0,
    fixed: u32 = 0,
    lpc: u32 = 0,
    escaped_partitions: u32 = 0,
    independent: u32 = 0,
    left_side: u32 = 0,
    right_side: u32 = 0,
    mid_side: u32 = 0,
};

pub const Stereo = enum { independent, left_side, right_side, mid_side };

const Frame = struct { block_size: usize, bytes: usize };

/// Fills `out` with `out.len / 4` stereo samples, big-endian L then R, as
/// chdman stores CD audio. Returns the bytes of `src` the frames occupied.
pub fn decodeFrames(src: []const u8, out: []u8, stats: ?*Stats) Error!usize {
    const total = out.len / 4;
    var done: usize = 0;
    var pos: usize = 0;
    var samples: [channels][max_block]i32 = undefined;
    while (done < total) {
        const frame = try decodeFrame(src[pos..], &samples, stats);
        const take = @min(frame.block_size, total - done);
        for (0..take) |i| {
            writeSample(out[(done + i) * 4 ..][0..2], samples[0][i]);
            writeSample(out[(done + i) * 4 + 2 ..][0..2], samples[1][i]);
        }
        done += take;
        pos += frame.bytes;
    }
    return pos;
}

fn writeSample(dst: *[2]u8, sample: i32) void {
    std.mem.writeInt(i16, dst, @truncate(sample), .big);
}

fn decodeFrame(src: []const u8, samples: *[channels][max_block]i32, stats: ?*Stats) Error!Frame {
    var br = BitReader.init(src);
    // 14-bit sync code plus the reserved zero bit.
    if (br.read(15) != 0x7FFC) return error.BadFrame;
    _ = br.read(1); // blocking strategy: irrelevant without seeking
    const size_code = br.read(4);
    const rate_code = br.read(4);
    const assignment = br.read(4);
    const size_bits = br.read(3);
    if (br.read(1) != 0) return error.BadFrame;
    try skipCodedNumber(&br);

    const block_size: usize = switch (size_code) {
        0 => return error.BadFrame,
        1 => 192,
        2...5 => @as(usize, 576) << @intCast(size_code - 2),
        6 => br.read(8) + 1,
        7 => br.read(16) + 1,
        else => @as(usize, 256) << @intCast(size_code - 8),
    };
    switch (rate_code) {
        12 => _ = br.read(8),
        13, 14 => _ = br.read(16),
        15 => return error.BadFrame,
        else => {},
    }
    // 0 means "from STREAMINFO", which a CHD never has: chdman's is 16-bit.
    if (size_bits != 0 and size_bits != 4) return error.Unsupported;
    const stereo: Stereo = switch (assignment) {
        1 => .independent,
        8 => .left_side,
        9 => .right_side,
        10 => .mid_side,
        else => return error.Unsupported,
    };
    if (block_size > max_block) return error.Unsupported;

    const header_end = br.bytePos();
    if (br.overflow or br.read(8) != Crc8.hash(src[0..header_end])) return error.BadCrc;

    for (0..channels) |ch| {
        const side = switch (stereo) {
            .independent => false,
            .left_side, .mid_side => ch == 1,
            .right_side => ch == 0,
        };
        try decodeSubframe(&br, samples[ch][0..block_size], sample_bits + @as(u32, @intFromBool(side)), stats);
    }
    restoreStereo(stereo, samples[0][0..block_size], samples[1][0..block_size]);

    br.alignToByte();
    const crc_pos = br.bytePos();
    if (br.overflow or crc_pos + 2 > src.len) return error.BadFrame;
    if (br.read(16) != Crc16.hash(src[0..crc_pos])) return error.BadCrc;

    if (stats) |s| switch (stereo) {
        .independent => s.independent += 1,
        .left_side => s.left_side += 1,
        .right_side => s.right_side += 1,
        .mid_side => s.mid_side += 1,
    };
    return .{ .block_size = block_size, .bytes = crc_pos + 2 };
}

/// The frame number, UTF-8-style: a lead byte whose high ones count the bytes.
fn skipCodedNumber(br: *BitReader) Error!void {
    const lead = br.read(8);
    if (lead & 0x80 == 0) return;
    var extra: u32 = 0;
    var mask: u32 = 0x40;
    while (mask != 0 and lead & mask != 0) : (mask >>= 1) extra += 1;
    if (extra == 0 or extra > 6) return error.BadFrame;
    for (0..extra) |_| {
        if (br.read(8) & 0xC0 != 0x80) return error.BadFrame;
    }
}

fn decodeSubframe(br: *BitReader, out: []i32, depth: u32, stats: ?*Stats) Error!void {
    if (br.read(1) != 0) return error.BadFrame;
    const kind = br.read(6);
    var wasted: u32 = 0;
    if (br.read(1) == 1) wasted = br.readUnary() + 1;
    if (wasted >= depth) return error.BadFrame;
    const bits: u6 = @intCast(depth - wasted);

    switch (kind) {
        0 => {
            @memset(out, br.readSigned(bits));
            if (stats) |s| s.constant += 1;
        },
        1 => {
            for (out) |*sample| sample.* = br.readSigned(bits);
            if (stats) |s| s.verbatim += 1;
        },
        8...12 => {
            try decodeFixed(br, out, kind - 8, bits, stats);
            if (stats) |s| s.fixed += 1;
        },
        32...63 => {
            try decodeLpc(br, out, kind - 31, bits, stats);
            if (stats) |s| s.lpc += 1;
        },
        else => return error.BadFrame,
    }
    if (wasted > 0) {
        for (out) |*sample| sample.* <<= @intCast(wasted);
    }
}

fn decodeFixed(br: *BitReader, out: []i32, order: usize, bits: u6, stats: ?*Stats) Error!void {
    if (order > out.len) return error.BadFrame;
    for (out[0..order]) |*sample| sample.* = br.readSigned(bits);
    try decodeResidual(br, out.len, order, out[order..], stats);
    var i = order;
    while (i < out.len) : (i += 1) {
        const r = out[i];
        out[i] = switch (order) {
            0 => r,
            1 => r +% out[i - 1],
            2 => r +% 2 *% out[i - 1] -% out[i - 2],
            3 => r +% 3 *% out[i - 1] -% 3 *% out[i - 2] +% out[i - 3],
            4 => r +% 4 *% out[i - 1] -% 6 *% out[i - 2] +% 4 *% out[i - 3] -% out[i - 4],
            else => unreachable,
        };
    }
}

fn decodeLpc(br: *BitReader, out: []i32, order: usize, bits: u6, stats: ?*Stats) Error!void {
    if (order > out.len) return error.BadFrame;
    for (out[0..order]) |*sample| sample.* = br.readSigned(bits);
    const precision = br.read(4) + 1;
    if (precision == 16) return error.BadFrame;
    const shift = br.readSigned(5);
    if (shift < 0) return error.BadFrame;
    var coefs: [max_lpc_order]i32 = undefined;
    for (coefs[0..order]) |*c| c.* = br.readSigned(@intCast(precision));
    try decodeResidual(br, out.len, order, out[order..], stats);
    var i = order;
    while (i < out.len) : (i += 1) {
        var sum: i64 = 0;
        for (coefs[0..order], 0..) |c, j| sum +%= @as(i64, c) *% out[i - 1 - j];
        out[i] +%= @truncate(sum >> @intCast(shift));
    }
}

/// Rice-coded residuals, partition by partition. An escaped partition stores
/// raw signed samples of a width it names itself.
pub fn decodeResidual(br: *BitReader, block_size: usize, order: usize, residual: []i32, stats: ?*Stats) Error!void {
    const method = br.read(2);
    if (method > 1) return error.BadFrame;
    const param_bits: u6 = if (method == 0) 4 else 5;
    const escape: u32 = if (method == 0) 15 else 31;
    const partitions = @as(usize, 1) << @intCast(br.read(4));
    if (block_size % partitions != 0) return error.BadFrame;
    const per = block_size / partitions;
    if (per < order) return error.BadFrame;

    var n: usize = 0;
    for (0..partitions) |p| {
        const count = if (p == 0) per - order else per;
        const param = br.read(param_bits);
        if (param == escape) {
            const width: u6 = @intCast(br.read(5));
            for (residual[n..][0..count]) |*r| r.* = br.readSigned(width);
            if (stats) |s| s.escaped_partitions += 1;
        } else {
            const k: u5 = @intCast(param);
            for (residual[n..][0..count]) |*r| {
                const folded = (br.readUnary() << k) | br.read(k);
                r.* = @bitCast((folded >> 1) ^ (0 -% (folded & 1)));
            }
        }
        n += count;
        if (br.overflow) return error.BadFrame;
    }
}

/// Undoes inter-channel decorrelation in place: `a` becomes left, `b` right.
pub fn restoreStereo(mode: Stereo, a: []i32, b: []i32) void {
    switch (mode) {
        .independent => {},
        .left_side => for (a, b) |left, *side| {
            side.* = left -% side.*;
        },
        .right_side => for (a, b) |*side, right| {
            side.* = side.* +% right;
        },
        .mid_side => for (a, b) |*m, *s| {
            const mid = (m.* *% 2) | (s.* & 1);
            const side = s.*;
            m.* = (mid +% side) >> 1;
            s.* = (mid -% side) >> 1;
        },
    }
}
```

Add `pub const flac = @import("flac.zig");` to `ps1-core/src/chd/chd.zig`.

- [ ] **Step 7: Run the FLAC tests to verify they pass**

Run: `zig build test -Dtest-filter="FLAC" 2>&1 | tail -5`
Expected: PASS. If a coverage assertion fails, the fixture missed its path (for example, flac chose LPC at `-0`). Fix the encoder flags in `make_fixtures.sh` and regenerate, rather than weakening the assertion.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-core/src/chd ps1-core/tests/chd_test.zig
git add .gitignore ps1-core/tests/chd ps1-core/src/chd ps1-core/tests/chd_test.zig
git commit -m "feat(core): a FLAC frame decoder and the CHD fixtures"
```

---

### Task 3: The CD codec wrapper and ECC regeneration

**Files:**
- Create: `ps1-core/src/chd/cd.zig`
- Modify: `ps1-core/src/chd/chd.zig`, `ps1-core/tests/chd_test.zig`

**Interfaces:**
- Consumes: `flac.decodeFrames` (Task 2).
- Produces:
  - `chd.cd.Codec` = `enum { cdzl, cdlz, cdzs, cdfl }`.
  - `chd.cd.frame_bytes` = 2448 and `chd.cd.subcode_bytes` = 96.
  - `chd.cd.Scratch` with `init(gpa, frames_per_hunk: usize, zstd: bool) !Scratch` and `deinit(gpa)`.
  - `chd.cd.decode(scratch: *Scratch, gpa: Allocator, codec: Codec, src: []const u8, dest: []u8) Error!void`. `dest` is one whole hunk, `frames × 2448` bytes.
  - `chd.cd.restoreSector(sector: *[2352]u8)`, which rewrites the sync pattern and the P/Q parity.
  - `chd.cd.Error` = `error{ BadHunk, OutOfMemory }`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/chd_test.zig`:

```zig
const cd = chd.cd;
const sector_bytes = ps1.constants.sector_bytes;
const disc_bin = @embedFile("chd/disc.bin");
const disc_cue = @embedFile("chd/disc.cue");

fn binSector(lba: usize) [sector_bytes]u8 {
    return disc_bin[lba * sector_bytes ..][0..sector_bytes].*;
}

/// Zeroes what chdman strips from a sector whose ECC verified: the sync
/// pattern and the P/Q parity.
fn stripped(lba: usize) [sector_bytes]u8 {
    var s = binSector(lba);
    @memset(s[0..12], 0);
    @memset(s[0x81C..], 0);
    return s;
}

test "ECC regeneration restores a Mode 2 Form 1 sector byte for byte" {
    var s = stripped(0);
    cd.restoreSector(&s);
    try std.testing.expectEqualSlices(u8, &binSector(0), &s);
}

test "ECC regeneration restores a Mode 1 sector byte for byte" {
    var s = stripped(25);
    cd.restoreSector(&s);
    try std.testing.expectEqualSlices(u8, &binSector(25), &s);
}

/// A raw deflate stream of one stored block: no compressor needed.
fn storedDeflate(list: *std.ArrayList(u8), bytes: []const u8) !void {
    const a = std.testing.allocator;
    try list.append(a, 0x01); // BFINAL, BTYPE=00
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(bytes.len), .little);
    try list.appendSlice(a, &len);
    std.mem.writeInt(u16, &len, ~@as(u16, @intCast(bytes.len)), .little);
    try list.appendSlice(a, &len);
    try list.appendSlice(a, bytes);
}

test "a cdzl hunk splits sectors from subcode and regenerates flagged ECC" {
    const a = std.testing.allocator;
    var sectors: [2 * sector_bytes]u8 = undefined;
    sectors[0..sector_bytes].* = stripped(0); // flagged: regenerated
    sectors[sector_bytes..].* = binSector(60); // audio: left alone
    var subcode: [2 * cd.subcode_bytes]u8 = undefined;
    for (&subcode, 0..) |*b, i| b.* = @truncate(i);

    var base = std.ArrayList(u8).empty;
    defer base.deinit(a);
    try storedDeflate(&base, &sectors);
    var src = std.ArrayList(u8).empty;
    defer src.deinit(a);
    try src.append(a, 0b01); // ECC bitmap: frame 0 only
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(base.items.len), .big);
    try src.appendSlice(a, &len);
    try src.appendSlice(a, base.items);
    try storedDeflate(&src, &subcode);

    var scratch = try cd.Scratch.init(a, 2, false);
    defer scratch.deinit(a);
    var hunk: [2 * cd.frame_bytes]u8 = undefined;
    try cd.decode(&scratch, a, .cdzl, src.items, &hunk);

    try std.testing.expectEqualSlices(u8, &binSector(0), hunk[0..sector_bytes]);
    try std.testing.expectEqualSlices(u8, subcode[0..96], hunk[sector_bytes..][0..96]);
    try std.testing.expectEqualSlices(u8, &binSector(60), hunk[cd.frame_bytes..][0..sector_bytes]);
    try std.testing.expectEqualSlices(u8, subcode[96..], hunk[cd.frame_bytes + sector_bytes ..][0..96]);
}

test "a cd hunk whose length field overruns its data is refused" {
    const a = std.testing.allocator;
    var scratch = try cd.Scratch.init(a, 2, false);
    defer scratch.deinit(a);
    var hunk: [2 * cd.frame_bytes]u8 = undefined;
    try std.testing.expectError(error.BadHunk, cd.decode(&scratch, a, .cdzl, &.{ 0, 0xFF, 0xFF, 1 }, &hunk));
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="ECC" 2>&1 | tail -5`
Expected: compile error, `chd` has no member `cd`.

- [ ] **Step 3: Write `cd.zig`**

`ps1-core/src/chd/cd.zig`:

```zig
//! The four CHD CD codecs. `cdzl`, `cdlz` and `cdzs` share one hunk layout:
//! an ECC bitmap (one bit per frame, LSB first), the compressed length of the
//! sector data (2 bytes, or 3 for a hunk of 64 KB or more), the sector data
//! through the base codec, then the subcode through its own stream. `cdfl` is
//! FLAC sector data followed directly by deflated subcode, with no header.
//!
//! A set ECC bit means chdman verified that frame's parity and then zeroed its
//! sync pattern and P/Q bytes, so they are regenerated here bit for bit.
const std = @import("std");
const constants = @import("../constants.zig");
const flac = @import("flac.zig");

const sector_bytes = constants.sector_bytes;
pub const subcode_bytes = 96;
pub const frame_bytes = sector_bytes + subcode_bytes;

pub const Codec = enum { cdzl, cdlz, cdzs, cdfl };
pub const Error = error{ BadHunk, OutOfMemory };

/// Literal/position properties chdman's LZMA encoder uses (lc 3, lp 0, pb 2).
const lzma_properties: std.compress.lzma.Decode.Properties = .{ .lc = 3, .lp = 0, .pb = 2 };
/// zstd window for one hunk; a CD hunk is under 20 KB.
const zstd_window = 1 << 20;

/// Per-reader working memory, sized once for the reader's hunk size.
pub const Scratch = struct {
    sectors: []u8,
    subcode: []u8,
    flate_window: []u8,
    /// Empty unless the CHD names `cdzs`.
    zstd_buffer: []u8,

    pub fn init(gpa: std.mem.Allocator, frames: usize, zstd: bool) !Scratch {
        const sectors = try gpa.alloc(u8, frames * sector_bytes);
        errdefer gpa.free(sectors);
        const subcode = try gpa.alloc(u8, frames * subcode_bytes);
        errdefer gpa.free(subcode);
        const flate_window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        errdefer gpa.free(flate_window);
        const zstd_buffer = if (zstd) try gpa.alloc(u8, zstd_window + std.compress.zstd.block_size_max) else &.{};
        return .{ .sectors = sectors, .subcode = subcode, .flate_window = flate_window, .zstd_buffer = zstd_buffer };
    }

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(self.sectors);
        gpa.free(self.subcode);
        gpa.free(self.flate_window);
        gpa.free(self.zstd_buffer);
    }
};

pub fn decode(scratch: *Scratch, gpa: std.mem.Allocator, codec: Codec, src: []const u8, dest: []u8) Error!void {
    const frames = dest.len / frame_bytes;
    const sectors = scratch.sectors[0 .. frames * sector_bytes];
    const subcode = scratch.subcode[0 .. frames * subcode_bytes];
    var ecc_bitmap: []const u8 = &.{};

    if (codec == .cdfl) {
        const used = flac.decodeFrames(src, sectors, null) catch return error.BadHunk;
        try inflate(scratch, src[used..], subcode);
    } else {
        const ecc_bytes = (frames + 7) / 8;
        const len_bytes: usize = if (dest.len < 65536) 2 else 3;
        const head = ecc_bytes + len_bytes;
        if (src.len < head) return error.BadHunk;
        var base_len: usize = std.mem.readInt(u16, src[ecc_bytes..][0..2], .big);
        if (len_bytes == 3) base_len = (base_len << 8) | src[ecc_bytes + 2];
        if (src.len < head + base_len) return error.BadHunk;
        const base = src[head..][0..base_len];
        const rest = src[head + base_len ..];
        switch (codec) {
            .cdzl => {
                try inflate(scratch, base, sectors);
                try inflate(scratch, rest, subcode);
            },
            .cdlz => {
                try unlzma(gpa, base, sectors);
                try inflate(scratch, rest, subcode);
            },
            .cdzs => {
                try unzstd(scratch, base, sectors);
                try unzstd(scratch, rest, subcode);
            },
            .cdfl => unreachable,
        }
        ecc_bitmap = src[0..ecc_bytes];
    }

    for (0..frames) |f| {
        const frame = dest[f * frame_bytes ..][0..frame_bytes];
        @memcpy(frame[0..sector_bytes], sectors[f * sector_bytes ..][0..sector_bytes]);
        @memcpy(frame[sector_bytes..], subcode[f * subcode_bytes ..][0..subcode_bytes]);
        if (ecc_bitmap.len > 0 and ecc_bitmap[f / 8] & (@as(u8, 1) << @intCast(f % 8)) != 0) {
            restoreSector(frame[0..sector_bytes]);
        }
    }
}

fn inflate(scratch: *Scratch, src: []const u8, out: []u8) Error!void {
    var in = std.Io.Reader.fixed(src);
    var d = std.compress.flate.Decompress.init(&in, .raw, scratch.flate_window);
    d.reader.readSliceAll(out) catch return error.BadHunk;
}

fn unlzma(gpa: std.mem.Allocator, src: []const u8, out: []u8) Error!void {
    var in = std.Io.Reader.fixed(src);
    var d = std.compress.lzma.Decompress.initParams(&in, gpa, &.{}, .{
        .properties = lzma_properties,
        // Any window covering the hunk decodes it: no match reaches further back.
        .dict_size = @intCast(@max(out.len, 4096)),
        .unpacked_size = out.len,
    }, std.math.maxInt(usize)) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.BadHunk;
    defer d.deinit();
    d.reader.readSliceAll(out) catch return error.BadHunk;
}

fn unzstd(scratch: *Scratch, src: []const u8, out: []u8) Error!void {
    if (scratch.zstd_buffer.len == 0) return error.BadHunk;
    var in = std.Io.Reader.fixed(src);
    var d = std.compress.zstd.Decompress.init(&in, scratch.zstd_buffer, .{ .window_len = zstd_window });
    d.reader.readSliceAll(out) catch return error.BadHunk;
}

// --- ECC ---------------------------------------------------------------------

const sync_pattern = [12]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
const p_offset = 0x81C;
const p_rows = 86;
const p_terms = 24;
const q_offset = p_offset + 2 * p_rows;
const q_rows = 52;
const q_terms = 43;

/// GF(2^8) doubling, and the inverse that finishes each parity pair.
const ecc_low: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = @truncate((i << 1) ^ (if (i & 0x80 != 0) 0x11D else 0));
    break :blk t;
};
const ecc_high: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[ecc_low[i] ^ i] = @intCast(i);
    break :blk t;
};

fn pOffset(row: usize, term: usize) usize {
    return row + p_rows * term;
}

fn qOffset(row: usize, term: usize) usize {
    return (((row >> 1) * q_terms + term * (q_terms + 1)) % (q_rows * q_terms / 2)) * 2 + (row & 1);
}

/// One parity pair over the bytes after the sync pattern. A Mode 2 sector's
/// header is excluded from its parity, so its four bytes count as zero.
fn parity(sector: *const [sector_bytes]u8, comptime terms: usize, comptime offsetOf: fn (usize, usize) usize, row: usize) [2]u8 {
    const data = sector[sync_pattern.len..];
    const mode2 = sector[15] == 2;
    var v1: u8 = 0;
    var v2: u8 = 0;
    for (0..terms) |term| {
        const off = offsetOf(row, term);
        const byte: u8 = if (mode2 and off < 4) 0 else data[off];
        v1 = ecc_low[v1 ^ byte];
        v2 ^= byte;
    }
    v1 = ecc_high[ecc_low[v1] ^ v2];
    return .{ v1, v2 ^ v1 };
}

/// Puts back what chdman strips from a frame whose ECC it verified. P is
/// written first because Q covers it.
pub fn restoreSector(sector: *[sector_bytes]u8) void {
    sector[0..sync_pattern.len].* = sync_pattern;
    for (0..p_rows) |row| {
        const v = parity(sector, p_terms, pOffset, row);
        sector[p_offset + row] = v[0];
        sector[p_offset + p_rows + row] = v[1];
    }
    for (0..q_rows) |row| {
        const v = parity(sector, q_terms, qOffset, row);
        sector[q_offset + row] = v[0];
        sector[q_offset + q_rows + row] = v[1];
    }
}
```

`q_rows * q_terms / 2` is 1118, the modulus of the Q diagonal. Check `qOffset(0, 26) == 52` and `qOffset(2, 1) == 174`, the first values of the reference Q table.

`decode` is called with `dest` as a whole hunk slice, while `restoreSector` takes `*[2352]u8`; `frame[0..sector_bytes]` coerces to that. Add `pub const cd = @import("cd.zig");` to `chd.zig`. If the `std.compress` APIs differ from the code above, read the std source (`/opt/homebrew/Cellar/zig/0.17.0/lib/zig/std/compress/`) and adapt the calls. The tests are the arbiter.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="ECC" 2>&1 | tail -5`, then `-Dtest-filter="hunk"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/chd ps1-core/tests/chd_test.zig
git add ps1-core/src/chd ps1-core/tests/chd_test.zig
git commit -m "feat(core): the CHD CD codecs and ECC regeneration"
```

---

### Task 4: The v5 header and hunk map

**Files:**
- Create: `ps1-core/src/chd/map.zig`
- Modify: `ps1-core/src/chd/chd.zig`, `ps1-core/tests/chd_test.zig`

**Interfaces:**
- Consumes: `BitReader` (Task 1), `cd.Codec` and `cd.frame_bytes` (Task 3).
- Produces:
  - `chd.Header.parse(bytes) Error!Header`, with fields `codecs: [4]?cd.Codec`, `logical_bytes: u64`, `map_offset: u64`, `meta_offset: u64`, `hunk_bytes: u32`, `unit_bytes: u32` and `hunk_count: u32`, plus the method `usesCodec(codec) bool`.
  - `chd.isChd(bytes) bool`.
  - `chd.Error` = `error{ NotChd, BadHeader, UnsupportedVersion, ParentChd, UnsupportedCodec, UncompressedChd, NotCdImage, BadMap, BadMetadata, UnsupportedTrackType, OutOfMemory }`.
  - `chd.map.Kind` = `enum(u8) { codec0, codec1, codec2, codec3, none, self }`.
  - `chd.map.Entry` = `struct { kind: Kind, length: u32, offset: u64, crc: u16 }`. For `.self`, `offset` is the target hunk number.
  - `chd.map.decode(gpa, file: []const u8, map_offset: u64, hunk_count: u32, hunk_bytes: u32) Error![]Entry`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/chd_test.zig`:

```zig
const Fixture = struct { name: []const u8, bytes: []const u8 };
const fixtures = [_]Fixture{
    .{ .name = "cdzl", .bytes = @embedFile("chd/disc-cdzl.chd") },
    .{ .name = "cdlz", .bytes = @embedFile("chd/disc-cdlz.chd") },
    .{ .name = "cdzs", .bytes = @embedFile("chd/disc-cdzs.chd") },
    .{ .name = "cdfl", .bytes = @embedFile("chd/disc-cdfl.chd") },
    .{ .name = "default", .bytes = @embedFile("chd/disc-default.chd") },
};

fn mutated(bytes: []const u8, offset: usize, patch: []const u8) ![]u8 {
    const m = try std.testing.allocator.dupe(u8, bytes);
    @memcpy(m[offset..][0..patch.len], patch);
    return m;
}

test "a CHD header parses into its CD geometry" {
    const h = try chd.Header.parse(fixtures[0].bytes);
    try std.testing.expectEqual(@as(u32, 19584), h.hunk_bytes);
    try std.testing.expectEqual(@as(u32, cd.frame_bytes), h.unit_bytes);
    try std.testing.expectEqual(@as(?cd.Codec, .cdzl), h.codecs[0]);
    try std.testing.expectEqual(@as(u32, @intCast((h.logical_bytes + 19583) / 19584)), h.hunk_count);
}

test "every fixture's map decodes and passes its CRC" {
    for (fixtures) |f| {
        const h = try chd.Header.parse(f.bytes);
        const entries = try chd.map.decode(std.testing.allocator, f.bytes, h.map_offset, h.hunk_count, h.hunk_bytes);
        defer std.testing.allocator.free(entries);
        try std.testing.expectEqual(@as(usize, h.hunk_count), entries.len);
    }
}

test "the fixtures cover self-referenced and stored hunks" {
    var self_refs: usize = 0;
    var stored: usize = 0;
    for (fixtures) |f| {
        const h = try chd.Header.parse(f.bytes);
        const entries = try chd.map.decode(std.testing.allocator, f.bytes, h.map_offset, h.hunk_count, h.hunk_bytes);
        defer std.testing.allocator.free(entries);
        for (entries) |e| switch (e.kind) {
            .self => self_refs += 1,
            .none => stored += 1,
            else => {},
        };
    }
    try std.testing.expect(self_refs > 0);
    try std.testing.expect(stored > 0);
}

test "the header refuses what this reader does not support" {
    const base = fixtures[0].bytes;
    const cases = [_]struct { offset: usize, patch: []const u8, err: chd.Error }{
        .{ .offset = 12, .patch = &.{ 0, 0, 0, 4 }, .err = error.UnsupportedVersion },
        .{ .offset = 104, .patch = &.{1}, .err = error.ParentChd },
        .{ .offset = 16, .patch = "xxxx", .err = error.UnsupportedCodec },
        .{ .offset = 16, .patch = &@as([16]u8, @splat(0)), .err = error.UncompressedChd },
        .{ .offset = 60, .patch = &.{ 0, 0, 0x09, 0x30 }, .err = error.NotCdImage },
    };
    for (cases) |c| {
        const m = try mutated(base, c.offset, c.patch);
        defer std.testing.allocator.free(m);
        try std.testing.expectError(c.err, chd.Header.parse(m));
    }
    try std.testing.expectError(error.NotChd, chd.Header.parse("not a chd at all"));
    try std.testing.expect(!chd.isChd("MComprH"));
}

test "a map whose CRC does not match is refused" {
    const h = try chd.Header.parse(fixtures[0].bytes);
    const crc_at: usize = @intCast(h.map_offset + 10);
    const m = try mutated(fixtures[0].bytes, crc_at, &.{ fixtures[0].bytes[crc_at] ^ 0xFF });
    defer std.testing.allocator.free(m);
    try std.testing.expectError(error.BadMap, chd.map.decode(std.testing.allocator, m, h.map_offset, h.hunk_count, h.hunk_bytes));
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="map" 2>&1 | tail -5`
Expected: compile error, no member `Header`/`map`.

- [ ] **Step 3: Write `map.zig`**

`ps1-core/src/chd/map.zig`:

```zig
//! The CHD v5 hunk map. Each hunk's compression type is Huffman-coded (with
//! run-length and "same as last self-reference" pseudo-types), then lengths,
//! CRCs and self-reference targets follow as packed bit fields. A CRC16 over
//! the decoded 12-byte records guards the whole map.
const std = @import("std");
const BitReader = @import("bitstream.zig").BitReader;
const chd = @import("chd.zig");

const Crc16 = std.hash.crc.@"CRC-16/IBM-3740";

pub const Kind = enum(u8) { codec0 = 0, codec1 = 1, codec2 = 2, codec3 = 3, none = 4, self = 5 };

pub const Entry = struct {
    kind: Kind,
    length: u32,
    /// A byte offset into the file, or the target hunk number for `.self`.
    offset: u64,
    crc: u16,
};

const parent = 6;
const rle_small = 7;
const rle_large = 8;
const self_0 = 9;
const self_1 = 10;
const parent_self = 11;
const parent_0 = 12;
const parent_1 = 13;

const map_header_bytes = 16;
const record_bytes = 12;

pub fn decode(gpa: std.mem.Allocator, file: []const u8, map_offset: u64, hunk_count: u32, hunk_bytes: u32) chd.Error![]Entry {
    if (map_offset + map_header_bytes > file.len) return error.BadMap;
    const head = file[@intCast(map_offset)..][0..map_header_bytes];
    const map_bytes = std.mem.readInt(u32, head[0..4], .big);
    const first_offset = std.mem.readInt(u48, head[4..10], .big);
    const map_crc = std.mem.readInt(u16, head[10..12], .big);
    const length_bits = head[12];
    const self_bits = head[13];
    if (length_bits > 32 or self_bits > 32 or head[14] > 32) return error.BadMap;
    const start = map_offset + map_header_bytes;
    if (start + map_bytes > file.len) return error.BadMap;
    var br = BitReader.init(file[@intCast(start)..][0..map_bytes]);

    const huffman = try Huffman.importRle(&br);
    const kinds = try gpa.alloc(u8, hunk_count);
    defer gpa.free(kinds);
    var last: u8 = 0;
    var repeat: u32 = 0;
    for (kinds) |*k| {
        if (repeat > 0) {
            k.* = last;
            repeat -= 1;
            continue;
        }
        const v = try huffman.decodeOne(&br);
        if (v == rle_small) {
            k.* = last;
            repeat = 2 + @as(u32, try huffman.decodeOne(&br));
        } else if (v == rle_large) {
            k.* = last;
            repeat = 2 + 16 + (@as(u32, try huffman.decodeOne(&br)) << 4);
            repeat += try huffman.decodeOne(&br);
        } else {
            last = v;
            k.* = v;
        }
    }

    const entries = try gpa.alloc(Entry, hunk_count);
    errdefer gpa.free(entries);
    var crc = Crc16.init();
    var cursor: u64 = first_offset;
    var last_self: u64 = 0;
    for (kinds, entries) |k, *e| {
        e.* = switch (k) {
            0...3 => blk: {
                const length = br.read(@intCast(length_bits));
                const entry = Entry{ .kind = @enumFromInt(k), .length = length, .offset = cursor, .crc = @intCast(br.read(16)) };
                cursor += length;
                break :blk entry;
            },
            @intFromEnum(Kind.none) => blk: {
                const entry = Entry{ .kind = .none, .length = hunk_bytes, .offset = cursor, .crc = @intCast(br.read(16)) };
                cursor += hunk_bytes;
                break :blk entry;
            },
            @intFromEnum(Kind.self), self_0, self_1 => blk: {
                if (k == @intFromEnum(Kind.self)) last_self = br.read(@intCast(self_bits));
                if (k == self_1) last_self += 1;
                break :blk .{ .kind = .self, .length = 0, .offset = last_self, .crc = 0 };
            },
            parent, parent_self, parent_0, parent_1 => return error.ParentChd,
            else => return error.BadMap,
        };
        var record: [record_bytes]u8 = undefined;
        record[0] = @intFromEnum(e.kind);
        std.mem.writeInt(u24, record[1..4], @intCast(e.length), .big);
        std.mem.writeInt(u48, record[4..10], @intCast(e.offset), .big);
        std.mem.writeInt(u16, record[10..12], e.crc, .big);
        crc.update(&record);
    }
    if (br.overflow or crc.final() != map_crc) return error.BadMap;
    return entries;
}

/// The map's 16-symbol, 8-bit-maximum Huffman code, with its code lengths
/// stored run-length encoded and the codes themselves canonical.
const Huffman = struct {
    const codes = 16;
    const max_bits = 8;
    const Slot = struct { value: u8 = 0, bits: u8 = 0 };

    lookup: [1 << max_bits]Slot = @splat(.{}),

    fn importRle(br: *BitReader) chd.Error!Huffman {
        var lengths: [codes]u8 = @splat(0);
        var n: usize = 0;
        while (n < codes) {
            const bits: u8 = @intCast(br.read(4));
            if (bits != 1) {
                lengths[n] = bits;
                n += 1;
                continue;
            }
            const next: u8 = @intCast(br.read(4));
            if (next == 1) {
                lengths[n] = 1;
                n += 1;
                continue;
            }
            const run = br.read(4) + 3;
            if (n + run > codes) return error.BadMap;
            @memset(lengths[n..][0..run], next);
            n += run;
        }

        // Canonical codes, assigned from the longest length down.
        var start_of: [33]u32 = @splat(0);
        for (lengths) |l| {
            if (l > max_bits) return error.BadMap;
            start_of[l] += 1;
        }
        var start: u32 = 0;
        var len: usize = 32;
        while (len > 0) : (len -= 1) {
            const next_start = (start + start_of[len]) >> 1;
            if (len != 1 and next_start * 2 != start + start_of[len]) return error.BadMap;
            start_of[len] = start;
            start = next_start;
        }

        var h = Huffman{};
        for (lengths, 0..) |l, value| {
            if (l == 0) continue;
            const code = start_of[l];
            start_of[l] += 1;
            const shift: u3 = @intCast(max_bits - l);
            const first = @as(usize, code) << shift;
            const count = @as(usize, 1) << shift;
            if (first + count > h.lookup.len) return error.BadMap;
            @memset(h.lookup[first..][0..count], .{ .value = @intCast(value), .bits = l });
        }
        return h;
    }

    fn decodeOne(self: *const Huffman, br: *BitReader) chd.Error!u8 {
        const slot = self.lookup[br.peek(max_bits)];
        if (slot.bits == 0) return error.BadMap;
        br.skip(slot.bits);
        return slot.value;
    }
};
```

A length of 8 makes `max_bits - l` zero, and that fits `u3`. A length of 0 is skipped before the subtraction.

- [ ] **Step 4: Add `Header`, `isChd` and `Error` to `chd.zig`**

Replace `ps1-core/src/chd/chd.zig` with:

```zig
//! CHD v5 disc images, read on demand. See `Reader`.
const std = @import("std");

pub const bitstream = @import("bitstream.zig");
pub const flac = @import("flac.zig");
pub const cd = @import("cd.zig");
pub const map = @import("map.zig");

const magic = "MComprHD";
const header_bytes = 124;
const version = 5;

pub const Error = error{
    NotChd,
    BadHeader,
    UnsupportedVersion,
    ParentChd,
    UnsupportedCodec,
    UncompressedChd,
    NotCdImage,
    BadMap,
    BadMetadata,
    UnsupportedTrackType,
    OutOfMemory,
};

pub fn isChd(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, magic);
}

fn be(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

pub const Header = struct {
    codecs: [4]?cd.Codec,
    logical_bytes: u64,
    map_offset: u64,
    meta_offset: u64,
    hunk_bytes: u32,
    unit_bytes: u32,
    hunk_count: u32,

    pub fn parse(bytes: []const u8) Error!Header {
        if (!isChd(bytes)) return error.NotChd;
        if (bytes.len < header_bytes or be(u32, bytes, 8) != header_bytes) return error.BadHeader;
        if (be(u32, bytes, 12) != version) return error.UnsupportedVersion;
        // A non-zero parent SHA-1 means hunks live in another file.
        if (!std.mem.allEqual(u8, bytes[104..124], 0)) return error.ParentChd;

        var codecs: [4]?cd.Codec = undefined;
        for (&codecs, 0..) |*c, i| c.* = try codecFromTag(bytes[16 + 4 * i ..][0..4]);
        if (codecs[0] == null) return error.UncompressedChd;

        const logical_bytes = be(u64, bytes, 32);
        const hunk_bytes = be(u32, bytes, 56);
        const unit_bytes = be(u32, bytes, 60);
        if (unit_bytes != cd.frame_bytes or hunk_bytes == 0 or hunk_bytes % cd.frame_bytes != 0) return error.NotCdImage;
        return .{
            .codecs = codecs,
            .logical_bytes = logical_bytes,
            .map_offset = be(u64, bytes, 40),
            .meta_offset = be(u64, bytes, 48),
            .hunk_bytes = hunk_bytes,
            .unit_bytes = unit_bytes,
            .hunk_count = std.math.cast(u32, (logical_bytes + hunk_bytes - 1) / hunk_bytes) orelse return error.BadHeader,
        };
    }

    pub fn usesCodec(self: Header, codec: cd.Codec) bool {
        for (self.codecs) |slot| {
            if (slot) |c| if (c == codec) return true;
        }
        return false;
    }
};

fn codecFromTag(tag: *const [4]u8) Error!?cd.Codec {
    if (std.mem.allEqual(u8, tag, 0)) return null;
    const tags = [_]struct { []const u8, cd.Codec }{
        .{ "cdzl", .cdzl }, .{ "cdlz", .cdlz }, .{ "cdzs", .cdzs }, .{ "cdfl", .cdfl },
    };
    for (tags) |t| if (std.mem.eql(u8, tag, t[0])) return t[1];
    return error.UnsupportedCodec;
}
```

In the refusal test, the `NotCdImage` case writes unit bytes `0x930` (2352, the cooked sector size). The `UncompressedChd` case zeroes all four codec slots.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="map" 2>&1 | tail -5`, then `-Dtest-filter="header"`
Expected: PASS. If "cover self-referenced and stored hunks" fails, regenerate the fixtures with more silent hunks in track 2 or more noise in track 3; do not delete the assertion.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/chd ps1-core/tests/chd_test.zig
git add ps1-core/src/chd ps1-core/tests/chd_test.zig
git commit -m "feat(core): the CHD v5 header and hunk map"
```

---

### Task 5: The reader: tracks, LBAs, hunk cache

**Files:**
- Modify: `ps1-core/src/chd/chd.zig`, `ps1-core/tests/chd_test.zig`

**Interfaces:**
- Consumes: `Header`, `map.decode` (Task 4), `cd.decode` and `cd.Scratch` (Task 3), `disc.Track` (existing, `disc.zig:88`).
- Produces: `chd.Reader`, with:
  - `open(gpa, file: []const u8) Error!*Reader` and `close(self: *Reader) void`;
  - `readSector(self: *Reader, lba: i32, out: *[2352]u8) bool`;
  - `sectorCount(self: *const Reader) i32`;
  - the pub fields `tracks: [99]disc.Track`, `track_count: u8`, `map: []map.Entry` and `header: Header`.

  Also `chd.TrackMeta` = `struct { number: u8, audio: bool, frames: u32, stored_pregap: u32 }` and `chd.parseTrack(text: []const u8) Error!TrackMeta`.

  `Reader` is not thread-safe. Each thread opens its own.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/chd_test.zig`:

```zig
const Disc = ps1.disc.Disc;

test "a CHT2 track with a stored pregap parses" {
    const t = try chd.parseTrack("TRACK:2 TYPE:AUDIO SUBTYPE:NONE FRAMES:10410 PREGAP:150 PGTYPE:VAUDIO PGSUB:NONE POSTGAP:0");
    try std.testing.expectEqual(chd.TrackMeta{ .number = 2, .audio = true, .frames = 10410, .stored_pregap = 150 }, t);
}

test "an unstored pregap is not in the image" {
    const t = try chd.parseTrack("TRACK:1 TYPE:MODE2_RAW SUBTYPE:NONE FRAMES:26404 PREGAP:150 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0");
    try std.testing.expectEqual(chd.TrackMeta{ .number = 1, .audio = false, .frames = 26404, .stored_pregap = 0 }, t);
}

test "a CHTR track (no pregap fields) parses" {
    const t = try chd.parseTrack("TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:300");
    try std.testing.expectEqual(chd.TrackMeta{ .number = 1, .audio = false, .frames = 300, .stored_pregap = 0 }, t);
}

test "a cooked track type is refused" {
    try std.testing.expectError(error.UnsupportedTrackType, chd.parseTrack("TRACK:1 TYPE:MODE1 SUBTYPE:NONE FRAMES:300"));
    try std.testing.expectError(error.BadMetadata, chd.parseTrack("TRACK:1 TYPE:AUDIO FRAMES:10 PREGAP:20 PGTYPE:VAUDIO"));
}

fn expectSameSector(flat: Disc, reader: *chd.Reader, lba: i32, name: []const u8) !void {
    var want: [sector_bytes]u8 = undefined;
    var got: [sector_bytes]u8 = undefined;
    try std.testing.expect(flat.readSector2352(lba, &want));
    try std.testing.expect(reader.readSector(lba, &got));
    std.testing.expectEqualSlices(u8, &want, &got) catch |err| {
        std.debug.print("{s}: LBA {d} differs\n", .{ name, lba });
        return err;
    };
}

test "every codec fixture reads back byte-identical to its .bin, in any order" {
    const flat = Disc.initFromCue(disc_cue, disc_bin);
    const count: i32 = @intCast(disc_bin.len / sector_bytes);
    for (fixtures) |f| {
        const r = try chd.Reader.open(std.testing.allocator, f.bytes);
        defer r.close();
        try std.testing.expectEqual(count, r.sectorCount());
        var lba: i32 = 0;
        while (lba < count) : (lba += 1) try expectSameSector(flat, r, lba, f.name);
        lba = count;
        while (lba > 0) : (lba -= 1) try expectSameSector(flat, r, lba - 1, f.name);
        // Interleaved: a data sector, then CD-DA, as a game streaming music does.
        lba = 0;
        while (lba < 30) : (lba += 1) {
            try expectSameSector(flat, r, lba, f.name);
            try expectSameSector(flat, r, count - 1 - lba, f.name);
        }
    }
}

test "a fixture's track table matches the cue's" {
    const flat = Disc.initFromCue(disc_cue, disc_bin);
    for (fixtures) |f| {
        const r = try chd.Reader.open(std.testing.allocator, f.bytes);
        defer r.close();
        try std.testing.expectEqual(flat.track_count, r.track_count);
        for (flat.tracks[0..flat.track_count], r.tracks[0..r.track_count]) |want, got| {
            try std.testing.expectEqualDeep(want, got);
        }
    }
}

test "a read outside the disc fails without touching a hunk" {
    const r = try chd.Reader.open(std.testing.allocator, fixtures[0].bytes);
    defer r.close();
    var out: [sector_bytes]u8 = undefined;
    try std.testing.expect(!r.readSector(-1, &out));
    try std.testing.expect(!r.readSector(r.sectorCount(), &out));
}

test "a corrupted hunk fails its own reads and no others" {
    const a = std.testing.allocator;
    const clean = try chd.Reader.open(a, fixtures[0].bytes);
    const first = clean.map[0];
    clean.close();
    try std.testing.expect(first.kind != .self and first.kind != .none);
    const at: usize = @intCast(first.offset + first.length / 2);
    const m = try mutated(fixtures[0].bytes, at, &.{fixtures[0].bytes[at] ^ 0xFF});
    defer a.free(m);
    const r = try chd.Reader.open(a, m);
    defer r.close();
    var out: [sector_bytes]u8 = undefined;
    try std.testing.expect(!r.readSector(0, &out));
    try std.testing.expect(r.readSector(r.sectorCount() - 1, &out));
}

test "a truncated or bit-rotted CHD never panics" {
    const a = std.testing.allocator;
    for (fixtures) |f| {
        // Half a file: chdman writes the map last, so open must refuse it.
        try std.testing.expectError(error.BadMap, chd.Reader.open(a, f.bytes[0 .. f.bytes.len / 2]));

        const h = try chd.Header.parse(f.bytes);
        const m = try a.dupe(u8, f.bytes);
        defer a.free(m);
        var rng = std.Random.DefaultPrng.init(f.bytes.len);
        for (0..64) |_| {
            const at = rng.random().intRangeLessThan(usize, 124, @intCast(h.map_offset));
            m[at] ^= rng.random().int(u8) | 1;
        }
        const r = chd.Reader.open(a, m) catch continue;
        defer r.close();
        var out: [sector_bytes]u8 = undefined;
        var lba: i32 = 0;
        while (lba < r.sectorCount()) : (lba += 1) _ = r.readSector(lba, &out);
    }
}
```

The bit-rot loop flips bytes between the header and the map. That covers the compressed hunks and, in the default fixture, the metadata. Some reads will fail, and the test only requires that none panic. For the half-file case, check with `xxd` that every fixture's map offset lies past its midpoint. If chdman ever wrote the map first, change that case to expect any error.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="track" 2>&1 | tail -5`
Expected: compile error, no member `Reader`/`parseTrack`.

- [ ] **Step 3: Write the reader**

Append to `ps1-core/src/chd/chd.zig` (and add `const disc = @import("../disc.zig");` and `const sector_bytes = @import("../constants.zig").sector_bytes;` at the top):

```zig
/// Tracks are padded to a multiple of this many frames inside the image.
const track_alignment = 4;
/// Hunks kept decoded: data and CD-DA interleave, and a self-reference
/// decodes its target into its own slot.
const cache_slots = 4;
const max_tracks = 99;
/// Metadata entries walked before the chain is declared corrupt.
const max_metadata = 1024;
const metadata_header_bytes = 16;

pub const TrackMeta = struct { number: u8, audio: bool, frames: u32, stored_pregap: u32 };

/// One `CHT2` (or older `CHTR`) entry. Only a pregap whose type starts with
/// `V` is stored in the image; any other takes no frames, and no LBAs.
pub fn parseTrack(text: []const u8) Error!TrackMeta {
    var number: ?u32 = null;
    var kind: []const u8 = "";
    var frames: ?u32 = null;
    var pregap: u32 = 0;
    var pregap_type: []const u8 = "";
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    while (fields.next()) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        const key = field[0..colon];
        const value = field[colon + 1 ..];
        if (std.mem.eql(u8, key, "TRACK")) {
            number = std.fmt.parseInt(u32, value, 10) catch return error.BadMetadata;
        } else if (std.mem.eql(u8, key, "TYPE")) {
            kind = value;
        } else if (std.mem.eql(u8, key, "FRAMES")) {
            frames = std.fmt.parseInt(u32, value, 10) catch return error.BadMetadata;
        } else if (std.mem.eql(u8, key, "PREGAP")) {
            pregap = std.fmt.parseInt(u32, value, 10) catch return error.BadMetadata;
        } else if (std.mem.eql(u8, key, "PGTYPE")) {
            pregap_type = value;
        }
    }
    const n = number orelse return error.BadMetadata;
    if (n == 0 or n > max_tracks) return error.BadMetadata;
    const total = frames orelse return error.BadMetadata;
    const audio = if (std.mem.eql(u8, kind, "AUDIO"))
        true
    else if (std.mem.eql(u8, kind, "MODE1_RAW") or std.mem.eql(u8, kind, "MODE2_RAW"))
        false
    else
        return error.UnsupportedTrackType;
    const stored = if (pregap_type.len > 0 and pregap_type[0] == 'V') pregap else 0;
    if (stored > total) return error.BadMetadata;
    return .{ .number = @intCast(n), .audio = audio, .frames = total, .stored_pregap = stored };
}

/// Where a track's LBAs live in the image.
const Layout = struct { first_lba: i32, frames: i32, chd_frame: u32, audio: bool };

/// A CHD opened over bytes the caller owns and keeps alive. Decodes hunks on
/// demand. Not thread-safe: a second thread opens its own.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    file: []const u8,
    header: Header,
    map: []map.Entry,
    tracks: [max_tracks]disc.Track = undefined,
    track_count: u8 = 0,
    layout: [max_tracks]Layout = undefined,
    sector_count: i32 = 0,
    cache_block: []u8,
    cache: [cache_slots]?u32 = @splat(null),
    next_slot: usize = 0,
    scratch: cd.Scratch,
    logged_failure: bool = false,

    const HunkError = error{ BadHunk, BadHunkCrc, OutOfMemory };

    pub fn open(gpa: std.mem.Allocator, file: []const u8) Error!*Reader {
        const header = try Header.parse(file);
        const entries = try map.decode(gpa, file, header.map_offset, header.hunk_count, header.hunk_bytes);
        errdefer gpa.free(entries);
        const cache_block = try gpa.alloc(u8, cache_slots * header.hunk_bytes);
        errdefer gpa.free(cache_block);
        var scratch = try cd.Scratch.init(gpa, header.hunk_bytes / cd.frame_bytes, header.usesCodec(.cdzs));
        errdefer scratch.deinit(gpa);

        const self = try gpa.create(Reader);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .file = file, .header = header, .map = entries, .cache_block = cache_block, .scratch = scratch };
        try self.readTracks();
        return self;
    }

    pub fn close(self: *Reader) void {
        const gpa = self.gpa;
        self.scratch.deinit(gpa);
        gpa.free(self.cache_block);
        gpa.free(self.map);
        gpa.destroy(self);
    }

    pub fn sectorCount(self: *const Reader) i32 {
        return self.sector_count;
    }

    fn readTracks(self: *Reader) Error!void {
        var offset = self.header.meta_offset;
        var lba: i32 = 0;
        var chd_frame: u32 = 0;
        var walked: usize = 0;
        while (offset != 0) : (walked += 1) {
            if (walked == max_metadata or offset + metadata_header_bytes > self.file.len) return error.BadMetadata;
            const head = self.file[@intCast(offset)..][0..metadata_header_bytes];
            const tag = head[0..4];
            const length = std.mem.readInt(u24, head[5..8], .big);
            const start = offset + metadata_header_bytes;
            if (start + length > self.file.len) return error.BadMetadata;
            offset = std.mem.readInt(u64, head[8..16], .big);

            if (std.mem.eql(u8, tag, "CHCD") or std.mem.eql(u8, tag, "CHGD")) return error.BadMetadata;
            if (!std.mem.eql(u8, tag, "CHT2") and !std.mem.eql(u8, tag, "CHTR")) continue;

            const text = std.mem.trimEnd(u8, self.file[@intCast(start)..][0..length], "\x00");
            const meta = try parseTrack(text);
            if (meta.number != self.track_count + 1) return error.BadMetadata;
            const frames: i32 = @intCast(meta.frames);
            const stored: i32 = @intCast(meta.stored_pregap);
            self.tracks[self.track_count] = .{
                .number = meta.number,
                .type = if (meta.audio) .audio else .data,
                .start_lba = lba + stored,
                .pregap_lba = if (stored > 0) lba else null,
            };
            self.layout[self.track_count] = .{ .first_lba = lba, .frames = frames, .chd_frame = chd_frame, .audio = meta.audio };
            self.track_count += 1;
            lba += frames;
            chd_frame += std.mem.alignForward(u32, meta.frames, track_alignment);
        }
        if (self.track_count == 0) return error.BadMetadata;
        if (@as(u64, chd_frame) * cd.frame_bytes > self.header.logical_bytes) return error.BadMetadata;
        self.sector_count = lba;
    }

    /// The raw 2352-byte sector at `lba`, audio in host (little-endian) order.
    pub fn readSector(self: *Reader, lba: i32, out: *[sector_bytes]u8) bool {
        if (lba < 0 or lba >= self.sector_count) return false;
        const layout = self.layoutFor(lba);
        const frame = layout.chd_frame + @as(u32, @intCast(lba - layout.first_lba));
        const per_hunk = self.header.hunk_bytes / cd.frame_bytes;
        const index = frame / per_hunk;
        const data = self.hunk(index) catch |err| {
            if (!self.logged_failure) std.log.warn("chd: hunk {d} unreadable: {s}", .{ index, @errorName(err) });
            self.logged_failure = true;
            return false;
        };
        @memcpy(out, data[(frame % per_hunk) * cd.frame_bytes ..][0..sector_bytes]);
        if (layout.audio) {
            var i: usize = 0;
            while (i < sector_bytes) : (i += 2) std.mem.swap(u8, &out[i], &out[i + 1]);
        }
        return true;
    }

    fn layoutFor(self: *const Reader, lba: i32) Layout {
        var found = self.layout[0];
        for (self.layout[0..self.track_count]) |l| {
            if (l.first_lba > lba) break;
            found = l;
        }
        return found;
    }

    fn slot(self: *Reader, index: usize) []u8 {
        return self.cache_block[index * self.header.hunk_bytes ..][0..self.header.hunk_bytes];
    }

    fn hunk(self: *Reader, n: u32) HunkError![]const u8 {
        for (self.cache, 0..) |cached, i| {
            if (cached) |c| if (c == n) return self.slot(i);
        }
        const i = self.next_slot;
        self.next_slot = (self.next_slot + 1) % cache_slots;
        self.cache[i] = null;
        try self.decodeHunk(n, self.slot(i));
        self.cache[i] = n;
        return self.slot(i);
    }

    fn decodeHunk(self: *Reader, n: u32, dest: []u8) HunkError!void {
        if (n >= self.map.len) return error.BadHunk;
        const entry = self.map[n];
        switch (entry.kind) {
            // A self-reference points back at a hunk that carries its own CRC.
            .self => {
                if (entry.offset >= n) return error.BadHunk;
                return self.decodeHunk(@intCast(entry.offset), dest);
            },
            .none => @memcpy(dest, try self.compressed(entry.offset, self.header.hunk_bytes)),
            else => {
                const codec = self.header.codecs[@intFromEnum(entry.kind)] orelse return error.BadHunk;
                try cd.decode(&self.scratch, self.gpa, codec, try self.compressed(entry.offset, entry.length), dest);
            },
        }
        if (std.hash.crc.@"CRC-16/IBM-3740".hash(dest) != entry.crc) return error.BadHunkCrc;
    }

    fn compressed(self: *const Reader, offset: u64, length: u64) HunkError![]const u8 {
        if (offset + length > self.file.len) return error.BadHunk;
        return self.file[@intCast(offset)..][0..@intCast(length)];
    }
};
```

If `std.mem.trimEnd` is spelled `trimRight` in 0.17, use that. `std.mem.alignForward(u32, …)` needs a power-of-two alignment, and 4 is one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter="track" 2>&1 | tail -5`, then `-Dtest-filter="fixture"`, `-Dtest-filter="hunk"` and `-Dtest-filter="never panics"`
Expected: PASS. A byte mismatch on an audio LBA only means the swap is wrong. A mismatch at a track's first LBA means the padding or pregap arithmetic is wrong. A mismatch on a data LBA only (bytes 0–11 or from 0x81C) means the ECC is wrong.

- [ ] **Step 5: Check the reader against GTA's real metadata (throwaway, not committed)**

Run this from the repo root, with a scratch test or a `zig run` of a five-line main that opens `games/grandtheftauto.chd` and prints `track_count`, each track's `start_lba`/`pregap_lba`/`type`, and `sectorCount()`.
Expected: 11 tracks. Track 1 is data at 0 with no pregap. Track 2 is audio, `pregap_lba` 26404, `start_lba` 26554. `sectorCount()` is the sum of the eleven FRAMES values. Delete the scratch file afterwards; never write to `games/`.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/chd ps1-core/tests/chd_test.zig
git add ps1-core/src/chd ps1-core/tests/chd_test.zig
git commit -m "feat(core): the CHD reader, its track table and hunk cache"
```

---

### Task 6: `Disc` reads from a CHD

**Files:**
- Modify: `ps1-core/src/disc.zig:155-322`
- Modify: `ps1-core/tests/chd_test.zig`

**Interfaces:**
- Consumes: `chd.Reader` (Task 5).
- Produces:
  - `disc.Source` = `union(enum) { flat: []const u8, chd: *chd.Reader }`, held as `Disc.source`. The `data` field is replaced.
  - `Disc.initFromChd(reader: *chd.Reader) Disc`.
  - `Disc.sectorCount(self) i32`.
  - `Disc.init` and `Disc.initFromCue` keep their signatures.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/chd_test.zig`:

```zig
test "a Disc over a CHD answers exactly as the Disc over its cue" {
    const flat = Disc.initFromCue(disc_cue, disc_bin);
    const r = try chd.Reader.open(std.testing.allocator, fixtures[4].bytes);
    defer r.close();
    const packed_disc = Disc.initFromChd(r);

    try std.testing.expectEqual(flat.sectorCount(), packed_disc.sectorCount());
    try std.testing.expectEqual(flat.leadOut(), packed_disc.leadOut());
    try std.testing.expectEqual(flat.firstTrack(), packed_disc.firstTrack());
    try std.testing.expectEqual(flat.lastTrack(), packed_disc.lastTrack());
    var lba: i32 = 0;
    while (lba < flat.sectorCount()) : (lba += 1) {
        try std.testing.expectEqual(flat.getSubchannelQ(lba), packed_disc.getSubchannelQ(lba));
        var want: [2048]u8 = undefined;
        var got: [2048]u8 = undefined;
        try std.testing.expectEqual(flat.readSector(lba, &want), packed_disc.readSector(lba, &got));
        try std.testing.expectEqualSlices(u8, &want, &got);
    }
}

test "a LibCrypt sidecar applies to a CHD disc as to a .bin" {
    const r = try chd.Reader.open(std.testing.allocator, fixtures[0].bytes);
    defer r.close();
    var d = Disc.initFromChd(r);
    // One record: MSF 00:02:05 (LBA 5), type 1, ten bytes of Q.
    const sbi = "SBI\x00" ++ [_]u8{ 0x00, 0x02, 0x05, 0x01 } ++ @as([10]u8, @splat(0));
    d.setSbi(sbi);
    try std.testing.expect(d.isLibCryptSector(5));
    try std.testing.expect(!d.isLibCryptSector(6));
}
```

Check `isLibCryptSector`'s address arithmetic against `disc.zig:258`. If it compares absolute MSF, `00:02:05` is LBA 5, which is right as written.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="Disc over a CHD" 2>&1 | tail -5`
Expected: compile error, no member `initFromChd`.

- [ ] **Step 3: Change `Disc`**

In `ps1-core/src/disc.zig`, add `const chd = @import("chd/chd.zig");` beside the other imports, and add this above `pub const Disc`:

```zig
/// Where a disc's sectors come from.
pub const Source = union(enum) {
    /// A flat image, 2352 bytes per sector, owned by the caller.
    flat: []const u8,
    /// A CHD, decompressed on demand; the reader is owned by the caller.
    chd: *chd.Reader,
};
```

In `Disc`:
- Replace `data: []const u8,` with `source: Source,`.
- In `init` and `initFromCue`, `Disc{ .data = data }` becomes `Disc{ .source = .{ .flat = data } }`.
- Add:

```zig
    pub fn initFromChd(reader: *chd.Reader) Disc {
        var d = Disc{ .source = .{ .chd = reader } };
        d.track_count = reader.track_count;
        @memcpy(d.tracks[0..reader.track_count], reader.tracks[0..reader.track_count]);
        return d;
    }

    pub fn sectorCount(self: Disc) i32 {
        return switch (self.source) {
            .flat => |data| @intCast(data.len / constants.sector_bytes),
            .chd => |reader| reader.sectorCount(),
        };
    }
```

- `leadOut` becomes `return MSF.fromLba(self.sectorCount());`.
- `readSector2352` becomes:

```zig
    pub fn readSector2352(self: Disc, lba: i32, buffer: *[constants.sector_bytes]u8) bool {
        if (lba < 0) return false;
        switch (self.source) {
            .chd => |reader| return reader.readSector(lba, buffer),
            .flat => |data| {
                const offset = @as(usize, @intCast(lba)) * constants.sector_bytes;
                if (offset + constants.sector_bytes > data.len) return false;
                @memcpy(buffer, data[offset..][0..constants.sector_bytes]);
                return true;
            },
        }
    }
```

- [ ] **Step 4: Fix every other `.data` reader**

Run: `zig build 2>&1 | grep -n "no field named 'data'" | head` and `grep -rn "disc\.data\|\.disc\.?\.data" --include=*.zig ps1-* | head`
Change each hit to `sectorCount()` or a `source` switch. The only known one is a print in `ps1-trace/src/main.zig:340`, which reads its own `LoadedCue.data` and is unaffected.

- [ ] **Step 5: Run the core tests and the golden gate**

Run: `zig build test 2>&1 | tail -3`
Expected: all 24 binaries pass.
Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -3`
Expected: every workload verifies. Only `Disc`'s storage changed, so a moved golden is a bug, never a recapture.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/disc.zig ps1-core/tests/chd_test.zig
git add ps1-core/src/disc.zig ps1-core/tests/chd_test.zig
git commit -m "feat(core): a Disc reads its sectors from a flat image or a CHD"
```

---

### Task 7: The C ABI opens a CHD

**Files:**
- Modify: `ps1-capi/src/root.zig` (`Handle` at :54, `ps1_destroy` at :164, `prepareDisc` at :366, `ps1_identify_disc` at :473)
- Modify: `ps1-capi/include/ps1.h:31-46` and the `ps1_load_disc` comment
- Modify: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `chd.isChd`, `chd.Reader`, `Disc.initFromChd`.
- Produces: `PS1_ERR_BAD_CHD` = `-15`. `ps1_load_disc`, `ps1_swap_disc` and `ps1_identify_disc` accept CHD bytes as `bin` when there is no cue. The handle owns its reader.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig` (runtime file reads, as the ROM suites do; `zig build test` runs from the repo root):

```zig
const chd_dir = "ps1-core/tests/chd/";

fn fixture(name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(std.testing.allocator, chd_dir ++ "{s}", .{name});
    defer std.testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
}

fn expectSectorsOf(h: *capi.Handle, bin: []const u8) !void {
    const d = h.cpu.bus.cdrom.disc orelse return error.NoDisc;
    var got: [2352]u8 = undefined;
    var lba: i32 = 0;
    while (lba < bin.len / 2352) : (lba += 1) {
        try std.testing.expect(d.readSector2352(lba, &got));
        try std.testing.expectEqualSlices(u8, bin[@as(usize, @intCast(lba)) * 2352 ..][0..2352], &got);
    }
}

test "load_disc opens a CHD passed as bin, and swap replaces its reader" {
    const a = std.testing.allocator;
    const bin = try fixture("disc.bin");
    defer a.free(bin);
    const zl = try fixture("disc-cdzl.chd");
    defer a.free(zl);
    const fl = try fixture("disc-cdfl.chd");
    defer a.free(fl);

    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, zl.ptr, zl.len, null, 0, null, 0));
    try std.testing.expect(h.chd != null);
    try expectSectorsOf(h, bin);

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_swap_disc(h, fl.ptr, fl.len, null, 0, null, 0));
    try expectSectorsOf(h, bin);

    // A flat image after a CHD leaves no reader behind.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, bin.ptr, bin.len, null, 0, null, 0));
    try std.testing.expect(h.chd == null);
}

test "a CHD the core refuses leaves the machine as it was" {
    const a = std.testing.allocator;
    const zl = try fixture("disc-cdzl.chd");
    defer a.free(zl);
    const v4 = try a.dupe(u8, zl);
    defer a.free(v4);
    v4[15] = 4; // version 5 -> 4

    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, zl.ptr, zl.len, null, 0, null, 0));
    const before = h.chd;
    try std.testing.expectEqual(@as(i32, -15), capi.ps1_load_disc(h, v4.ptr, v4.len, null, 0, null, 0));
    try std.testing.expectEqual(before, h.chd);
    // A cue never travels with CHD bytes.
    const cue = "FILE \"x.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n";
    try std.testing.expectEqual(@as(i32, -15), capi.ps1_load_disc(h, zl.ptr, zl.len, cue.ptr, cue.len, null, 0));
}

test "identify answers the same for a CHD as for its bin, and refuses a bad CHD" {
    const a = std.testing.allocator;
    const bin = try fixture("disc.bin");
    defer a.free(bin);
    const def = try fixture("disc-default.chd");
    defer a.free(def);
    var flat: capi.Ps1DiscId = undefined;
    var packed_id: capi.Ps1DiscId = undefined;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_identify_disc(bin.ptr, bin.len, &flat));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_identify_disc(def.ptr, def.len, &packed_id));
    try std.testing.expectEqual(flat, packed_id);

    def[15] = 4;
    try std.testing.expectEqual(@as(i32, -15), capi.ps1_identify_disc(def.ptr, def.len, &packed_id));
}
```

The fixture is no PlayStation disc, so both identities read "unknown, no serial". The equality still pins the path through the reader, and GTA's real serial is checked by hand in Task 9.

- [ ] **Step 2: Run them to verify they fail**

Run: `zig build test -Dtest-filter="CHD" 2>&1 | tail -5`
Expected: compile error, `Handle` has no field `chd`.

- [ ] **Step 3: Implement**

`ps1-capi/include/ps1.h`, after `PS1_ERR_ENGINE_UNAVAILABLE`:

```c
#define PS1_ERR_BAD_CHD          (-15)
```

Add this paragraph to the `ps1_load_disc` comment, after the multi-FILE paragraph:

```c
 * `bin` may instead be a whole CHD image (it begins "MComprHD"), with `cue`
 * NULL/0: the tracks come from the CHD itself. It is BORROWED exactly like a
 * flat image. Only CHD v5 CD images are read; an older version, a parent
 * (delta) CHD, an unknown codec, or a CHD passed with a cue is refused with
 * PS1_ERR_BAD_CHD.
```

`ps1-capi/src/root.zig`:
- Add `pub const PS1_ERR_BAD_CHD: i32 = -15;` beside the other codes. Match however the existing codes are declared.
- Add a `Handle` field after `sbi`:

```zig
    /// The open reader when the disc is a CHD, owned. `disc.source` points at
    /// it, so it is closed only once a new disc has replaced that one.
    chd: ?*ps1.chd.Reader = null,
```

- `ps1_destroy`: add `if (h.chd) |r| r.close();` before `allocator.free(h.sbi);`.
- `prepareDisc`: replace the tail from `const data = bin[0..bin_len];` through `return .{ .ok = d };` with:

```zig
    const data = bin[0..bin_len];
    var d: Disc = undefined;
    var reader: ?*ps1.chd.Reader = null;

    if (ps1.chd.isChd(data)) {
        if (cue_len > 0) return .{ .err = PS1_ERR_BAD_CHD };
        reader = ps1.chd.Reader.open(allocator, data) catch |err|
            return .{ .err = if (err == error.OutOfMemory) PS1_ERR_OOM else PS1_ERR_BAD_CHD };
        d = Disc.initFromChd(reader.?);
    } else if (cue_len > 0) {
        // ... the existing cue branch, unchanged ...
        d = Disc.initFromCue(cue_text, data);
    } else {
        d = Disc.init(data);
    }

    // Past this point nothing can fail but the copy itself, so the handle's
    // old sidecar and old reader are safe to drop: the caller installs `d`
    // before the machine reads another sector.
    const new_sbi: []u8 = if (sbi_len > 0)
        allocator.dupe(u8, sbi.?[0..sbi_len]) catch {
            if (reader) |r| r.close();
            return .{ .err = PS1_ERR_OOM };
        }
    else
        &.{};
    allocator.free(h.sbi);
    h.sbi = new_sbi;
    if (h.chd) |old| old.close();
    h.chd = reader;
    d.setSbi(new_sbi);
    return .{ .ok = d };
```

- `ps1_identify_disc`: replace `const id = ps1.discid.identify(Disc.init(bin[0..bin_len]));` with:

```zig
    const data = bin[0..bin_len];
    // A CHD needs its map decoded to be read at all; that is the one
    // allocation here, freed before returning.
    const reader: ?*ps1.chd.Reader = if (ps1.chd.isChd(data))
        ps1.chd.Reader.open(allocator, data) catch return PS1_ERR_BAD_CHD
    else
        null;
    defer if (reader) |r| r.close();
    const id = ps1.discid.identify(if (reader) |r| Disc.initFromChd(r) else Disc.init(data));
```

Update that function's doc comment: "no allocation" becomes "no allocation, except a CHD's map". Each call opens its own reader, so concurrent library-scan threads never share one. `smp_allocator` is thread-safe.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -3`
Expected: all pass, `capi_test` included.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-capi/src
git add ps1-capi
git commit -m "feat(capi): a CHD passed as bin loads, swaps and identifies"
```

---

### Task 8: The harnesses: `chd-verify`, `verify --chd`, and the round-trip script

**Files:**
- Create: `ps1-trace/src/cue_files.zig` (`LoadedCue`, `loadCue`, `cueFileName`, moved verbatim from `ps1-trace/src/main.zig:120-183`)
- Modify: `ps1-trace/src/main.zig` (the disc branch at ~:332-348)
- Modify: `ps1-bench/main.zig:66-82`
- Modify: `build.zig` (`trace_exe` ~:63-70, `golden_exe` ~:77-86)
- Create: `ps1-golden/src/chd_verify.zig`
- Modify: `ps1-golden/src/golden.zig:120-124` (`Source`)
- Modify: `ps1-golden/src/main.zig` (usage, `Options`, `parseArgs`, workload selection, `loadMachine`)
- Create: `tools/chd-roundtrip.sh`

**Interfaces:**
- Consumes: `chd.isChd`, `chd.Reader`, `Disc.initFromChd`, `Disc.sectorCount`.
- Produces:
  - `ps1-golden chd-verify --cue=<path> --chd=<path>`, which exits 1 on any difference.
  - `ps1-golden verify --cue=<path> --chd=<path>`, which boots that workload from the CHD, or prints a skip line and exits 0 when the cue is not a workload.
  - `golden.Source.chd: golden.ChdSource { chd: []const u8, cue: []const u8 }`.
  - `tools/chd-roundtrip.sh [filter]`.

- [ ] **Step 1: Move the cue loader into a shared module**

Create `ps1-trace/src/cue_files.zig` holding `const std = @import("std");`, plus `LoadedCue`, `loadCue` and `cueFileName` exactly as they are in `ps1-trace/src/main.zig`, with `pub` added to the struct and to `loadCue`. Delete them from `main.zig` and add `const cue_files = @import("cue_files");` there. Callers become `cue_files.loadCue(...)`.

In `build.zig`, after `trace_exe` is created:

```zig
    // One copy of the multi-FILE cue loader, for ps1-trace and ps1-golden's chd-verify.
    const cue_files_mod = b.createModule(.{
        .root_source_file = b.path("ps1-trace/src/cue_files.zig"),
        .target = target,
        .optimize = optimize,
    });
    trace_exe.root_module.addImport("cue_files", cue_files_mod);
```

After `golden_exe` is created, add `golden_exe.root_module.addImport("cue_files", cue_files_mod);`.

Run: `zig build 2>&1 | tail -3`
Expected: clean build.

- [ ] **Step 2: `ps1-trace` and `ps1-bench` open a CHD**

In `ps1-trace/src/main.zig`, the non-cue branch reads `disc_bytes` and calls `Disc.init(disc_bytes)`. Make it:

```zig
        d = if (ps1.chd.isChd(disc_bytes))
            ps1.disc.Disc.initFromChd(try ps1.chd.Reader.open(a, disc_bytes))
        else
            ps1.disc.Disc.init(disc_bytes);
```

Raise that branch's `.limited(900 * 1024 * 1024)` to `.limited(1 << 30)`, so any CHD a 900 MB-capped image could produce still fits. The reader lives in the run's arena; the process exits without closing it.

In `ps1-bench/main.zig:82`:

```zig
    const reader: ?*ps1.chd.Reader = if (cue_text == null and ps1.chd.isChd(data)) try ps1.chd.Reader.open(alloc, data) else null;
    defer if (reader) |r| r.close();
    const disc = if (cue_text) |c|
        ps1.disc.Disc.initFromCue(c, data)
    else if (reader) |r|
        ps1.disc.Disc.initFromChd(r)
    else
        ps1.disc.Disc.init(data);
```

Run: `zig build -Doptimize=ReleaseFast && zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin games/grandtheftauto.chd 300000000 /tmp/claude-gta 2>&1 | tail -15`
Expected: the run completes and writes `frame_*.ppm` files to the snapshot directory. Look at the last one (the Read tool shows images). If GTA is a PAL disc and the US BIOS stops at the region screen, rerun with `SCPH-7502` (its BIOS file in the repo root). Delete `/tmp/claude-gta` afterwards. If `ps1-trace`'s snapshot argument differs, read its usage line (`ps1-trace/src/main.zig:13`).

- [ ] **Step 3: Write `chd_verify.zig`**

`ps1-golden/src/chd_verify.zig`:

```zig
//! `chd-verify`: a CHD made from a cue must be the same disc as the cue. Every
//! sector from LBA 0 to the lead-out, the track table and the identity.
const std = @import("std");
const ps1 = @import("ps1_core");
const cue_files = @import("cue_files");

const Disc = ps1.disc.Disc;
const sector_bytes = ps1.constants.sector_bytes;

/// True when the two discs differ in any way.
pub fn run(a: std.mem.Allocator, io: std.Io, cue_path: []const u8, chd_path: []const u8) !bool {
    const loaded = try cue_files.loadCue(io, a, cue_path);
    const flat = Disc.initFromCue(loaded.cue, loaded.data);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, chd_path, a, .limited(1 << 30));
    const reader = try ps1.chd.Reader.open(a, bytes);
    defer reader.close();
    const packed_disc = Disc.initFromChd(reader);

    var failed = false;
    if (flat.track_count != packed_disc.track_count or
        !std.meta.eql(flat.tracks[0..flat.track_count].*, packed_disc.tracks[0..packed_disc.track_count].*))
    {
        failed = true;
        std.debug.print("  track tables differ\n", .{});
        for (0..@max(flat.track_count, packed_disc.track_count)) |i| {
            std.debug.print("    cue {any}\n    chd {any}\n", .{ flat.tracks[i], packed_disc.tracks[i] });
        }
    }
    if (flat.sectorCount() != packed_disc.sectorCount()) {
        failed = true;
        std.debug.print("  sector counts differ: cue {d}, chd {d}\n", .{ flat.sectorCount(), packed_disc.sectorCount() });
    }

    const count = @min(flat.sectorCount(), packed_disc.sectorCount());
    var want: [sector_bytes]u8 = undefined;
    var got: [sector_bytes]u8 = undefined;
    var mismatches: u32 = 0;
    var first: i32 = 0;
    var lba: i32 = 0;
    while (lba < count) : (lba += 1) {
        const ok_flat = flat.readSector2352(lba, &want);
        const ok_chd = packed_disc.readSector2352(lba, &got);
        if (ok_flat != ok_chd or !std.mem.eql(u8, &want, &got)) {
            if (mismatches == 0) first = lba;
            mismatches += 1;
        }
    }
    if (mismatches > 0) {
        failed = true;
        std.debug.print("  {d} sectors differ, the first at LBA {d} (track {d})\n", .{
            mismatches, first, flat.trackForLba(first).number,
        });
    }

    const id_flat = ps1.discid.identify(flat);
    const id_chd = ps1.discid.identify(packed_disc);
    if (!std.meta.eql(id_flat.region, id_chd.region) or !std.mem.eql(u8, id_flat.serial.slice(), id_chd.serial.slice())) {
        failed = true;
        std.debug.print("  identities differ: cue {s}, chd {s}\n", .{ id_flat.serial.slice(), id_chd.serial.slice() });
    }

    std.debug.print("  {s}: {d} sectors, {d} tracks, {s}  {s}\n", .{
        cue_path, count, flat.track_count, id_flat.serial.slice(), if (failed) "DIFFERS" else "identical",
    });
    return failed;
}
```

If `std.meta.eql` does not accept the array-of-struct-with-optional comparison, compare field by field in a loop.

- [ ] **Step 4: Wire `chd-verify` and `--chd` into `ps1-golden`**

`ps1-golden/src/golden.zig`:

```zig
/// A CHD standing in for the cue it was made from. The cue still names the
/// workload and finds the `.sbi`.
pub const ChdSource = struct { chd: []const u8, cue: []const u8 };

pub const Source = union(enum) {
    bios_only,
    disc: []const u8, // cue path
    exe: []const u8, // .exe path
    chd: ChdSource,
};
```

`ps1-golden/src/main.zig`:
- Usage: add these lines.

```
    \\  chd-verify      --cue=<path> --chd=<path>: the CHD must read back as the
    \\                  same disc as the cue, sector for sector
```

  and, under `--cue`:

```
    \\  --cue=<path> --chd=<path>  (verify) boot the workload whose cue is
    \\                          --cue from the CHD instead; its golden must
    \\                          verify unchanged. A cue that is not a workload
    \\                          prints a skip line and exits 0.
```

- `Options`: add `chd: ?[]const u8 = null`. Mode enum: add `chd_verify`.
- `parseArgs`: map `"chd-verify"` to `.chd_verify`; parse `--chd=`. Replace the two `--cue`/`--key` checks at the end with:

```zig
    // `--cue` and `--key` are one option in two halves for stream-capture: the
    // key is the fixture's filename and there is no directory to fall back on.
    if (opts.mode == .stream_capture and (opts.cue == null) != (opts.key == null)) return error.BadArguments;
    if (opts.mode == .chd_verify and (opts.cue == null or opts.chd == null)) return error.BadArguments;
    if (opts.chd != null and opts.mode != .verify and opts.mode != .chd_verify) return error.BadArguments;
    if (opts.chd != null and opts.cue == null) return error.BadArguments;
    if (opts.cue != null and opts.mode != .stream_capture and opts.chd == null) return error.BadArguments;
```

- In `main`, before workload selection:

```zig
    if (opts.mode == .chd_verify) {
        if (try chd_verify.run(a, init.io, opts.cue.?, opts.chd.?)) std.process.exit(1);
        return;
    }
```

  Add `const chd_verify = @import("chd_verify.zig");` with the other imports.

- Workload selection: put this branch before the existing `if (opts.cue)`:

```zig
    const workloads = if (opts.chd) |chd_path| blk: {
        for (try golden.discover(a, init.io)) |wl| {
            if (wl.source == .disc and std.mem.eql(u8, wl.source.disc, opts.cue.?)) {
                const one = try a.alloc(golden.Workload, 1);
                one[0] = wl;
                one[0].source = .{ .chd = .{ .chd = chd_path, .cue = opts.cue.? } };
                break :blk one;
            }
        }
        std.debug.print("[golden] {s} is not a verify workload; boot check skipped\n", .{opts.cue.?});
        return;
    } else if (opts.cue) |cue_path| blk: {
```

  Check that `discover` builds the cue path as `games/<dir>/<name>.cue`, the same spelling the script passes (`golden.zig:256`).

- `loadMachine`: pull the sidecar lookup into a helper, so the `.disc` and `.chd` branches share it:

```zig
/// A LibCrypt disc without its `.sbi` never gets past its own protection
/// check, so a run without one records a loop, not a boot.
fn attachSbi(a: std.mem.Allocator, io: std.Io, d: *ps1.disc.Disc, cue_path: []const u8) !void {
    const sbi_path = try std.fmt.allocPrint(a, "{s}.sbi", .{cue_path[0 .. cue_path.len - 4]});
    if (std.Io.Dir.cwd().readFileAlloc(io, sbi_path, a, .limited(1 << 20))) |sbi| {
        d.setSbi(sbi);
    } else |_| {}
}
```

  Use it in `.disc`, and add:

```zig
        .chd => |src| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, src.chd, a, .limited(1 << 30));
            var d = ps1.disc.Disc.initFromChd(try ps1.chd.Reader.open(a, bytes));
            try attachSbi(a, io, &d, src.cue);
            if (ps1.discid.identify(d).region) |region| chosen = golden.biosForRegion(region);
            bus.cdrom.setDisc(d);
        },
```

  The reader is allocated from the workload's arena, which frees it with the workload. Every other exhaustive `switch (wl.source)` gets `.chd` handled wherever `.disc` is: `zig build` names each one.

- [ ] **Step 5: Write the round-trip script**

`tools/chd-roundtrip.sh`:

```bash
#!/usr/bin/env bash
# Converts each games/*/*.cue to a CHD in a private temporary directory,
# checks it (sector-for-sector, then a boot against the disc's golden), and
# deletes it before the next disc. At most one converted disc exists at a
# time; nothing is ever written to games/. Optional $1 filters cue paths.
#
# Needs chdman (brew install rom-tools) and a ReleaseFast build:
#   zig build -Doptimize=ReleaseFast
set -uo pipefail
cd "$(dirname "$0")/.."

GOLDEN=zig-out/bin/ps1-golden
MIN_FREE_KB=$((2 * 1024 * 1024))

command -v chdman >/dev/null || { echo "chdman not found: brew install rom-tools"; exit 2; }
[ -x "$GOLDEN" ] || { echo "$GOLDEN missing: zig build -Doptimize=ReleaseFast"; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/chd-roundtrip.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

failed=0
for cue in games/*/*.cue; do
    [[ -n "${1:-}" && "$cue" != *"$1"* ]] && continue
    free_kb=$(df -k "$scratch" | awk 'NR==2 {print $4}')
    if (( free_kb < MIN_FREE_KB )); then
        echo "less than 2 GB free; stopping before $cue"
        exit 2
    fi

    chd="$scratch/$(basename "${cue%.*}").chd"
    echo "== $cue"
    if chdman createcd -i "$cue" -o "$chd" >/dev/null 2>&1; then
        "$GOLDEN" chd-verify --cue="$cue" --chd="$chd" || failed=1
        "$GOLDEN" verify --cue="$cue" --chd="$chd" || failed=1
    else
        echo "   chdman could not convert this cue"
        failed=1
    fi
    rm -f "$chd"
done
exit $failed
```

Run: `chmod +x tools/chd-roundtrip.sh && zig build -Doptimize=ReleaseFast && tools/chd-roundtrip.sh croc`
Expected: one `identical` line for Croc, then its `verify` line. The scratch directory is gone afterwards: `ls "${TMPDIR:-/tmp}" | grep chd-roundtrip` prints nothing.

- [ ] **Step 6: Run the whole library**

Run: `df -h . | tail -1 && tools/chd-roundtrip.sh 2>&1 | tee /tmp/claude-roundtrip.log | grep -E "^==|identical|DIFFERS|diverged|skipped|could not"`
Expected: every disc prints `identical`, and every workload's `verify` matches or prints "not a verify workload; boot check skipped". This takes on the order of an hour; run it in the background and check back. Afterwards `ls games/*/*.chd 2>/dev/null` lists nothing, and `ls games/` still shows `grandtheftauto.chd`.

On a `DIFFERS`, use the LBA and track in the report. A first-LBA-of-track mismatch is the pregap or padding mapping. An audio-only mismatch is byte order, or a pregap chdman stored (`V`) that the cue had as `PREGAP`. Reproduce it in `chd_test.zig` with a fixture before fixing the reader.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-trace ps1-bench ps1-golden build.zig
git add ps1-trace ps1-bench ps1-golden build.zig tools/chd-roundtrip.sh
git commit -m "feat(golden): chd-verify and verify --chd, run one disc at a time by chd-roundtrip"
```

---

### Task 9: The macOS app

**Files:**
- Create: `ps1-macos/Sources/PS1/DiscKind.swift`
- Modify: `ps1-macos/Sources/PS1/GameEntry.swift`, `GameScanner.swift`, `EmulatorViewModel.swift` (:905-907, :949-951, :960-970, :990-1000, :1089, :1711), `Ps1Core.swift` (:12-40), `LibraryView.swift:215`, `OnboardingView.swift:30`, `ps1-macos/Info.plist:5-33`
- Create: `ps1-macos/Tests/PS1Tests/DiscKindTests.swift`
- Modify: `ps1-macos/Tests/PS1Tests/GameScannerTests.swift`, and every test passing `isCue:` (`grep -rln "isCue" ps1-macos/Tests`)

**Interfaces:**
- Consumes: `PS1_ERR_BAD_CHD` (-15); `ps1_load_disc`/`ps1_swap_disc`/`ps1_identify_disc` accepting CHD bytes (Task 7).
- Produces: `DiscKind` (`.cue`, `.bin`, `.chd`, `init(_ url: URL)`), `GameEntry.kind`, `GameEntry.init(url:identity:)` (the `isCue:` parameter is removed), and `Ps1Error.badCHD`.

Invoke the `ps1-macos-app` skill before starting this task.

- [ ] **Step 1: Write the failing tests**

`ps1-macos/Tests/PS1Tests/DiscKindTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

@Test func discKindReadsTheExtensionCaseInsensitively() {
    #expect(DiscKind(URL(fileURLWithPath: "/g/Croc.cue")) == .cue)
    #expect(DiscKind(URL(fileURLWithPath: "/g/Croc.CUE")) == .cue)
    #expect(DiscKind(URL(fileURLWithPath: "/g/GTA.chd")) == .chd)
    #expect(DiscKind(URL(fileURLWithPath: "/g/GTA.CHD")) == .chd)
    #expect(DiscKind(URL(fileURLWithPath: "/g/Loose.bin")) == .bin)
}

/// A converted copy resumes the original's state: both identify to one
/// serial, and the store keys on the serial.
@Test func aCueAndItsChdShareOneResumeKey() {
    let identity = DiscIdentity(region: .america, serial: "SLUS-00530",
                                volumeID: nil, gameTitle: nil, discNumber: nil)
    let cue = GameEntry(url: URL(fileURLWithPath: "/g/Croc/Croc.cue"), identity: identity)
    let chd = GameEntry(url: URL(fileURLWithPath: "/elsewhere/Croc.chd"), identity: identity)
    #expect(ResumeStateStore.key(for: cue) == ResumeStateStore.key(for: chd))
}

@Test func aChdFindsTheSidecarBesideIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("SBI\0".utf8).write(to: dir.appendingPathComponent("FF9.sbi"))
    #expect(EmulatorViewModel.sidecar(forDisc: dir.appendingPathComponent("FF9.chd")) != nil)
}
```

Match `DiscIdentity`'s real memberwise initializer and `sidecar(forDisc:)`'s real visibility and return type. Read them first: `DiscIdentity.swift`, and `EmulatorViewModel.swift` near :1693.

Append to `GameScannerTests.swift`:

```swift
@Test func scannerListsALoneChd() throws {
    let root = try makeGamesFolder(["GTA/grandtheftauto.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.map(\.title) == ["grandtheftauto"])
    #expect(entries.first?.kind == .chd)
}

@Test func scannerShowsACueAndItsSameNamedChdOnce() throws {
    let root = try makeGamesFolder(["Croc/Croc.cue", "Croc/Croc.bin", "Croc/Croc.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.count == 1)
    #expect(entries.first?.kind == .cue)
}

@Test func scannerPrefersAChdOverASameNamedLoneBin() throws {
    let root = try makeGamesFolder(["Loose/Game.bin", "Loose/Game.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.count == 1)
    #expect(entries.first?.kind == .chd)
}

@Test func scannerKeepsADifferentlyNamedChdBesideACue() throws {
    let root = try makeGamesFolder(["Mixed/Croc.cue", "Mixed/Croc.bin", "Mixed/Spyro.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GameScanner.scan(root: root).map(\.title) == ["Croc", "Spyro"])
}

/// A CHD the core refuses still shows: unidentified, never dropped.
@Test func scannerKeepsAChdItCannotIdentify() throws {
    let root = try makeGamesFolder(["Old/Old.chd"])
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = GameScanner.scan(root: root)
    #expect(entries.count == 1)
    #expect(entries.first?.serial == nil)
}
```

- [ ] **Step 2: Implement**

`ps1-macos/Sources/PS1/DiscKind.swift`:

```swift
import Foundation

/// What kind of image a disc file is, read off its extension. A `.cue` names
/// its tracks, a `.chd` carries its own, and a lone `.bin` is one data track.
enum DiscKind: Equatable, Sendable {
    case cue, bin, chd

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "cue": self = .cue
        case "chd": self = .chd
        default: self = .bin
        }
    }
}
```

`GameEntry.swift`: delete `let isCue: Bool` and its init parameter and assignment, then add:

```swift
    var kind: DiscKind { DiscKind(url) }
```

`init(url: URL, identity: DiscIdentity = .unknown)`. Then run `grep -rln "isCue" ps1-macos` and fix each call site:
- `isCue: true, ` / `, isCue: true` / `isCue: false, ` disappear from the constructors;
- `entries.first?.isCue == true` becomes `entries.first?.kind == .cue`, and `== false` becomes `== .bin`.

`GameScanner.swift`: update the type comment to describe the three kinds and the same-stem rule, add `private static let chdExtension = "chd"` and a `chds` dictionary filled in the switch, then replace the entry building with:

```swift
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        func stems(_ urls: [URL]?) -> Set<String> { Set((urls ?? []).map(stem)) }
        func entry(_ url: URL) -> GameEntry {
            GameEntry(url: url, identity: DiscIdentity.identify(disc: url) ?? .unknown)
        }

        var entries = cues.values.flatMap { $0 }.map(entry)
        // A converted copy kept beside its original is the same game: the cue
        // wins over its .chd, and a .chd wins over a lone .bin of its name.
        for (directory, urls) in chds {
            let taken = stems(cues[directory])
            entries += urls.filter { !taken.contains(stem($0)) }.map(entry)
        }
        for (directory, urls) in bins where cues[directory] == nil {
            let taken = stems(chds[directory])
            entries += urls.filter { !taken.contains(stem($0)) }.map(entry)
        }
```

`EmulatorViewModel.swift`:
- `discEntry(for:)`: `GameEntry(url: url, identity: DiscIdentity.identify(disc: url) ?? .unknown)`.
- In `changeDisc` and `load`: `let isCue = …` becomes `let kind = DiscKind(url)` (`entry.url` in `changeDisc`), and `if isCue {` becomes `if kind == .cue {`. The `else` branch (`Data(contentsOf:)`) already serves a `.chd`.
- `showRawBinWarning = !isCue` becomes `showRawBinWarning = kind == .bin`.
- The open panel message becomes `"Open a .cue (preferred), a .chd, or a raw .bin"`.
- `describe`: add `case Ps1Error.badCHD: return "This CHD was made by an old chdman or depends on a parent image. Re-create it with chdman createcd."`

`Ps1Core.swift`: add `case badCHD` to `Ps1Error`, and `case -15: return .badCHD` to `from(_:)`.

`LibraryView.swift:215`: `"A game is a .cue or .chd file, or a .bin in a folder with no .cue. Subfolders are scanned too."`
`OnboardingView.swift:30`: `"Scanned recursively for .cue and .chd files. A .bin counts too, when its folder has no .cue."`

`ps1-macos/Info.plist`: add a third `CFBundleDocumentTypes` dict after the `bin` one:

```xml
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>chd</string>
            </array>
            <key>CFBundleTypeIconFile</key>
            <string>Substation</string>
            <key>CFBundleTypeName</key>
            <string>PlayStation CHD Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
        </dict>
```

Check the Finder-open path (`open(_ url:)` and any `application(_:open:)`) for an extension allowlist: `grep -rn '"cue"' ps1-macos/Sources`. Add `chd` wherever `cue` is accepted.

- [ ] **Step 3: Build and run the Swift suite**

Run: `zig build capi-lib metallib -Doptimize=ReleaseFast && pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -5`
Expected: all tests pass. The count is the previous 625 plus the 8 new ones.

- [ ] **Step 4: Check GTA in the app by hand**

Run: `zig build macos -Doptimize=ReleaseFast && open zig-out/Substation.app`
Expected:
- GTA's tile appears in the library with its serial on the row; this is the real-disc identify check.
- It boots to gameplay.
- A car radio plays music, which is CD-DA through `cdfl`.
- Finder's "Open With" lists Substation for a `.chd`.

Ask the user to confirm the music if it can't be heard from here.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos
git commit -m "feat(macos): .chd discs in the library, Open Disc, Finder and disc swap"
```

---

### Task 10: Docs, speed check, and memory

**Files:**
- Modify: `.claude/skills/ps1-cdrom-disc/SKILL.md` (new section after "Disc identification")
- Modify: `CLAUDE.md` (test count, quick commands, repository layout, tests list)
- Modify: `docs/superpowers/specs/2026-10-07-chd-disc-images-design.md` (Status line)

- [ ] **Step 1: Write the skill section**

Add `## CHD images` to `.claude/skills/ps1-cdrom-disc/SKILL.md`, covering each point as a rule followed by its reason:
- the five files in `chd/` and what each owns;
- the three traps: tracks padded to 4 frames; a pregap is stored only when `PGTYPE` starts with `V`, and an unstored one takes no LBAs, as a cue `PREGAP` takes none; audio is big-endian;
- ECC regeneration: LSB-first bitmap, sync plus P then Q, a Mode 2 header counts as zero;
- why the subcode is decompressed (the hunk CRC covers it) and never read;
- what is refused, and that a failed hunk fails only its reads;
- the reader is not thread-safe: identify opens its own, and the handle's is read on the emulator thread only;
- the gates: `chd_test` with fixtures from `make_fixtures.sh`, and `tools/chd-roundtrip.sh`, which deletes every copy;
- GTA is the in-the-wild `cdfl`/CD-DA disc and has no cue.

- [ ] **Step 2: Update `CLAUDE.md`**

- The `zig build test` row: **24 test binaries**, "the 18 `unit_test_files`".
- Add rows after `trace-golden -- savestate`:
  - `zig build trace-golden -- chd-verify --cue=<c> --chd=<h>`: a CHD must read back as the same disc as its cue, every sector, the tracks and the identity.
  - `tools/chd-roundtrip.sh [filter]`: converts each `games/*/*.cue` into a temp dir, runs `chd-verify` and `verify --cue --chd`, and deletes the copy. Needs `chdman` (`brew install rom-tools`). Never writes to `games/`.
- Repository layout: add `chd/` under `ps1-core/src` ("CHD v5 reader: chd.zig (Reader, header, tracks), map.zig, cd.zig (CD codecs + ECC), flac.zig, bitstream.zig"), and add `chd_test` to the `tests/` list.
- The `disc.zig` line gains "a `Source`: a flat image or a CHD reader".
- Under "Rules that must not be broken → CDROM + disc", add: **A CHD hunk's CRC covers its subcode, and an unstored pregap takes no LBAs.** Skipping the subcode leaves the CRC unverifiable, and giving a non-`V` pregap LBAs desynchronises every later track from the cue it was made from.

- [ ] **Step 3: Speed check (not a gate)**

```bash
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
chdman createcd -i "games/Croc - Legend of the Gobbos/"*.cue -o "$d/croc.chd" >/dev/null
for i in 1 2 3 4 5; do zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "games/Croc - Legend of the Gobbos/"*.cue 3000 | tail -1; done
for i in 1 2 3 4 5; do zig-out/bin/ps1-bench-dual SCPH-1001_BIOS_1995_US.bin "$d/croc.chd" 3000 | tail -1; done
rm -rf "$d"
```

Expected: the best of five for the CHD is within noise (±2%) of the best for the cue. Record both numbers in the skill section. If the CHD is measurably slower, profile before adding cache slots.

- [ ] **Step 4: Run every gate once more**

Run: `zig build test 2>&1 | tail -3 && zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -3`
Expected: all green.

- [ ] **Step 5: Mark the spec done and commit**

Set the spec's status line to `Status: implemented 2026-10-07`, then:

```bash
git add .claude/skills/ps1-cdrom-disc/SKILL.md CLAUDE.md docs/superpowers/specs/2026-10-07-chd-disc-images-design.md
git commit -m "docs: CHD images, their traps and their gates"
```

- [ ] **Step 6: Update memory**

Write `project-chd-disc-images.md` in the memory directory, and update `project-duckstation-parity-roadmap.md`'s item 2 to DONE (unpushed). Include:
- the three traps;
- that GTA is the only real CHD and has no cue;
- that `chd-roundtrip` deletes every converted copy because disk space is tight.
