#!/usr/bin/env bash
# Writes each games/*/*.cue as a CloneCD set, an ECM, an eboot, an Alcohol
# image with and without subchannel and (for a single data track) an ISO in a
# private temporary directory, checks each one sector for sector, boots each
# but the ISO against the disc's golden, and deletes it before the next. At
# most one written image exists at a time; nothing is ever written to games/.
# Once per run, a two-disc eboot from the first two cues the filter keeps is
# written and each disc is checked against its own cue.
# Optional $1 filters cue paths.
#
# Needs a ReleaseFast build: zig build -Doptimize=ReleaseFast
set -uo pipefail
cd "$(dirname "$0")/.."

GOLDEN=zig-out/bin/ps1-golden
MIN_FREE_KB=$((2 * 1024 * 1024))
REFUSED=3

[ -x "$GOLDEN" ] || { echo "$GOLDEN missing: zig build -Doptimize=ReleaseFast"; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/format-roundtrip.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

failed=0
for cue in games/*/*.cue; do
    [[ -n "${1:-}" && "$cue" != *"$1"* ]] && continue
    echo "== $cue"
    for format in ccd ecm iso pbp mds mds-sub; do
        free_kb=$(df -k "$scratch" | awk 'NR==2 {print $4}')
        if (( free_kb < MIN_FREE_KB )); then
            echo "less than 2 GB free; stopping before $cue ($format)"
            exit 2
        fi

        stem="$scratch/$(basename "${cue%.*}")"
        "$GOLDEN" image-write --cue="$cue" --format="$format" --out="$stem"
        status=$?
        if (( status == REFUSED )); then
            continue
        elif (( status != 0 )); then
            echo "   $format: image-write failed"
            failed=1
        elif [ "$format" = ccd ]; then
            "$GOLDEN" image-verify --cue="$cue" --image="$stem.ccd" --sub="$stem.sub" || failed=1
            "$GOLDEN" verify --cue="$cue" --image="$stem.ccd" --sub="$stem.sub" || failed=1
        elif [ "$format" = iso ]; then
            # Read back only: a cooked image keeps no mode byte, subheader or
            # Form 2 sector, all of which the drive reports, so its boot
            # leaves the golden by construction (Crash Warped: at 97.5M
            # dressed as Mode 1, at 160M dressed as Form 1).
            "$GOLDEN" image-verify --cue="$cue" --image="$stem.$format" || failed=1
        else
            image="$stem.${format%%-*}"
            "$GOLDEN" image-verify --cue="$cue" --image="$image" || failed=1
            "$GOLDEN" verify --cue="$cue" --image="$image" || failed=1
        fi
        rm -f "$stem".*
    done
done

# One two-disc eboot per run: disc 1 must boot as the second cue.
cues=()
for cue in games/*/*.cue; do
    [[ -n "${1:-}" && "$cue" != *"$1"* ]] && continue
    cues+=("$cue")
done
if (( ${#cues[@]} >= 2 )); then
    echo "== two-disc eboot: ${cues[0]} + ${cues[1]}"
    free_kb=$(df -k "$scratch" | awk 'NR==2 {print $4}')
    if (( free_kb < MIN_FREE_KB )); then
        echo "less than 2 GB free; stopping before the two-disc eboot"
        exit 2
    fi
    stem="$scratch/two-disc"
    if "$GOLDEN" image-write --cue="${cues[0]},${cues[1]}" --format=pbp --out="$stem"; then
        for n in 0 1; do
            "$GOLDEN" image-verify --cue="${cues[$n]}" --image="$stem.pbp" --disc=$n || failed=1
            "$GOLDEN" verify --cue="${cues[$n]}" --image="$stem.pbp" --disc=$n || failed=1
        done
    else
        echo "   two-disc eboot: image-write failed"
        failed=1
    fi
    rm -f "$stem".*
fi
exit $failed
