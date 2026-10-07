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
