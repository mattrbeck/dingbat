<p align="center"><img src="README/dingbat_large.png"></p>

<p align="center">A Game Boy, Game Boy Color, and Game Boy Advance emulator written in Nim.</p>

<h3 align="center"><a href="https://dingbat.gg">▶ Play it in your browser</a></h3>

<p align="center"><img width="800" src="README/GoldenSun.gif"></p>

## Highlights

**Link cable.** Trade and battle over the internet or on one machine. → [Multiplayer guide](docs/link-usage.md)

**Enhanced MP2K audio.** Music in games using Nintendo's MP2K/M4A sound engine can be
re-rendered per note, above the hardware's native mix rate. Optional.

**Cross-device sync.** Games, saves, and save states sync through Google Drive.

**Accuracy.** Scored every CI run against the mGBA suite, jsmolka's gba-tests, the AGS
aging cartridge, blargg, mooneye, mealybug, SameSuite, gambatte, GBMicrotest, AGE and the
acid2 ROMs — current tallies in [tests/results.md](tests/results.md).

**No BIOS file required.** An HLE BIOS is built in; a real dump can be supplied instead.

**Everything else.** Nine save-state slots with thumbnails, rewind, fast forward, cheats,
hq4x / xBR upscaling, per-panel LCD color correction, and a cycle-accurate Game Boy FIFO
PPU.

## Documentation

- [**Downloads**](docs/downloads.md) — prebuilt desktop binaries for Linux, macOS, Windows
- [**Features**](docs/features.md) — what both front-ends and both systems support
- [**Usage**](docs/usage.md) — loading ROMs, BIOS files, save files, GB renderer choice
- [**Multiplayer**](docs/link-usage.md) — local 2P, online room codes, native TCP
- [**Building**](docs/building.md) — native, WebAssembly, and Windows cross-builds

## Acknowledgements

The Game Boy and Game Boy Color work would not be possible without the
[Pan Docs](https://gbdev.io/pandocs), [izik's opcode table](https://izik1.github.io/gbops),
the [gbz80 opcode reference](https://rednex.github.io/rgbds/gbz80.7.html),
[The Cycle-Accurate Game Boy Docs](https://github.com/AntonioND/giibiiadvance/blob/master/docs/TCAGBD.pdf),
or gekkio's [Game Boy: Complete Technical Reference](https://gekkio.fi/files/gb-docs/gbctr.pdf).
The Game Boy Advance work would not be possible without
[GBATEK](http://problemkaputt.de/gbatek.htm), [Tonc](https://www.coranac.com/tonc),
[mGBA](https://mgba.io/), or the wonderful emudev community.

A special thanks goes out to those in the emudev community who are always helpful, both
with insightful feedback and targeted test ROMs:
[ladystarbreeze](https://github.com/ladystarbreeze),
[DenSinH](https://github.com/DenSinH),
[fleroviux](https://github.com/fleroviux),
[destoer](https://github.com/destoer),
[GhostRain0](https://github.com/GhostRain0),
[bmchtech](https://github.com/bmchtech).
