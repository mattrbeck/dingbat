# DS saves: the card's save chip, .sav files, and the firmware that blocked them

Status: **working**. Every chip type GBATEK lists for NDS cards is modelled
(NAND carts are out of scope); a loaded save is fitted to the chip the game
actually addresses; the web app imports and exports through the same rules.
The synthesized firmware now has a complete wifi section, which was what made
Pokemon SoulSilver's CONTINUE fail without a firmware dump.

Code: `src/dingbat/nds/io/backup.nim` (chip + file rules), `io/cart.nim`
(the slot's SPI and the one per-game override), `boot.nim` (`synth_firmware`),
`web/index.js` (`applyImportedSave`, `persistSave`, "Nintendo DS").
Tests: `tests/nds_system_test.nim` (save chip types, save files),
`tests/nds_boot_test.nim` (synthesized firmware structure; with the user's
dump, a run-time comparison), `web/tests/nds.test.mjs`, `web/e2e/nds.e2e.mjs`,
`web/e2e/nds-soulsilver.e2e.mjs` (local only).

## The bug: "A communication error has occurred" on CONTINUE

With no dumps (the web app's default: HLE BIOS, built-in firmware) or with
the real BIOS and no firmware.bin, SoulSilver's CONTINUE on a save showed
"A communication error has occurred. You will be returned to the title
screen." With the user's firmware.bin it worked. A new game never noticed.

**Cause.** `synth_firmware` left the wifi calibration section (firmware
02Ah..1FFh, GBATEK "DS Firmware Wifi Calibration Data") zero: config length
0 and channel mask 0. Bisected in scratch by copying ranges of the user's dump
into the synthesized image at run time (never committed): the wifi section
alone fixes it; within it, config length 0138h plus a non-zero channel mask
(with the CRC made valid) is the minimum; every other single region, and
the header alone, does not. So the wireless code that CONTINUE starts (a new
game does not reach it in the p12 script) refuses a section that is empty or
has no channel enabled.

**Fix.** `synth_firmware` builds the whole section from GBATEK. No byte comes
from a dump; the run-time comparison below is a check, not a source.

| Field (firmware offset) | Value | Evidence |
|---|---|---|
| 02Ah CRC16 | computed, initial 0, over 02Ch..163h | GBATEK |
| 02Ch config length | 0138h | GBATEK "usually 0138h" |
| 02Fh wifi version | 3 (firmware v5) | GBATEK table; console type FFh (original DS), MAC in the v1-v5 form 0009BFxxxxxx |
| 030h-035h | 00h | GBATEK (DS; the Lite has FFh x5) |
| 03Ch channel mask | 3FFEh (channels 1..13) | GBATEK "usually 3FFEh" |
| 03Eh flags | FFFFh | GBATEK "usually FFFFh" |
| 040h-043h RF type, bits, entries, unknown | 02h, 18h, 0Ch, 01h | GBATEK "usually" values; type 2 = RF9008, the original DS's |
| 044h-063h W_CONFIG / W_POWER_TX | 0002 0017 0026 1818 0048 4840 0058 0042 0140 8064 E0E0 2443, 0003, 0032 01F4 0101 | GBATEK "DS Wifi Configuration Ports": the value after firmware init, "identical in all consoles". W_POWER_TX has none listed: **Assumed** its reset value 0003h |
| 064h-0CCh BB[0..68h] | 00h=6Dh, 01h=9Eh, 1Eh=BBh, 35h=1Fh, rest 00h | GBATEK "Important BB Registers" and the chip ID; the rest **Assumed** 0 (no model reads them) |
| 0CEh RF init (12 x 24 bit) | 00C007 129C03 141728 1AE8BA 1D456F 23FFFA 241D50 280001 2C0000 069C03 080022 0DFF6F | GBATEK "DS Wifi RF9008 Registers" example table, RF[09h] = 01D50h ("v5 and up uses narrower tx filter") |
| 0F2h channels 1..14, RF[05h]/RF[06h] | derived | below |
| 146h BB[1Eh] per channel | B4h | GBATEK "usually somewhat B1h..B7h": **Assumed** B4h |
| 154h RF[09h] TXVGC per channel | 10h | GBATEK "usually 10h-filled" |
| 162h unknown | 1Ah | GBATEK "usually 19h..1Ch": **Assumed** 1Ah |
| 163h-1FFh | FFh | GBATEK |

The channel table: RF[05h] holds the RF PLL's divide-by-N (bits 17-6) and
numerator bits 23-18, RF[06h] numerator bits 17-0 (GBATEK RF9008 registers),
a fractional-N divider on the RFU's 22 MHz clock (GBATEK pin-outs). GBATEK's
example RF[05h]/RF[06h] = 01728h/2E8BAh is N = 92 + 10676410/2^24 = 92.636,
i.e. 2038 MHz = channel 1's 2412 MHz less 374 MHz. Each channel moves that LO
with its carrier (2412 + 5(ch-1) MHz, 2484 for 14), the fraction rounded to
nearest. Against the user's dump (nds_boot_test, local): all 14 pairs equal.

Also checked against GBATEK, every other synthesized field a game may
validate: the header's "MAC" identifier, console type FFh with 01Eh/01Fh and
028h/029h FFh (they were 00h), user settings at 3FE00h; both user-settings
copies version 5, CRC16 (initial FFFFh, which the dump confirms), copy 2 the
newer (counter + 1), language English, none of the "settings lost / prompt"
flag bits (64h bits 9, 10, 11, 13, 14, 15), nickname length 1..10,
birthday in range, two distinct touch calibration points, 74h..FFh FFh (no
extended settings: console type FFh reads as 00h, bit 6 clear). The three
access points (3FA00h..3FCFFh) were all FFh; they are now GBATEK's
unconfigured entry: zero-filled, status (0E7h) FFh, valid CRC16 at 0FEh.

**Evidence.** SoulSilver with `soulsilver_newbark.sav`, START@700, START@1000,
A@1300: before the fix frame 1600 is the title (after the error), now New
Bark Town with no dumps, with the real BIOS and no firmware, and with the
dumps (unchanged). The new-game script (p12) gives the same frames 3000/5000/
8000 as before (e4b66d68/6cf51b7e/d2ad8167) with the real BIOS and with HLE.
nds_wifi_test passes with the dumps and with HLE + synthesized firmware (the
Air now matches channels for synthesized consoles too: the table exists).

Local check (the ROM never enters the repo):

    ndsrun PokemonSoulSilver.nds --frames 1600 --rtc 2004-01-01 \
      --press "START@700,START@1000,A@1300" --save <copy of a save in New Bark Town> \
      --shots 1500 --out x.png          # x_1500.png: New Bark Town, the touch menu up

## The save chip (GBATEK "DS Cartridge Backup")

| Chip | Sizes | Address | Page (write wrap) | RDSR | RDID |
|---|---|---|---|---|---|
| EEPROM 0.5K (M95040) | 512 | 8 bit + command bit 3 (RDHI 0Bh / WRHI 0Ah) | 16 | bits 4-7 set | FFh |
| EEPROM (M95640 / M95512) | 8K, 64K | 16 bit | 32 / 128 | bits 4-6 clear, 7 SRWD | FFh |
| EEPROM 128K | 128K | 24 bit | **Assumed** 256 (GBATEK "?") | as above | FFh |
| FRAM | 32K (8K: see below) | 16 bit | none | as above | FFh |
| FLASH (ST M45PE / Macronix) | 256K, 512K, 1M, 8M | 24 bit | 256 | WIP, WEL | 20 40 12 / 20 40 13 / 20 40 14 / C2 20 17 |

- Commands: WREN, WRDI, RDSR, WRSR (EEPROM/FRAM: WP bits 2-3 and SRWD
  only; WEL drops; FLASH has no WRSR), READ 03h, FAST READ 0Bh (FLASH: one
  dummy byte), WRITE 02h (EEPROM/FRAM: write; FLASH: page program, clears
  bits only), PAGE WRITE 0Ah (FLASH: replaces), PAGE ERASE DBh, SECTOR ERASE
  D8h. WEL is needed for every write/erase and drops after it.
- Write protect: WP 1/2/3 makes the upper quarter / half / all of an EEPROM
  or FRAM read-only.
- WIP (status bit 0) is always 0: writes and erases complete at once.
- An unformatted chip is all FFh: what a game reads from a new cart.
- IR carts (game code 'I', SoulSilver among them): a command byte first,
  00h passes the rest to the chip (GBATEK "DS Cart Infrared Cartridge SPI
  Commands").

**Detection.** Nothing in the header says which chip a game has. Without a
file the chip is decided at the game's first read or write by counting the
bytes sent from the address bytes' program counter (GBATEK "Detection (in
emulators)"); RDID or an erase first means FLASH. While a detected chip is
unwritten every access detects again (GBATEK's Over the Hedge first
addresses an 8K EEPROM, then uses its 0.5K one). Rune Factory (ARFx) is
forced to 64K EEPROM, as GBATEK says. A 16-bit chip is taken as 64K (8K and
64K EEPROMs answer alike; 64K holds either), a 24-bit one as 512K FLASH that
grows to 1M or 8M when the game addresses past its end (Spirit Tracks, Art
Academy).

**24-bit EEPROM or FLASH.** GBATEK: "FLASH has same 24bit bus-width as
128Kbyte EEPROM, but isn't compatible on writing". A detected 24-bit chip
starts as FLASH; a 02h write that would set a bit, before any page write,
erase or RDID, can only be the EEPROM's write+erase (FLASH code erases first,
FLASH 02h cannot set bits), so the chip becomes the 128K EEPROM (when nothing
past 128K was written).

**Fixes in this round.** A 0.5K EEPROM loaded from a file put RDHI/WRHI in
the low half (address bit 8 was shifted out by the address byte; only the
detection path had it right). Page wrap, write protect, the 8M FLASH id and
the no-WRSR FLASH are new.

## .sav files

A .sav is the raw chip image, byte 0 = chip address 0, exactly the chip's
size. That is what dingbat writes (ndsrun `--save`, the web app's export).

On load (`set_data`, the same in ndsrun and the web app):

1. A text footer is stripped: a file whose last KB contains "|<--Snip above
   here to create a raw sav by excluding this" is cut there (the .dsv
   form; the text itself says the raw image is what precedes it).
2. 512, 8K, 64K, 32K, 128K bytes name the chip: 0.5K EEPROM, EEPROM, EEPROM,
   FRAM, 128K EEPROM. (An 8K FRAM, GBATEK "which/any games?", loads as an
   8K EEPROM: same protocol, a 32-byte write page.)
3. Any other size (a FLASH size, or a file padded or trimmed by a flashcart
   or another program) is a hint. The game's first access picks the address
   width; then the image is fitted: kept from byte 0, extended with FFh to the
   chip's size (24-bit: the next FLASH size), cut only where the excess is
   padding (all FFh, all 00h, or repeats of the chip). Excess that is not
   padding cannot be on the chip: it is reported (`dropped`, stderr; ndsrun
   prints it) and the file is not rewritten until the game writes.
4. A stripped footer or a fitted size marks the chip dirty, so the frontend
   stores the exact chip at its next save and every export after that is
   the raw image.

So a 512K flashcart file of an 8K-EEPROM game comes in as a 64K EEPROM (it
used to become a 512K FLASH, which the game's 16-bit commands could not use),
and a 200K trimmed FLASH dump as 256K.

Exact sizes the game cannot reveal: a 16-bit chip with no file exports 64K
(an 8K game's file is 64K, the first 8K its data; 8K files load as 8K), a
24-bit one 512K (a 256K game's file is 512K). A file of the right size
always stays that size.

## Web app

- Import (Manage Saves > Import, or drop a .sav/.dsv): a DS game's file is
  stored as it is and the core reboots on it (`applyImportedSave`); the GBA
  container sniffing (SharkPort, GameShark SP) is skipped for DS games, since
  a DS save's bytes could look like one. The core applies the rules above
  and marks the chip dirty when it normalised it, so `persistSave` stores
  the exact chip (within 5 s, or at once on Export).
- Export: `persistSave` first, then the stored bytes: the chip as the core
  holds it.
- Tests: `web/tests/nds.test.mjs` (the whole file reaches the core, a .dsv
  drop imports), `web/e2e/nds.e2e.mjs` (a .dsv for `save_write` through
  Manage Saves: the game reads it, the stored save is 512 bytes), and the
  local-only `web/e2e/nds-soulsilver.e2e.mjs` (header of the file says how).

**SoulSilver in the real app** (`nds-soulsilver.e2e.mjs`, headless Chromium,
no dumps): Add a game, Manage Saves > Import `soulsilver_newbark.sav`,
START, START, A: New Bark Town with the touch menu; walk, touch SAVE, A
through the questions until the menu is back: the stored save is a new 512K
image; reload the page, the library tile, the core boots on exactly that
image, CONTINUE: New Bark Town one step further down. On the branch before
the fix the first CONTINUE ends at the title; with firmware.bin chosen in
Settings > Nintendo DS it works there too (the workaround).

## Save states and the battery save

A state carries the chip; loading one marks the chip dirty, so the state's
battery is written over the stored save (`apply_new`), as for GB/GBA. The
app's guards are system-independent and cover DS: the auto-resume snapshot
records `saveSig` = the signature of `ndsSaveBytes()` at capture
(`liveSaveSig`), and Resume (toast or hero) is offered only while the stored
save still has that signature, so a game that saved since retires the
snapshot. A slot load has no such guard (also as GB/GBA): it puts the slot's
battery in, with a 6-second Undo that re-applies the pre-load state, chip
included. The new chip fields change the DS state layout: states from
before this round are refused (srkIncompatible) and the battery save is
untouched.

## Left

- WIP timing (GBATEK: page program 1.2 ms, page write 11 ms, sector erase
  1 s); FLASH deep power-down (B9h/ABh); WP/SRWD are not kept across power
  (non-volatile on the chip, not in a .sav).
- RDID of a growing FLASH answers the 512K id until the game has addressed
  past 512K.
- The 8M Macronix part's own command set beyond the common ones.
- IR commands 03h-07h (memory access), IR traffic; NAND carts.
- Other save containers with headers (e.g. Action Replay exports) are not
  recognised: they load as a hint and their header ends up at address 0.
