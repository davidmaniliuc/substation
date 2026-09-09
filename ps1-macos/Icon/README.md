# Substation icon

An angular S struck as a lightning bolt: flat-shaded facets in Zig amber over a
dark CRT plate. `Substation.icon` is the Icon Composer document the app ships;
`generate.py` emits its layers.

    python3 ps1-macos/Icon/generate.py

The generator writes straight into `Substation.icon/Assets/`, so there is one
copy of each layer and regenerating cannot leave the icon holding stale art.
Edit the constants at the top of `generate.py` and re-run rather than
hand-editing an SVG — `SHEAR` sets the lean, `CHAMFER` how far the mark reads
away from a 5, `BAND_SHADES` the amber ramp. Re-open the document in Icon
Composer afterwards to see the change; `icon.json` (group membership, shadow,
translucency) is Icon Composer's and the generator never touches it.

## Layers

Bottom-up, in filename order:

| File | Role |
|---|---|
| `01-plate.svg` | full-bleed background gradient; Icon Composer clips the squircle |
| `02-scanlines.svg` | CRT texture, 4.5% white — invisible below ~128pt, by design |
| `03-glow.svg` | amber bloom behind the mark |
| `04-extrude.svg` | the silhouette offset down-right; the mark's thickness |
| `05-bolt.svg` | the flat-shaded facets |
| `06-sparks.svg` | lit top edge plus one shard off each strike terminal |

`preview.svg` composites all six flat, without Icon Composer's treatment, and is
not part of the document.

Every layer is plain paths and gradients — no filters, masks or text, which
Icon Composer's SVG import does not handle. It supplies its own gloss, specular
and shadow, so nothing here fakes depth beyond the extrude layer.

## How it reaches the app

`Substation.icon` is a resource of the `PS1` target, and
`ASSETCATALOG_COMPILER_APPICON_NAME = Substation` is set on both of its build
configurations. `GENERATE_INFOPLIST_FILE = NO` here, so `CFBundleIconName` is
written by hand in `ps1-macos/Info.plist` rather than injected — the icon
compiles but never appears if that key is missing.

`actool` emits both `Assets.car` (holding the six layers as vectors, the two
icon groups and the image stack — this is what macOS 26 renders, and what keeps
the layers separate enough to parallax) and a `Substation.icns` carrying only
the 16pt and 128pt sizes as a compatibility fallback. The thin `.icns` is
expected, not a truncated build.
