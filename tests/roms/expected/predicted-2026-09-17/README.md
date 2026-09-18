# dingbat predictions for the gbaedge probes — 2026-09-17

**Not hardware.** `pages.txt` is what dingbat produces for all 54 gbaedge
pages at this date, in `hwprobe_expected.py`'s transcription format, HLE BIOS,
`-auto` build. Hardware truth lives in the `agb-sp-*.txt` files.

This directory exists because `predicted-2026-09/` is what dingbat said
*before* sessions 5 and 6 ran, which is the record those sessions were
diffed against and must not be overwritten. Four pages have moved since,
and the reasons are worth keeping apart:

| page | 2026-09 | now | why |
|---|---|---|---|
| 27 DMAOPENBUS | 8A4F | **2CB2** | a model fix, and the new value **is** the AGS column: a DMA's word is open bus only for the CPU's first access after the burst (`55c79b9fb`) |
| 2D MEMCTL | 5EC2 | B63F | not a model change — the pre-`78d2a5631` build gives the same B63F on today's ROM |
| 2F IWCYCLE | 06BC | 7DD7 | the same, and this page documents itself as drifting with accumulated boot phase |
| 31 UNDMODE | 25D2 | EFA2 | the same |

Only the first is dingbat answering differently. The other three moved with
the ROM and with emulator changes that landed between the two captures — the
viewer's own start frame moved from 188 to 552 over the same period, which is
the same drift seen from outside. Verified by capturing those four pages from
both builds against one ROM: they agree except DMAOPENBUS.

Pages 32-35 (HDMAPHASE, PSGFIRST, PSGWHY, HDMASWEEP) are new since, and 32/33
have hardware columns in `agb-sp-6.txt`.

Regenerate rather than diff an old capture against a new build:

    python3 tests/roms/hwprobe_capture.py ./dingbat_test tests/roms/gbaedge-auto.gba <outdir>
