@ eesettle4k.s -- eesettle.s for a 4 Kbit (512-byte) EEPROM cart.
@
@ The payload is eesettle.s unchanged; this file only gives the 4 Kbit
@ recording its own r0table row (tools/hwlink/r0table.py `eesettle4k`, called
@ with bit 8 set: 6-bit addresses), so a 64 Kbit cart's cells and a 4 Kbit
@ cart's never share a row. Never run it with a 64 Kbit cart in the slot:
@ a 6-bit write command is not a command that chip understands.
@
@ WHY: Klonoa - Empire of Dreams (4 Kbit) writes 15 blocks on entering
@ Vision 1-1, each polled to ready; dingbat (GBATEK's ca. 108368 cycles)
@ reaches the level two frames before both references, and with
@ -d:EEPROM_SETTLE_CYCLES=115005 it matches them pixel for pixel
@ (docs/playtest-bugs.md, "Klonoa: the clouds are the darken rounding, the
@ Vision 1-1 card is the cart's EEPROM").
@
@ RIG: as eesettle.s, with Klonoa's cart (or another 4 Kbit EEPROM cart) in
@ the slot: boot holding SELECT+START, install the monitor, then
@ `python3 tools/hwlink/r0table.py --record eesettle4k`.
@
@ PROVENANCE: dingbat and mgba as eesettle.s's 6-bit cells (r0table.py
@ eesettle4k 0x103 0x102 0x100 0x101 --emulators-only). Console: not yet run.
    .include "eesettle.s"
