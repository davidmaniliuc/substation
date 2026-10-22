# Engine into Zig: measurements

This file collects every number Plan C takes, one section per task, so the
switch can be judged against figures taken the same way.

## Renderer benchmark (Task 2)

The Zig Metal renderer (`ps1-metal/`) against the Swift one
(`MetalRasterizer.swift`), replaying the same `.p1fx` fixtures through the same
synchronous-then-pipelined passes.

Machine: Apple M1, macOS 27.0.1.

Builds: `zig build -Doptimize=ReleaseFast` (installs `zig-out/bin/ps1-bench-gpu`)
and `zig build macos -Doptimize=ReleaseFast` (the Release app, which runs
`GpuBench`).

Commands, run from the repo root, alternating Swift then Zig for five rounds
after the machine had settled (nothing heavy ran beforehand or during):

    PS1_GPU_BENCH=crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 PS1_GPU_BENCH_SCALES=1,4,6,8 zig-out/Substation.app/Contents/MacOS/Substation
    zig-out/bin/ps1-bench-gpu crash-bandicoot-warped,silent-hill-usa,tr1-usa-v1-1 --scales=1,4,6,8 --dither=true-color --filter=nearest --sprite-filter=nearest

Settings pinned to the app's shipped defaults on both sides: dither true
colour, texture filter nearest, sprite filter nearest. For Swift that was
`defaults write dev.substation.app ditherMode -int 3`, `textureFilter -int 0`
and `spriteTextureFilter -int 0`; the player's own values (3, 1, 1) were
written back afterwards.

Both sides time the same things. Each process already takes the best of five
repeats per row by GPU ms; the table takes the best of the five processes on
top of that. GPU ms is the summed command-buffer GPUEndTime minus GPUStartTime
of a synchronous pass, CPU ms is the encode time only (the wait is stopped
before), fps is wall clock over a pipelined pass.

| fixture | scale | Swift gpu | Zig gpu | gpu ratio | Swift cpu | Zig cpu | cpu ratio | Swift fps | Zig fps | GPU | CPU |
|---|---|---|---|---|---|---|---|---|---|---|---|
| crash-bandicoot-warped | 1x | 0.63 | 0.47 | 0.746 | 0.390 | 0.170 | 0.436 | 1671.1 | 2034.6 | pass | pass |
| crash-bandicoot-warped | 4x | 3.21 | 3.12 | 0.972 | 1.150 | 0.250 | 0.217 | 317.1 | 306.1 | pass | pass |
| crash-bandicoot-warped | 6x | 6.42 | 6.46 | 1.006 | 1.670 | 0.250 | 0.150 | 152.7 | 147.5 | pass | pass |
| crash-bandicoot-warped | 8x | 10.83 | 10.92 | 1.008 | 1.480 | 0.250 | 0.169 | 90.5 | 89.3 | pass | pass |
| silent-hill-usa | 1x | 1.24 | 0.70 | 0.565 | 0.700 | 0.140 | 0.200 | 1504.0 | 1504.4 | pass | pass |
| silent-hill-usa | 4x | 3.89 | 3.84 | 0.987 | 1.020 | 0.140 | 0.137 | 236.6 | 253.0 | pass | pass |
| silent-hill-usa | 6x | 7.92 | 8.00 | 1.010 | 1.620 | 0.210 | 0.130 | 123.8 | 121.7 | pass | pass |
| silent-hill-usa | 8x | 13.14 | 13.22 | 1.006 | 1.650 | 0.230 | 0.139 | 72.7 | 73.9 | pass | pass |
| tr1-usa-v1-1 | 1x | 0.09 | 0.10 | 1.111 | 0.040 | 0.010 | 0.250 | 6010.0 | 5628.4 | FAIL | pass |
| tr1-usa-v1-1 | 4x | 0.52 | 0.51 | 0.981 | 0.160 | 0.030 | 0.188 | 1757.9 | 1897.3 | pass | pass |
| tr1-usa-v1-1 | 6x | 1.13 | 1.11 | 0.982 | 0.150 | 0.030 | 0.200 | 866.1 | 884.6 | pass | pass |
| tr1-usa-v1-1 | 8x | 1.95 | 1.95 | 1.000 | 0.200 | 0.020 | 0.100 | 498.1 | 493.6 | pass | pass |

Ratios are Zig over Swift. Bounds: GPU ms within 5% of Swift's (same shaders),
CPU ms at most Swift's times 1.03. The 3% on CPU is run-to-run noise.

Verdict: 11 of 12 rows pass the GPU bound and all 12 pass the CPU bound. The
one GPU miss is tr1 at 1x, 0.10 ms against 0.09 ms: the benchmark prints two
decimals, so that is a 0.01 ms difference at the resolution of the output, on
a frame that costs a tenth of a millisecond, and its fps rows (5628 against
6010) are the same gap. It is reported, not fixed. The 1x rows of Crash and
Silent Hill are faster on the Zig side by a wide margin (GPU 0.75 and 0.57 of
Swift's), and the CPU encode cost is 0.10 to 0.44 of Swift's everywhere.

Raw outputs of all ten runs are kept outside the repo.

## Baseline (Swift path)

The app before the switch, so the session path in Task 7 is judged against
the same game, the same machine and the same readings. Release build
(`zig build macos -Doptimize=ReleaseFast`), Spyro.

| reading | value |
|---|---|
| fast-forward fps, 1x internal resolution | 237 |
| fast-forward fps, 4x internal resolution | 144 |
| fast-forward fps, 6x internal resolution | 82 |
| process CPU %, 1x, normal speed, 30 s of play | 57.2 (range 53.1 to 61.9) |

The CPU figure is the average of the last 30 samples of
`top -pid $(pgrep -x Substation) -l 31 -s 1 -stats cpu`.

Fast-forward was the 4x speed setting, so the 1x reading of 237 sits at that
setting's 240 fps ceiling: it shows the cap is reached, not what the Swift path
could do uncapped. The 1x reading was taken during the opening dragon scene and
the 4x and 6x readings in the Artisans hub; Task 7 reads each at the same place.

## Hand checks (session path)

The app after the switch (30c0649), Release build
(`zig build macos -Doptimize=ReleaseFast`). Each line is pass or fail, with a
note for anything that looks different from the Swift path.

Signed off by the user on 2026-10-22 with no results reported line by line, so
the cells below are blank: no check here has a recorded outcome. The tables
stay as the list to run on the session path, which from Task 8 on is the only
path.

| check | result |
|---|---|
| Crash: picture, sound and input | |
| Silent Hill: 24-bit FMV and fog | |
| FF7's menu (the lost-upload repair) | |
| FF8's movie uploads | |
| Runahead on and off | |
| Rewind held to the end of the history | |
| A scale change and a depth-buffer toggle mid-game | |
| A disc swap | |
| Save, load and reset | |
| The window hidden and shown again | |
| A live resize (watch for a stretched frame; the remedy is the spec's `IOSurface` follow-up) | |
| A move to a 120 Hz screen | |
| Screenshots at 1x and 4x | |
| The resume thumbnail | |
| Quitting during a card write | |
| One `PS1_LIVE_DIFF=1` run at `.native`: the checked/skipped tally | |
| Library and own-window launches back to back, and a fullscreen toggle | |

## Performance (session path)

Spyro, the same build, read at the same places and the same way as the
baseline. Not read: the sign-off above covers this table too.

| reading | baseline | session | bound | result |
|---|---|---|---|---|
| fast-forward fps, 1x internal resolution | 237 | | holds the 240 fps cap | |
| fast-forward fps, 4x internal resolution | 144 | | at least 144 | |
| fast-forward fps, 6x internal resolution | 82 | | at least 82 | |
| process CPU %, 1x, normal speed, 30 s of play | 57.2 | | at most 57.2 | |

The 4x speed setting is the fastest the app offers, so at 1x internal
resolution both paths reach its 240 fps ceiling and the reading can only show
the cap is held, not which path is faster.
