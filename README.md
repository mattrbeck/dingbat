<p align="center"><img src="README/dingbat_large.png"></p>

<p align="center">A Game Boy, Game Boy Color, and Game Boy Advance emulator written in Nim.</p>

<h3 align="center"><a href="https://dingbat.gg">▶ Play it in your browser</a></h3>

<p align="center"><img width="800" src="README/GoldenSun.gif"></p>

## Highlights

**Link cable.** Trade and battle with your friends, both over the internet and on the
local network. → [Multiplayer guide](docs/link-usage.md)

**Enhanced MP2K audio.** Music in games using Nintendo's MP2K/M4A sound engine is
re-rendered per note, above the hardware's native mix rate. Optional.

**Cross-device sync.** Your games, saves, and save states sync through Google Drive, so
you can put a game down on one device and pick it up on another.

**Accuracy.** 6910 of 7008 mGBA test-suite cases, all of jsmolka's gba-tests, the AGS
aging cartridge, blargg, mooneye, dmg-acid2, and cgb-acid2 all pass.

**No BIOS file required.** An HLE BIOS is built in, though you can supply a real BIOS
dump instead.

**Everything else.** Nine save-state slots with thumbnails, rewind, fast forward, cheats,
hq4x / xBR upscaling, per-panel LCD color correction, and a cycle-accurate Game Boy FIFO
PPU for games like Prehistorik Man.

## Downloads

The browser version above is the recommended way to play. For the desktop app, the
[**Latest build**](../../releases/tag/latest) release always carries current Linux
(`.tar.gz`), macOS (`.dmg`) and Windows (`.exe`) binaries, rebuilt from `main` on every
push:

| Platform | Download |
|---|---|
| Linux x64 | [`dingbat-linux-x64.tar.gz`](../../releases/latest/download/dingbat-linux-x64.tar.gz) |
| macOS (Apple Silicon) | [`dingbat-macos.dmg`](../../releases/latest/download/dingbat-macos.dmg) |
| Windows x64 | [`dingbat-windows-x64.exe`](../../releases/latest/download/dingbat-windows-x64.exe) |

Those are development builds and change without notice; verify them against
`SHA256SUMS.txt` on the release if you care to. Tagged `v*` releases, when cut, publish
the same three files on the [Releases](../../releases) page.

For a build of one specific commit, open its run under
[Actions → Build](../../actions/workflows/build.yml) and download from that run's
**Artifacts** section.

Those binaries are **unsigned**, so the OS warns on first launch — on macOS, open
**System Settings → Privacy & Security** and click **Open Anyway**; on Windows, click
**More info → Run anyway**. Once only.

The Linux build needs SDL2 present at runtime (`apt install libsdl2-2.0-0`, or
`dnf install SDL2`); macOS and Windows link it statically and need nothing installed.
It is built against glibc 2.34, so it runs on Ubuntu 22.04+, Debian 12+ and Fedora 35+.

## Documentation

- [**Features**](docs/features.md) — everything both front-ends and both systems support,
  plus remaining work
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

## Contributors

- [Matthew Beck](https://github.com/mattrbeck) — creator and maintainer
