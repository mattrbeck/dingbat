# Usage

## Loading games

Browser: drop a ROM onto the page or pick one from the home-screen library grid. Games
you have loaded before stay available offline; signed in to Google Drive, the grid is your
library across devices (a game held only elsewhere shows as a dashed tile and downloads on
tap).

Native: run `dingbat`, pass a ROM path (`./dingbat /path/to/rom`), or drag a file onto
the window.

On macOS the menus live in the system menu bar (Settings and Quit in the dingbat menu),
Settings… (⌘,) opens a Mac settings window, File > Open ROM… (⌘O) is the system's Open
panel, and the app opens ROMs from Finder: Open With, or a drop on the Dock icon. Games
you open show in the Dock icon's and the Apple menu's recent items. The Edit menu's Cut,
Copy, Paste and Undo work in any text field, the Cheats and Link Cable windows' too.
`DINGBAT_IMGUI_MENU=1` brings back the in-window menu bar and Settings window.
The Mac app draws with Metal; `DINGBAT_RENDERER=gl` draws with OpenGL instead, as
Windows and Linux do.

Zipped ROMs work in both: the first `.gba` / `.gb` / `.gbc` in the archive is loaded.

Nintendo DS games (`.nds`) load in the native app only with Settings > General >
Advanced > DS Beta ticked (off by default): see [nds/desktop.md](nds/desktop.md).

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

## Multiplayer

See [link-usage.md](link-usage.md).
