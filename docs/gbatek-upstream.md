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

### 1.4 The scanline, and where the H-blank DMA's write lands in it

Both from payloads that start one timer, never stop it, and report only
differences between reads of it, so the timer's enable latency is common to
every stamp and cancels. That matters more than it sounds: the same
measurements taken against a timer started inside the payload disagreed with
hardware by seven cycles, and those seven cycles turned out to be the
payload's own polling loop landing one iteration later at two phases in
seven. An absolute cycle count from a probe of this kind is worth little.

`linegeo.s` stamps the VCOUNT 158→159 edge, the H-blank flag of line 159, the
VCOUNT 159→160 edge and the V-blank flag, all on one free-running timer. On
an AGB SP the scanline comes back bracketing **1232**, the H-blank flag
bracketing **1006**, and the V-blank flag simultaneous with the VCOUNT 160
edge to within the poll's resolution. GBATEK's numbers for all three are
confirmed — a corroboration, not a correction, and worth having because none
of the three had been measured here before.

`hdmageo.s` adds a second timer started immediately after the first and
frozen by the H-blank DMA's own write to its control register, so the DMA's
write is reported relative to the flag with nothing absolute in it. Over nine
runs the write lands **5 to 11 cycles before a polling loop first observes
the flag**: the grant is already committed by the time software can see the
flag at all. That is worth stating because a model that grants the DMA when
software could first notice the flag is consistently late. The bound is what
is solid; the distribution inside it is finer than the payload can address.

### 1.5 HALTCNT is BIOS-only, and the halt wake against the DMA grant

Two rows from `halthb.s` and a minimal halt probe, both on an AGB SP.

**`HALTCNT` (`0x04000301`) does not halt when written from ROM or RAM.** A
byte write to it from IWRAM leaves the CPU running on the same scanline;
`SWI 2` from the same place halts for 4931 cycles and returns four lines
later on a V-count match. GBATEK already restricts `0x04000300`-`0x04000301`
to BIOS access, so this corroborates rather than corrects it — but it is
worth a test ROM, because emulators disagree about it in both directions and
a game that halts by the wrong route will hang or spin depending on which way
the emulator errs.

**The H-blank DMA's grant against a halted CPU's wake.** With `IME` clear a
V-count match halt fixes the line exactly, and a second halt on the H-blank
IRQ leaves the bus idle, so the grant has nothing to wait on. Timing the
wake and the DMA's own write on one clock, the wake follows the write by a
constant **24 cycles**, identical on every sled offset and across four runs.
That is the grant's floor, and it is the cleanest number on this page: both
ends are hardware events and there is no software sampling between them.

### 1.6 What an H-blank DMA costs the CPU

`dmasteal.s` enters a chosen line by a V-count match halt, then runs a loop of
fixed iteration count across that line's H-blank, once with a DMA armed and
once without; the difference is the steal, with no poll anywhere to quantise
it. On an AGB SP a 16-bit DMA of N transfers between internal memories costs
**3 + 2N cycles**, and the figure is unchanged across source and destination
in IWRAM, EWRAM, VRAM, palette and OAM, and across 16- and 32-bit width, once
each region's own wait states are accounted for. Both emulators we compare
against agree on every row, so this is a corroboration rather than a
correction — recorded because the number is useful and because the method
(fixed-count loop, halted entry) is what makes it exact.

### 1.7 An empty cartridge slot, and code executed from it

With no cartridge, a **nonsequential** halfword read of the gamepak region
returns `addr >> 1` and a **sequential** one returns `0xFFFF`, at the reset
WAITCNT (4/2) -- `tests/roms/payloads/slotfloat.s`, identical over sixteen
runs. GBATEK gives the `addr >> 1` half only. Two consequences: `0xFFFF` is
the Thumb `BL` suffix, so a branch into the empty slot executes exactly one
chosen opcode and returns through `lr + 0xFFE` (`slotexec.s`), which makes
gamepak opcode timing measurable over a link cable; and the value read
*witnesses* whether the memory controller treated a fetch as sequential. At
other first-access waits the float is not reliable -- do not build on it.

Measured that way (`slotdma.s`), in the gamepak region at 4/2:

- the H-blank DMA's grant waits for the opcode fetch in flight, 0..4 cycles
  into a nonsequential fetch and 0..2 into a sequential one (1.3, now for
  opcode fetches);
- **the first gamepak access after a DMA is nonsequential** -- the fetch that
  should float to `0xFFFF` reads `addr >> 1`;
- an unmapped load reads the DMA's word only when the request fell in that
  load's own opcode fetch;
- a DMA requested during a data cycle runs *over* the internal cycle that
  follows it: the instruction ends a cycle sooner.

With the prefetcher on, twenty single-opcode timings match dingbat's model
and nine of them differ from mGBA's.

### 1.8 The V-blank interrupt is a cycle ahead of the V-count match

`tests/roms/payloads/vbwait.s`: IntrWait called from a fixed cycle returns
one cycle earlier when it waits on V-blank than when it waits on a V-count
match at line 160 -- the same line boundary, two sources, 2379 against 2378
on every run. Emulators that share one delay for both are a cycle out on one
of them.

## 2. Not settled — hardware needed first

1. **BIOS-region Thumb open bus** (§1.1). No payload can execute from BIOS, so
   the one remaining row of that table is unmeasured. It would need a BIOS
   entry point that returns to caller-controlled code mid-fetch.
2. **The grant's fine phase response.** §1.4 pins the window the H-blank
   grant lands in, and its bounds agree with hardware exactly. Inside those
   bounds the console reaches two phases we do not, so something resolves the
   grant against a phase finer than an instruction boundary. Unmodelled here,
   and not yet characterised well enough to state as a correction.

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
