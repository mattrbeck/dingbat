# dbsuite — GBA behaviour as a real GBA SP shows it

One ROM, a menu of suites, many cases each. Every case prints PASS or FAIL
with the value it got and the value the hardware gave, and every expected
value comes from a measurement on a real **GBA SP (AGS-001)**: photographed
probe pages (`tests/roms/expected/agb-sp-*.txt`), link-rig tables recorded
off the console (`tools/hwlink/*-agb.json`), or rig runs noted in the
project history. The idea and the output format follow the mGBA test suite;
the cases are this project's own measurements.

`dbsuite.gba` is the cartridge build. `dbsuite.mb.gba` is the same body as a
256 KB-or-smaller multiboot image. It runs from EWRAM, so it can go to a
console over a link cable with no flashcart. It also boots as a cartridge,
so an emulator without multiboot support can run it too. In the multiboot
build, cases that measure the cartridge bus or time code fetched from the
cartridge are reported `SKIP`.

## The suites

| suite | cases | what |
|---|---|---|
| cpu | 102 | PSR write masks, Thumb `cmp/add/mov pc`, MSR setting T, loose BX decodes, r15 base writeback, user-bank STM/LDM, the LDM^ glitch, empty register lists, the multiply carry flag and timing, undefined CPSR modes |
| irq | 42 | the dispatch window after IME/IE/`msr`, interrupt latency per source, the IF-acknowledge race, a timer IRQ storm under a DMA burst, the halted CPU's wake, the V-count match edge |
| timer | 14 | start latency, back-to-back reads, cascade, reload writes, a read against a stop |
| dma | 125 | the CNT_H byte-write anomaly, capture DMA, start delays and per-region burst costs, the completion IRQ against a running CPU, the H-blank DMA's grant against every instruction phase, immediate-DMA length, DMA from unmapped memory reading the data bus |
| bus | 79 | unused/write-only IO read map, 0x04000800 and its EWRAM wait field, renderer contention on PRAM/VRAM/OAM, cartridge-window wait states, open bus from ARM and Thumb in four memories and after a DMA |
| ppu | 156 | DISPSTAT byte writes; the whole `DMA Prefetch Break` path (V-blank IRQ, BIOS VBlankIntrWait, a table-walking dispatcher, an H-blank DMA), DISPSTAT edges against VCOUNT |
| apu | 23 | channel 1's sweep at trigger and at its ticks; the first trigger after a PSG master-on |
| bios | 24 | Div, DivArm, Sqrt, ArcTan and ArcTan2 answers at their edges, GetBiosChecksum |

`cases.json` lists every case: its index, suite, name, what the check
compares (offset, mask, expected value or range), and whether it is
cartridge only. `build.py` writes it from the built image.

Each case's source comment states **what** it tests, **why** (the emulator
behaviour it catches), and **provenance** (the device, the date, how the
number was obtained). Where hardware answered with a spread (jitter),
the case checks a range and says so. Where the recorded value depends on
this ROM's own code bytes (the opcode an open-bus read returns, the address
an empty-list STM stores), the case checks the measured *rule* against its
own code.

## Running

```
python3 tests/roms/dbsuite/build.py         # rebuild (arm-none-eabi-*, gbafix)
python3 tests/roms/dbsuite/run.py [--mb] [--bios=PATH] [--all]
```

`run.py` drives `./dingbat_test <rom> --mode=mgba-suite`. The run stops at
the ROM's `DBSUITE ALL DONE` line. The script prints each case that is not a
pass and the per-suite totals. `tests/dingbat_test_runner.nim` scores the
cartridge image as the suite **GBA - dbsuite (AGS-001)**: one row per
sub-suite in `tests/results.md`, and every non-passing case in
`tests/results_dbsuite.md`.

On the console: `python3 tests/roms/dbsuite/run.py --sp OUT.json` uploads
the multiboot image over the link rig (`tools/hwlink`). It follows the ROM's
progress beacons, reads the results block back, and reinstalls the monitor.
Take the rig's lock first.

## How the ROM behaves

- **Auto-run.** The menu counts down 2.5 s and then runs every suite, unless
  a key is pressed. `rom_config` (the word at `0x080000C4`, the body's second
  word in the multiboot image) can be patched: bit 0 runs everything at once,
  with no menu; bit 1 never auto-runs.
- **Menu.** A runs the selected suite, START runs everything. After a run,
  the summary lists each suite and the first failures. A on a suite opens
  every case, with got and expected. B goes back.
- **Watchdog.** Each case runs from a known machine state: IME/IE/IF,
  timers, DMA, WAITCNT, 0x04000800, sound, SIO, DISPSTAT, the display and
  the IRQ vector are all reset. TM3 at /1024 is armed as a 4-second watchdog.
  A case that hangs with interrupts open reads `TIMEOUT`, and the run goes
  on. A case that resets the machine (a jump to 0, a BIOS handler that
  reboots) is found at the next boot: the results block still says running,
  so that case reads `CRASH` and the run resumes at the next one. A case
  that hangs with interrupts masked cannot be taken back from inside the
  machine. The results block then says RUNNING and names the case in flight,
  and the screen keeps its white verdict block and red RUNNING banner.
- **Verdict pixel.** A 4x4 block at (236..239, 156..159) stays white until a
  run finishes. It then turns green (`0x03E0`) if nothing failed, timed out
  or crashed, and red (`0x001F`) otherwise. Sample pixel (239,159).

## Output channels

**mGBA debug registers** (0x04FFF780 = 0xC0DE, then read back 0x1DEA; the
string goes to 0x04FFF600, and 0x0103 is written to 0x04FFF700) and the
**no$gba debug port** (used when 0x04FFFA00 reads `no$g`; a pointer to the
string is written to 0x04FFFA10). Both are probed at boot and used only if
they answer. One line per case, then one line per suite and a total:

```
DBSUITE begin version=1 cases=565 first=0 end=565 mode=cartridge
DBSUITE case cpu/psr-f-field-sets-nzcv PASS got=F000001F exp=F000001F
DBSUITE case irq/irqwin-if-ack-race PASS got=00000008 exp=00000006..0000000A
DBSUITE case bus/obuswin-1-nop-dma-word FAIL got=E59F0170 exp=DEADBEE3
DBSUITE case apu/sweep-512-dies-tick-3 SKIP got=- exp=00002A00..00004000
DBSUITE suite cpu pass=102 fail=0 timeout=0 crash=0 skip=0 total=102
DBSUITE done pass=541 fail=24 timeout=0 crash=0 skip=0 total=565
DBSUITE ALL DONE
```

`exp=A..B` is a range and `exp=A|B` is two accepted answers. `got=-`
means the case produced no value (SKIP, TIMEOUT, CRASH).

**Link cable.** After a run the results block is streamed in the protocol
of `tests/roms/linkreport.inc`: `'LRPT'`, a word count, the words, repeated.
Read it with `python3 tools/hwlink/gblink.py report`. While the suite runs,
each case first arms a 32-bit slave transfer carrying `0xDB000000 | case
index` (no interrupt), so a host that keeps clocking can tell where a run
stopped. `0xDBFF0001` means booted and `0xDBFF0002` means in the menu. Once
the results stream is going, a host word of `'BOOT'` (0x424F4F54) makes the
ROM call the BIOS's HardReset, which returns an empty-slot console to the
multiboot wait loop.

## Results block

At **0x02014000** in EWRAM, in both builds. All fields are little-endian.
`RB_DONE` is written last.

| offset | field |
|---|---|
| +0x00 | magic `0x55534244` ("DBSU") |
| +0x04 | version (1) |
| +0x08 | done: `0x454E4F44` ("DONE") once a run has finished, 0 while running |
| +0x0C | state: 0 idle, 1 running, 2 finished |
| +0x10 | flags: bit 0 = multiboot build |
| +0x14 | number of cases N |
| +0x18 | number of suites |
| +0x1C | case in flight (0xFFFFFFFF none) |
| +0x20 | totals: pass, fail, timeout, crash, skip, not run (6 words) |
| +0x38 | crash-resumes taken this run |
| +0x3C | one past the last case of this run |
| +0x40 | 16 suite records, 16 bytes each: pass, fail, timeout, crash, skip, total, first case, case count (u16 each) |
| +0x140 | N case records, 16 bytes each: status (u8: 0 not run, 1 pass, 2 fail, 3 timeout, 4 crash, 5 skip), suite (u8), check kind (u8: 0 range, 1 one of two, 2 slot-relative), 0; got (u32); expected lo (u32); expected hi (u32) |

Case *i*'s name, suite and check are entry *i* of `cases.json`.

## Memory map

Cases keep scratch in 0x02000000-0x02013FFF (the link-rig payloads' own
addresses: results at 0x02008000, DMA buffers at 0x02010000 and 0x02020000).
The results block is at 0x02014000, runtime state at 0x02018000, and the
multiboot body runs at 0x02024000 (`mbstub.s` copies it there). Payloads run
at 0x03000000, and copied blocks at 0x03000200.

## Provenance and what is not here

- The **hwverified** experiments (`tests/roms/hwverified/*.s`) come over
  with their code. The **gbaedge** pages come in where their cells do not
  depend on the probe ROM's own layout: LDMSTM, MULFLAGS/MULTIME, UNDMODE,
  MEMCTL, TIMERS, PSGFIRST, IOBYTE2, DMATIME, CONTEND2 and IRQDECOMP. The
  last three ran with the IRQ stack in EWRAM (two earlier gbaedge pages moved
  it and never put it back). Their ports recreate that, because the BIOS
  dispatcher's push and pop are part of every latency.
- The **link-rig payloads** are carried byte for byte and run at 0x03000000,
  as the rig's monitor ran them: `tests/roms/payloads/*.s` and
  `payloads/*.s` here. The latter are copies of the 2026-09-24 session's
  probes; each header gives the console's answers and any address moved
  out of the multiboot body's way. The `r0-agb.json` and `breakram-agb.json`
  tables become cases at build time.
- **Left out on purpose:**
  - the BXDECODE candidate 0xE120FF11, which wedges a console;
  - BIOS-protection and boot-time open-bus values, which are BIOS bytes;
  - the power-on prescaler phase and `bootio`'s cartridge-entry IO state,
    which depend on what ran before;
  - pages whose cells encode gbaedge's own code layout (OPENBUS, DMALATCH);
  - phase-dependent rig pages whose rows move between runs (hdmageo,
    hdmasweep, hdmastamp, linegeo, timergeo, psgwhy);
  - the empty-slot execution payloads (slot*), which need an empty cartridge
    slot and an emulator image with planted words;
  - SIO: nothing single-console has been measured, and a transfer with the
    internal clock would drive the link line against the adapter;
  - visual pages (OBJBUDGET/OBJGEOM, blend), which need a camera, not a CPU
    read.
