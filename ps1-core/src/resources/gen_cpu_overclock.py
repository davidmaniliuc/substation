#!/usr/bin/env python3
"""Generates cpu_overclock.zon from the upstream game database, the same
gamedb.yaml gen_pgxp_presets.py reads (its docstring says where to fetch it).

    python3 ps1-core/src/resources/gen_cpu_overclock.py gamedb.yaml <commit> > ps1-core/src/resources/cpu_overclock.zon

Keeps every entry whose settings carry cpuOverclockPercent: the games that
need the CPU at another clock than the real one, mostly to work around a
crash. Run it on the commit pgxp_presets.zon was generated from, so the
tables describe one database.
"""

import pathlib
import sys

# Run under `python3 -I`, which leaves the script's own directory off the path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gen_pgxp_presets import entries, keys  # noqa: E402

SETTING = "cpuOverclockPercent"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_cpu_overclock.py <gamedb.yaml> <upstream commit>")
    path, commit = sys.argv[1], sys.argv[2]

    rows = {}
    for serial, codes, _, settings in entries(path):
        percent = dict(settings).get(SETTING)
        if percent is None:
            continue
        for key in keys(serial, codes):
            rows[key] = int(percent)

    out = sys.stdout
    out.write("// Generated, do not edit: ps1-core/src/resources/gen_cpu_overclock.py\n")
    out.write(f"// from the upstream data/resources/gamedb.yaml at {commit}.\n")
    out.write("// Read through cpu_overclock.zig.\n")
    out.write(".{\n")
    for key in sorted(rows):
        out.write(f'    .{{ .serial = "{key}", .percent = {rows[key]} }},\n')
    out.write("}\n")
    print(f"{len(rows)} serials", file=sys.stderr)


if __name__ == "__main__":
    main()
