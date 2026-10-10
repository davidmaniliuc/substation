# In-game HUD: design (2026-10-10)

Builds the HUD settled in `../handoffs/2026-10-10-ingame-hud-redesign.md`
(every look-and-feel decision, with dates) into the macOS app. The brief is
`../handoffs/2026-10-10-ingame-hud-implementation.md`; the mockup is
`ps1-macos/HudPrototype/` (reference for LOOK and INTERACTION only).

## Decisions taken for this spec

| # | Question | Answer |
| --- | --- | --- |
| 1 | Title vs traffic lights | The title starts right of the green button in a window; at the leading inset in fullscreen, where there are no traffic lights. |
| 2 | Controller button for the pause menu | **Home.** It no longer toggles Analog; that moves to Quick Settings (the keyboard binding and Machine ▸ Toggle Analog stay). |
| 3 | Game info | Its own **Game Info ›** page. Quick Settings stays adjustable rows only. |
| 4 | Pause menu's Save/Load rows | They open the **same** Save States panel the bar opens, so mouse and controller share one surface. The panel is D-pad and keyboard navigable. |
| 5 | Screenshot destination | A PNG in `~/Pictures/Substation/`, named `<Title> <yyyy-MM-dd> at <HH.mm.ss>.png`. The notice is clickable and reveals the file in Finder. |
| 6 | Screenshot content | What is on screen: the picture at the current internal resolution, true colour and filtering included, no letterbox. Output height = displayed lines × scale, width = height × 4/3 (the shape the player sees). |
| 7 | "Playing for" | ACTIVE play this session, by `PlayClock`'s rules (running, unpaused, app active, uptime clock). |

## Surfaces

`GameScreen` stays the one composition, shared by the library window and the
game's own window. Top to bottom in its `ZStack`:

1. The picture (`MetalDisplayView`), tap hides the HUD (unchanged).
2. **`TitleStrip`**: a dark top gradient, no glass. Line 1 the title; line 2
   `60 FPS · Playing for 42 min` (`Paused` in place of the FPS while paused).
   In fullscreen the right side shows `23:14` and the battery (`battery.75percent`
   + `64%`), battery omitted on a Mac without one. Fades with the HUD.
3. **`GameHUD`** (bottom): `⏸ · Save States · Screenshot │ Speed · Full Screen · 🔊 · …`.
4. **`BadgeStack`** (top-trailing): speed (>1×), rewind, card saving,
   Paused (only while the HUD is hidden and no menu is open), the notice.
   Drops below the title strip while the strip shows in fullscreen.
5. **`PauseMenu`** (leading-edge glass panel over a 40% black scrim).
6. The exit dialog (unchanged).

Reset and Eject leave the bar. They remain in the Machine menu (⌘R, ⌘E) and
appear in the pause menu as Reset and Quit Game.

### The bar

- One glass shape, `BarShape` (capsule + speed tab, concave fillets, 14 pt top
  corners, the invisible 0.01 pt speck at the tab's full rise so the material
  never thickens). The glass view is `allowsHitTesting(false)` because it is
  always full height.
- **Perf rule kept by construction**: the bar is ONE glass effect, so it is
  one pass with or without a `GlassEffectContainer`. The volume pill stays the
  one deliberate second glass, laid over the bar (unchanged behaviour).
- Buttons are 32×30 with the soft hover capsule (`HoverStyle`). The speaker's
  seat is 32 wide in both the bar and the pill; `pillInset + pillPadding ==
  barInset` still registers it.
- The menu button (`ellipsis`) is rightmost; the pill anchors on the speaker
  and stops short of it.
- Full Screen's icon reflects the window's state.
- **Speed** is `SpeedButton` exactly as the mockup has it (pop-up-button
  interaction: press-slide-release picks; a click opens and a second click
  picks; clicking the value again closes; a drag released on nothing closes;
  strays beyond 40 pt close, never mid-press). It sets `model.speed` (the
  persisted base). Holding Tab is still shown only by the badge.

### Save States panel

A `.popover` (its own window, so it may leave the game window) holding the
Resume tile in the left column under the title "Save States", a divider, then
slots 1-6 in a 3×2 grid, each tile a thumbnail + title + saved time
(`StateSource.savedAt`). Picking a tile opens a sheet inside the popover:
Load (default) + Overwrite for a full slot, Save Here for an empty one,
Cancel; Resume is load-only. Nothing writes on one click.

It is opened from the bar's button or from the pause menu's Save State /
Load State rows (anchored to the row). The row sets the sheet's DEFAULT
button: from Save State, Overwrite/Save Here; from Load State and the bar,
Load. Empty slots under Load State are still selectable, to save into.

Keyboard/pad: arrows/D-pad move between the seven tiles; Return/✕ picks;
in the sheet, left/right move between the buttons, Return/✕ confirms,
Esc/○ cancels; Esc/○ on the grid closes the panel. Navigation state is a
value type (`SaveStatesNavigation`) so the rules are unit-tested.

The thumbnails come from `SaveStateStore` (the PNG beside each state).

### Pause menu

Opened by the bar's `…` button, Esc, or the controller's Home. Root rows:

`Resume · Save State › · Load State › · Change Disc › · Quick Settings › ·
Game Info › · Reset · Quit Game` (red), dividers after Resume and before Reset.

- **Change Disc** is a flyout beside its row listing `currentDiscs`
  (`circle.circle`, `.fill` for the inserted one); greyed and skipped by the
  arrows for a single-disc game. Picking calls `changeDisc(to:)`.
- **Quick Settings** page: stepper rows `‹ value ›`, never cycling: Speed
  (1-4×), Resolution (1-8×), PGXP (Off/On), Analog (Off/On), Volume (0-100%,
  steps of 10). Analog shows the pad's mode; a change queues the pad's Analog
  press, which the pad acts on when the game resumes (the existing "Analog
  on/off" notice confirms it).
- **Game Info** page, read-only: Serial, Region, Disc (`n of m`), Time Played
  (`PlayStatsStore`), Last Played, BIOS (the model name of the BIOS
  `findBIOS` chose), Image (CUE/BIN, CHD, BIN), plus "PPF patch" and
  "LibCrypt (.sbi)" rows only when present.
- **Reset** resets and closes the menu. **Quit Game** closes the menu and calls
  `eject()` (the exit sheet follows as today).

Keyboard/pad: up/down move (skipping disabled rows), right/Return/✕ enter a
page or adjust a stepper up, left adjusts down or goes back, Esc/○ backs out
one level and closes at the root, Home closes from anywhere. The footer shows
the hints. Navigation is a value type (`PauseMenuNavigation`), unit-tested.

### Pausing and visibility

`HudSurfaces` (a value type on the model) records which of the speed tab, the
Save States panel and the pause menu are open.

- The menu and the panel PAUSE the game when the first of them opens and, when
  the last closes, restore the pause state from before (a game paused by the
  player stays paused). The speed tab does not pause.
- Any open surface holds the HUD up: `showHUDThenHide` does not schedule the
  hide while one is open, and closing the last one restarts the idle timer.
  `hideHUDNow` (a click on the picture) closes the speed tab first.
- Ejecting, a disc swap, and an exit prompt close every surface.

### Input routing

- **Keyboard.** While the pause menu or the panel is open, the key monitor
  sends arrow keys, Return, Esc and Space to the surface and NOTHING to the pad;
  held pad keys are released when a surface opens. Esc while playing with no
  surface and no dialog opens the menu. The panel is a popover window, so
  while a surface is open the routing ignores which window the key came from
  (except the Settings window, which keeps its own keys).
- **Controller.** While a surface is open, `applyPadInput` turns D-pad and
  left-stick EDGES (press, not hold; stick threshold 0.5) plus ✕ and ○ into
  surface moves, and sends a released pad to the core. Home toggles the menu
  (closes the panel first if it is up).
- Tab (fast-forward) and the rewind key are ignored while a surface is open.

### Notices

`notice` becomes a `Notice` value: `icon`, `text`, optional `reveal: URL`.
Every caller passes an icon:

| Notice | Icon |
| --- | --- |
| Analog on / off | `gamecontroller.fill` |
| Saved to Slot n | `square.and.arrow.down.fill` |
| Loaded … | `clock.arrow.circlepath` |
| Load undone | `arrow.uturn.backward` |
| Any refusal or failure | `exclamationmark.triangle.fill` |
| Disc n inserted | `circle.circle` |
| Screenshot saved | `camera.fill` (clickable: reveals in Finder) |
| Auto-saved | `clock.badge.checkmark.fill` |

A notice with `reveal` is the one badge that takes a click; the rest of the
stack keeps `allowsHitTesting(false)`. Notices last 2 s.

**Auto-save is no longer silent**: a successful timed auto-save posts
"Auto-saved". A failure is still only logged. The `ps1-macos-app` skill's
"It is silent" line changes with it.

### Screenshot

`EmulatorViewModel.takeScreenshot()` asks the display view for its next
frame through the runner (the display view is keyed on the runner, so a
request on the runner is the one route that reaches the coordinator on
screen). The coordinator, after encoding the frame it presents, encodes the
same display pass into an offscreen `bgra8Unorm` texture of the size in
decision 6 with the letterbox at (1, 1), and on completion reads it back,
builds a PNG with `CGImage`/`ImageIO` (sRGB), and hands it to the model on the
main actor. The model writes it to `~/Pictures/Substation/` (created on
demand) and posts the notice; a write failure posts the failure notice. A
display that is disabled (`enabled == 0`) yields a black image of 640×480,
not an error.

### Title strip details

- Left inset: 78 pt in a window (clears the traffic lights, which sit in the
  same top band and fade with the HUD), 20 pt in fullscreen. First line's
  baseline sits level with the traffic lights' centre.
- Fullscreen is read from the hosting window through its four transition
  notifications (`FullScreenReader`, same filtering as `WindowConfigurator`'s
  probe), not from `styleMask`.
- Battery: `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType`;
  `nil` when there is no internal battery. Clock and battery refresh every
  30 s via `TimelineView`; "Playing for" refreshes on the same tick.
- "Playing for": `PlayClock` gains `elapsed(at:)` (the current stretch), and
  the model keeps `sessionPlayed`, the sum banked since this game loaded
  (reset on load/eject; a disc swap keeps it). Format: `42 min`, `1 h 05 min`;
  under a minute reads `0 min`.

## Out of scope

The library, Settings, the Machine menu's contents (apart from labels that
must change), the core and the C ABI. No new persisted setting.

## Testing

Unit (swift-testing, no window): `PauseMenuNavigation`,
`SaveStatesNavigation`, `HudSurfaces` (pause restore, HUD hold),
`SpeedButton`'s pick rule extracted as `SpeedPick` (index-at-point and the
click/drag outcomes), `PlayClock.elapsed`, the "Playing for" formatter,
the screenshot size rule and filename, input routing on the model (keys and
pad edges reach the menu and not the core while open; Home opens/closes),
notices carry icons, auto-save posts its notice. Existing
`HudVisibilityTests` stay green.

On screen (measured, as in the design phase): every surface by screenshot
against the mockup; the bar's glass does not thicken when the speed tab
opens; the speaker does not move when the pill opens; a popover survives the
HUD's idle timer; a screenshot file's pixel size and that it is not black.
