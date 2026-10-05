#!/usr/bin/env python3
"""Generates pgxp_presets.zon from DuckStation's gamedb.yaml.

    curl -sSfLO https://raw.githubusercontent.com/stenzek/duckstation/<commit>/data/resources/gamedb.yaml
    python3 ps1-core/src/resources/gen_pgxp_presets.py gamedb.yaml <commit> > ps1-core/src/resources/pgxp_presets.zon

Only the PGXP traits and settings are kept. The file is read line by line
rather than through a YAML library: its layout is machine-written and regular
(a serial at column 0, sections at two spaces, list items at four), and the
standard library has no YAML parser. A PGXP key this script does not know is
an error, so an upstream addition cannot be dropped silently.
"""

import re
import sys

# Trait -> (field, value). The fields are pgxp_presets.zig's.
TRAITS = {
    "DisablePGXP": ("enabled", False),
    "ForcePGXPCPUMode": ("cpu", True),
    "DisablePGXPCulling": ("culling", False),
    "ForcePGXPVertexCache": ("vertex_cache", True),
    "DisablePGXPTextureCorrection": ("texture_correction", False),
    "DisablePGXPColorCorrection": ("color_correction", False),
    "DisablePGXPDepthBuffer": ("depth_buffer", False),
    "DisablePGXPOn2DPolygons": ("disable_2d", True),
}

# Setting -> field, or None for one this core has no equivalent of.
SETTINGS = {
    "gpuPGXPTolerance": "tolerance",
    "gpuPGXPPreserveProjFP": "preserve_projection",
    "gpuPGXPDepthThreshold": None,
}

FIELDS = ["enabled", "cpu", "culling", "vertex_cache", "texture_correction",
          "color_correction", "depth_buffer", "disable_2d", "preserve_projection",
          "tolerance"]

SERIAL = re.compile(r"^([A-Za-z0-9_.-]+):\s*$")
SECTION = re.compile(r"^  ([A-Za-z]+):")
ITEM = re.compile(r"^    - (\S+)")
SETTING = re.compile(r"^    ([A-Za-z0-9]+):\s*(\S+)")


def strip_comment(line):
    # No value this script reads is a quoted string, so a '#' always starts a
    # comment on the lines it looks at.
    return line.split("#", 1)[0].rstrip()


def parse(path):
    """Yields (serial, codes, fields, skipped) per entry."""
    serial, codes, fields, skipped, section = None, [], {}, [], None
    for raw in open(path, encoding="utf-8"):
        line = strip_comment(raw.rstrip("\n"))
        if not line:
            continue
        m = SERIAL.match(line)
        if m:
            if serial:
                yield serial, codes, fields, skipped
            serial, codes, fields, skipped, section = m.group(1), [], {}, [], None
            continue
        m = SECTION.match(line)
        if m:
            section = m.group(1)
            continue
        if section == "codes":
            m = ITEM.match(line)
            if m:
                codes.append(m.group(1))
        elif section == "traits":
            m = ITEM.match(line)
            if m and "PGXP" in m.group(1):
                if m.group(1) not in TRAITS:
                    sys.exit(f"{serial}: unknown PGXP trait {m.group(1)}")
                field, value = TRAITS[m.group(1)]
                fields[field] = value
        elif section == "settings":
            m = SETTING.match(line)
            if m and "PGXP" in m.group(1):
                if m.group(1) not in SETTINGS:
                    sys.exit(f"{serial}: unknown PGXP setting {m.group(1)}")
                field = SETTINGS[m.group(1)]
                if field is None:
                    skipped.append(m.group(1))
                elif field == "tolerance":
                    fields[field] = float(m.group(2))
                else:
                    fields[field] = {"true": True, "false": False}[m.group(2)]
    if serial:
        yield serial, codes, fields, skipped


def zon_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return repr(float(v))


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_pgxp_presets.py <gamedb.yaml> <duckstation commit>")
    path, commit = sys.argv[1], sys.argv[2]

    rows, skipped_total = {}, 0
    for serial, codes, fields, skipped in parse(path):
        skipped_total += len(skipped)
        if not fields:
            continue
        # DuckStation's rule: an entry with a codes list is found by those
        # codes, and its own key is not one of them unless listed.
        for code in codes or [serial]:
            key = code.upper()
            # DuckStation's key for a disc with no serial, from a hash of its
            # executable. A SYSTEM.CNF serial can never match one.
            if key.startswith("HASH-"):
                continue
            if key in rows:
                print(f"duplicate serial {key}, keeping the first", file=sys.stderr)
                continue
            rows[key] = fields

    out = sys.stdout
    out.write("// Generated, do not edit: ps1-core/src/resources/gen_pgxp_presets.py\n")
    out.write(f"// from DuckStation's data/resources/gamedb.yaml at {commit}.\n")
    out.write("// Read through pgxp_presets.zig.\n")
    out.write(".{\n")
    for key in sorted(rows):
        fields = rows[key]
        parts = [f'.serial = "{key}"'] + [
            f".{f} = {zon_value(fields[f])}" for f in FIELDS if f in fields]
        out.write("    .{ " + ", ".join(parts) + " },\n")
    out.write("}\n")
    print(f"{len(rows)} serials; skipped {skipped_total} settings with no equivalent",
          file=sys.stderr)


if __name__ == "__main__":
    main()
