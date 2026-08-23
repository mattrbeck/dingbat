# Usage

## Loading games

Browser: drop a ROM onto the page or pick one from the home-screen library grid. Games
you have loaded before stay available offline; signed in to Google Drive, the grid is your
library across devices (a game held only elsewhere shows as a dashed tile and downloads on
tap).

Native: run `dingbat`, pass a ROM path (`./dingbat /path/to/rom`), or drag a file onto
the window.

Zipped ROMs work in both: the first `.gba` / `.gb` / `.gbc` in the archive is loaded.

## BIOS

No GBA BIOS file is needed; the built-in HLE BIOS is the default. To use a real dump,
select it in the settings panel or place it at `~/.config/dingbat/bios.bin`
(Linux / macOS) or `%APPDATA%\dingbat\bios.bin` (Windows).

## Save files

Native builds write `.sav` next to the ROM. The browser keeps one save per ROM in
IndexedDB; "Manage ROMs and Saves" resets a game's save or deletes the game. Both mirror
to Drive when signed in. Game Boy saves are plain SRAM images, interchangeable with other
emulators.

Save states are separate: nine slots per ROM with thumbnails, plus Quick Save / Quick Load.

## Game Boy renderer

Two PPU implementations, chosen in settings (takes effect on the next load or reset):

- **FIFO** (default) — cycle-accurate; needed by games such as Prehistorik Man.
- **Scanline** — faster; fine for the large majority of games.

## Multiplayer

See [link-usage.md](link-usage.md).
