---
name: Substation
description: A native PlayStation emulator for the Mac.
colors:
  system-accent: "#007AFF"
  inset-fill-dark: "rgba(0, 0, 0, 0.28)"
  inset-fill-light: "rgba(255, 255, 255, 0.55)"
  dialog-tint: "rgba(30, 30, 30, 0.3)"
  placeholder-top: "#333333"
  placeholder-bottom: "#1F1F1F"
  game-black: "#000000"
typography:
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
  callout:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  label:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro, -apple-system, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 400
rounded:
  thumbnail: "5px"
  row: "8px"
  tile: "10px"
  panel: "12px"
  alert: "18px"
  dialog: "22px"
  capsule: "9999px"
spacing:
  hairline: "1px"
  tight: "4px"
  row-gap: "9px"
  panel-inset: "10px"
  bar-inset: "16px"
  grid: "18px"
  tile-gap: "20px"
  dialog: "20px"
components:
  library-panel:
    backgroundColor: "{colors.inset-fill-dark}"
    rounded: "{rounded.panel}"
    padding: "{spacing.grid}"
  game-tile:
    rounded: "{rounded.tile}"
    width: "132px"
  game-tile-placeholder:
    backgroundColor: "{colors.placeholder-top}"
    rounded: "{rounded.tile}"
  dialog-card:
    backgroundColor: "{colors.dialog-tint}"
    rounded: "{rounded.dialog}"
    padding: "{spacing.dialog}"
  confirm-card:
    backgroundColor: "{colors.dialog-tint}"
    rounded: "{rounded.alert}"
    padding: "{spacing.dialog}"
  hud-icon-button:
    rounded: "{rounded.capsule}"
    width: "32px"
    height: "30px"
  pause-menu-row:
    typography: "{typography.body}"
    rounded: "{rounded.row}"
    padding: "0 8px"
    height: "34px"
  pause-menu:
    width: "300px"
  button-prominent:
    backgroundColor: "{colors.system-accent}"
    rounded: "{rounded.capsule}"
---

# Design System: Substation

## Overview

**Creative North Star: "The Console Behind Glass"**

The game is the picture. Everything Substation adds, the bar, the pause menu, the
save states, the prompts, floats over that picture as glass or blur and gets out
of the way. In the library the same idea holds: cover art is the only colour on
screen, set into a quiet inset panel, and the chrome around it is the Mac's own.

The system is quiet, native and tactile. Quiet: the chrome is monochrome, and
the accent marks only what a click will act on (the selection, the default
button, a control's value), never decoration. Native: system fonts, system
controls, system window colours under the System, Dark and Light themes, and
behaviour copied from Apple's own apps (Music, Finder) rather than invented.
Tactile: covers sit on the panel with a small shadow like physical cases, SF
Symbols change with a symbol transition, and floating surfaces arrive on short
snappy springs.

Confirmed rejections: animated or gradient library backdrops, a pure-black
library theme, and Liquid Glass on content.

**Key Characteristics:**
- Monochrome chrome; colour comes from cover art and the player's accent only.
- Three depths: the window material, an inset fill for content, glass and shadow
  for anything floating.
- One radius ladder (5 / 8 / 10 / 12 / 18 / 22) so nested shapes stay concentric.
- SF Pro at macOS text-style sizes, secondary and tertiary label colours for
  hierarchy.
- The game's picture is black under every theme.

## Colors

Almost no literal colour: semantic system colours carry text, separators and
backgrounds, and the few values the code defines exist to sit on top of them.

### Primary
- **System Accent** (`system-accent`, shown with macOS's default blue): the
  player's own macOS accent colour, never a Substation brand colour. It marks the
  selected cover's outline, the prominent button, focus rings in cards and the
  selected save slot. Whether Substation should ever ship its own tint is an
  open question; until it is decided, nothing hard-codes one.

### Neutral
- **Inset Shade, dark** (`inset-fill-dark`): the fill under content set into a
  surface (the library panel, the resume sheet's list and footer) in Dark. A
  shade darker than the window material, so it reads as sunk.
- **Inset Shade, light** (`inset-fill-light`): the same fill in Light, a shade
  lighter than the material.
- **Window-Leaning Glass Tint** (`dialog-tint`): modal cards tint their glass 30%
  toward the window background colour, as a macOS 26 system alert does. The
  value shown is indicative; the code resolves it from
  `NSColor.windowBackgroundColor` per scheme.
- **Empty Case Gradient** (`placeholder-top` to `placeholder-bottom`): a cover
  with no art, a vertical grey gradient under a thin `opticaldisc` symbol in the
  tertiary label colour. The only gradient in the app.
- **Game Black** (`game-black`): behind the game's picture, under every theme.
- Text uses the system label hierarchy: primary for titles, secondary for
  supporting lines and key-hint actions, tertiary for counts and section labels.
  Hairlines are the system separator.

### Named Rules
**The Covers Bring the Colour Rule.** The chrome is monochrome. Cover art and the
player's accent are the only colour on a library screen.

**The Accent Means Click Rule.** The accent appears only where a click acts: a
selection, the default button, a control's value. Never as a fill for decoration
or a section colour.

## Typography

**Display Font:** none; there is no display face.
**Body Font:** SF Pro (the system font, through SwiftUI text styles and
`.system(size:)`)
**Label/Mono Font:** SF Pro with monospaced digits for counts, clocks, speeds and
scales.

**Character:** the Mac's own voice at the Mac's own sizes. Hierarchy comes from
weight and label colour, not from size jumps.

### Hierarchy
- **Headline** (600, 15px): a game's title in the pause menu header and the
  resume sheet, scrolled by a marquee when it overflows.
- **Title** (600, 13px, the macOS `headline` style): the library panel's tab
  name, a confirm card's title, onboarding steps.
- **Body** (400, 13px): pause menu rows, list rows, save state names (500 there).
- **Callout** (400, 12px): cover titles under the grid (500), confirm messages,
  counts, status banners.
- **Label** (600, 11px): section headers in the pause menu and save states
  panel, in secondary or tertiary label colour.
- **Caption** (400, 10px): a cover's second line, key hints, timestamps.

Larger styles appear only on first-run and empty states (`title2`, `title3`).

### Named Rules
**The Weight, Not Size Rule.** Separate levels with weight and label colour first.
A new screen does not introduce a size outside the macOS text styles.

**The Digits Hold Still Rule.** Any number that changes while visible (a count,
a play clock, a speed, a scale) uses monospaced digits.

## Layout

The library is a single inset panel 10px from the window's edges, with a header
row (tab symbol, tab name, count, order controls) and an adaptive grid of
covers: 132px default tiles (100px minimum, stretching up to 1.36x), 20px
between columns, 22px between rows, 18px around the grid. A quiet line of key
hints runs under the panel. Density follows Finder.

The game window is the picture edge to edge. The HUD is a glass bar along the
bottom (16px horizontal inset, 32 by 30px icon buttons, 6px apart, a divider
between playback and view controls). The pause menu is a 300px sidebar flush to
the window's leading edge, clearing the traffic lights by 52px windowed and 24px
in full screen, with 34px rows, an 18px icon column and a 9px gap to the title.
It turns compact under a 640px window height. The save states panel is a 340px
popover anchored to its button.

Modal cards pad their content by 20px.

### Named Rules
**The Hints Are Never Buttons Rule.** Nothing that must be clicked sits at a
bottom edge; the key hints there only restate actions reachable elsewhere.

## Elevation & Depth

Inset down, glass up. The window's own material is the ground. Content (the
cover grid, a resume list, a sheet's button strip) sinks into an inset fill,
edged by the system separator hairline. Anything that floats over content or
over the game takes Liquid Glass and, for a modal card, a soft shadow. The pause
menu is the one floating surface that is a plain `regularMaterial` blur instead:
glass rims its whole shape, and on a rectangle flush to the window the rim reads
as a box. Covers carry their own small shadow because they are objects, not
surfaces.

### Shadow Vocabulary
- **Case shadow** (SwiftUI `black 35%, radius 6, y 3`): every cover, flat or
  cut-out, on the art only, never on its selection highlight.
- **Thumbnail shadow** (`black 35%, radius 4, y 2`): the cover in the pause
  menu header.
- **Card lift** (`black 30%, radius 30, y 12`): modal cards over a dialog or the
  window.

### Named Rules
**The No Glass on Content Rule.** Liquid Glass belongs to controls and to cards
floating over content: the HUD bar, the volume pill, the library's floating
status capsule, dialogs. The library panel, lists and grids never take glass.

**The One Glass Pass Rule.** The HUD bar is one glass shape, the speed tab drawn
as part of its outline, because each glass effect is a pass over the 60 fps
picture. The volume pill is the single deliberate second glass, and exists only
while open.

## Shapes

Continuous rounded rectangles on one ladder, picked by the shape's size so that
nested shapes stay roughly concentric: thumbnail (5px), row (8px), tile (10px),
panel (12px), alert (18px), dialog (22px). Controls that float are capsules: the
HUD bar's ends, the volume pill, icon-button press states, prominent buttons. A
cover is square (a jewel case front is 1:1). A cut-out 3D case is drawn as its
own silhouette and never clipped or outlined as a square.

## Components

### Buttons
- **System first:** `.borderedProminent`, `.bordered` and `.glassProminent` carry
  the default and secondary actions; there is no custom primary button.
- **HUD icon button:** an SF Symbol at 15px medium (17px for play/pause) in a
  32 by 30px seat, no background at rest, a black 35% circle while pressed. A
  symbol change animates with a replace transition (snappy, 0.25s).
- **Hover capsule:** a soft capsule behind a control while the pointer is over
  it, for the few custom controls that need hover feedback.

### Cards / Containers
- **Library panel:** inset fill, 12px corners, separator hairline, clipped to its
  shape.
- **Modal card** (resume sheet, exit prompt): glass tinted toward the window
  background, 22px corners, card-lift shadow, content clipped to the same shape
  so an inset footer meets the corners exactly. No hairline: the glass draws its
  own rim.
- **Confirm card:** the same surface at 18px, laid over a dialog; title, a
  secondary message, then buttons, the default one ringed in the accent.

### Lists and Rows
- **Pause menu row:** 34px, 8px corners, highlighted by a soft primary-colour
  tint (9%), never a solid accent fill, because most rows carry a control. Pointer,
  arrows and controller move the same highlight.
- **Save state row:** a 56 by 42px thumbnail, a medium-weight name and a caption
  line; the selected slot takes the system's selection colours
  (`selectedContentBackgroundColor` under `alternateSelectedControlTextColor`),
  which stay readable under every accent.

### Game Tile (signature)
A square cover with 10px corners, a 1px hairline at primary 8%, the case shadow,
and two lines of caption flush with its leading edge. Selected, the hairline
becomes a 3px accent outline. A cut-out case is selected with a soft accent
highlight (25%) behind its square, 6px larger, as Finder selects an icon. With
no art: the empty case gradient and a thin disc symbol. Single click selects,
double click plays, the context menu holds cover actions.

### HUD Bar (signature)
One glass capsule along the bottom of the game: play/pause, save states,
screenshot, a divider, speed, full screen, volume, menu. The speed button grows a
tab out of the bar's own outline; the volume slider slides out as a second
capsule from under the speaker icon, which is drawn once above both. It fades
in and out (0.25s) with the pointer.

### Key Hints
A single caption line: each key in semibold secondary, its action in secondary,
separated by a tertiary middle dot. Hints only.

## Do's and Don'ts

### Do:
- **Do** reach for the stock SwiftUI control first; style a custom one only where
  the system has none, and make it look like it could be stock.
- **Do** take corner radii from `Design.Radius` (5 / 8 / 10 / 12 / 18 / 22);
  never introduce a new one inline.
- **Do** sink content into `InsetFill` with a separator hairline, and float
  overlays on glass or blur.
- **Do** use the system label colours for hierarchy, and secondary rather than
  tertiary for small text on dark glass, to hold 4.5:1.
- **Do** keep motion short and snappy (0.2-0.3s springs, ease-in-out fades);
  nothing bounces.
- **Do** match Apple's own apps material for material when copying a control
  (Music's paging arrow is a flat grey pill, not glass).

### Don't:
- **Don't** put Liquid Glass on the library panel, a list or a grid.
- **Don't** add gradient or animated backdrops, or a pure-black library theme;
  both were built and removed.
- **Don't** hard-code a brand accent; the accent is the player's macOS accent
  until a brand tint is decided.
- **Don't** scale a cover on hover or invent paging, hover or selection
  interactions Apple's apps do not use.
- **Don't** fill a highlighted row with solid accent; use the soft tint.
