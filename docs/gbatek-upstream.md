# gbatek-upstream: GBA corrections to send upstream, and what hardware must settle first

The GBA counterpart to `docs/pandocs-upstream.md`. Everything in §1 is
measured on Matt's AGB SP over the GB-Link rig (`tools/hwlink`), with the
payload that produces it named so anyone can reproduce the table rather than
take our word for it. §2 is not settled yet.

Each payload builds into a cartridge wrapper as well as a monitor payload
(`tools/hwlink/payloadcmp.py` does both), so a correction can be offered as a
self-contained test ROM. That is the useful unit: a ROM that prints a table
beats a prose claim, because the recipient can check it on their own silicon.

## 1. Upstream corrections (hardware-settled)

### 1.1 Open bus from Thumb code is not "the prefetched opcode"

GBATEK ("GBA Unpredictable Things", *Reading from Unused Memory*) says unused
memory "returns the recently pre-fetched opcode". For ARM code that is a whole
32-bit fetch and the statement is fine. For Thumb code a fetch is a halfword,
so something has to fill 32 bits, and what fills it depends on **the width of
the bus the code is being fetched over** — not on the instruction set and not
on the region being read.

`tests/roms/payloads/obusbus.s` copies the identical Thumb block into four
memories and runs it from each, so the rows differ in the memory executed from
and in nothing else. On an AGB SP, with the display on and again under forced
blank (so the OAM row is not the PPU competing for the bus):

| executing from | bus | unmapped read returns |
|---|---|---|
| IWRAM | 32-bit | the two most recent halfword fetches, each in the half **its own address bit 1 selects** — not in fetch order |
| EWRAM | 16-bit | the single halfword, mirrored into both halves |
| VRAM | 16-bit | the same mirroring |
| OAM | 32-bit | the whole aligned **word** containing the fetch |

Worked values from `obusprobe.s`, the same load at two addresses in IWRAM:
`0x030000F0` reads `3E0260A8` and `0x030000FA` reads `61283E02`, where `[$+2]`
is `3E02` in both and `[$+4]` is `60A8` and `6128`. A model that duplicates
`[$+4]` into both halves is right only when the two happen to be equal.

BIOS is the one region we cannot measure — a payload cannot execute there.

### 1.2 The post-DMA open-bus value is per-halfword, and ends at the next bus access

Two corrections, from `obuswin.s` (ARM) and `obuswint.s` (Thumb).

**What ends it.** The common description is that the DMA's last word survives
"until the next gamepak fetch". It is not the gamepak: a single `MUL` — one
instruction that touches no bus at all — already ends it, and it never goes
near the cartridge. It is also not "one instruction". What ends it is the
CPU's next bus access of any kind, opcode fetches included.

**How much of it survives.** It is not all-or-nothing. From Thumb code in
IWRAM, two NOPs after a burst, an AGB SP returns `DEAD6019`: the DMA word's
high half beside a freshly fetched opcode halfword. A DMA drives all 32 lines
and fills the latch; halfword fetches afterwards overwrite it one at a time,
each into the half its own address bit 1 selects — the same placement rule as
§1.1. Any model that answers "the whole DMA word" or "no DMA word" cannot
produce that value at all.

### 1.3 The H-blank DMA grant waits for the bus access in flight, and nothing else

Three payloads. `hdmasweep.s` runs the CPU on a 32-bit gamepak load at 8
waits, `hdmamul.s` replaces that load with a multiply — four internal cycles,
bus idle — and both sweep where in the CPU's work the H-blank request lands.
The multiply page is flat and the load page is not, so the grant tracks the
**bus cycle**, not the instruction: a request landing inside a multiply waits
for nothing.

`hdmastamp.s` measures the profile instead of inferring it, by reporting each
DMA's write raw rather than differencing the two, and sweeping a full loop
period. Over five runs, on the stable rows:

| pre-delay k | 19 | 20 | 21 | 22 | 23 | 24 | 25 |
|---|---|---|---|---|---|---|---|
| grant deferred by | 6 | 7 | 8 | 9 | 10 | 11 | 0 |

One cycle of wait per cycle of pre-delay, then a snap to zero — each extra
cycle of delay puts the request one cycle earlier inside the access, so the
grant waits one cycle longer, until it falls before the access and waits
nothing. Several such ramps interleave because the loop holds more than one
bus access, and the largest wait observed is 15, the length of the longest
access in that loop.

## 2. Not settled — hardware needed first

1. **BIOS-region Thumb open bus** (§1.1). No payload can execute from BIOS, so
   the one remaining row of that table is unmeasured. It would need a BIOS
   entry point that returns to caller-controlled code mid-fetch.
2. **A seven-cycle anchor discrepancy with no DMA in it.** `hdmastamp.s`'s
   control row times the interval from a timer start just after the VCOUNT
   158→159 edge to the cycle a poll loop first sees the H-blank flag. Hardware
   reads 1006 where dingbat reads 999. That is line geometry, timer enable
   latency, or the poll's own timing, and separating the three needs a payload
   that stamps each independently. Until it is understood, no *absolute* cycle
   claim anchored on this page should be published — see §3.

## 3. A note on method, and one for the mGBA suite

Two mistakes made and corrected in one day, both worth stating because both
are easy to repeat:

* **A difference does not pin its terms.** `hdmasweep`/`hdmamul` report the
  V-blank DMA's write *minus* the H-blank DMA's. Reading "hardware 227, ours
  226" as a statement about the H-blank grant attributed a difference to one
  of its terms; the cycle was in fact the V-blank DMA's. Worse, a difference
  is blind to a common-mode error — moving both grants together changes it not
  at all, and ours were out by several cycles without either page noticing.
* **An absolute stamp is only as good as its anchor.** Adding a no-DMA control
  row to `hdmastamp.s` turned an apparently clean six-cycle common-mode offset
  into an artifact of the anchor. A probe that stamps events against its own
  timer needs one measurement in it that the mechanism under test does not
  touch.

For the suite itself: **Misc "DMA Prefetch Break"** is a phase coincidence
rather than a measurement. The loop costs 36 cycles an iteration, an H-blank
DMA lands once a line, and the reported value is the read count at which the
two first coincide — so it moves by whole scanlines under sub-cycle changes
elsewhere. Logging the DMA-to-read phase offset for all 16384 reads and
evaluating every possible landing window offline shows the reachable exit
counts are **dense**: almost every integer is produced by some window. A row
whose expected value can be hit by many mutually exclusive models, and missed
by whole scanlines from a one-cycle change, is a fragile regression target as
written; a tolerance, or a formulation that reports the window directly rather
than a race outcome, would be a stronger test. Offered as a suggestion from
someone failing the row, not as a complaint about it.
