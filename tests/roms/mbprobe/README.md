# mbprobe — retail-cart probes delivered by multiboot

Closes the three "multiboot probe" rows of `docs/hwprobe-questions.md`. A
retail cartridge cannot be flashed, so the probe code reaches the GBA that
holds it over the link cable: a SENDER ROM on the flashcart GBA (#1) runs
the master half of the multiboot handshake and SWI 25h, the slave GBA (#2)
boots the PAYLOAD from its EWRAM, and the payload then probes whatever cart
is in #2's slot. Results are drawn on #2 as 12x16 px hex glyphs with 6x6
corner marks (photograph them) and are also pulled back over the cable and
shown on #1.

Nothing here executes from the retail cart; the payloads only read it (and
for the EEPROM probe, write one block back to itself).

## Build

```
python3 tests/roms/mbprobe/build.py
```

Needs `arm-none-eabi-{as,ld,objcopy}`. Outputs in `build/`:

| file | what |
|---|---|
| `sender.gba` | flash this to the flashcart for GBA #1 (14 KB, embeds the four payloads) |
| `payload_{eeprom,tilt,gyro,mirror}.mb` | the multiboot images (linked at 0x02000000), for reference / PC-side multiboot tools |
| `payload_*_cart.gba` | the same sources linked at 0x08000000 with a cart header, for `./dingbat_test` predictions (see below). The mirror twin is padded to exactly 1 MiB |

Sources: `sender.s`, `payload_*.s`, `mbprobe.inc` (equates/macros, top of
each source), `mbcommon.inc` (text, keys, timers, link child side, bottom of
each source), `mbfont.inc` (generated), `mbprobe_ocr.py` (reads a dingbat
screenshot back into text).

## Rig

- Two GBAs (AGB-001 or AGS-001/101; the DS has no link port, GBATEK), one
  GBA link cable (AGB-005), a flashcart for #1, the retail cart for #2.
- #1: flashcart with `sender.gba`. #2: the retail cart.
- Power-on order:
  1. #1 on, sender menu up. Its row 7 shows `SI= SD= ID=` live from
     SIOCNT. **`SI=0` means #1 is on the parent end of the cable**; if it
     reads 1 with the cable plugged in, swap the cable ends.
  2. #2 on, **holding SELECT+START with the retail cart inserted** (GBATEK
     "Multiboot Slave with Cartridge"): the BIOS stays in multiboot mode
     instead of booting the cart, and the cart bus (ROM, EEPROM, GPIO,
     SRAM window) is fully accessible to the uploaded program. This is the
     recommended way — no hot-insert needed.
     Fallback: #2 on with **no** cart, then hot-insert the cart after the
     payload is up (the payload never touches the cart until you press A).
  3. On #1: UP/DOWN to pick a payload, A to send. The status row walks
     `S1 FIND SLAVE` → `S2` → `S3 HEADER` → `S6 PALETTE` → `S8 SWI 25`.
     `FAIL Sn rrrr` shows the step and the last reply halfword (B aborts
     S1). The slave shows the Nintendo logo during S1-S8.
  4. On #2 the payload shows `INSERT CART - A`. Insert the cart now if you
     went the hot-insert route. Press **A** (EEPROM payload: A = 64 Kbit
     chip, B = 4 Kbit). The payload re-reads the header and compares the
     156 logo bytes at 0x08000004 with the copy in its own header (the one
     the slave BIOS verified); `NO CART - RETRY` loops until they match.
  5. `DONE - L/R PAGES`: L/R page through the 4 x 64-byte result pages.
     #1 meanwhile shows `SWI OK WAIT`, fetches the 256 bytes and shows the
     same pages (`GAPS=EE` in its status means some bytes never echoed;
     trust the photo of #2 for those).

Photograph every page of #2 (`P0`..`P3` in the title row), square-on, with
the four corner marks in frame. Rows are `NN` + 16 hex digits = bytes
`NN*8 .. NN*8+7` of the result slot; multi-byte fields are big-endian so
they read left to right.

Common to every payload: byte 00 = the multiboot boot-mode byte the slave
BIOS wrote at 0x020000C4 (expect **03** = multiplay; the cart-boot twins
show 00), byte 01 = slave number (expect **01**).

## Payload 1: EEPROM SETTLE

Cart: any EEPROM title. 64 Kbit (8 KB save; Boktai, most later titles)
or 4 Kbit (512 B; GBATEK's example is Super Mario Advance). Pick the width
at the gate: A = 64 Kbit (14 address bits), B = 4 Kbit (6 bits).

**What it writes.** The LAST block of the chip (address = all address bits
set: 0x3FFF / 0x3F — a 64 Kbit chip uses only the low 10 bits, and a
4 Kbit chip fed the 14-bit command takes its first 6 bits, so a wrong
width still hits the last block, with garbage in the 4 Kbit case). It
reads that block, writes the same 8 bytes back eight times, writes the
complement once, writes the original back, and reads it back to compare.
The save is left as it was found, but: every write erases and reprograms
the block (10 of the chip's ~100k cycles), and a power loss or a pulled
cart during the ~70 ms of writes loses that block. Do not run it on a save
you care about without a dump.

**Result layout**

| off | field |
|---|---|
| 03 | address bits used (0E or 06) |
| 04-0B | the block as first read |
| 10+8n | trial n = 0..7, unchanged write-back: u16 TM0:TM1 count when the command DMA had finished, u32 count when the ready poll first read bit 0 = 1 (FFFFFFFF = never within ~0.5 s), 2 pad |
| 50 | same for the CHANGED write (complement) |
| 58 | same for the write restoring the original |
| 60-67 | block read back after all writes; 68 = 01 if identical to 04-0B |
| 70 / 74 | u32 min / max of the eight ready counts |
| 78-7F | diagnostic read with the OTHER address width (done last: an incomplete command may leave the chip mid-stream) |

TM0 runs at prescaler 1 (16.78 MHz, one count per CPU cycle) with TM1
cascaded, zeroed immediately before the DMA3 that clocks the write command
in (2 + n + 64 + 1 halfwords, one bit each, WAITCNT 0x4317 = 8/8 WS2
clocks). The poll is `ldrh [0x0DFFFF00]; tst #1` from EWRAM, ~35 cycles
per iteration.

**What it pins.** `storage/eeprom.nim` `EEPROM_SETTLE_CYCLES = 108368`
(GBATEK "ca. 108368 clock cycles (ca. 6.5ms)") and the Assumed rule that
the window restarts at the LAST data bit. `ready − dma_end` is the settle
as seen from the end of the command; `ready − dma_end + (dma_end − first
data bit)` compares with the model's anchor. Whether a changed write costs
more than an unchanged one (a chip that skips erase on identical data
would show it) is row 50 vs 10..48.

**dingbat's prediction** (`./dingbat_test build/payload_eeprom_cart.gba
--mode=screenshot --screenshot=x.ppm --timeout=292` then
`python3 mbprobe_ocr.py x.ppm`; timeouts 100/164/228 show P1/P2/P3):
every trial `03AA 0001AB11` — DMA done at 938 cycles, ready at 109329
cycles, i.e. 108391 after the DMA ended = 108368 + one poll iteration.
Changed and restoring writes identical (`03AA 0001AB11`), readback OK
(`68 = 01`), min = max = 0001AB11, diagnostic 6-bit read on the 64 Kbit
model = FF FF FF FF FF FF FF FF (an incomplete command returns 1s).
Hardware giving e.g. 0x1A000-ish is the same constant; a spread across
trials, or a changed-write count well above the unchanged ones, is a model
gap.

## Payload 2a: TILT STATUS

Cart: Yoshi's Universal Gravitation / Topsy-Turvy (KYGE/KYGP/KYGJ) or Koro
Koro Puzzle (KHPJ). Read-only apart from the two start-conversion
registers. WAITCNT 0x4B17 (SRAM 8 clocks + PHI 4 MHz, both required by
GBATEK "GBA Cart Tilt Sensor"). Hold #2 flat and still.

| off | field |
|---|---|
| 03 | raw 0x0E008300 before any conversion (idle status byte) |
| 04-07 | raw 0x8200 / 0x8300 / 0x8400 / 0x8500 before any conversion |
| 08+6n | sample n = 0..15, one per frame after `55h→0x8000, AAh→0x8100`: u16 number of reads of 0x8300 with bit 7 = 0 before the first read with bit 7 = 1 (FFFF = gave up), raw 0x8300 (X high nibble \| status), raw 0x8200 (X low), raw 0x8500 (Y high), raw 0x8400 (Y low) |
| 68 / 6A | u16 min / max count; 6C = samples that gave up |

X = (b[2] & 0x0F) << 8 | b[3], Y likewise from b[4], b[5]. GBATEK's
example centre is X 0x392, Y 0x3A0.

**What it pins.** `bus.nim` `tilt_read`: bit 7 of 0x0E008300 is always
set (Assumed; conversion time undocumented). The counts are the
conversion time in ~9-cycle read units (8-clock SRAM access + loop from
EWRAM); byte 03 says whether the status bit idles ready or busy.

**dingbat's prediction:** idle `80`, idle raws `00 80 00 00`; every sample
`0000 83 92 03 A0` (count 0, X 0x392, Y 0x3A0); min/max 0000, 0 gave up.
Any non-zero count is the conversion time dingbat lacks.

## Payload 2b: GYRO EDGES

Cart: WarioWare: Twisted! (RZWE/RZWP/RZWJ). Read-only on the GPIO apart
from the start/clock pulses GBATEK's own `read_gyro` issues; rumble bit 3
is preserved. WAITCNT 0x45B7 (Wario's). Keep #2 still: the value should
be the "no rotation" ~0x6C0.

Per clock k the port (0x080000C4, low nibble; data is bit 2) is read
three times: with the clock still high (GBATEK's sample point), after the
falling edge, after the rising edge.

| off | field |
|---|---|
| 03-05 | raw 0xC4 / 0xC6 / 0xC8 after enabling the port (expect x, 0B, 01) |
| 08+3k | conversion A, clock k = 0..15: before-falling, after-falling, after-rising |
| 38+3k | conversion B, same |
| 68 / 6A / 6C | u16 A assembled from the before / after-falling / after-rising bits, MSB first (top nibble = the 4 dummy bits) |
| 6E / 70 / 72 | the same for B |
| 74+3k, A4/A6/A8 | conversion C with ~100 µs between edges, and its three values |

**What it pins.** `gpio.nim` `gyro_update`: the ADC shifts on the FALLING
edge (Assumed; Wario plays either way). Falling-edge shifting reads as
`after-falling == after-rising == next clock's before` and the 6A value
equal to 6C; rising-edge shifting reads as `before == after-falling` and
6C equal to the next-shifted 68.

**dingbat's prediction:** raws `00 0B 01`; A/B/C bit rows all follow
`02 00 02` (data 0) until clock 5, then `02 04 06 / 06 04 06 / 06 00 02
/ 02 04 06 / 06 04 06 / 06 00 02` for clocks 5-10, then data 0 — i.e.
0x6C0 = `0000 0110 1100 0000` appearing after each falling edge.
Assembled: before `0360`, after-falling `06C0`, after-rising `06C0` for
all three conversions. Hardware showing `0360 0360 06C0` instead is
rising-edge shifting; a value drifting between A, B and C is the ADC's
settling/aperture, which the model has no notion of.

## Payload 3: ROM MIRRORS

Cart: a Classic NES Series / Famicom Mini title (1 MiB, game code Fxxx),
or any small cart. Read-only; every read is a 16-bit LDRH, WAITCNT 0x4317.

| off | field |
|---|---|
| 04 | u32 first 32-byte-aligned ROM offset whose 16 halfwords equal the open-bus pattern `(addr/2) & 0xFFFF`, by binary search over 0..32 MiB assuming ROM-then-open-bus is monotone; `02000000` = none found |
| 0C-0F | game code from the cart header |
| 10+8n | 8 bytes at address n |
| 70+8n | 8 bytes at address n + 0x20 (a mirror shows ROM content; open bus shows the pattern advanced by 0x10 per halfword — the "echo" distinction) |
| D0 | u16, bit i = 32 bytes at 0x08000000 + (64 KiB << i) are open bus |
| D2 | u16, bit i = those 32 bytes equal the first 32 bytes of ROM (i = 0..9: 64K 128K 256K 512K 1M 2M 4M 8M 16M 32M) |
| D4 | raw LDRH of 0x0DFFFF00 (an EEPROM cart answers on bit 0) |

Address table n = 0..11: `08000000 08100000 08200000 08400000 08800000
08FFFFF0 09000000 09FFFFF0 0A000000 0BFFFFF0 0C000000 0DFFFFF0`.

**What it pins.** `cartridge.nim`: a 1 MiB image is mirrored 4x in a
4 MiB window, then the address pattern (Assumed from Classic NES Metroid
jumping into the mirrors). D0/D2 give the window directly; 04 gives its
end to 32 bytes; rows 0A/0C say what the WS1/WS2 regions return.

**dingbat's prediction** (1 MiB twin, no EEPROM): `04 = 00400000`;
addresses 0..2 = ROM start `37 00 00 EA 24 FF AE 51`; 0x08400000 and
0x08800000 = `00 00 01 00 02 00 03 00`; 0x08FFFFF0 and 0x09FFFFF0 =
`F8 FF F9 FF FA FF FB FF`; 0x09000000 = `00 00 01 00 ...`;
0x0A000000 and 0x0C000000 = ROM start (the 32 MiB wrap); 0x0BFFFFF0 and
0x0DFFFFF0 = `F8 FF ...`. The +0x20 set: ROM bytes `93 09 CE 20 10 46 4A
4A` for the mirrors, `10 00 11 00 12 00 13 00` for open bus. D0 = `01C0`
(4M, 8M, 16M open bus), D2 = `0230` (1M, 2M and the 32 MiB wrap equal the
base), D4 = `FF80`. On a real Classic NES cart with its 64 Kbit EEPROM,
0x0DFFFFF0 and D4 will show the EEPROM's bit 0 instead, and whether the
window is 4 MiB (D0 bit 6 set, 04 = 00400000) or the whole 32 MiB (D0 =
0, 04 = 02000000, D2 = 03F0) is the answer.

## Link protocol details (verified against GBATEK, not runnable in dingbat)

dingbat's HLE BIOS returns 1 ("failed") from SWI 25h and has no multiboot
receive path (`hle_bios.nim` `of 0x25`), so nothing below has been
exercised end to end. What has been checked:

- Sender initiation (`sender.s` S1-S7) follows the "Required Transfer
  Initiation in master program" table of GBATEK "Multiboot Transfer
  Protocol" line by line, multiplay mode, `y = client_bit = 02`, palette
  `D1`, `hh = 11h + cc1 + cc2 + cc3` with cc2/cc3 read from SIOMULTI2/3
  (FF when absent — the same values the slave sees on its bus).
- MultiBootParam offsets (disassembly checked): 14h handshake_data, 19h-1Bh
  client_data, 1Ch palette_data, 1Eh client_bit, 20h boot_srcp =
  image + 0xC0, 24h boot_endp; structure zeroed to 0x4C; `swi 0x250000`
  with r1 = 1 (multiplay). Transfer length = image − 0xC0, padded to a
  multiple of 16 and ≥ 0x100 (SWI limits).
- Multiboot image header (build.py `check_mb_header` + a separate byte
  check): logo bytes from `tests/roms/gbaedge.py` `LOGO`, `96h` at 0xB2,
  complement over 0xA0-0xBC, `B start` at 0x00 / 0xC0 / 0xE0, 0xC4 and
  0xC5 zero for the BIOS to fill.
- Every transfer waits for SIOCNT's start bit to clear, then ≥ 36 µs
  (GBATEK "Multiboot Communication"); S1 restarts with a 1/16 s delay on a
  non-`720x` reply, immediately after `0000`.
- Send-back (custom, both ends ours): parent sends `A0ii`, child answers
  `(ii<<8)|RESULT[ii]`; `AF00` → `AF00|STATUS`. The child's reply is
  latched at transfer start, so the parent repeats a request until the
  echoed index matches (200 tries × 200 µs, then `EE`).

What has been run in dingbat: all four payloads as cart-boot twins (the
predictions above come from those screens, read with `mbprobe_ocr.py`),
and the sender's menu/link-status display.

Untested assumptions to watch on hardware: the slave BIOS's tolerance of
the S1 retry timing; that a SELECT+START multiboot slave leaves the cart
bus fully readable (GBATEK says current models do); that a child's
SIOMLT_SEND update between parent transfers is picked up by the next
transfer (if the fetch-back reports `GAPS=EE`, the screen of #2 is the
record).
