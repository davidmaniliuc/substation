# test-roms

PS1 hardware-conformance and regression ROM suites consumed by
`ps1-core/tests/rom_test.zig` (run via `zig build rom-test`).

## Suites

### `jaczekanski/`
[JaCzekanski/ps1-tests](https://github.com/JaCzekanski/ps1-tests) — hardware
conformance tests that print to TTY. Verified by comparing captured TTY output
against each test's golden `psx.log`. See `jaczekanski/README.md` for the test
catalog.

### `peterlemon/`
Curated demos from [PeterLemon/PSX](https://github.com/PeterLemon/PSX). These
are graphical (no `psx.log`), so they are verified by comparing our rendered
320×224 display region against the demo's upstream **reference image**
(`reference.png`, pre-converted to raw `reference.rgb`). The comparison is
tolerant — our software rasterizer diverges from hardware by design — so each
test counts matching pixels (in 5-bit RGB space) and passes when the count meets
a committed per-ROM floor in `floor.txt` (run with `PS1_UPDATE_GOLDENS=1` to
(re)pin floors to the current value). The reference PNG is the gold standard; the
floor is a regression guard and a visible record of the current conformance gap.
