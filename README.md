The goal of this project is to make a thin and very portable emulator core in zig.

# Install (macOS, alpha)

> Substation is **alpha** software: expect crashes and missing features. It needs
> Apple silicon and macOS 26 or later, and you supply your own BIOS.

```sh
brew install --cask davidmaniliuc/tap/substation
```

Or download the DMG from [Releases](https://github.com/davidmaniliuc/substation/releases).
The app is not notarized yet, so macOS blocks the first launch: click **Open Anyway**
in System Settings ▸ Privacy & Security. Maintainers: see [docs/RELEASING.md](docs/RELEASING.md).

# Ressources

- [nocash docs](https://psx-spx.consoledev.net/memorymap)
- [pdf guide by Lionel Flandrin](https://github.com/simias/psx-guide)
- [cpp psx emulator for referance](https://github.com/JaCzekanski/Avocado)
- [test roms](https://github.com/JaCzekanski/ps1-tests)
- [other test roms](https://github.com/PeterLemon/PSX)
test roms AmiDog

# Roadmap

- [x] CPU + memory map
- [x] GTE (COP2)
- [x] DMA (7 channels)
- [x] GPU + software rasterizer
- [x] SPU + timers + interrupts
- [x] CDROM controller (CUE/TOC discs, XA-ADPCM audio)
- [x] MDEC (FMV decoding)
- [x] Booting real games from disc — Croc, Silent Hill, Spyro, Crash Bandicoot
- [x] SPU reverb
- [ ] Save states, memory-card persistence
