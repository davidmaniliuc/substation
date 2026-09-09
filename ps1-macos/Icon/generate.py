#!/usr/bin/env python3
"""Emit the Substation icon as flat SVG layers for Icon Composer.

The mark is a blocky S -- three horizontal bars joined by two connectors --
sheared about the canvas centre. The shear turns the connectors into diagonals
and slants every terminal in one step; the two outer terminals are then cut
steeper than the shear so they finish as strike points.

Icon Composer supplies its own gloss, specular and shadow, so every layer here
stays flat: paths and gradients only, no filters, masks or text.
"""

import os

CANVAS = 1024
CENTRE = CANVAS / 2

BAR = 118                      # bar thickness
LEFT, RIGHT = 276, 748         # upright mark box
TOP, BOTTOM = 204, 820
MID_TOP, MID_BOTTOM = 454, 570
SHEAR = 0.17
TIP = 54                       # extra cut on the two strike terminals
ARM = 34                       # how far the two arms stop short of the bowl
CHAMFER = 104                  # corner cut on the outside of each bowl

PLATE_TOP, PLATE_BOTTOM = "#1A2340", "#070A14"
GLOW = "#F7A41D"
EXTRUDE_TOP, EXTRUDE_BOTTOM = "#7A4B08", "#3F2504"
EXTRUDE_OFFSET = (22, 26)
RIM = "#FFE9B0"

# Light falls from the upper left, so the ramp runs bright at the top bar to
# dark at the bottom one. Each band carries several shades so its seams show
# the way a flat-shaded facet group does.
BAND_SHADES = [
    ["#FFD070", "#FDC252", "#F9BA46", "#F5B23C"],   # top bar + its chamfer
    ["#FBB63C", "#F7A82A"],                          # left connector
    ["#F7A41D", "#EE9A16"],                          # middle bar -- hero amber
    ["#DE8C11", "#D0810D"],                          # right connector
    ["#C8790B", "#BC7109", "#B06B08", "#A46307"],   # bottom bar + its chamfer
]

# A blocky 5 and a blocky S are the same topology; what separates them is that
# the 5 has a hard corner outside each bowl where the S turns. CHAMFER cuts
# those two corners with a pair of straight segments -- a low-poly quarter arc.
BEVEL = 0.293


def shear(x, y):
    return (round(x + SHEAR * (CENTRE - y), 2), float(y))


def on_edge(a, b, y):
    """Point at height y on the segment a-b."""
    t = (y - a[1]) / (b[1] - a[1])
    return (round(a[0] + (b[0] - a[0]) * t, 2), float(y))


A1 = shear(LEFT + CHAMFER, TOP)
A2 = shear(LEFT + BEVEL * CHAMFER, TOP + BEVEL * CHAMFER)
A3 = shear(LEFT, TOP + CHAMFER)
P2 = shear(RIGHT - ARM, TOP)
P3 = shear(RIGHT - ARM - TIP, TOP + BAR)
P4 = shear(LEFT + BAR, TOP + BAR)
P5 = shear(LEFT + BAR, MID_TOP)
P6 = shear(RIGHT, MID_TOP)
B1 = shear(RIGHT, BOTTOM - CHAMFER)
B2 = shear(RIGHT - BEVEL * CHAMFER, BOTTOM - BEVEL * CHAMFER)
B3 = shear(RIGHT - CHAMFER, BOTTOM)
P8 = shear(LEFT + ARM, BOTTOM)
P9 = shear(LEFT + ARM + TIP, BOTTOM - BAR)
P10 = shear(RIGHT - BAR, BOTTOM - BAR)
P11 = shear(RIGHT - BAR, MID_BOTTOM)
P12 = shear(LEFT, MID_BOTTOM)

OUTLINE = [A1, P2, P3, P4, P5, P6, B1, B2, B3, P8, P9, P10, P11, P12, A3, A2]

# Seam points where a band boundary meets the outer edge.
S1 = on_edge(A3, P12, TOP + BAR)
S2 = on_edge(A3, P12, MID_TOP)
S3 = on_edge(P6, B1, MID_BOTTOM)
S4 = on_edge(P6, B1, BOTTOM - BAR)

# Each band is fanned from its first point, so a band carrying a chamfer simply
# has more points and picks up more shades from its row of BAND_SHADES.
BANDS = [
    [A1, P2, P3, S1, A3, A2],      # top bar, chamfered at the outside of the bowl
    [S1, P4, P5, S2],              # left connector
    [S2, P6, S3, P12],             # middle bar
    [P11, S3, S4, P10],            # right connector
    [P9, S4, B1, B2, B3, P8],      # bottom bar, chamfered
]

# One shard off each strike terminal. More than this reads as dust once the
# icon is down at 32pt.
SPARKS = [
    [(846, 178), (906, 218), (842, 232)],
    [(178, 846), (118, 806), (182, 792)],
]


def poly(points, fill, opacity=None):
    pts = " ".join(f"{x},{y}" for x, y in points)
    extra = f' opacity="{opacity}"' if opacity is not None else ""
    return f'  <polygon points="{pts}" fill="{fill}"{extra}/>'


def svg(body, defs=""):
    head = f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">'
    if defs:
        head += f"\n <defs>\n{defs}\n </defs>"
    return f"{head}\n{body}\n</svg>\n"


def linear(ident, top, bottom, x2=0):
    return (f'  <linearGradient id="{ident}" x1="0" y1="0" x2="{x2}" y2="1">\n'
            f'   <stop offset="0" stop-color="{top}"/>\n'
            f'   <stop offset="1" stop-color="{bottom}"/>\n'
            f'  </linearGradient>')


def layer_plate():
    defs = linear("plate", PLATE_TOP, PLATE_BOTTOM, x2=0.35)
    return svg(f'  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#plate)"/>', defs)


def layer_scanlines():
    rows = "\n".join(
        f'  <rect x="0" y="{y}" width="{CANVAS}" height="3" fill="#FFFFFF"/>'
        for y in range(0, CANVAS, 10))
    return svg(f'  <g opacity="0.045">\n{rows}\n  </g>')


def layer_glow():
    defs = ('  <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">\n'
            f'   <stop offset="0" stop-color="{GLOW}" stop-opacity="0.55"/>\n'
            f'   <stop offset="0.55" stop-color="{GLOW}" stop-opacity="0.18"/>\n'
            f'   <stop offset="1" stop-color="{GLOW}" stop-opacity="0"/>\n'
            '  </radialGradient>')
    return svg(f'  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#glow)"/>', defs)


def layer_extrude():
    dx, dy = EXTRUDE_OFFSET
    shifted = [(round(x + dx, 2), round(y + dy, 2)) for x, y in OUTLINE]
    defs = linear("extrude", EXTRUDE_TOP, EXTRUDE_BOTTOM)
    return svg(poly(shifted, "url(#extrude)"), defs)


def layer_bolt():
    facets = []
    for band, shades in zip(BANDS, BAND_SHADES):
        for i in range(len(band) - 2):
            facets.append(poly([band[0], band[i + 1], band[i + 2]], shades[i]))
    return svg("\n".join(facets))


def layer_sparks():
    rim = [A1, P2, (round(P2[0] - 24, 2), P2[1] + 14), (round(A1[0] + 12, 2), A1[1] + 14)]
    parts = [poly(rim, RIM, opacity="0.9")]
    parts += [poly(s, "#FFC34D", opacity="0.95") for s in SPARKS]
    return svg("\n".join(parts))


LAYERS = [
    ("01-plate.svg", layer_plate),
    ("02-scanlines.svg", layer_scanlines),
    ("03-glow.svg", layer_glow),
    ("04-extrude.svg", layer_extrude),
    ("05-bolt.svg", layer_bolt),
    ("06-sparks.svg", layer_sparks),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    # The layers live inside the Icon Composer bundle rather than beside it, so
    # there is one copy of each and regenerating cannot leave the icon stale.
    assets = os.path.join(here, "Substation.icon", "Assets")
    for name, build in LAYERS:
        with open(os.path.join(assets, name), "w") as f:
            f.write(build())
    bodies = []
    defs = []
    for name, build in LAYERS:
        text = build()
        inner = text.split(">", 1)[1].rsplit("</svg>", 1)[0]
        if "<defs>" in inner:
            head, inner = inner.split("</defs>", 1)
            defs.append(head.split("<defs>", 1)[1])
        bodies.append(inner.strip())
    with open(os.path.join(here, "preview.svg"), "w") as f:
        f.write(svg("\n".join(bodies), "\n".join(defs)))


if __name__ == "__main__":
    main()
