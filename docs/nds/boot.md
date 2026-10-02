# DS boot: real BIOS + firmware, and card encryption

Status: **working**. With the user's `bios9.bin`, `bios7.bin` and
`firmware.bin`, `--boot firmware` runs the real BIOSes from power-on, the
card handshake through KEY1 and KEY2, the real firmware (logo, health and
safety, the DS menu) and the game it launches. Pokemon SoulSilver boots that
way into its intro, with frames matching the reference core's own firmware
boot (below). Direct boot (the default) is unchanged for every dump form and
now also takes encrypted secure areas.

Code: `src/dingbat/nds/io/cartcrypt.nim` (KEY1, KEY2, secure-area forms),
`io/cart.nim` (the card's protocol), `boot.nim` (`direct_boot`,
`firmware_boot`, `synth_firmware`), `nds.nim` (`NdsBoot`, `new_nds`,
`load_nds`), `io/spi.nim` (user-settings choice). Tests:
`tests/nds_boot_test.nim` (`nimble test_ndsboot`).

## What the hardware does

GBATEK "DS Cartridge Protocol", "DS Encryption by Gamecode/Idcode (KEY1)",
"DS Encryption by Random Seed (KEY2)", "DS Cartridge Secure Area", "DS
Firmware Header/User Settings", "BIOS RAM Usage".

1. Power-on: ARM9 at 0xFFFF0000, ARM7 at 0, both in SVC with IRQ/FIQ off;
   POSTFLG, BIOSPROT and ROMCTRL are zero, so the card is held in reset.
2. The ARM7 BIOS releases the card (ROMCTRL.29) and talks to it raw: `9F`
   dummy (0x2000 bytes), `00` header (0x200), `90` chip ID, then `3C`
   (enter KEY1).
3. KEY1 phase. Each command is Blowfish-encrypted with the gamecode's
   level-2 key (the table comes from BIOS7 0x30..0x1077): `4` hands the
   card a KEY2 seed (the BIOS writes the same seed to the SEED registers and
   applies it with ROMCTRL.15), `1` reads the chip ID again (KEY2-encrypted
   reply), `2` reads secure-area blocks 4..7 in random order, `A` enters main
   mode. A card with chip-ID bit 31 (the newer protocol) gets every command
   twice, the first time with no data, and a secure block as eight
   0x200-byte reads; older cards get each once, a block as one 0x1000 read
   with gap clocks. Our logs show the BIOS doing exactly that for both
   (SoulSilver: newer; a libnds homebrew ROM: older).
4. The BIOS decrypts the secure area's first 2 KB (level 2 for the first 8
   bytes, then level 3 for all 2 KB), checks the "encryObj" ID and
   overwrites it with E7FFDEFF E7FFDEFF (or the whole 2 KB on a mismatch),
   checks the header CRC and Nintendo logo, then loads the firmware from SPI
   flash (KEY1 with "MACP", LZ77) and runs it.
5. The firmware reads the card in KEY2 main mode (`B7`, `B8`), shows the
   logo and the health and safety screen, then the menu; launching the card
   loads its ARM9/ARM7 binaries and starts them.

KEY2 is applied by hardware at both ends: the card XORs its stream onto
replies (and, in main mode, takes commands through it); the console's card
interface XORs its own onto commands (ROMCTRL.22) and data (ROMCTRL.13).
With the same seed and the same bytes clocked, they cancel.

## What dingbat had before

Direct boot only: ARM9/ARM7 binaries copied, post-boot state written, the
card answering `B7`/`B8`/`00`/`90` in plaintext in any state, "encryObj"
replaced if present. No KEY1, no KEY2, no SEED registers, no card reset,
no way to start at the reset vectors. An encrypted dump crashed.

## What dingbat does now

**Card (cart.nim).** Three modes: raw after reset, KEY1 after `3C` (only
with a KEY1 table: the BIOS7 dump's), main after `A`. KEY1 commands are
decrypted with the gamecode level-2 key; `2bbbb...` serves the secure area
in card form (a decrypted dump re-encrypted, an encrypted one as dumped);
the newer protocol's repeats are recognised (a repeat of the last command
continues a block's 0x200-byte portions; `4`/`6`/`A` take effect on the
repeat). Two KEY2 streams, card side and console side (SEED registers
0x40001B0-BA per CPU, applied by ROMCTRL.15), advance over every clocked
byte: command bytes, gap1/gap2 clocks when ROMCTRL.28 is set, data. In main
mode any command but `B7`/`B8` reads the 00 stream. ROMCTRL.29 is sticky,
.15 write-only. The chip ID has GBATEK's IR flag (gamecode 'I') and bit 31
from 128 MB (GBATEK's table: every NDS card of 128 MB and up has it); an
empty slot reads FFFFFFFF.

**Direct boot.** The card is left in main mode with both streams at one
seed, so games read plaintext as before. The ARM9 binary's first 2 KB are
what the BIOS would leave for each dump form (cartcrypt `boot_secure_area`):

| Dump form (ROM 0x4000) | Detected by | Direct boot | Firmware boot (card serves) |
|---|---|---|---|
| encrypted | decrypts to "encryObj" (needs the BIOS7 table) | decrypted, ID overwritten | as dumped |
| decrypted, "encryObj" | the ID itself | ID overwritten | re-encrypted |
| decrypted, ID overwritten (most dumps) | E7FFDEFF E7FFDEFF | as dumped | ID restored, re-encrypted |
| zero fill / plain code (homebrew) | none of the above | as dumped | as dumped (the BIOS then fills 2 KB with E7FFDEFF) |

An encrypted dump without a BIOS7 dump direct-boots with a warning (the game
will crash: nothing can decrypt it).

**Firmware boot (`boot.nim` firmware_boot).** Both CPUs at their reset
vectors, POSTFLG/BIOSPROT 0, the card in reset, POWCNT2 = 1 (GBATEK);
WRAMCNT 0, EXMEMCNT 0x2000 and POWCNT1 0 are Assumed (GBATEK gives no reset
values; the BIOS sets them before they matter). Nothing else is faked: the
BIOS, firmware and card handshake run as on hardware.

**API.**

```
new_nds(rom, bios9, bios7, firmware, force_hle = false, boot = nbDirect)
load_nds(rom_path, bios_dir = "", boot = nbDirect)   # rom_path "" = empty slot
ndsrun ROM --boot firmware --bios DIR                 # or no ROM: the menu
```

`nbFirmware` needs all three dumps and no forced HLE; otherwise it prints
why and direct-boots. To get into a game: `--press A@300,A@460` (A leaves
health and safety, A launches the selected card), or touch anywhere on the
warning and on the card's tile. `-d:ndsdebug` builds take `--cartlog`: one
line per card transfer (mode, ROMCTRL, plain command, first reply bytes).

**Wasm (not done).** `nds_load` in `src/dingbat_nds_wasm.nim` needs a boot
argument passed to `new_nds(..., boot = ...)`, and web/nds.html must hand it
all three dumps; a dump-less page can only direct-boot.

## Synthesized firmware (no firmware.bin)

`synth_firmware` builds every section GBATEK documents except firmware
code: header (identifier, console type, user-settings offset, FFh unused
bytes), a complete CRC-valid type-2 wifi calibration section (config length
138h, channel mask 3FFEh, RF/BB/W_CONFIG init tables, per-channel RF[05h]/
RF[06h] pairs derived from the RF9008's divider), three unconfigured
CRC-valid access points, and two user-settings copies with valid CRCs (copy
1 current), English, touch calibration. Each value's source is in
docs/nds/saves.md ("The firmware fix"): before it, the wifi section had
config length 0 and channel mask 0 and SoulSilver's CONTINUE ended in "A
communication error has occurred". There is no firmware code at all, so
**a firmware boot needs a real firmware dump**; dingbat cannot synthesize
one.

## Evidence

- KEY2: GBATEK's pre-init dummy stream (HIGH-Z, C5, 3A, 81) comes out of
  the seeds 58C56DE0E8 / 5C879B9B05 with step-then-XOR (nds_boot_test).
- KEY1: round trips and the full handshake on a made-up table (dingbat has
  no BIOS copy); with the user's BIOS7, re-encrypting SoulSilver's
  secure area gives CRC16 86A5, the header's 06Ch value (the CRC is over the
  card form), and the BIOS's own handshake verifies it (0x27FF80C/80E = 0).
- Real boot: SoulSilver's three dump forms (as dumped, with "encryObj"
  restored, fully encrypted; made in scratch, never committed) all
  firmware-boot to the same frame 1600, and direct-boot to the same frame
  3000 as before.
- Reference: the reference core's firmware boot (docs/oracles.md, "NDS
  core") with the same dumps and inputs: identical frames, ours 2 frames
  later through the BIOS/logo phase, identical again from the menu on.
- Homebrew: a libnds ROM (16bit_color_bmp: devkit-style zeroed secure
  area, valid logo) firmware-boots into its picture; our bare-metal test
  ROMs (logo CRC E155, code in the secure area, ARM7 binary below 0x8000)
  show "There is no DS Card inserted" in the menu, as the BIOS's header check
  decides; they still direct-boot (all suites green).

## Left

- The BIOS phase is 2 frames slower than the reference's (logo at frame 86
  line 16 vs 84). The ARM7 BIOS computes for the whole 1.4 s (KEY1 setup,
  the secure-area delays, firmware decryption, two ~100 ms CRC16 passes)
  while the ARM9 waits, so ARM7 speed decides it. arm7_timing shows the
  reference's ARM7 main-RAM data accesses 3 cycles cheaper than GBATEK's
  table (ours follows GBATEK); with its costs our logo comes 0.7 frames
  earlier. The other ~1.3 frames are not found: every other ARM7 access
  kind measured (WRAM, BIOS-table CRC, branches, MUL, calls) matches the
  reference. Both charge 3 cycles per ARM7 SUB/BGT pass where GBATEK's
  WaitByLoop table says 4; following GBATEK there would put our logo at
  frame 90 (docs/nds/accuracy.md).
- Assumed, unverified: a KEY2 side only advances while it encrypts; a
  transfer's bytes are all clocked at its start; the card's HIGH-Z first
  dummy byte is not modelled; reset values above.
- NAND and DSi carts (command 3D), the "Optional KEY2 Disable" path via
  firmware "enPngOFF" (implemented card-side, never exercised).
- Firmware writes (settings changed in the menu, a game's WFC setup) set
  `spi.firmware_dirty`; ndsrun `--firmware-out FILE` and the wasm exports
  `nds_firmware_dirty/_ptr/_len/_clean` hand the image to the frontend
  (docs/nds/accuracy.md). The web app does not store it yet.
- No autostart switch (user-settings bit 6) for skipping the menu.
- Hardware checks that would settle the Assumed items: a test ROM reading
  the card with ROMCTRL.13 toggled mid-stream on a real DS.
