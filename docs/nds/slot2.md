# The GBA slot (slot 2)

What the DS's 32-pin GBA slot does in DS mode, what dingbat models, and the
evidence for each value. Code: `src/dingbat/nds/io/slot2.nim` (devices),
`nds.nim` `slot2_read`/`slot2_write` (ownership, bus widths), `timing.nim`
(access times). Tests: `tests/nds_slot2_test.nim` (`nimble test_ndsslot2`)
and our probe ROM `tests/nds/src/slot2_probe` (`tests/nds/tools/build_slot2.sh`).
Reference runs: docs/oracles.md, "NDS core".

## The hardware (GBATEK)

- **Map.** ROM region 0x08000000-0x09FFFFFF on a 16-bit bus, SRAM region
  0x0A000000-0x0AFFFFFF on an 8-bit bus, repeating every 64 KB. A GBA
  cart's backup chip moves from the GBA's 0x0E000000 to 0x0A000000; there are
  no WS1/WS2 mirrors. ("DS Cartridge GBA Slot")
- **EXMEMCNT / EXMEMSTAT (0x04000204).** Bits 0-1 SRAM access time, 2-3 ROM
  first access (10/8/6/18 cycles), 4 ROM second access (6/4), 5-6 PHI pin,
  7 slot owner (0 ARM9, 1 ARM7). Bits 0-6 are per CPU (each writes its own),
  bits 7-15 belong to the ARM9 and both read them. Bit 14 "writes appear to
  be ignored". ("DS Memory Control - Cartridges and Main RAM")
- **Ownership.** The owner sees the slot; the other CPU reads zeros over the
  whole 0x08000000-0x0AFFFFFF.
- **Open bus (no cart).** SRAM bytes read FFh (High-Z). ROM halfwords read
  address/2, "possibly ORed with garbage depending on the selected ROM access
  time": 6 and 8 cycles address/2, 10 cycles "Addr/2 OR FE08h (or similar
  garbage)", 18 cycles FFFFh.
- **Timing.** GBATEK's "DS Memory Timings" rows for GBA ROM/RAM are the
  default setting (ROM 10 + 6, SRAM 10); NDS times are total access times,
  so a GBA cart's N waitstates are (N+1)*2 DS cycles. EEPROMs can be read by
  DMA with the 6-cycle second access (4 fails).
- **Rumble Pak** (NTR-008, USG-006). Wires only VCC, GND, /WR, AD1, IRQ. AD1
  is pulled low on reads, the other AD lines are open bus, so GBATEK's
  detection is: every halfword i of 0x08000000..+1FFEh reads (i AND FFFDh).
  A write latches AD1; the actuator moves each time the latch changes.
  ("DS Cart Rumble Pak")
- **Memory Expansion Pak** (NTR-011, USG-007, for the DS Browser). 8 MB at
  0x09000000, STRH 1/0 to 0x08240000 unlocks/locks; detection = a write
  sticks only while unlocked. ("DS Cart Expansion RAM")
- **Boot info.** The firmware leaves header bytes of the GBA cart at
  0x027FFC30 (BEh-BFh, B5h-B7h, a flags byte, B0h-B1h, ACh-AFh); SDK games
  compare them with the slot to notice a pulled cart.

## What dingbat had before

`slot2_read` returned the empty-slot pattern for the owner and zeros for the
other CPU (already per GBATEK); writes were dropped; the slot timing was the
table's fixed default whatever EXMEMCNT said; the boot info said "no cart".

## What is built

| Piece | Model | Evidence |
|---|---|---|
| Ownership | EXMEMCNT.7; non-owner reads 0 and its writes are dropped | GBATEK; reference run (probe words 24-26, 38) |
| EXMEMCNT | bits 0-7, 11, 15 writable on the ARM9, 13 reads set, 14 stays set (writes ignored), the ARM7 writes only its bits 0-6 | GBATEK; reference run (words 36-37, 68-69) |
| Open bus | as GBATEK, by the reading CPU's own first-access setting; FE08h taken as the "garbage" | reference run, words 0-23, 27-35 identical |
| Timing | `SlotTiming` from each CPU's bits 0-4: halfword N = first, S = second, word = two halfwords, ARM9 +3 on nonsequential, ARM7 data -1 on nonsequential, SRAM one access per load whatever the width; reproduces GBATEK's table at the default setting | GBATEK; reference run: per-setting deltas identical on both CPUs (words 39-52) |
| 8-bit SRAM bus | a 16/32-bit load reads the byte repeated; a 16/32-bit store writes the byte its address selects | GBA rule (the GBA core, jsmolka save tests), Assumed for the DS |
| GBA cart | ROM image at 0x08000000; past its end open bus as an empty slot; backup chip from the GBA core's ROM-string scan (`gba/storage_chip.nim`: SRAM 32 KB, FLASH 64/128 KB with the GBA core's own command state machine, EEPROM); GPIO at 0x080000C4-C9 (data/direction/read-enable; bit 3 output high = rumble motor) | GBATEK; reference run (Emerald: words 0-23, 53-64, 77-79) |
| EEPROM | serial on bit 0 at 0x09000000+ (ROM up to 16 MB) or 0x09FFFF00+ (32 MB); the command's bit count when the next read arrives gives the chip size (9/73 bits = 4 Kbit, 17/81 = 64 Kbit); ready at once after a write (Assumed) | GBATEK "GBA Cart Backup EEPROM"; unit test only (no EEPROM cart was run) |
| Rumble Pak | open bus AND FFFDh; writes latch AD1, latch changes per frame give the strength (one = 64/255, +64 each) | GBATEK (detection loop finds all 1000h halfwords; libnds' FFFDh check at 18 cycles passes) |
| Expansion Pak | 8 MB RAM at 0x09000000, lock at 0x08240000 (starts unlocked; locked reads FFFFh, drops writes), byte stores ignored, header ID at 0x080000B0-BF, rest FFFFh | GBATEK for base/size/lock; the rest from the reference run only |
| Boot info | 0x027FFC30 filled from the cart header; FFh with no cart, but the flags byte (0x027FFC35) 00h | GBATEK boot-info list; the flags byte as the real firmware leaves it with an empty slot (the user's dumps, `--boot firmware`), and as the reference's direct boot has it |

API: `n.insert_slot2(kind, rom, save)` (`s2Empty`, `s2GbaCart`,
`s2RumblePak`, `s2ExpansionPak`; before the first instruction it is power-on
insertion and rewrites the boot info), `n.slot2_save()` (the cart's chip
bytes in the usual GBA .sav layout; `n.slot2.dirty` says when it changed),
`n.slot2_rumble()` (0-255). ndsrun: `--slot2 gba:FILE[,SAVE]` (the save is
written back when changed), `--slot2 rumble`, `--slot2 expansion`,
`--rumble-log`. wasm: `nds_insert_slot2`, `nds_slot2_save_{len,ptr,dirty}`,
`nds_rumble` (for `navigator.vibrate`, as the GB/GBA page uses
`wasm_rumble`). tools/ndsref gained `--slot2 FILE[,SAVE]` (the core's
two-cart subsystem) and `--rumble-log`.

## The end-to-end check: Pal Park in SoulSilver

SoulSilver reads the slot every few frames from both CPUs (header bytes B2h,
ACh-AFh, BEh, as in the boot info), sends the FLASH ID command
(SRAM at 18 cycles, EXMEMCNT bits 0-1 = 3) and reads the header block
0x08000000-0x080001FF. With Emerald (U) and its .sav in slot 2 the main menu
gains MIGRATE FROM EMERALD — but only for a save where the Pokedex tail has
two flags set: the menu code reads general-block bytes 15EEh and 15EFh
(Pokedex struct + 336h/337h) and nothing else in the tail. The New Bark
save used for development has them 0, so neither we nor the reference show
the option with it. With both set (and the block CRC fixed):

- Emerald + .sav: MIGRATE FROM EMERALD (frame 1520 of `START@700,
  START@1000, DOWN@1400, DOWN@1430, DOWN@1460, DOWN@1490`), the same as the
  reference core.
- FireRed (U) 1.0, no .sav: MIGRATE FROM FIRERED.
- no cart: the list ends at Wii MESSAGE SETTINGS.

Migrating itself (choosing the option, the transfer) has not been run.

## Left

- Not modelled: the GBA cart's RTC (S-3511 on GPIO: Ruby/Sapphire/Emerald;
  HGSS does not read it), solar/tilt/gyro sensors, the Guitar Grip, Paddle,
  Piano and Slider (AD8 motor) accessories, flashcart RAM/unlock schemes,
  the PHI clock output. libnds has drivers for the Guitar Grip, Paddle and
  Piano (they would read through `rom_read16` as open bus today).
- Hardware-unverified values (a run of `slot2_probe` on a DS would settle
  them): the FE08h garbage at 10 cycles (GBATEK's "or similar"), open bus
  past a GBA cart's ROM (the reference reads 0), SRAM-region reads with an
  option pak (FFh here, 00h on the reference), the Expansion Pak's header
  ID, power-on lock state and byte stores, the Rumble Pak at other timings
  (the reference reads FFFDh everywhere, which defeats GBATEK's loop), the
  boot-info flags byte.
- Timing: the slot deltas match the reference, but its absolute loop counts
  differ by a per-CPU constant that the main-RAM control shows is CPU fetch
  timing, not the slot (docs/oracles.md).
- Save states (another agent's topic) must add the slot: kind, ROM identity,
  chip bytes and FLASH/EEPROM state, GPIO, the Expansion Pak's RAM and lock.
- The web page does not insert a slot-2 device or call `nds_rumble` yet.

## slot2_probe result words

Top screen: 82 words, 4 per row, left to right; also at 0x02200100
(0x02200248 = 'SOT2' when done). After the run the Rumble Pak latch flips
once a frame for 30 frames. "10" etc. = ROM first access time set.

| Words | What |
|---|---|
| 0-19 | ARM9 owner, first access 10/8/6/18 then 10 with the 4-cycle second access: halfwords 0x08000000, 0x0800ABCE, 0x09FFFFFE, word 0x08000100 |
| 20-23 | SRAM: byte 0x0A000000, halfword 0x0A000002, word 0x0A000004, byte 0x0A012345 |
| 24-26 | ARM9 after giving the slot to the ARM7: halfword, word, SRAM byte |
| 27-34 | ARM7 owner, its first access 10/8/6/18: halfwords 0x08000000, 0x0800ABCE |
| 35-37 | ARM7 SRAM byte; ARM7 EXMEMSTAT (608Ch); ARM9 EXMEMCNT after writing 0080h |
| 38 | ARM7 not owning: halfword 0x08000000 |
| 39-44 | ARM9 timer ticks for 16 LDRH of 0x08000000: first access 10/8/6/18, 10 + 4, 6 + 4 |
| 45-48 | ARM9 ticks for 16 LDRB of 0x0A000000: SRAM 10/8/6/18 |
| 49-52 | ARM7 ticks for 16 LDRH, its first access 10/8/6/18 |
| 53 | GBATEK's Rumble Pak loop at 6 cycles: halfwords i (0..FFFh) reading i AND FFFDh |
| 54-57 | words 0x080000B0-BC |
| 58-62 | Expansion Pak halfword 0x09000000: as found, after a write, after unlock + write 5678h, after a byte store AB to 0x09000001, after lock + write 9999h |
| 63 | word 0x080000AC (game code) |
| 64 | FLASH ID (AAh/55h/90h): bytes 0x0A000000 / 1 |
| 65-67 | boot info words 0x027FFC30-3B |
| 68-69 | EXMEMCNT after writing FFFFh (E8FFh); ARM7 EXMEMSTAT after it writes FFFFh (607Fh) |
| 70-71 | SRAM byte after leaving ID mode; halfword 0x09000002 |
| 72-76 | Expansion Pak: unlock and read 0x09000000 (was the locked write dropped?), lock and read 0x09000002, halfword 0x09800000, halfword 0x08240000, word store/read at 0x09000010 unlocked |
| 77-79 | GPIO: word 0x080000C4 (low half) write-only; after C8h = 1; after direction 0Fh, data 05h |
| 80-81 | control: 16 LDRH of main RAM, ARM9 then ARM7 |
