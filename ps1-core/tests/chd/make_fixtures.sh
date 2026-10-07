#!/usr/bin/env bash
# Regenerates every CHD/FLAC fixture in this directory. Needs `chdman`
# (brew install rom-tools) and `flac`. The outputs are committed; nothing in
# the build runs this.
set -euo pipefail
cd "$(dirname "$0")"

for t in python3 flac chdman; do command -v "$t" >/dev/null || { echo "make_fixtures.sh: $t not found (brew install rom-tools flac)" >&2; exit 1; }; done

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
    text = (f"sector {lba} mode {mode} " * 140).encode()
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
