@ eestray4k.s -- eestray.s for a 4 Kbit (512-byte) EEPROM cart.
@
@ The payload is eestray.s unchanged; this file only gives the 4 Kbit
@ recording its own r0table row (tools/hwlink/r0table.py `eestray4k`, called
@ with bit 8 set: 6-bit addresses), so a 64 Kbit cart's cells and a 4 Kbit
@ cart's never share a row. Columns Crown (ACGE, the game that asked the
@ question, docs/playtest-bugs.md §95) is a 4 Kbit cart whose save fills
@ both blocks the payload compares. On a 64 Kbit chip a 6-bit request is
@ only part of a command: the cells mean nothing there, though they still
@ write no 0 but a request's last bits (eestray.s, SAFETY).
@
@ RIG: as eestray.s, a 4 Kbit cart in the slot:
@ `python3 tools/hwlink/r0table.py --record eestray4k --cart=<game code>`.
@
@ PROVENANCE: as eestray.s's 6-bit cells (r0table.py eestray4k
@ --emulators-only). Console: not yet run.
    .include "eestray.s"
