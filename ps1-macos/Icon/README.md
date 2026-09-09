# Substation icon

An angular S struck as a lightning bolt: flat-shaded facets in Zig amber over a
dark CRT plate. `generate.py` emits every layer; edit the constants at the top
of it and re-run rather than hand-editing an SVG.

    python3 ps1-macos/Icon/generate.py

## Layers

Import into Icon Composer bottom-up, in filename order:

| File | Role |
|---|---|
| `01-plate.svg` | full-bleed background gradient; Icon Composer clips the squircle |
| `02-scanlines.svg` | CRT texture, 4.5% white — invisible below ~128pt, by design |
| `03-glow.svg` | amber bloom behind the mark |
| `04-extrude.svg` | the silhouette offset down-right; the mark's thickness |
| `05-bolt.svg` | the flat-shaded facets |
| `06-sparks.svg` | lit top edge plus one shard off each strike terminal |

`preview.svg` composites all six and is not an import layer.

Every layer is plain paths and gradients — no filters, masks or text, which
Icon Composer's SVG import does not handle. It supplies its own gloss, specular
and shadow, so nothing here fakes depth beyond the extrude layer.
