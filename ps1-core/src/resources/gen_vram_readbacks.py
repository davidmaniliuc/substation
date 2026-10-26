#!/usr/bin/env python3
"""Generates vram_readbacks.zon from the upstream game database, the same
gamedb.yaml gen_pgxp_presets.py reads (its docstring says where to fetch it).

    python3 ps1-core/src/resources/gen_vram_readbacks.py gamedb.yaml <commit> > ps1-core/src/resources/vram_readbacks.zon

Keeps the serials of every entry carrying the ForceSoftwareRendererForReadbacks
trait: the games that read VRAM back often enough that a machine whose only
VRAM is the GPU's would spend its frames waiting. Run it on the commit
pgxp_presets.zon was generated from, so the two tables describe one database.
"""

import pathlib
import sys

# Run under `python3 -I`, which leaves the script's own directory off the path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gen_pgxp_presets import entries, keys  # noqa: E402

TRAIT = "ForceSoftwareRendererForReadbacks"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_vram_readbacks.py <gamedb.yaml> <upstream commit>")
    path, commit = sys.argv[1], sys.argv[2]

    rows = set()
    for serial, codes, traits, _ in entries(path):
        if TRAIT not in traits:
            continue
        for key in keys(serial, codes):
            rows.add(key)

    out = sys.stdout
    out.write("// Generated, do not edit: ps1-core/src/resources/gen_vram_readbacks.py\n")
    out.write(f"// from the upstream data/resources/gamedb.yaml at {commit}.\n")
    out.write("// Read through vram_readbacks.zig.\n")
    out.write(".{\n")
    for key in sorted(rows):
        out.write(f'    "{key}",\n')
    out.write("}\n")
    print(f"{len(rows)} serials", file=sys.stderr)


if __name__ == "__main__":
    main()
