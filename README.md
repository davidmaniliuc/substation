The goal of this project is to make a thin and very portable emulator core in zig.

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
