# Usage

## Loading games

In the browser, drop a ROM onto the page or pick one from the home screen's
recently-played grid. Games you've loaded before stay available offline.

With the native build, run the `dingbat` executable. To open a specific ROM directly,
pass it as an argument (`./dingbat /path/to/rom`) or drag the file onto the window.

Zipped ROMs work in both: the first `.gba` / `.gb` / `.gbc` file in the archive is loaded.

## BIOS

No GBA BIOS file is needed — an HLE BIOS is built in and used by default.

If you have a real BIOS dump and prefer it, select it through the UI, or place it at:

| Platform | Path |
|---|---|
| Linux / macOS | `~/.config/dingbat/bios.bin` |
| Windows | `%APPDATA%\dingbat\bios.bin` |

The web build offers the same choice through the settings panel.

## Save files

Native builds write `.sav` files next to the ROM. The browser keeps a save file per ROM
in IndexedDB; "Manage ROMs & Saves" lets you export, import, or reset them.

Game Boy save files are compatible with other emulators such as BGB, so you can move a
save between them.

Save states are separate from save files: nine slots per ROM, each with a thumbnail,
plus Quick Save and Quick Load.

## Picking a Game Boy renderer

The GB / GBC PPU has two implementations:

- **FIFO** (default) — cycle-accurate. Required by games like Prehistorik Man that
  depend on precise PPU timing.
- **Scanline** — faster, and fine for the large majority of games.

Choose one in the settings window. The change takes effect on the next ROM load or reset.

## Multiplayer

Link cable play — local 2P, online room codes, and native TCP — is covered in
[link-usage.md](link-usage.md).
