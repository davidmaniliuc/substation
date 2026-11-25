#!/usr/bin/env python3
"""Generates cd_speedup.zon from the upstream game database, the same
gamedb.yaml gen_pgxp_presets.py reads (its docstring says where to fetch it).

    python3 -I ps1-core/src/resources/gen_cd_speedup.py gamedb.yaml <commit> > ps1-core/src/resources/cd_speedup.zon

Keeps, per serial, which CD speedup a game cannot take: DisableCDROMReadSpeedup
disables the read speedup, DisableCDROMSeekSpeedup the seek speedup, and
DisableCDROMSpeedupOnMDEC also disables the read speedup, because this core has
no MDEC-activity gate and disabling it for those games is the safe first cut.
Run it on the commit pgxp_presets.zon was generated from, so the tables
describe one database.
"""

import pathlib
import sys

# Run under `python3 -I`, which leaves the script's own directory off the path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gen_pgxp_presets import entries, keys  # noqa: E402

READ_TRAITS = {"DisableCDROMReadSpeedup", "DisableCDROMSpeedupOnMDEC"}
SEEK_TRAITS = {"DisableCDROMSeekSpeedup"}


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_cd_speedup.py <gamedb.yaml> <upstream commit>")
    path, commit = sys.argv[1], sys.argv[2]

    rows = {}
    for serial, codes, traits, _ in entries(path):
        read = bool(READ_TRAITS & set(traits))
        seek = bool(SEEK_TRAITS & set(traits))
        if not (read or seek):
            continue
        for key in keys(serial, codes):
            was_read, was_seek = rows.get(key, (False, False))
            rows[key] = (was_read or read, was_seek or seek)

    out = sys.stdout
    out.write("// Generated, do not edit: ps1-core/src/resources/gen_cd_speedup.py\n")
    out.write(f"// from the upstream data/resources/gamedb.yaml at {commit}.\n")
    out.write("// Read through cd_speedup.zig.\n")
    out.write(".{\n")
    for key in sorted(rows):
        read, seek = rows[key]
        out.write(
            f'    .{{ .serial = "{key}", .read_disabled = {str(read).lower()}, '
            f".seek_disabled = {str(seek).lower()} }},\n"
        )
    out.write("}\n")
    print(f"{len(rows)} serials", file=sys.stderr)


if __name__ == "__main__":
    main()
