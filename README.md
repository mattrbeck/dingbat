<p align="center"><img src="README/dingbat_large.png"></p>

<p align="center">A Game Boy, Game Boy Color, and Game Boy Advance emulator written in Nim.</p>

<h3 align="center"><a href="https://gba.mattrb.com">▶ Play it in your browser</a></h3>

<p align="center"><img width="800" src="README/GoldenSun.gif"></p>

## Highlights

**Online link cable.** Trade and battle over the internet using room codes, including
cross-game Pokémon trades like Emerald↔FireRed. Optional rollback netplay. Two tabs in
the same browser link with no server at all. → [Multiplayer guide](docs/link-usage.md)

**Enhanced MP2K audio.** Music in games using Nintendo's MP2K/M4A sound engine is
re-rendered per note, above the hardware's native mix rate. Optional.

**No BIOS file required.** An HLE BIOS is built in. Real BIOS dumps are also supported.

**Accuracy.** 6910 of 7008 mGBA test-suite cases, the AGS aging cartridge, blargg,
mooneye, dmg-acid2, and cgb-acid2. The default Game Boy PPU is a cycle-accurate FIFO
renderer, for games like Prehistorik Man that need one.

**Cross-device sync.** Back up saves, save states, and ROMs to your own Google Drive.

<p align="center"><img width="400" src="README/gbc_silver_rival_battle.gif"> <img width="400" src="README/linksawakening.gif"></p>

## Downloads

The browser version above is the recommended way to play. Tagged releases also publish
prebuilt macOS (`.dmg`) and Windows (`.exe`) binaries on the
[Releases](../../releases) page.

Those binaries are **unsigned**, so the OS warns on first launch — on macOS, open
**System Settings → Privacy & Security** and click **Open Anyway**; on Windows, click
**More info → Run anyway**. Once only.

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
