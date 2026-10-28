#!/bin/sh
# Renders Substation.icon into SubstationDocument.icns, the icon the disc
# document types name (CFBundleTypeIconFile). actool's own Substation.icns
# stops at 256 px, which Finder, Spotlight and Raycast upscale for a large
# preview. Re-run after editing the .icon and commit the result.
set -eu
cd "$(dirname "$0")"
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/doc.iconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        name="icon_${points}x${points}"
        [ "$scale" = 2 ] && name="${name}@2x"
        px=$((points * scale))
        # A macOS icon's squircle is 824 of 1024: the rest is the grid's margin.
        inner=$(((px * 824 + 512) / 1024))
        "$ictool" Substation.icon --export-image --output-file "$work/plate.png" \
            --platform macOS --rendition Default \
            --width "$inner" --height "$inner" --scale 1 >/dev/null
        sips -p "$px" "$px" "$work/plate.png" --out "$work/doc.iconset/$name.png" >/dev/null
    done
done
iconutil -c icns -o SubstationDocument.icns "$work/doc.iconset"
