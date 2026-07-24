<p align="center"><img src="README/dingbat_large.png"></p>

<p align="center">A Game Boy, Game Boy Color, and Game Boy Advance emulator written in Nim.</p>

<h3 align="center"><a href="https://gba.mattrb.com">▶ Play it in your browser</a></h3>

<p align="center">No install, no account, no BIOS file. Add it to your home screen and it works offline.</p>

<p align="center"><img width="800" src="README/GoldenSun.gif"></p>

## Highlights

**Online link cable, with room codes.** Trade and battle over the internet — one player
shares a room code, the other pastes it, and you're connected. Optional rollback netplay
hides the latency. Two tabs in the same browser link with no server involved at all.
Covers GBA link games and Game Boy / Game Boy Color Gen 1–2 trades.
→ [Multiplayer guide](docs/link-usage.md)

**Enhanced MP2K audio.** Games built on Nintendo's standard MP2K/M4A sound engine are
detected at runtime and their music is re-rendered per note, well above the hardware
FIFO's native mix rate. The same songs, without the muffle. Optional, and off by default.

**No BIOS file required.** An HLE BIOS is built in, so you can drop in a ROM and play
immediately. If you have a real BIOS dump, it's supported — but nothing here needs one.

**Accuracy you can check.** 6910 of 7008 mGBA test-suite cases, the AGS aging cartridge
(everything except COM, which needs a second multiboot unit), blargg + mooneye +
dmg-acid2 + cgb-acid2 on the Game Boy side, and a cycle-accurate FIFO PPU for games like
Prehistorik Man that depend on one.

**Cross-device sync** *(experimental)*. Back up saves, save states, and ROMs to your own
Google Drive, then pick a game up again on another device.

<p align="center"><img width="400" src="README/gbc_silver_rival_battle.gif"> <img width="400" src="README/linksawakening.gif"></p>

## Downloads

The browser version above is the recommended way to play. Tagged releases also publish
prebuilt macOS (`.dmg`) and Windows (`.exe`) binaries on the
[Releases](../../releases) page.

Those binaries are **unsigned**, so the OS warns on first launch — on macOS, open
**System Settings → Privacy & Security** and click **Open Anyway**; on Windows, click
**More info → Run anyway**. Once only.

## Documentation

| | |
|---|---|
| [Features](docs/features.md) | Everything the emulator and both front-ends support, plus remaining work |
| [Usage](docs/usage.md) | Loading ROMs, BIOS files, save files, and picking a GB renderer |
| [Multiplayer](docs/link-usage.md) | Link cable setups: local 2P, online room codes, native TCP |
| [Building](docs/building.md) | Native, WebAssembly, and cross-compiled Windows builds |

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
[GhostRain0](https://github.com/GhostRain0).

## Contributors

- [Matthew Beck](https://github.com/mattrbeck) — creator and maintainer
