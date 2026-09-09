---
name: ps1-macos-app
description: Use when working in ps1-macos/ - the SwiftUI app, PS1.xcodeproj, Swift tests, cover art, BIOS/disc identity, the window/fullscreen/aspect lock, the HUD and volume control, memory cards, Application Support stores, or the Metal display view. Covers why the Xcode project is shaped the way it is and the traps that crash or wedge the app.
---

# The macOS app

## The macOS app

`ps1-capi` is a flat C ABI over the core (`ps1-capi/include/ps1.h` is the
reviewable contract; a rename in Zig cannot silently break it because the header
is hand-written). `ps1-macos` is an **Xcode project** that links the resulting
`libps1core.a`, runs the emulator on its own thread **paced by the audio
device's clock**, and hands frames to a Metal view through a triple buffer. The
software rasterizer is untouched — this is the display path only.

Build it with `zig build macos`; run the Swift tests with `ps1-macos/test.sh`.
Both are thin wrappers over `xcodebuild`, and both need **full Xcode** — see
below.

The app has three stages — `.onboarding`, `.library`, `.playing`. Onboarding
captures a BIOS folder and a games folder as security-scoped bookmarks
(`ScopedBookmark`); the library is the home screen, and `eject()` returns to
it. `GameScanner`'s rule is per-DIRECTORY: every `.cue` is a game, and a
`.bin` counts only when its own directory holds no `.cue`, so the usual
cue+bin pair is one tile rather than two. **Every entry is IDENTIFIED as it is
scanned** (`DiscIdentity.identify(disc:)`, mapped not read — see
the `ps1-cdrom-disc` skill),
which is what gives covers a key that survives a rename. Covers are
user-supplied only — a PS1 disc carries no artwork — and are copied into
Application Support keyed **by the disc's SERIAL**, falling back to the old
SHA-256 of the path for a disc that identifies nothing. A cover stored under
the old key is ADOPTED onto the serial the first time a tile asks for it,
rather than by a migration pass: an entry never displayed is never migrated.
Two consequences worth knowing — two rips of one game now SHARE a cover (they
stay two tiles, and one piece of art for one game is the better answer), and
the discs of a multi-disc game keep separate covers, since a serial is per
disc. The `NSEvent` key monitor is gated on `.playing`: the arrow keys are the
D-pad, and outside a game they must reach the grid instead.

**Covers can be DOWNLOADED, and the disc's serial is the whole reason that
works.** `CoverDownloader` fetches from a URL template carrying `${serial}`
(`CoverSource`, persisted by `CoverSourceSetting`), which is the shape
DuckStation's own cover downloader uses; the two presets point at
`covers/default/${serial}.jpg` and `covers/3d/${serial}.png`. Because the
collection is keyed on serials and `DiscIdentity` reads the serial off the
disc, a rip named `disc1.cue` finds its cover and a rip named after the wrong
game does not find the wrong one — no title matching anywhere. Five rules
matter. The default source is a **FORK** of `xlenore/psx-covers` rather than
the upstream repo, because a fork cannot be renamed or retired out from under
the library and missing covers can be added to it directly. **A 404 is
`missing`, not `failed`** — the collection covers roughly two thirds of the
PS1 library, so treating an absent cover as an error would make every sweep
report alarming numbers; only a throwing fetch is a failure, and the summary
is a count in the grid rather than an alert per disc. Fetches run **four at a
time**: a 200-disc library opening a socket per game gets rate limiting back
instead of covers. The fetch is off the main actor and returns bytes;
**`CoverStore` and `coverRevision` are touched only back on it**, which is why
`CoverDownloader` knows nothing about where a cover lives on disk. And
**Library ▸ Cover Art ▸ Download Missing Covers skips discs that already have
one** so a hand-picked cover is never overwritten, while the tile's own
Download Cover replaces — the request there is explicit. A sweep also runs
**automatically after every scan** (`GameLibrary.didFinishScan`, switchable by
Cover Art ▸ Download Automatically, default on); `CoverSweepPolicy` holds the
selection rule, and its session-only `attempted` set is what stops a ⇧⌘R
re-asking for the same few dozen misses every time — session-only rather than
persisted, so a relaunch still picks up covers added to the collection since.
The automatic sweep reports nothing unless it fails: a status line about work
the player never requested is noise.

**Some scans in the collection carry a white margin, and it is trimmed on
import** (`CoverTrim`). `SCES-00344` carries one on its top, bottom and
right (7/6/6 pixels), `SCES-00967` on all three too (5/8/8) and `SLES-00132`
three rows along its bottom, while Croc has none — so against the dark grid it
read as a bright hairline on some tiles and not others.

**The rule is UNIFORMITY, not whiteness, and getting there took two wrong
rules, both of which passed their own verification.** Requiring every pixel in
a row to be white trims NOTHING on these covers: a margin row is 97-100% white
and never 100%, because a few pixels carry JPEG ringing off the artwork beside
them. Loosening that to a 97% fraction still leaves a residual row per edge at
86-94%, and the fraction cannot go lower, because the four Final Fantasy IX
covers are genuinely pale at the top and their ARTWORK is 82-87% white — the
ranges overlap and no threshold on that axis separates them. What does
separate them is how flat the row is: margins measure mean 240-248 with a
standard deviation of **5-9**, FF9's pale artwork mean 222 with a deviation of
**62-65**, and nothing observed lands in between, so `meanFloor` 235 and
`deviationCeiling` 25 sit in a wide empty gap rather than on a knife-edge.

**Verify a trim by measuring the STORED file, never by re-running the trim
rule over it.** Both wrong rules reported "0 margin remaining" when asked
their own question back, while the border was plainly on screen; an
independent probe printing each edge ring's white percentage is what caught
them. A single-COLUMN probe is not independent enough either — it reported
these same files as bordered across the top, which is not where their margins
are. The old threshold note (`whiteFloor` 236, between 247,252,240 and
212,216,211) described a rule that is gone; a row counts as margin only if EVERY pixel in it
qualifies, and at most a tenth of a side comes off, so a pale cover loses a
margin at worst and never its artwork. Trimming happens before the downscale,
or the margin would be resampled into a soft edge instead of removed. The tests inject a
fake fetcher: a test that reached GitHub would pass or fail on the connection,
and would pass silently when offline in the one way that matters, by
downloading nothing and calling it a clean sweep. Note the app is **not
sandboxed** (there is no entitlements file and no `ENABLE_APP_SANDBOX` in the
project), so no network entitlement was needed for any of this.

**The BIOS a disc gets is the DISC's answer, not its filename's**
(`BiosRegion.forDisc(_:named:)`). The filename rule — `(europe)`/`(japan)`,
else US — is `ps1-golden`'s, verbatim, and it is a guess that was wrong for a
real disc in this library: `Final Fantasy IX (France)` carries no `(Europe)`
token, drew a US BIOS, and stopped at the region-lock screen. It remains the
fallback for a disc that names no region. `load(disc:)` identifies the bytes it
has already loaded rather than mapping the file a second time.

**And which FILE is that BIOS is answered by its sha256, not by its name
either** (`BiosIdentity`, since 2026-09-09). `findBIOS` makes two passes over
the BIOS folder: pass 1 identifies every 512 KB file by content and takes the
one whose MODEL is the region's, so a rename cannot hide it and a folder whose
images have been swapped still yields the right one; pass 2 is the old
`hasPrefix("scph-1001")` stem match, kept because the table is curated, with one
addition — a file the table identifies as ANOTHER region is passed over, since
its name is known to be lying and honouring it costs a boot to the region-lock
screen. Pass 1 matches the model rather than merely the region on purpose: a
folder holding only `SCPH-101` still yields nothing for a US disc, because that
is the model Crash Bandicoot fails on under every BIOS and selecting it silently
would read as a core regression. Four rules are worth keeping.
**An unidentified image is never REJECTED** — the table knows the images someone
put in it and nothing else, so a hash cannot tell a corrupt file from a valid
dump nobody has listed; it lets a listed image be preferred over both, and the
`data.count == 524288` check stays as the only thing standing behind an unlisted
one. **The five entries were hashed locally and then cross-checked against
DuckStation's own table** (`src/core/bios.cpp`, ~170 entries keyed on MD5) by
matching each file's MD5 to an entry there — all five matched, and one corrected
a guess: `SCPH-101_BIOS_2000_US.bin` is **v4.5 05-25-00**, not the v4.4
03-24-00 image of the same model, which is a different dump with a different
hash. Do not add a row from memory; hash the file, then find that hash in a real
source. **Extending the table needs the image itself**, since DuckStation
publishes MD5 and this table is sha256 — adding a dump nobody here has means
switching hash functions, not copying a column. And **only 512 KB files are
hashed**, screened on `.fileSizeKey` before any read, so a BIOS folder holding
something large is not read into memory to be rejected.

`DiscGrouping` folds the scanner's per-file entries into per-game tiles behind
**Library ▸ Merge Multi-Disc Games** (`MultiDiscSetting`, default ON). The rule
is keyed on the SCOPE directory as well as the disc-token-stripped title, so two
rips of one game in different corners of the library stay two games; an entry
whose name carries no `(Disc N)` token never groups. **The scope is the disc's
own folder, or its PARENT when that folder itself carries a disc token** —
because both layouts are common and both ship in `games/`: Final Fantasy IX
keeps four `.cue`s loose in one folder, while Final Fantasy VII gives each disc
its own subfolder under a parent named for the game. Keying on the disc's own
directory groups the first and never groups the second. `siblingDiscs` scans
that same scope for the same reason — scanning FF7's per-disc folder finds one
disc and leaves Change Disc with nothing to offer. Note DuckStation has no such
rule: it groups off its game database by disc serial (FF7's three discs are
SCUS-94163/94164/94165), which is why folder layout never matters to it and
does to us. With merging off every group holds exactly one
disc, which is why `LibraryView` renders groups unconditionally rather than
carrying two paths. The group's cover is its FIRST disc's, since `CoverStore`
keys on a hash of the disc path. **`MultiDiscSetting` cannot read its key with
`bool(forKey:)`** the way `PgxpSetting` does — it defaults to true, so absence
is ambiguous and is probed with `object(forKey:)`, exactly as `VolumeSetting`
does for its level. **Machine ▸ Change Disc is deliberately independent of the
toggle** and derives its list from the running disc's own directory, so it also
works for a game opened through `File ▸ Open Disc…` that was never in the
library folder.

`InternalResolution` is the app's second persisted setting, after
`ScopedBookmark`, and is shaped after it: `init` resolves from `UserDefaults`,
`set` persists, and the clamp lives in the type so it is reachable from a test
without a window.

`VolumeSetting` is the third, and the same shape — but with one trap
`InternalResolution` does not have: **a missing key must mean full volume, not
silence.** `double(forKey:)` returns 0 for an absent key and 0 is a legitimate
volume, so unlike the scale the default cannot fall out of the clamp and the
key's absence is read separately through `object(forKey:)`. **Mute is a flag
over an untouched level**, not a level of zero with the old one stashed beside
it, so unmuting restores what you had without a second field to keep in step;
moving the slider unmutes, or the control is dead with no visible reason why.
The gain reaches the audio device through `AudioOutput.setGain`, which stores a
`Float` **as its bit pattern in an `Atomic<UInt32>`** — `Synchronization` has no
`Float` conformance and the render callback may not take a lock — and it is
applied by multiplying the samples in that callback rather than through
`kHALOutputParam_Volume`, which on a default-output unit reaches toward the
device instead of staying inside our own stream. `AudioOutput` is rebuilt per
game while the setting outlives every disc, so `play()` re-applies the gain to
each new one. In the HUD the slider is a SECOND capsule laid OVER the bar from
the trailing edge, exactly as Apple Music does it: the bar keeps its width, its
layout AND its contents, and the pill covers what it physically sits over and
nothing else. Neither of the two obvious shortcuts is right — reflowing the bar
moves every control when the speaker is clicked, and hiding the bar's contents
makes the controls to the LEFT of the pill disappear for no reason the player
can see. That makes the HUD three layers — bar, pill, and the
speaker icon drawn ONCE on top of both, so the pill slides out from under it
and it is never dimmed by the glass. `pillInset + pillPadding == barInset` is
what registers the icon's seat in the two capsules to the same place; changing
one of the three without the others slides the icon as the slider opens. The
pill is also the one glass effect deliberately OUTSIDE the single
`GlassEffectContainer` — the container would merge an overlapping capsule into
the bar's shape, which is the opposite of covering it. `VolumeControlState`
holds the two-stage click rule — first click opens, every click after it mutes
— and the mouse-out rule, so both are testable without a window, the same
reason the OSD's show/hide policy lives on the model. The mouse-out has one
trap: the slider's track is 10pt inside a 36pt pill, so a drag that strays off
it is ordinary aiming and must NOT close the control mid-adjustment — the stray
is remembered and acted on when the drag ends, and `adjustingBegan` is
idempotent because `DragGesture.onChanged` fires for the movements outside the
pill too and a began that reset the flag on each would lose it. The hover is
also ONE region over the pill and the icon together: the icon sits on top of
the pill, so separate regions report the icon's exit as the pointer moves onto
the slider and close it there.

**Full Xcode 26.6 is installed** and `xcode-select` points at it, so
`swift`/`swiftc` on `PATH` are Xcode's toolchain. This was a Command Line
Tools-only machine until 2026-08-22 — if you find a note claiming Xcode is
unavailable, `@State` is unusable, or the shader compiles at runtime, it
predates that and is wrong.

Five things about the build still look odd and each is load-bearing:

- **The shaders are compiled OFFLINE and it is the one part that needs full
  Xcode.** `ps1-macos/Shaders/DisplayShader.metal` and `ps1-macos/Shaders/Rasterizer.metal`
  are both sources of record. `build.zig` drives `xcrun -sdk macosx metal` over
  each of them, then `metallib` to merge the two `.ir` files into one library, as
  real build-graph steps; `@embedFile`s the result through
  `ps1-macos/Shaders/embed.zig`, and repacks that object into
  **`libps1shaders.a`** (`zig build metallib`). Swift gets the bytes back over
  two C functions (`ps1_metallib_ptr/len`, declared in
  `Sources/CPs1/include/metallib.h`) and builds the library with
  `makeLibrary(data:)`. This is
  [how Ghostty does it](https://github.com/ghostty-org/ghostty/blob/main/src/build/MetallibStep.zig) —
  including the embed, which is what avoids bundle resources entirely: no
  `.metallib` in `Substation.app`, no copy-resources build phase, no `Bundle.main`
  lookup that can miss at runtime, and the test suite loads the exact same bytes
  the app does.
  **It is a separate library from `libps1core.a` on purpose**: `metal`/`metallib`
  ship with Xcode, not Command Line Tools, and on Xcode 16.3+ they are a further
  separate download (`xcodebuild -downloadComponent MetalToolchain`) — the
  portable emulator ABI must not inherit that requirement, so `zig build
  capi-lib` still works on a CLT-only machine. `build.zig` probes for the
  compiler at configure time (~50 ms) and swaps in an `addFail` naming both
  install steps, because xcrun's own message ("unable to find utility metal")
  says nothing about the component download.
  This replaced a runtime `makeLibrary(source:)` over a Swift string on
  2026-08-22 — **do not reintroduce it.** A shader error belongs at build time,
  not at the first frame of the first game opened.
- **`libps1core.a` is emitted as one object and repacked with `xcrun libtool`**,
  not produced by `b.addStaticLibrary`. Apple's `ld` rejects Zig's own archive
  members outright (`64-bit mach-o not 8-byte aligned`), so `-lps1core` against
  a Zig-produced `.a` does not link at all.
- **There is no `Package.swift` any more.** `ps1-macos/PS1.xcodeproj` is
  committed and hand-maintained, `objectVersion = 70`, following Ghostty (which
  also commits its project rather than generating it with XcodeGen or Tuist).
  `swift build` and `swift test` no longer work in this directory at all;
  `xcodebuild` is the only build system. Two targets: **`PS1`** (the app) and
  **`PS1Tests`** (a unit-test bundle hosted by it).
  `Sources/` and `Tests/` are **`PBXFileSystemSynchronizedRootGroup`s**, which
  is why the project file is ~340 lines and why **adding a `.swift` file needs
  no project edit** — the folder is the target's membership. Do not "fix" this
  by adding `PBXFileReference`/`PBXBuildFile` entries per file.
- **`SWIFT_INCLUDE_PATHS` is set at PROJECT level, not on the app target**, and
  that placement is load-bearing. It points at `Sources/CPs1/include` so the
  hand-written `module.modulemap` resolves `import CPs1`. The test target needs
  it too: `@testable import PS1` loads PS1's swiftmodule, which re-resolves its
  own `import CPs1`, and with the setting only on the app target the build fails
  with `unable to resolve module dependency: 'CPs1'`. `LIBRARY_SEARCH_PATHS` and
  `OTHER_LDFLAGS` stay on the *app* target, because the test bundle resolves
  those symbols through its `BUNDLE_LOADER` host instead of linking them twice.
- **The Zig archives are linked by `$(SRCROOT)`-relative build setting**
  (`LIBRARY_SEARCH_PATHS = $(SRCROOT)/../zig-out/lib`, `OTHER_LDFLAGS =
  -lps1core -lps1shaders`). The old absolute path in `build.sh` existed because a
  relative path in `Package.swift`'s `unsafeFlags` resolves against the linker's
  working directory; a build setting has no such problem.
- **`ONLY_ACTIVE_ARCH = YES` in Release too, which is not the Xcode default.**
  The Zig archives are built for the host architecture only, so a stock
  `ARCHS_STANDARD` release build would try x86_64 and fail to link. A universal
  app needs two `zig build` runs plus a lipo step; that is deliberately not done.
- **`test.sh` passes no `-quiet`, `build.sh` does.** xcodebuild's quiet mode
  suppresses the per-test result lines along with the build noise, so the suite
  would pass in silence and report a failure only through its exit status.

Do not reinstate the three CLT-era workarounds removed on 2026-08-22/23: the
`-rpath` flags for swift-testing, the `-plugin-path` for `libTestingMacros`,
and the ban on `@State`. The Xcode test runner supplies swift-testing itself,
and **`@State` compiles** — view state on the `@Observable` model is a design
choice now, not a constraint.

A few more things worth knowing before changing this code:

- **The letterbox is applied to UV, not to vertex position.** `display_vertex`
  keeps the oversized triangle at full viewport size and divides the UV by
  `scale_x/scale_y`; `display_fragment` returns black for any UV outside
  `[0,1)`. Scaling the *position* instead — which is what it did until
  2026-08-20 — shrinks the triangle around the origin, so the left and top bars
  fall outside it and get the black clear colour while the right and bottom
  bars stay inside it, land past the picture, and get painted by the
  `px >= p.width` clamp with a stretched copy of the last texel column. The
  give-away is the asymmetry: black bar on the left, smeared one on the right.
  Pinned by offscreen render tests in `DisplayRenderTests.swift`, which read the
  corner pixels back — the bug survived every compile-and-pipeline test because
  only the pixels were ever wrong.
- **The window is locked to 4:3** (`WindowConfigurator` sets
  `NSWindow.contentAspectRatio`), so in practice the picture fills it exactly
  and no bar is drawn at all; the letterbox path only runs in fullscreen on a
  non-4:3 display. `letterboxScale` therefore *snaps* to `(1, 1)` when the
  drawable is within half a pixel of 4:3 — the locked ratio lands a hair off,
  and an unsnapped 0.99999 blacks out the outermost pixel column.
  `WindowConfigurator` is also how the traffic lights fade with `GameHUD`:
  SwiftUI exposes neither the aspect ratio nor the standard window buttons, so a
  zero-sized `NSViewRepresentable` that walks up to `view.window` is the whole
  mechanism.
- **The aspect lock must come OFF for fullscreen, and ALL FOUR transition
  notifications are needed — `willEnterFullScreen` alone was wrong and it
  CRASHED the app on leaving fullscreen** (fixed 2026-09-05). AppKit honours
  `contentAspectRatio` in fullscreen by *centring* a 4:3 window on a black
  desktop instead of filling the screen — the picture is correct and the whole
  window is letterboxed, rounded corners and all. `updateNSView` does not fire
  on a fullscreen transition, and by `didEnterFullScreen` AppKit has already
  sized the window against the ratio, so clearing it then resizes nothing back.
  Snapping the window to 4:3 when the lock is first applied also has to pick a
  size that fits the *screen*: deriving height from width alone lets AppKit
  clamp the height and keep the width, leaving the window further from 4:3 than
  it started. Two further rules are load-bearing, and both were learnt the hard
  way from one report ("enter fullscreen, leave it, the screen goes black"):
  - **`styleMask` cannot tell you whether you are in fullscreen, and it lies in
    the one direction that matters.** AppKit clears `.fullScreen` from the mask
    PART WAY THROUGH the exit — measured 2.4 s into a transition that otherwise
    takes 0.6 s — while the window is still 1440x900 and still on the
    fullscreen space. `updateNSView` re-runs on every `hudVisible` flip and the
    OSD's 2.5 s idle timer lands square in that gap, so the lock was re-applied
    to a window AppKit still considered fullscreen: it snapped the frame to
    1160x870, AppKit centred that on the black desktop, and
    `didExitFullScreen` did not arrive for **37 s**. `Probe` therefore observes
    all four notifications and holds `inFullScreenTransition` from either WILL
    to its matching DID; `wantedAspect` treats a transition in flight as
    fullscreen. Disabling the lock entirely took the same transition to 0.58 s,
    which is the A/B that identified it.
  - **Clearing the lock goes through `contentResizeIncrements`; assigning
    `.zero` to `contentAspectRatio` does NOT clear it.** The two are mutually
    exclusive — setting either resets the other — and that is the only
    supported way to turn a ratio off. A `.zero` ratio leaves AppKit in ratio
    mode with a zero ratio, so the fullscreen-exit restore derives the height
    from the width as `713 * 0 / 0` and hands `-[NSWindow _reallySetFrame:]`
    a frame of `{{722, 331}, {713, nan}}`. That throws
    NSInternalInconsistencyException out of
    `-[_NSExitFullScreenTransitionController setupWindowForAfterFullScreenExit]`,
    nothing catches it, and the process **aborts** — which is what the player
    sees as the picture going black. It reads back as `.zero` either way, so
    the two forms look equivalent at every point except this one. The old code
    hid the crash by accident: re-applying 4:3 mid-exit (the bug above) gave
    AppKit a valid ratio, so the app survived and merely wedged for 37 s.
    Fixing only the first rule made it abort on the SECOND exit, every time.
    Eleven consecutive round trips now survive, each exit under 961 ms.
- **Game Mode is opted into from `Info.plist`, and it only engages in
  FULLSCREEN.** `GCSupportsGameMode` (true) and `LSApplicationCategoryType`
  (`public.app-category.games`) are both set. Neither is generated:
  `GENERATE_INFOPLIST_FILE = NO` and `ps1-macos/Info.plist` is hand-written,
  so an `INFOPLIST_KEY_*` build setting would be ignored. The keys make the
  app *eligible*; macOS decides at runtime, and it declines while the window
  is not fullscreen — which is why the aspect-lock removal above is a
  prerequisite and not merely cosmetic. **Verified end-to-end 2026-08-31**:
  fullscreen with a disc running, `gamepolicyd` logs `Found game
  GameProcess(Optional("PS1"), …, labelReason=LSSupportsGameMode
  (Info.plist))` then `Game mode enabled` / `Game mode status is now on`. Read
  it back with
  `log show --last 5m --predicate 'process == "gamepolicyd"' --style compact |
  grep -iE 'found game|game mode'`; the status flaps to `paused` every time
  the app loses focus, so ignore that unless it never reaches `on`.
  **Which of the two keys is load-bearing is NOT established** — the obvious
  differential (strip a key, re-sign, relaunch) is defeated by a per-bundle
  label cache in `gamepolicyd`, which went on reporting `Found game` with
  *both* keys deleted and after `lsregister -f`. Clearing that cache needs the
  daemon restarted, which was not attempted. Set both and do not read the
  working configuration as evidence about either key alone.
- **The OSD, the traffic lights and the CURSOR hide together, and "a mouse
  move" is defined as a change of POSITION.** A click on the picture calls
  `hideHUDNow()`, which takes all three down at once instead of waiting out the
  2.5 s idle timer; `WindowConfigurator.applyChrome` hides the pointer with
  `NSCursor.setHiddenUntilMouseMoves(true)` and has no matching unhide, because
  the system brings it back on the first movement. The subtle half is on the
  other side: `onContinuousHover` reports the pointer for a *click* as well as
  for a move, so re-showing on every callback undoes the hiding click in the
  same runloop turn and the OSD never goes down at all. `hoverMoved(to:)`
  therefore compares the point against the last one and re-shows only when it
  actually differs — which is the same rule the hidden cursor returns under, so
  the two stay in step without either driving the other. Pinned by four tests in
  `HudVisibilityTests.swift`.
- **The FPS readout counts EMULATED frames, not presented ones.**
  `EmulatorRunner` republishes `frameSeq` as the `framesProduced` atomic and the
  view model polls that total every `FpsCounter.window` (0.5 s) — a cumulative
  count rather than a rate, so the reader sets its own cadence and a missed poll
  costs accuracy rather than a frame. The number that matters is whether the
  core is keeping up with the ~59.94 a real NTSC machine runs at, which the
  display's own refresh rate cannot tell you; a paused emulator correctly reads
  0. `FpsCounter` is a value type for the same reason `InternalResolution` is
  one — the windowing rule is then reachable from a test with synthetic
  timestamps, including the case that matters: `eject()` installs a new runner
  whose count restarts at zero, and subtracting the old baseline would underflow
  `UInt64` rather than merely read wrong.
- **Keyboard input goes through an `NSEvent` monitor, not `onKeyPress`.**
  SwiftUI hands back a `KeyEquivalent` (a Character); `InputMap.button(forKey:)`
  is keyed on macOS **virtual key codes**, which are layout-independent, so the
  D-pad stays on the same physical keys on AZERTY or Dvorak.
- **`Disc` borrows its bytes.** `ps1_load_disc` does not copy the `.bin`; it
  holds a slice into the caller's buffer, so `Ps1Core` retains the `Data`
  alongside the handle. The cue is parsed immediately and is not retained.
  `ps1_load_disc` also decides `PS1_ERR_BAD_CUE`/`PS1_ERR_MULTI_FILE_CUE`
  *before* calling `initFromCue`, because `initFromCue` never fails — it falls
  back to a single data track on a cue it cannot parse.
- **The `.sbi` sidecar crosses the ABI too, and until 2026-08-31 it did not.**
  `ps1_load_disc` takes `sbi`/`sbi_len` and
  `EmulatorViewModel.sidecar(forDisc:)` supplies them from `<stem>.sbi` beside
  the disc. Without it Final Fantasy IX loaded, booted the BIOS and then sat on
  a pure black screen sweeping its LibCrypt sectors forever — while the SAME
  disc worked in the browser, whose `stageSbi` had carried the sidecar since
  the disc-boot work. That asymmetry is the tell for anything else the app
  refuses that wasm accepts: check what `index.html` stages that
  `EmulatorViewModel` does not. Three rules here are load-bearing. The bytes
  are **COPIED into the `Handle`, not borrowed** like the `.bin` — a sidecar
  is a few hundred bytes, so a second lifetime obligation on every caller buys
  nothing, and a copy is what stops one disc's sidecar surviving into the next
  (`h.sbi` is freed and replaced in the same call that swaps the disc). The
  copy happens **after every rejection**, because the function returns a code
  rather than an error, so `errdefer` would never fire and each early return
  would have to free by hand. And the sidecar is matched on the disc's **own
  stem, never "the only `.sbi` in the folder"** — FF9's four discs share a
  directory and each sidecar names sectors of its own image, so the wrong one
  is worth exactly as much as none. A file that does not start with `SBI\0` is
  refused with `PS1_ERR_BAD_SBI` rather than ignored the way `Disc.setSbi`
  ignores it: at this boundary a silently-dropped sidecar is a black screen
  with nothing to say why.
- **Both stores live under `Application Support/Substation/`, and the folder
  was `PS1/` until 2026-09-09.** The path is a hardcoded component and has
  never depended on the bundle identifier, so renaming the app did not move it
  and nothing would have found the old saves again — `AppSupport.migrate`
  renames `PS1/<component>` to `Substation/<component>` the first time a store
  resolves its directory. Two rules: a destination that already exists is the
  live data and is never merged into or written over (nothing on disk says
  which of two `card1.mcd`s is newer, and stranding one is recoverable where
  overwriting it is not), and the emptied `PS1/` shell is removed only once it
  is genuinely empty, since each store migrates its own folder and the first
  one through must leave the other's behind. Both rules are pinned by tests in
  `AppSupportTests.swift` that were verified to FAIL against a destructive move
  and against an eager `createDirectory` respectively.

- **The memory cards are ONE shared pair for the whole library, and the load
  must happen AFTER the teardown.** `MemoryCardStore` keeps
  `~/Library/Application Support/Substation/MemoryCards/card{1,2}.mcd` — raw 131072-byte
  images, the `.mcd` layout DuckStation and the PCSX line read. Shared rather
  than per-game so that a multi-disc game finds its own save on disc 2 and a
  sequel finds its predecessor's, both of which are what hardware does; the
  cost is the 15-block cap, managed through the BIOS card manager, which is
  what the second slot is for. `load(disc:)` builds every other part of the new
  machine BEFORE tearing the old one down, so that a disc which fails to load
  leaves the running game alone — the card is the one exception, because the
  teardown is what flushes the outgoing card and a read before it would load
  stale bytes and then write them back over the save. `EmulatorRunner` polls
  `ps1_take_memcard` at the TOP of its loop, above the paused and ring-full
  early-outs, so a save followed immediately by ⌘P is not parked; the write
  itself is debounced a second by `MemoryCardFlushPolicy` because a save is a
  burst of ten or so blocks. The unconditional flush is in `stop()`, called
  after it attempts to join the emulator thread — but that join has a
  one-second timeout and can fall through with the thread still mid-frame, so
  the two card methods (`serviceMemoryCards`/`flushMemoryCards`) share a
  dedicated `cardLock` rather than relying on the join to keep them from
  touching `pendingCards`/`cardScratch` at the same time. ⌘Q reaches the flush
  through a `willTerminateNotification` observer — `eject()` is not on that
  path.
- **A per-track rip is concatenated in the FRONTEND, and `REM FILESIZE` is how
  the seams survive it.** Tekken 3 (3 `FILE`s), Castlevania (2), Doom (8),
  Tekken (28) and Rayman (51) all ship one `.bin` per track, and `Disc` holds
  one slice. `EmulatorViewModel.discImage(forCue:)` reads the images in cue
  order, concatenates them, and emits a `REM FILESIZE <bytes>` line before each
  `FILE` — the only record `initFromCue` then has of where one image ended.
  This is the mechanism `ps1-wasm/www/index.html` has used since the disc-boot
  work; the app went without it until 2026-08-31 and refused all five titles
  outright. `ps1_load_disc` therefore no longer rejects a multi-`FILE` cue as
  such: it rejects one that **cannot be laid out** (`disc.cueFilesAreLaidOut`
  — a missing or sub-sector size on any `FILE` but the last), because
  `initFromCue` would otherwise stack every image at the same base LBA and
  read as a bad rip rather than a bad call. Note `ps1-golden` still skips
  multi-`FILE` cues by its own rule; relaxing that is a golden recapture and
  has not been done. `ps1-trace`'s `loadCue` is the same routine in Zig — the
  sector count the two produce for a rip must agree.
- **A cue sheet is CRLF, and in Swift `"\r\n"` is ONE `Character` that does not
  equal `"\n"`.** Every rip in `games/` is CRLF, so
  `text.split(separator: "\n")` returns the WHOLE sheet as a single line and
  the per-line parse silently never happens. It does not fail loudly: the
  single "line" still matches `FILE `, and `lastIndex(of: "\"")` then reaches
  the closing quote of the LAST `FILE` in the file. A one-`FILE` cue holds
  exactly two quotes, so it named the right image by accident and every
  single-file game loaded; a per-track rip named a path spanning half the
  sheet. Split on `\.isNewline`, which matches the grapheme cluster. Pinned by
  two tests in `DiscImageTests.swift`, both verified to FAIL against the
  scalar split.
- **`Sources/PS1` and `Sources/PS1App` are ONE module, `PS1`.** The `PS1`
  target's `fileSystemSynchronizedGroups` is the whole `Sources` root, with
  `PRODUCT_MODULE_NAME = PS1` — there is no per-subdirectory module boundary,
  `Sources/PS1App` is a directory convention, not a second target, and
  `import PS1` inside it is a self-import (a "file is part of module 'PS1';
  ignoring import" warning, not an error). `public` on the app-facing seams
  (`ContentView`, `EmulatorViewModel.isPaused`, `rescanLibrary()`,
  `internalScale`) is therefore a uniform convention across those seams, not a
  boundary requirement — nothing in `Sources/PS1App` needs `public` to reach
  them. Treating it as a real module boundary is what produced `menuRange`, a
  member invented to "cross" a boundary that does not exist; it was dead
  weight and was reverted in `4252a00`.
- **`Sources/CPs1` is a DIFFERENT thing: a headers-only Clang module, not part
  of `PS1`.** It holds no compiled sources, only
  `include/{ps1_shim.h, metallib.h, prim_instance_shim.h, module.modulemap}`,
  and that modulemap is what declares `module CPs1 { … }`. It is reached
  through `SWIFT_INCLUDE_PATHS = $(SRCROOT)/Sources/CPs1/include`
  (`PS1.xcodeproj/project.pbxproj:209,230`), and `import CPs1` is a real,
  load-bearing cross-module import used by 20 files across `Sources/` and
  `Tests/` — do not delete it as if it were the `PS1App` self-import above.
  The tell that separates the two: a genuine `import CPs1` emits no "ignoring
  import" warning, because there really is a module boundary there.

The button mask crossing the ABI is `sio.zig`'s own: **0 means pressed**, 1
released, `0xFFFF` idle. The ABI deliberately does not re-invent a button enum.
