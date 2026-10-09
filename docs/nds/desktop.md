# DS games in the desktop app (DS Beta)

The native app (`src/dingbat.nim`, SDL2 + Dear ImGui) plays `.nds` games
behind **Settings > General > Advanced > DS Beta**, off by default ("Lets DS
games load. An early, incomplete Nintendo DS core."). The DS-only half that
needs no window is `src/dingbat/frontend/nds_game.nim`
(tests/desktop_nds_test.nim builds it headless); the web
(`src/dingbat_nds_wasm.nim`, docs/nds/web.md) and iOS (`src/dingbat_ios.nim`)
front ends are the models it follows.

## Off (the default)

The app is what it was before the DS core. Every path that could open a DS
game is the old code with the setting false:

| | Off |
|---|---|
| Open ROM dialog | lists `.gba .gb .gbc .cgb .sgb .zip` (`ROM_DIALOG_EXTS`), no `.nds`. |
| Drop on the window | `is_rom_file` only: a `.nds` is ignored. |
| A zip | only `ROM_EXTS` are looked for: a zip holding just a `.nds` says "No Game Boy or GBA ROM could be read". |
| Command line, Recent | `load_rom` builds a GB/GBA core as before (a `.nds` named on the command line goes to the GBA core, as it always did). |
| Settings file | the `nds:` section is written only for values that differ from their defaults, so the file is byte for byte the one a build without DS Beta writes. |
| Menus, settings | nothing of the DS: the BIOS tab's DS rows and the X/Y (DS) binding rows show only while the DS Beta box is ticked. The one new thing is the General tab with its folded Advanced section. |
| Frame loop | no work added for GB/GBA: each `case app.emu_kind` gained an `ekNDS` branch, the frame scheduler reads its period from a variable `load_rom` sets (the same value as before for GB/GBA). |

Turning DS Beta off while a DS game runs leaves it running; Reset reboots it
as a DS game. The next game opened follows the setting.

## On

| | |
|---|---|
| Opening | `.nds` in the dialog, a drop, the command line and Recent, and inside a zip (the first `.gb/.gbc/.gba/.nds...` entry). A file of another name whose header passes GBATEK's checks (logo CRC CF56h at 15Ch, or the header CRC16) opens as a DS game too. A `.nds` that fails them is refused with the running game kept ("x.nds isn't a DS ROM."). |
| Screens | One 256x384 texture, the top screen above the bottom, through the GB/GBA presenter: the window is Frame size x 256x384, except that a DS window takes the largest multiple that fits the display's usable height (a 3x DS is 1152 px tall). Preserve aspect letterboxes as for GB/GBA; the filters and screen looks apply; colour correction and the LCD response model do not (they model the GBA and GBC panels; the menu item is greyed for a DS game). |
| Buttons | The GB/GBA bindings for the d-pad, A, B, L, R, Select and Start. X and Y have their own: keyboard D and C (the Home-row preset: I and U), pad X and Y (by label, as the web maps a standard pad). In a DS game they come before the GB/GBA bindings of the same key or button (pad X/Y are also A/B for GB/GBA by default). Rebindable in Settings > Keybindings / Controller as "X (DS)" and "Y (DS)", stored under `nds: keybindings` / `controller_bindings`. |
| Touch screen | The left mouse button on the bottom screen: a touch starts only there (and not on the menu bar or an ImGui window over it), then follows the mouse, clamped to the screen, until the button comes up (`touch_point`). |
| Lid | Emulation > Close Lid (a toggle). Closed, no touch lands, and a game typically sleeps (the title says SLEEPING) until it opens. Every boot starts open; a state load keeps the lid where the menu has it. |
| Sound | The SPU's float32 stereo, queued after each frame to SDL's legacy audio device (which each core opens for itself) at 32728 Hz. Volume, mute, 2x Speed (WSOLA when Pitch-correct fast-forward is on, else every other sample) and Fast Forward as for GB/GBA. Pacing is the GB's frame scheduler on the DS's own frame period (1120380 cycles at 67.027964 MHz, 59.83 Hz). Asleep or switched off, silence keeps the pace. The Channels submenu and the GBA audio options are greyed. |
| Battery | The cart's save chip in `<rom>.sav` beside the ROM (in the zip's cache folder for a zip), as the GB/GBA battery: read at boot (the core's rules, docs/nds/saves.md), written within a second of the game changing it (then again while it goes on) and at every switch, Reset and quit. A write that fails shows the same "save file can't be written" notice. |
| Firmware settings | What a game or the DS menu writes to the firmware flash (name, birthday, language, Wi-Fi settings) is kept once per computer in `<config dir>/nds/flash.bin`, shared by every DS game, in the iOS app's record format (the image, then the firmware base it was written on). On the built-in firmware only its user area is laid over this build's, as on the web (docs/nds/web.md "Firmware settings"); over a dump, the written image whole. The user's `firmware.bin` is never written. |
| BIOS / firmware dumps | Settings > BIOS, below the GBA BIOS: DS ARM9 BIOS (`bios9.bin`), DS ARM7 BIOS (`bios7.bin`), DS firmware (`firmware.bin`), each optional (HLE BIOS, built-in firmware without). Used from the next DS game loaded; stored as `nds: bios9/bios7/firmware` and kept by Reset to Defaults. Direct boot only (no firmware menu boot). |
| Save states | The nine slots, Quick Save / Quick Load and the Save States window, in the same slot files (named by the ROM file and `rom_identity`), with a 128x192 thumbnail of both screens. A DS switched off by its game has no state to save. A refused state says why with the usual sentences (a state made with the other BIOS, HLE or a dump, is `srkIncompatible`). |
| Rewind | The backquote key while Rewind is on: a ring of `state_payload(aligned = true)` snapshots every 10 frames, capped at 64 MB, without keyframes (the web's choice: each would be a 2 MB zlib), applied with `load_own_payload`. Dropped on a state load. |
| Screenshot | F12: both screens, 256x384, no colour correction. |

## Not on the desktop (yet)

Hidden or greyed for a DS game, never reached: cheats (the Cheats window
edits GB/GBA codes; `nds/cheats.nim` is not wired here), the Link Cable
window and network link (GBA only), the GB/GBA debug windows, the audio
channel toggles, rumble, the playtest input log, the latency test. Also not
done: the microphone, a gap between the screens (the hq4x/xBR filters can
blend the seam row), other screen arrangements (side by side, swap), a
firmware boot, the GBA slot.
