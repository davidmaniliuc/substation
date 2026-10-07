#!/usr/bin/env python3
"""Generates game_titles.zon from DuckStation's gamedb.yaml.

    curl -sSfLO https://raw.githubusercontent.com/stenzek/duckstation/<commit>/data/resources/gamedb.yaml
    python3 ps1-core/src/resources/gen_game_titles.py gamedb.yaml <commit> > ps1-core/src/resources/game_titles.zon

Only each entry's `name` is kept. The file is read line by line, as
gen_pgxp_presets.py reads it: a serial at column 0, fields at two spaces,
list items at four. A name that is not a plain double-quoted string, or an
entry with no name, is an error, so an upstream change of layout cannot
produce a mangled or missing title silently.
"""

import re
import sys

SERIAL = re.compile(r"^([A-Za-z0-9_.-]+):\s*$")
SECTION = re.compile(r"^  ([A-Za-z]+):")
NAME = re.compile(r'^  name: "([^"\\]*)"\s*$')
ITEM = re.compile(r"^    - (\S+)")


def parse(path):
    """Yields (serial, codes, name) per entry."""
    serial, codes, name, section = None, [], None, None
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = SERIAL.match(line)
        if m:
            if serial:
                yield serial, codes, name
            serial, codes, name, section = m.group(1), [], None, None
            continue
        m = SECTION.match(line)
        if m:
            section = m.group(1)
            if section == "name":
                n = NAME.match(line)
                if not n:
                    sys.exit(f"{serial}: name is not a plain quoted string: {line}")
                name = n.group(1)
            continue
        if section == "codes":
            m = ITEM.match(line)
            if m:
                codes.append(m.group(1))
    if serial:
        yield serial, codes, name


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_game_titles.py <gamedb.yaml> <duckstation commit>")
    path, commit = sys.argv[1], sys.argv[2]

    rows = {}
    for serial, codes, name in parse(path):
        if name is None:
            sys.exit(f"{serial}: entry has no name")
        # An entry with a codes list is found by those codes, and its own key
        # is not one of them unless listed.
        for code in codes or [serial]:
            key = code.upper()
            # A key for a disc with no serial, from a hash of its executable.
            # A SYSTEM.CNF serial can never match one.
            if key.startswith("HASH-"):
                continue
            if key in rows:
                print(f"duplicate serial {key}, keeping the first", file=sys.stderr)
                continue
            rows[key] = name

    out = sys.stdout
    out.write("// Generated, do not edit: ps1-core/src/resources/gen_game_titles.py\n")
    out.write(f"// from DuckStation's data/resources/gamedb.yaml at {commit}.\n")
    out.write("// Read through game_titles.zig.\n")
    out.write(".{\n")
    for key in sorted(rows):
        out.write(f'    .{{ .serial = "{key}", .title = "{rows[key]}" }},\n')
    out.write("}\n")
    print(f"{len(rows)} serials", file=sys.stderr)


if __name__ == "__main__":
    main()
