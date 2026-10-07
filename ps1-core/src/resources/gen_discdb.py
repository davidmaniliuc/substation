#!/usr/bin/env python3
"""Generates discdb.zon from DuckStation's discsets.yaml and gamedb.yaml.

    curl -sSfLO https://raw.githubusercontent.com/stenzek/duckstation/<commit>/data/resources/discsets.yaml
    curl -sSfLO https://raw.githubusercontent.com/stenzek/duckstation/<commit>/data/resources/gamedb.yaml
    python3 ps1-core/src/resources/gen_discdb.py discsets.yaml gamedb.yaml <commit> > ps1-core/src/resources/discdb.zon

A set's identity is its `saveName` (else its `name`), which carries the region,
so two regions' rips of one game stay two sets. A disc's number is its
one-based position in the set's `serials` list. A set lists each disc by its
gamedb KEY; a disc whose SYSTEM.CNF serial is one of that entry's `codes`
belongs to the same set, so every code is expanded here, beneath any serial
the set lists by name.

Both files are read line by line, as gen_pgxp_presets.py reads gamedb.yaml.
A duplicate set identity or a serial in two sets is an error, so an upstream
change cannot regroup discs silently. A set serial with no gamedb entry is
kept under its own serial, with a warning.
"""

import re
import sys

SET_NAME = re.compile(r'^- name: "([^"\\]*)"\s*$')
SET_FIELD = re.compile(r'^  ([A-Za-z]+):(?: "([^"\\]*)")?\s*$')
SET_SERIAL = re.compile(r"^    - ([A-Za-z0-9_.-]+)\s*(?:#.*)?$")

ENTRY = re.compile(r"^([A-Za-z0-9_.-]+):\s*$")
SECTION = re.compile(r"^  ([A-Za-z]+):")
ITEM = re.compile(r"^    - (\S+)")


def parse_sets(path):
    """Yields (identity, serials) per set."""
    name, save_name, serials, section = None, None, [], None
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = SET_NAME.match(line)
        if m:
            if name is not None:
                yield save_name or name, serials
            name, save_name, serials, section = m.group(1), None, [], None
            continue
        m = SET_FIELD.match(line)
        if m:
            section = m.group(1)
            if section == "saveName":
                save_name = m.group(2)
            continue
        m = SET_SERIAL.match(line)
        if m and section == "serials":
            serials.append(m.group(1).upper())
            continue
        sys.exit(f"{path}:{n}: unrecognised line: {line}")
    if name is not None:
        yield save_name or name, serials


def parse_codes(path):
    """Returns {gamedb key: [serials a disc may report]}."""
    codes, key, section = {}, None, None
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].rstrip()
        if not line:
            continue
        m = ENTRY.match(line)
        if m:
            key, section = m.group(1).upper(), None
            codes[key] = []
            continue
        m = SECTION.match(line)
        if m:
            section = m.group(1)
            continue
        if section == "codes":
            m = ITEM.match(line)
            if m:
                codes[key].append(m.group(1).upper())
    return codes


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: gen_discdb.py <discsets.yaml> <gamedb.yaml> <duckstation commit>")
    sets_path, gamedb_path, commit = sys.argv[1:]

    codes = parse_codes(gamedb_path)
    sets = list(parse_sets(sets_path))

    # A serial a set LISTS is placed first, at its own position: one gamedb
    # entry's codes can span discs the set numbers apart (Tokimeki Memorial
    # 2's undumped revision is five serials under one entry).
    identities, rows = set(), {}
    for identity, serials in sets:
        if identity in identities:
            sys.exit(f"duplicate set {identity}")
        identities.add(identity)
        for number, serial in enumerate(serials, 1):
            if serial in rows:
                sys.exit(f"{serial} is in both {rows[serial][0]} and {identity}")
            rows[serial] = (identity, number)

    # Then each listed entry's codes, where nothing listed them already.
    for identity, serials in sets:
        for number, key in enumerate(serials, 1):
            if key not in codes:
                # Still a serial a disc can report, so it keys itself.
                print(f"{identity}: {key} has no gamedb entry", file=sys.stderr)
            for serial in codes.get(key, []):
                if serial.startswith("HASH-"):
                    continue
                owner = rows.setdefault(serial, (identity, number))
                if owner[0] != identity:
                    sys.exit(f"{serial} is in both {owner[0]} and {identity}")

    out = sys.stdout
    out.write("// Generated, do not edit: ps1-core/src/resources/gen_discdb.py\n")
    out.write(f"// from DuckStation's data/resources/discsets.yaml and gamedb.yaml at {commit}.\n")
    out.write("// Read through discdb.zig.\n")
    out.write(".{\n")
    for serial in sorted(rows):
        identity, number = rows[serial]
        out.write(f'    .{{ .serial = "{serial}", .game_title = "{identity}", .disc_number = {number} }},\n')
    out.write("}\n")
    print(f"{len(identities)} sets, {len(rows)} serials", file=sys.stderr)


if __name__ == "__main__":
    main()
