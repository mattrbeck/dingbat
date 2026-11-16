# Playtest bug investigations

Bugs the cross-emulator playtest harness (tools/playtest) found in dingbat:
one short entry per investigation, giving its status, cause and fix.

The full dated working notes for §1-§107 are in git, not the tree:

    git show 95f590ce:docs/playtest-bugs.md

Where an entry's title differs from its heading there, the entry gives that
heading ("Notes:"), so a reference by number or by heading lands here; a
reference to an item or a table inside a section is only in the notes.

To add an investigation: take the next number and write a short entry here in
the same shape. Put the working notes (what was tried, traces, tables) in the
commit message of the change that settles it, not in this file.

## §1. Sonic Advance 1 + 2 hang on grey bars at boot

**Status:** FIXED (commit not stated) · **Date:** 2026-09-16, 2026-09-17

The skip-BIOS boot left RCNT at 0; the real BIOS leaves it in general-purpose mode (bit 15 set). The fix sets RCNT at skip-boot, and both games now pass their playtests. A full diff of skip-BIOS against dingbat's own real-BIOS boot at ROM entry then found five differences, all fixed: RCNT (the BIOS's last write is 0x8000; it reads back 0x800F because bits 0-3 read the pins), SOUNDCNT_H = 0x000E, wave RAM cleared, LR = 0x08000000, and the entry video phase 14 cycles earlier (line 126, 838 cycles, with the first two ROM words already fetched). Open: Sonic Advance 2's save differs from mGBA's in 28 bytes, not examined. Unsettled against hardware: `tests/roms/bootio.gba` shows dingbat and mGBA differ on the RCNT data nibble, the RCNT pin readout per mode, and SIODATA32_L/SIOMULTI2 readback in normal 8-bit mode.

## §2. Save state with a game-set clock fails to load (RangeDefect)

**Status:** FIXED (commit not stated) · **Date:** not stated

Rockman EXE 4.5 sets its clock to 2006, earlier than the harness's source clock, so the RTC bias is negative. The writer wrapped it into a u64 and the reader's checked `int64(u64)` conversion raised. Fixed with casts on both sides; `tests/gba_rtc_test.nim` covers a negative bias. The bias code existed only on that branch, so no released save state is affected.

## §3. Rockman EXE 4.5 never saves (SRAM picked over FLASH512)

**Status:** FIXED (commit not stated) · **Date:** not stated

The ROM names both an SRAM and a FLASH512 save library, and dingbat picked SRAM; the game only sends a flash ID command and then waits on flash. Fix (storage.nim): SRAM plus a flash library without EEPROM now selects that flash type; `tests/savestate_compat_test.nim` covers the pairs and the harness's `saves.py` mirrors the rule. The playtest passes, all 9 cross-loads work, and 9 bytes differ from mGBA's save. The section also lists the other ROMs in the 7906-ROM library that name more than one save library and what each does at boot; Ueki no Housoku and Breath of Fire (J) were left unchanged (EEPROM).

## §4. Yu-Gi-Oh! 2004 deck and Harvest Moon farm differ on identical input

*Notes: "Random outcomes differ on identical input frames (Yu-Gi-Oh! 2004 deck)"*

**Status:** PARTLY FIXED (boot video phase, 9a3c7b7cd); the one-frame lag left OPEN here, later attributed to the references (§7, §29) · **Date:** 2026-09-17 (earlier part undated)

Not an RNG bug: the seed sequence (IWRAM 0x03000040) is identical, but dingbat reaches each value one frame later than mGBA. One real bug was found and fixed: the skip-BIOS boot started the PPU on line 0 instead of line 126, 838 cycles in. The lag itself is not a boot-phase offset: shifting the phase from -800 to +130 cycles never moves it. Instruction-by-instruction cycle counts agree with mGBA until the game writes WAITCNT 0x4014 (prefetcher on) at instruction 82,689; after that dingbat runs about one cycle per 17 instructions slower. §7 later shows mGBA is the one running too fast there, so the "dingbat drifts slow" reading in this section is backwards. Harvest Moon FoMT's `farm_intro` failure (random debris laid out differently, save differs in 4051 bytes) is the same effect. After the phase fix Yu-Gi-Oh! 2004 and Mario Golf AT pass their checkpoints but their saves still differ from both references (107 and 4 bytes).

## §5. Boktai: "Solar Sensor is broken."

**Status:** FIXED (commit not stated); one item OPEN · **Date:** not stated

The GPIO solar sensor was missing. It is now implemented in gpio.nim for game codes U3I*/U32*/U33* following GBATEK: bit 1 resets a counter, rising edges on bit 0 count, and bit 3 reads 1 once the counter reaches `solar_level` (default 0xE8 = no sunlight). `tests/gba_rtc_test.nim` covers dark and bright readings. Open: no desktop or web control for `gpio.solar_level`, so the in-game sun gauge stays at zero.

## §6. Fire Emblem: The Sacred Stones, one-step colour on two menus

**Status:** NOT A DINGBAT BUG (blend rounding plus the references' lag-frame phase; resolved in §92) · **Date:** 2026-09-17, resolved 2026-10-15

At `select_mode` and `slots_empty` dingbat's picture differs from both references. The composite's inputs (VRAM, palette, OAM, PPU registers, per-line BG2HOFS writes) are the same game state in all three emulators, a few frames apart. Rendered per layer, dingbat's frame gives each reference's picture when that reference's blend formula is applied, so the difference is §72's blend rounding (dingbat truncates, as the SP photographs do) over an animation phase. The phase comes from lag frames: mGBA's cheaper gamepak code under the prefetcher (WS0 3/1) avoids five that dingbat takes. Open: dingbat and the second reference differ by one lag frame, a 3/1 prefetch-cost question not yet measured on the console. Exact-frame comparison cannot judge these screens: no two emulators ever draw an identical frame there.

## §7. Prefetch: Thumb multiplies from ROM cost 340 in dingbat, 212 in mGBA

*Notes: "Prefetch: Thumb code with internal cycles (the Yu-Gi-Oh residue)"*

**Status:** HARDWARE-CONFIRMED that mGBA is wrong; dingbat's own number unmeasured here · **Date:** not stated

`tests/roms/prefetchbench.{s,py}` times nine instruction patterns at four wait settings; eight agree between dingbat and mGBA. The ninth, 64 Thumb multiplies fetched from ROM with the prefetcher on at 3/1, costs 340 cycles in dingbat and 212 in mGBA. The same block run from IWRAM costs 317 cycles on hardware, dingbat and mGBA (`tests/roms/payloads/thumbmul.s`, `tools/hwlink/payloadcmp.py`), so mGBA's 212 is below a measured floor and cannot happen on hardware. This reverses §4's reading: mGBA runs the Yu-Gi-Oh code too fast. dingbat was not changed; its 340 was unmeasured in this section because that needs code fetched from a cartridge (§22 later checks the prefetch-on model against the console). The wait-state path (`waitcnt.s`) matches hardware on all six settings.

## Suite snapshot, 2026-09-17 (unnumbered)

**Status:** SNAPSHOT (no bug of its own) · **Date:** 2026-09-17

Of 52 ready scripts, 46 pass and 6 fail; 19 `@status wip` scripts still need a human to play to a first save. Failing: Fire Emblem Sacred Stones (§6), Harvest Moon FoMT (§4), Advance Wars `02_mark` and Mario & Luigi `07_mark` (not traced at the time; see §35 and §34), Wario Land 4 `difficulty` (palette-cycle animation, known), and Dragon Ball Z: The Legacy of Goku (plays identically, but a reference's save read back in dingbat differs). Advance Wars and Mario & Luigi fail identically on the commit before that session, so they are not regressions.

## §8. Boot sweep of the whole library: Yu-Gi-Oh EDS and Donkey Kong Country 2

*Notes: "A second net: every game, no script"*

**Status:** OPEN (DKC2 needs a visual hardware probe; Yu-Gi-Oh EDS is traced in §33) · **Date:** not stated

`tools/playtest/bootsweep.py` boots each game in three emulators for 40 seconds with no input and counts frames one emulator drew that the others never drew; `triage` ranks flags by how often the two references agree byte for byte. With 659 of 2,297 titles swept, two findings were worth a person's time. Yu-Gi-Oh! The Eternal Duelist Soul: 1,813 odd dingbat frames in 2,400; only the scrolling grid behind the title differs. Donkey Kong Country 2 (E): 208 odd frames, about 300 pixels each, all on BG1, which DMA0 scrolls per line (H-blank, repeating, two halfwords to 0x04000014). The differing lines (119, 127, 135 at driver frame 549) are exactly where BG1's vertical offset changes, so the question is which line a per-line vertical scroll write takes effect on. Ruled out for DKC2: grant count (exactly 160 per frame), the grant instant (identical result with the request at cycle 960 and 1008), blending, and a horizontal shift. Nothing was changed; settling it needs a photograph of a BG with a sharp horizontal edge whose vertical offset toggles every eight lines. Not findings: R-Type III (the references never agree with each other), the four Sonic "2 Games in 1" compilations, X-Bladez (sub-perceptual), two Pokemon Ruby hacks.

## §9. dingbat_test and the playtest driver disagree on the same core

*Notes: "Two harnesses on the same core disagree"*

**Status:** FIXED (commit not stated; "fixed upstream") · **Date:** not stated

On Donkey Kong Country 2 the two harnesses gave identical frames at 10 and 30 and fully different ones from 60. There was no core divergence; there were three harness defects. `--nosave` did not detach a GBA battery, so `dingbat_test` loaded the `.sav` beside the ROM. `dingbat_test` wrote GBA screenshots in greyscale. And the frame mapping is `--timeout` = driver frame + 1. With those fixed the harnesses agree to the pixel. Trap that remains: `dingbat_test` writes its battery file beside the ROM, so point it at a symlink or pass `--nosave` when using the read-only library. Per-layer figures taken before these fixes are void.

## §10. Hardware run of six queued payloads on the SP

*Notes: "The hardware run, 2026-09-18"*

**Status:** HARDWARE-MEASURED (details and follow-ups in §12, §14) · **Date:** 2026-09-18

Summary of one link-cable session. `waitprobe`: an empty cartridge slot honours WAITCNT, cycle for cycle the same as both emulators, so wait states belong to the memory controller and can be measured with no cartridge. `hdmasweep`/`hdmamul`: the H-blank DMA grant waits for the CPU's bus access in flight and not for the instruction; dingbat modelled no deferral and read 226 where hardware reads 227. `swiedge`: all 24 HLE BIOS arithmetic answers match the real BIOS. `psgfirst`/`psgwhy`: hardware disagrees with both emulators at five sound-channel tests (see §12). Also fixed: `open_link` failed 22 of 25 cold opens, reading `FFFFFFFF`; it now probes with word 0x6202 and retries the whole sequence up to 40 times.

## §11. Empty-slot reads, the IWRAM prefetch floor, and Thumb open-bus composition

*Notes: "Two more from the rig, 2026-09-18"*

**Status:** Thumb open bus FIXED (commit not stated); post-DMA open-bus window OPEN here (see §13) · **Date:** 2026-09-18

An empty slot returns `addr >> 1` on the first halfword of a read and `FFFF`/`FFFE` on the sequential one. This section concluded that code cannot be run from an empty slot and prefetchbench needs the flashcart; §22 later found a way, so that conclusion is wrong. `pfram.s` (prefetchbench's eight subjects from IWRAM, four wait settings) matches on hardware, dingbat and mGBA in all 32 cases, and shows the prefetch buffer does not serve data loads. `obusprobe.s` (reads of unmapped 0x10000000): for Thumb code in IWRAM, each of the two most recent fetches (`$+2`, `$+4`) lands in the half of the bus latch its own address bit 1 selects; dingbat duplicated `[$+4]` into both halves. Fixed for the 32-bit-wide regions only (§12 refines which); on a 16-bit bus the duplicate is correct. Open: hardware keeps a DMA's last word on the bus for exactly one instruction after the burst; dingbat holds it one instruction too long, mGBA releases it one too early.

## §12. Checking §11's assumptions: open bus by region, H-blank grant rule, PSG, SWIs

*Notes: "Checking what section 11 assumed, 2026-09-18"*

**Status:** HARDWARE-CONFIRMED; OAM open bus FIXED (commit not stated); grant deferral and PSG sweep behaviour not modelled at this point · **Date:** 2026-09-18

`obusbus.s` ran the same Thumb block from four memories. The rule is how much of the latch one fetch fills: a 16-bit bus (EWRAM, VRAM, cartridge) mirrors `[$+4]` into both halves; IWRAM drives only the half its address selects; OAM returns the aligned word holding `$+4`. dingbat had OAM in IWRAM's case; fixed. BIOS is unmeasured and stays with IWRAM. `hdmasweep.s` and `hdmamul.s` settle the grant rule: the H-blank DMA grant waits for the CPU's bus access in flight (a stable 11-cycle deferral at one phase of an 8-wait ROM load) and waits for nothing during internal cycles (a multiply loop reads 227 flat). dingbat read 226 flat on both; the missing cycle and the deferral are followed up in §14, §25 and §26. `psgwhy.s`: channel 1 triggered with a sweep that overflows (`f + f` reaching 0x800, e.g. f = 0x400) enables and is then killed at once; both emulators either keep it on or never enable it. Six of that page's fifteen tests vary between runs and are not reported. `swiedge.s`: 0 of 96 bytes differ between the HLE BIOS and Nintendo's (Div, Sqrt, ArcTan2 edge cases, GetBiosChecksum `BAAE187F`); SWI cycle costs remain open (Sqrt up to 3x off).

## §13. The post-DMA open-bus latch, measured

*Notes: "The post-DMA open-bus latch, measured, 2026-09-18"*

**Status:** HARDWARE-MEASURED; prototype `-d:obuslatch` built, off by default; did not close `DMA Prefetch Break` · **Date:** 2026-09-18

`obuswin.s` (ARM) shows the DMA's word stays on the bus only until the CPU's next bus access, opcode fetches included; one MUL with no bus access already closes it, so it is neither "one instruction" nor "until the next gamepak access". `obuswint.s` (Thumb) shows the latch is per halfword: two NOPs after the burst hardware reads `DEAD6019`, half DMA word and half fresh opcode. dingbat's `read_open_bus_value` is an all-or-nothing predicate and cannot produce that; tightening its lower bound fixes the ARM cases but breaks the passing `DMA Prefetch Read` test. `-d:obuslatch` replaces it with a real 32-bit register (`Bus.obus_latch`, `obus_half_at`); it is neutral on the mGBA suite and the runner, but all three post-DMA cases are late by exactly one opcode fetch, because dingbat charges fetches lazily per instruction rather than ahead of execution. Trap: `dingbat_test_runner` does not rebuild `./dingbat_test`; a stale binary produces stale results, so rebuild before trusting a runner number.

## §14. `DMA Prefetch Break`: open-bus window bounds cannot close it

*Notes: "`DMA Prefetch Break`: what the window cannot do, and what can, 2026-09-18"*

**Status:** SUPERSEDED (test resolved in §23/§25); one real bug FIXED here (commit not stated) · **Date:** 2026-09-18

The mGBA suite test arms a one-word repeating H-blank DMA3 and spins a 36-cycle Thumb loop in ROM reading unmapped memory until a read is not the prefetched opcode; expected `0x10002A94` (2725 reads), dingbat `0x10002540`. A 13x13 sweep of the open-bus window bounds reaches only three values, none the target; the second reference gives dingbat's value and mGBA 0.10.5 gives `0x100024B8`. Moving the H-blank DMA request from 2 to 9-12 cycles after the flag passes the whole suite, but p50 HDMAPHASE's absolute stamps refute that shift. `hdmamul` measures only the difference between the V-blank and H-blank DMA writes and cannot see a shift common to both. The V-blank DMA request was set to flag+1 here to make hdmamul read 227; §25 shows that was wrong (both requests are flag+2 and the H-blank flag itself is a cycle later). A prototype `Bus.access_end` deferral reproduced the "load varies, multiply flat" shape but not the magnitudes and was not merged. Fixed: `end_frame` did not rebase `Bus.dma_request_at`, which held the open-bus window shut for a frame.

## §15. The H-blank DMA deferral is a ramp, not a constant

*Notes: "The H-blank DMA deferral, stamped: a shape, not a constant, 2026-09-18"*

**Status:** HARDWARE-MEASURED; not modelled at this point (modelled in §26) · **Date:** 2026-09-18

`hdmastamp.s` (five runs on the AGB SP) shows one cycle of deferral per cycle the request moves earlier inside the bus access in flight, then a snap to zero; the largest deferral is 15, the length of the longest access. The rule to model is "grant at the end of the bus access in flight"; no constant fits. dingbat's spread on the same measurement is 6, and it is jitter from dispatching at instruction boundaries. The page's absolute stamps are anchored to its own timer start and must not be read as absolute. The 7-cycle difference in its no-DMA control (1006 vs 999) was withdrawn in §17: it was the page's own polling loop.

## §16. `DMA Prefetch Break`: knob map; flag delay and grant delay are one axis

*Notes: "`DMA Prefetch Break`: a knob map, and two beliefs retired, 2026-09-18"*

**Status:** SUPERSEDED (resolved in §23/§25) · **Date:** 2026-09-18

The test sees only the sum of `HBLANK_FLAG_DELAY` and the H-blank grant delay: moving either by +7 to +10 passes it. The flag cannot move because the six `H-blank bit start Flip` tests read it directly. A grant deferral to the end of the access in flight (`Bus.access_end`) was built and had no effect on this test at any cap, and it broke `DMA Prefetch Read`. The numbers in this section are stale (§20 re-measures them). Lasting lesson: any new `CycleCount` field on `Bus` needs a rebase line in `end_frame`; `access_end` lacked one and sat about 150,000 cycles in the future.

## §17. `linegeo.s` and `hdmageo.s`: the 7-cycle discrepancy was the instrument

*Notes: "The anchor was the artifact: `linegeo.s` and `hdmageo.s`, 2026-09-18"*

**Status:** HARDWARE-MEASURED; conclusions partly overturned by §23 and §25 · **Date:** 2026-09-18

Two payloads take every stamp from one free-running timer, so the enable latency cancels. `linegeo.s`: scanline length, H-blank flag position and V-blank flag against VCOUNT agree on hardware, dingbat and mGBA; §15's 7-cycle difference was one iteration of a 7-cycle polling loop. `hdmageo.s` (nine runs): the H-blank DMA write relative to the flag lies in -11..-5 on hardware and dingbat alike, though dingbat produces 4 distinct values where hardware shows 6. Two conclusions here were later shown wrong. "The H-blank flag position is correct" was limited by the 7-cycle polling; §25 finds the flag rises one cycle later than dingbat had it. "`DMA Prefetch Break` is a phase coincidence and should stay failing" is overturned by §23. Method notes: the payload's entry phase is not controlled, so only value sets and bounds are comparable across runs; a 32-trial sweep exceeds the monitor's ten-second limit.

## §18. Halted-entry rig (`halthb.s`): HALTCNT is BIOS-only; line IRQ was 2 cycles early

*Notes: "Controlling the line: `halthb.s`, and two bugs it found, 2026-09-18"*

**Status:** FIXED (line IRQ fix is commit 6964209c6 per §20; HALTCNT commit not stated); HARDWARE-CONFIRMED · **Date:** 2026-09-18

A V-count match interrupt with IME clear plus HALT gives a payload a cycle-exact entry; `halthb.s` uses it and is identical across four hardware runs. Bug 1: a write to HALTCNT (0x04000301) from ROM or RAM is ignored on hardware (11 cycles later the CPU is still running) and only works from BIOS code; dingbat halted. Fixed in mmio.nim by gating on the PC being in the BIOS; `SWI 2` is unaffected. Bug 2: the V-count match wake was two cycles early; line-boundary interrupts were split out as `LINE_IRQ_SYNC_DELAY = 5` (the suite does not constrain this value). §25 later replaces that with `PPU_IRQ_SYNC_DELAY = 4` plus `VCOUNT_MATCH_DELAY = 1`. With the bus idle, the halt wake minus the H-blank DMA write is 24 on hardware and dingbat (mGBA 31). Method: control the line with a V-count match halt, use one free-running timer, prefer two hardware events over any poll.

## §19. Four more halted-entry probes: V-blank grant, DMA steal, timer prescaler

*Notes: "Four more probes on the halted-entry rig, 2026-09-18"*

**Status:** HARDWARE-MEASURED; timer prescaler phase OPEN in this section · **Date:** 2026-09-18

`vdmageo.s`: V-blank wake minus DMA write is 24 on hardware and dingbat (the constant behind it is still revised in §25). `dmasteal.s`: an IWRAM 16-bit DMA of N transfers costs the CPU exactly 3 + 2N cycles; all region and width combinations agree on hardware, dingbat and mGBA. `timergeo.s`: counting prescaler-64 ticks from eight consecutive lines, hardware reads 18 at one line phase in four where dingbat reads 19 (mGBA is low at a different phase); no phase constant fixes it, the suite does not constrain it, and it was not fixed. The /256 and /1024 results changed between hardware runs and are discarded: the rig controls the line but not the frame, and those phases walk with the frame index.

## §20. `DMA Prefetch Break`: reading the test source and re-sweeping the knobs

*Notes: "`DMA Prefetch Break`: what the test actually is, 2026-09-18"*

**Status:** SUPERSEDED (resolved in §23/§25) · **Date:** 2026-09-18

The baseline had moved unnoticed: after commit 6964209c6 dingbat reports `0x100025C8`, not `0x10002540`, so §16's table is stale. Facts about the test that stay true: it never writes WAITCNT (4/2 waits, gamepak prefetcher off), `DMA Prefetch Read` is the second output of the same function, and every constant moves the result in steps of 34 iterations (one scanline of 36-cycle passes). The expected constant is per-build and was introduced without a stated hardware reading. `tests/roms/prefetchdma.gba` was written for a cartridge run. Two code observations remain valid: `clear_pipeline`'s flat `2 x wait_s` refill is 6 of the loop's 36 cycles and removing it breaks 704 suite tests, and the burst-break rule is duplicated by hand in `rom_access_cycles` and `rom_fetch_cycles`. The candidate cause given here (lazy fetch ordering) was not the answer.

## §21. `DMA Prefetch Break`: "target out of range" argument

*Notes: "`DMA Prefetch Break`: the target is out of range, and the loop period is why, 2026-09-18 evening"*

**Status:** WRONG (corrected in §22) · **Date:** 2026-09-18

Argued that with a 36-cycle loop the expected value is unreachable and predicted the real loop period must be 31, 34, 37 or 38 cycles. The argument forgot the cycles the DMA itself steals from the loop. §22 measures the period as 36 on hardware and shows the target is reachable. Still true from this section: the loop runs from ROM (16-bit bus), so every fetch mirrors into both latch halves and the per-halfword latch of §13 has no effect on this test.

## §22. Running code from an empty cartridge slot; gamepak DMA rules measured

*Notes: "`DMA Prefetch Break`: gamepak timing without a cartridge, and what silicon says, 2026-09-20"*

**Status:** HARDWARE-CONFIRMED; V-blank IRQ delay FIXED (commit not stated); its prediction for the test superseded by §23 · **Date:** 2026-09-20

An empty slot answers a nonsequential halfword read with `addr >> 1` and a sequential one with `0xFFFF`, the Thumb BL suffix, so a branch to address A executes opcode `(A >> 1) & 0xFFFF` with real gamepak wait states and then returns via `lr` (`slotfloat.s`; emulator image built by `tools/hwlink/slotexec.py`). Rules: `bx pc` must be word-aligned, and only WAITCNT 0 is safe (§26 adds 0x4000). `slotexec.s`: twenty single opcodes at 4/2 agree on hardware, dingbat and mGBA with the prefetcher off, which makes the test's loop 36 cycles; with the prefetcher on, hardware equals dingbat on all twenty and mGBA misses nine. `slotdma.s`: the H-blank grant waits for the access in flight only; the first gamepak access after a DMA is nonsequential (+2 when it would have been sequential); the open-bus capture window is exactly the three cycles of the load's own fetch; a DMA requested during a data cycle overlaps the following internal cycle (-1). `vbwait.s` against Nintendo's BIOS: the V-blank interrupt reaches the CPU one cycle sooner than a V-count match at the same boundary; fixed as `VBLANK_IRQ_SYNC_DELAY = LINE_IRQ_SYNC_DELAY - 1` (re-expressed in §25). Left open here and settled later: the HLE returning one cycle late (§24: it was Halt, not IntrWait), wake-handler entry 2 cycles later and exit 2 sooner on hardware (§26), and a torn unmapped read `000000FF` when a DMA lands inside it (§25).

## §23. `DMA Prefetch Break` fails because of the suite fork, not the emulator

*Notes: "`DMA Prefetch Break`: it was the fork, 2026-09-20 evening"*

**Status:** NOT A DINGBAT BUG (the fork of the mGBA suite); rebuilt ROM passes · **Date:** 2026-09-20

The fork runs all thirteen suites back to back; upstream runs one at a time from a menu. The SIO timing suite, which runs before Misc, leaves an `irqSet(IRQ_TIMER1, ...)` entry in libgba's handler table, and with no V-blank handler registered every V-blank walks the whole table at 11 cycles per entry. `VBlankIntrWait` therefore returns 11 cycles later, and the test catches the DMA on line 2 instead of line 11: exactly the 307 missing iterations. Proof: `-d:breakirq` (empty the table) gives 6998/6998, and the fork rebuilt with `irqInit(); irqEnable(IRQ_VBLANK);` before each suite passes on unmodified dingbat. The compiler is not a factor: `dmaPrefetch` is byte-identical to upstream's published binary apart from one data address. The test is order-dependent on hardware too (worth reporting upstream). Three ROMs for a flashcart check are in `~/Documents/emu/gba/flashcart-tests/`; the expected readings are corrected in §25.

## §24. Real BIOS one line short: gamepak refill order, Halt return, SIO overhead

*Notes: "The real BIOS, chased: three bugs, and the row is mGBA's number, 2026-09-20 night"*

**Status:** FIXED (four timing bugs, commits not stated); its conclusion about the test is WRONG (see §25) · **Date:** 2026-09-20

Fixes, each checked on the AGB SP. (1) A branch into the gamepak now refills nonsequential then sequential at the target, instead of a flat 2S with the N charged later (`ROM_REFILL_ORDERED`, prefetch-off only); `slotdma.s`'s cost column then matches the console at every phase. (2) The HLE's Halt returned a cycle early: `HALT_RETURN_COST` 20 -> 21 (not IntrWait, as §22 said). (3) `SIO_TRANSFER_OVERHEAD` 8 -> 7; the real-BIOS core passes the four SIO timing tests for the first time. (4) An IRQ that wakes an HLE Halt now returns into the BIOS, not the caller, for the exception-return cycle. Ruled out by probes: exception return into gamepak Thumb (`slotret.s`), a table-walking dispatcher, a DMA across a store. After these both cores gave `0x10002B1C` on the rebuilt ROM and the section argued the suite's `0x10002A94` was only mGBA's number; §25 shows the constant is the console's.

## §25. The H-blank flag rises at cycle 1007, not 1006

*Notes: "The pieces matched and the sum did not: the H-blank flag rises at 1007, 2026-09-20 late"*

**Status:** FIXED (commits not stated); HARDWARE-CONFIRMED (`breakram.py` 151/152, rebuilt mGBA suite 6998/6998 under both BIOSes) · **Date:** 2026-09-20

`tests/roms/payloads/breakram.s` runs the test's whole sequence from RAM on the console; the console caught the DMA one NOP later than dingbat at every setting. Single reads of DISPSTAT located the cycle: the H-blank flag rises at 1007 (low for 1007 cycles, high for 225), not GBATEK's 1006. Both the H-blank and V-blank DMA requests are flag+2; §14's V-blank +1 was wrong. Other fixes from the same payloads: one interrupt delay `PPU_IRQ_SYNC_DELAY = 4` plus `VCOUNT_MATCH_DELAY = 1` replaces the old 4/5/6; a DMA delays an interrupt still in the synchroniser by the burst's whole length (dma.nim); a halted CPU resumes on a DMA's last cycle; the V-count match flag is a live compare, and an LYC write that newly matches raises the interrupt (`lycwrite.s`); an unmapped read now gets one verdict for the whole word (`read_open_bus_word`), fixing the torn `000000FF`. The suite's constant `0x10002A94` is the console's; the released fork ROM still fails with `0x10002540`, as a console would after SIO timing (§23). mGBA 0.10.5 matches 70 of 152 cells. Method: compare the end-to-end result, not only its terms. The four items left open here are settled in §26.

## §26. Five more hardware timing rules and a link-rig defect

*Notes: "The open items, chased: five more laws and one link-rig defect, 2026-09-21"*

**Status:** FIXED (commits not stated); HARDWARE-CONFIRMED; three prefetch-on phases and one HLE cell OPEN · **Date:** 2026-09-21

The one odd `breakram` cell was the link: `monitor.py` sent the payload argument unverified and a flipped bit ran the wrong k. `run_payload` now passes the argument through a verified trampoline; dingbat scores 152/152 under both BIOSes. Rules measured and implemented: (1) a halted CPU runs one more instruction before taking the interrupt (`wakeirq.s`: the return address is 0x170, not 0x1B4); (2) `IRQ_ENTRY_EXTRA = 1`, `TIMER_STOP_DELAY = 1` (a write that stops a timer takes effect a cycle later, `tmrw.s`) and `DMA_LEAD_CYCLES = 1` (a burst's hand-off is one cycle before and one after, not two before); (3) a DMA request inside a bus access is granted at that access's end, and the CPU keeps running internal cycles under a burst (`dmaphase.s`; `DMA_ACCESS_WINDOW`, costing about +0.7% instructions in Metroid Zero Mission and +0.63% in Golden Sun 2); (4) with the prefetcher on, the refill uses hardware order and a DMA that never touches the gamepak neither breaks the prefetch stream nor wastes its cycles (`ROM_REFILL_ORDERED_PF`, `DMA_KEEPS_PREFETCH`). `r0table.py --check`: 54/55 HLE, 55/55 real BIOS, mGBA 16. Open: three prefetch-on phases of `slotdma.py --waitcnt=0x4000` are one cycle off; an HLE handler sees a different return address on the stack than Nintendo's BIOS leaves; the library-wide waitloop on==off sweep was not re-run.

## §27. Boktai 2: REGION SETTING screen ignores keys at some clock times

*Notes: "Boktai 2: the REGION SETTING screen ignores every key, at some clock times, 2026-10-01"*

**Status:** FIXED (dma.nim, interrupts.nim; commit not stated); HARDWARE-CONFIRMED 2026-10-02 · **Date:** 2026-10-01, 2026-10-02

The game had crashed, and it was not the solar sensor. Its IRQ handler was entered with IE & IF zero, fell through its dispatch table to a null slot and jumped to address 0. Cause: timer 3 overflowed inside a preemptible DMA3 burst (sound DMA armed); the interrupt got a plain 3-cycle synchroniser delay and was then pushed back by the whole burst, so after the handler had already served and acknowledged it, the stale sample was delivered as a fresh interrupt. Which DMA3 copy the overflow lands in depends on the cart clock, hence the clock times. Fix: a timer interrupt raised inside a burst counts from the burst's end, as the core already did for other paths, and a check dispatched inside the burst no longer recognises what the stopped synchroniser holds. `tests/roms/payloads/dmairqarm.s` on the AGB SP: dingbat 60/60 under both BIOSes, mGBA 16/60; the cells are held as `tests/roms/cyclelaws/dmairqarm.gba`. Of 39 clock times tested, 17 stalled before and none after.

## §28. Phantasy Star Collection: Master System windows drawn with shifted scanlines

*Notes: "Phantasy Star Collection: every Master System window drawn with shifted scanlines, 2026-10-02"*

**Status:** FIXED (dma.nim, `DMA_BUS_BACK_TO_BACK` in gba.nim; commit not stated); HARDWARE-CONFIRMED 2026-10-02 · **Date:** 2026-10-02

The game scrolls BG0 per line by having DMA2 (H-blank, source fixed at write-only BG1VOFS, 0x04000016) copy the open-bus value that DMA1 put on the bus a moment earlier on the same H-blank. dingbat gave DMA2's read the CPU's last fetched or loaded word, so BG0's rows landed at arbitrary heights. The CPU never has the bus between two bursts granted on the same H-blank; the second burst's first unmapped read now returns the first's last word. Console tables (`hdmaobus.s`, `hdmaphase.s`, `hdmalag` 23-28 and 30) confirmed it and added four rules, each a knob in gba.nim: `DMA_BUS_WHILE_HALTED`, `DMA_READS_IO_LOAD` (the I/O bus is 32 bits wide), `DMA_SEES_REFILL_FETCH`, and `DMA_PENDING_CHAIN` (requests latched together chain with no hand-back; requests arriving during a burst are not chained, because chaining them changed Pokemon Mystery Dungeon Red's timing-seeded quiz). After: hdmaobus 26/32 (the other six race on hardware), hdmaphase 80/80, hdmalag 28/28. Still differs: hdmalag configuration 29 (18 bursts against the console's 20). Of 135 scripted games only this one reaches the new path. The `ps1_title` checkpoint difference is a one-field phase offset, not a DMA effect.

## §29. Final Fight One and others: dingbat a frame behind both references after loads

*Notes: "Final Fight One: a frame late after a load, and why that is the references, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (mGBA and the second reference under-charge gamepak code with the prefetcher on); HARDWARE-CONFIRMED 2026-10-02 · **Date:** 2026-10-02

Flagged in Final Fight One (f315), The Sims Bustin' Out, Harvest Moon FoMT, Yu-Gi-Oh! EDS, Lunar Legend and Yoshi's Island. In the three traced, every extra cycle dingbat spends is hardware-measured: renderer contention on CPU VRAM access (`contmap.s`; neither reference models it), a branch waiting out a committed prefetch halfword (`BRANCH_COMMIT_WAIT`, required by the alyosha prefetcher tests), and data accesses under the prefetcher, which mGBA prices below the bus floor (`slotexec.s`: console = dingbat). Turning off both knobs still leaves Final Fight One a frame late. On the alyosha prefetcher ROMs dingbat passes all nine tried, mGBA fails 8 and the second reference fails 5. `slotbranch.py` on the AGB SP confirmed the commit wait at a gamepak branch target (12 cycles where the references charge 11). Open: 3-register `ldmia` from IWRAM and VRAM in slot code varied between runs and read higher on the console (22 and 25) than dingbat (20 and 23); no rule fits yet, nothing changed. Tooling: the driver's `peek` is now untimed (it used to charge wait states and move the game); new `trace`, `runto`, `pft` commands. Not traced: Yoshi's Island, MMBN2/4.

## §30. Kingdom Hearts - Chain of Memories: near-mono DirectSound after the movie

*Notes: "Kingdom Hearts - Chain of Memories: DirectSound near-mono after the movie, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (both references' FIFO reset is wrong); HARDWARE-CONFIRMED 2026-10-02 · **Date:** 2026-10-02

After the opening movie both references play FIFO B 29 output samples behind FIFO A for the rest of the run; dingbat keeps them aligned (L/R correlation 0.90 against 0.42 and 0.44) and fails the audio check. The references keep playing the word a FIFO is on through a SOUNDCNT_H reset; at f8009 FIFO A is reset three bytes short of a word boundary, so it carries stale samples that FIFO B does not. `r0table.py --record fiforeset` on the AGB SP reads `00020202` in all 18 cells: a FIFO reset drops the word being played too, as dingbat does (dingbat 18/18, mGBA 3/18). The near-mono sound is the console's. `FIFO_RESET_KEEPS_WORD` stays off and exists only to reproduce the references; the cells are held as `tests/roms/cyclelaws/fiforeset.gba`.

## §31. Castlevania HoD: thunder plays at different frames

*Notes: "Castlevania HoD: thunder at different frames is the lightning's randomness, not the APU, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (timing-dependent game randomness; the references differ from each other too) · **Date:** 2026-10-02

Screens are identical at every checkpoint but the audio check fails (2.4% of the run, from f6960). The sound register writes match in all three emulators; what differs is when the game schedules its random lightning and the thunder with it. The seed (EWRAM 0x02000008) steps once per main-loop pass, and the emulators take different numbers of lag frames (f1-f6913: mGBA 92, second reference 100, dingbat 103), so the seeds at f6900 are three different values. dingbat's extra cycles are VRAM contention on a DMA3 in active display and data accesses under the prefetcher, both console-measured (§29, §22). The remaining question, multi-register `pop` cost, is §29's open `slotbranch.s` item. No emulator change.

## §32. Lunar Legend: load screen differs when reading any save

*Notes: "Lunar Legend: the load screen reads differently, and it is not the save, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (references' prefetcher, as §29); no change · **Date:** 2026-10-02

The cross-load check fails at `load_file`, but not because of the save: each emulator shows every save file the same way, and dingbat's and mGBA's battery files are byte-identical. The file menu's globe and cursor are one animation step apart. With a battery present the game reads the whole EEPROM at boot (about 1030 calls of the routine at 0x080567F0, WAITCNT 0x4314); a call costs 4167 cycles in dingbat and 4096 in mGBA, which puts dingbat a frame behind from f21. The 71 cycles are almost all the rule that the opcode fetch after a gamepak data load is nonsequential (alyosha `prefetcher_branch_thumb_2`, hardware-verified, failed by both references). A user importing a reference's save sees the same menu as with dingbat's own.

## §33. Yu-Gi-Oh! The Eternal Duelist Soul: title a frame late after the boot load

*Notes: "Yu-Gi-Oh! - The Eternal Duelist Soul: the title a frame late after the boot load, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (references under-charge the load loop, as §29); no change · **Date:** 2026-10-02

`title` and `continue_title` differ from both references in all four configurations. Play diverges at f582, not f32: from there dingbat's IWRAM at frame f+1 equals mGBA's at f. The boot load's hot loop (0x0807517A-0x080751DA, Thumb ROM, WAITCNT 0x4014, 8192 iterations) costs 72.6 cycles per iteration in dingbat and 64.8 in mGBA; the difference is EWRAM byte loads from gamepak code with the prefetcher on, where the console agrees with dingbat (`slotexec.s`). mGBA reaches the idle loop 55k cycles before the f582 V-blank and dingbat 21k after it. The earlier fade differences from f32 are blend rounding of at most one 5-bit step. This is the same game §8's sweep flagged.

## §34. Mario & Luigi: Superstar Saga: Bowser on a different idle pose

*Notes: "Mario & Luigi - Superstar Saga: Bowser on another idle pose, five main-loop counts behind, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (references' cheaper gamepak code, as §29); no change · **Date:** 2026-10-02

`07_mark` (f20257) differs in all four configurations; the references also disagree with each other at other checkpoints. Battle animations run off the main-loop counter (IWRAM 0x03000368), which is exactly 5 lower in dingbat by f17600. Poking only that counter in mGBA's state makes mGBA draw the battle exactly as dingbat for 239 frames. dingbat's main loop misses a V-blank that mGBA's makes at f3829, f3964, f5025, f5054 and f10335, all scene loads; the extra cycles are spread over many ROM functions where mGBA charges stack pushes and loads below the bus floor. A still screen would be a steadier checkpoint.

## §35. Advance Wars: menu scroll one frame out of phase after first-boot flash writes

*Notes: "Advance Wars: first-boot flash writes finish instantly, and the menu scroll is a frame out of phase, 2026-10-02"*

**Status:** OPEN (needs a real-cart flash timing measurement; no core change) · **Date:** 2026-10-02

At `02_mark` (f3932) dingbat's scrolling menu background is one scroll step ahead of both references. On first boot the game programs a 4 KB flash sector (0xF000) one byte at a time and polls the chip after each byte. dingbat's flash (`storage/flash.nim`, Panasonic ID 0x1B32) has no busy state, so the fill ends at f41 against mGBA's f45, the game's frame counter (0x03004358) starts 3 frames earlier, and the scroll, which steps on that counter's parity, lands on the other frame. A scratch build with a 700-cycle busy time per byte (DQ7 inverted, DQ6 toggling, DQ5 = 0; the game reads DQ5 as a timeout and hangs on a DQ7-only model) matches mGBA frame for frame. No public datasheet gives program or erase times for the Panasonic MN63F805MNP (1B32h) or Sanyo LE26FV10N1TS (1362h); GBATEK lists only timeouts, and SST's 14 us figure is for a chip that polls differently. The value has to be measured on a real cart per chip ID. See §64 for the probe; after §65's driver fix the script passes because the references no longer agree against dingbat at this checkpoint.

## §36. Super Mario Advance 3: 1-1's first bush and Shy Guy depend on EEPROM write time

*Notes: "Super Mario Advance 3: the cart's EEPROM decides 1-1, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (cart-dependent, unmeasured; no core change) · **Date:** 2026-10-02

Every dingbat config shows pink tulip buds on 1-1's first bush where both references show white puffs, then a Shy Guy that hits Yoshi. On a blank cart the game formats its 64 Kbit EEPROM with 196 block writes, each polled to ready. dingbat takes 108,116 cycles a block (`EEPROM_SETTLE_CYCLES` 108368, GBATEK's figure), mGBA 114,753, the second reference about 101,000; the 4.6-frame difference sets the phase of counters that later seed the level. Built with `-d:EEPROM_SETTLE_CYCLES=115005` all four configs pass, but a sweep from 100k to 118k flips the outcome every 1000-3000 cycles, which is within normal chip variation, so the result is not fixed on real carts either. `EEPROM_SETTLE_CYCLES` is now an `{.intdefine.}`. The probe `tests/roms/payloads/eesettle.s` (r0table row `eesettle`, `--cart=A3AE`) measures the real cart; it has not been run. The script needs a route that avoids the first-boot format (soft reset or a seeded save).

## §37. Yoshi Topsy-Turvy: calibration ball sits still where references show it rolling

*Notes: "Yoshi Topsy-Turvy: the calibration ball is frame parity, not the sensor, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (references lack renderer contention); harness input fixed for mGBA · **Date:** 2026-10-02

All four dingbat configs fail `confirm` (f1360): the ball is still on dingbat and has rolled right on both references. The tilt sensor's resting value is not the cause. The game's tilt-direction state (0x03001DE0) flips 1/2 every frame until calibration is stored and then freezes; dingbat freezes it at 2, the references at 1. The phase is set at f725-f730, where an IWRAM LZ77 decompressor writing VRAM costs dingbat 12.9k cycles more than mGBA because of renderer contention (console-measured, `contmap.s`, gbaedge p41), which neither reference models. With `-d:CONTENTION=false` dingbat passes. The mGBA driver now attaches a level rotation source. Still open on hardware, not needed here: the tilt ready bit's conversion time and the latch before the first conversion (tests/roms/mbprobe payload_tilt). After §65 the second reference is identical to dingbat here.

## §38. Mario Party Advance: HLE BIOS copies ignored the cost of an EWRAM stack

*Notes: "Mario Party Advance: the HLE BIOS's copies ignored an EWRAM stack, 2026-10-02"*

**Status:** FIXED (hle_bios.nim, cpu.nim; commit not stated) · **Date:** 2026-10-02

The game failed under the HLE BIOS and passed under Nintendo's: sparkle particles came out in different places. Its random number generator is seeded from TM0, whose start depends on a VCOUNT poll loop's phase, and the HLE reached that loop 350 cycles early. The game runs tasks on stacks in EWRAM (0x02036Exx); the BIOS dispatcher and routines push frames on the caller's stack, and the HLE priced every stack word as IWRAM (1 cycle) where EWRAM costs 6, so each CpuSet returned 50 cycles early and each CpuFastSet 100. The HLE now charges each stack word by its region (dispatcher push/pop, routine frames, loop spills). `tools/biosdrv/swisp.c` and `swisp2.c` show the HLE equal to the official BIOS on all 80 EWRAM-stack calls. Left at the time and fixed in §44: validation-skip paths 4-17 cycles short, and SoundBias(0) with the level already 0 was 2 cycles short. The sound-driver SWIs' own frames are not modelled.

## §39. Rockman EXE 4.5: Mega Man fully drawn while references still show mosaic fade

*Notes: "Rockman EXE 4.5: Mega Man's mosaic is the install bar's dice, and the dice are the boot's EWRAM cycles, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (mGBA under-charges EWRAM access from ROM code; no core change) · **Date:** 2026-10-02

At `pet_greeting` (f3624) dingbat is ten frames ahead of mGBA. The mosaic is not at fault: copying dingbat's two RNG words (0x02003F6C, 0x02003C84) into mGBA at f3200 makes mGBA follow dingbat exactly. The install bar pauses on a per-frame random number generator that starts at f476 on mGBA and f478 on dingbat, so the dice differ. The two frames come from the boot RAM clear over EWRAM (26 cycles an iteration in dingbat, 22 in mGBA, which charges nothing for the 6-cycle EWRAM word store) and an XOR pass and checksum at title load (20 vs 16, 16 vs 14). §22's `slotexec.s` on the AGB SP gives dingbat's cost for EWRAM access from gamepak code with the prefetcher on; mGBA is 4-5 cycles short. The exact cells at 3/1 wait states cannot be run on the empty-slot rig (only WAITCNT 0 is safe). The checkpoint is marked known in the script.

## §40. Klonoa: clouds one step darker; Vision 1-1 card two frames ahead

*Notes: "Klonoa: the clouds are the darken rounding, the Vision 1-1 card is the cart's EEPROM, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (darken rounding follows hardware photos; EEPROM time is the cart's, unmeasured; no core change) · **Date:** 2026-10-02

Two separate causes. The clouds (f861-1070) are in the same place as mGBA's but one 5-bit step darker under brightness decrease: dingbat computes `t*11 >> 4`, mGBA `t - (t*5 >> 4)`; dingbat's rounding comes from SP photographs of `blendprobe.gba`, and an exact capture is still wanted. From f3213 dingbat runs two frames ahead because the game writes 15 blocks of its 4 Kbit EEPROM, 108,141 cycles a block in dingbat against 114,776 in mGBA; with `-d:EEPROM_SETTLE_CYCLES=115005` dingbat matches mGBA frame for frame. As in §36 the real time belongs to the chip. Probe for a 4 Kbit cart: `tests/roms/payloads/eesettle4k.s` (r0table row `eesettle4k`), not yet run; never run it with a 64 Kbit cart inserted.

## §41. PSG envelope restart and master volume probes; SOUNDBIAS and timer-read bugs found

*Notes: "The PSG envelope restart and master volume: probes built, the SP not heard, 2026-10-02"*

**Status:** PARTLY FIXED (SOUNDBIAS and prescaled-timer read fixed; master volume changed but unmeasured; envelope question OPEN; commits not stated) · **Date:** 2026-10-02

Two audio probes were built but not heard on the console because the Mac's microphone permission was not granted: `tests/roms/payloads/envrestart.s` (`tools/hwlink/envrestart_listen.py record`) and `psgvol.s` (`psgvol_listen.py record`). Open question 1: dingbat keeps the extra envelope clock armed by an NRx2 write (period 0 to non-zero) across a trigger, so a new note's first envelope step comes about 2 ms after the trigger; mGBA and the second reference do not. The proposed `ch.env_extra_tick = false` in `psg_trigger_envelope` is not applied until the SP answers. Fixed without hardware: SOUNDBIAS was applied at half its level (the field is bits 1-9, so it counts x2), which clipped DirectSound below -256 (`gba/apu.nim`). Changed but unmeasured: PSG master volume is now (V+1)/8 as on the GB, not V/8; `psgvol.s` will settle it (predictions: V/8 gives P3/P7 0.43, (V+1)/8 gives 0.50). Also fixed: a timer with prescaler 64, 256 or 1024 read as its reload value once every 16 frames at the start of a frame, because `end_frame`'s rebase left the timer's anchor after the rebased clock (`gba.nim`); the SP shows no jump (`tests/roms/payloads/tmjump.s`, frozen as `tests/roms/cyclelaws/tmjump.gba`).

## §42. hdmalag configuration 29: H-blank DMA request landing in a branch refill started 2 cycles late

*Notes: "hdmalag configuration 29: the request that lands in a refill, 2026-10-02"*

**Status:** FIXED (`REFILL_WINDOW_SPLIT`, cpu.nim `window_refill`, ppu.nim `start_hblank`; commit not stated) · **Date:** 2026-10-02

In configuration 29 of `tests/roms/payloads/hdmalag.s` (DMA1 and DMA3 armed on every H-blank, CPU polling VCOUNT from IWRAM) the console starts all 20 bursts on their H-blank's cycle; dingbat started line 143's 2 cycles late and dropped the next (18 bursts). The request landed in the second cycle of a `blo`'s refill, which dingbat charged as one 2-cycle block with no access boundary. Now, with the DMA access window open, a refill outside the gamepak is two fetches, each synced to its end, with r15 moving after each sync (moving r15 first broke 23 hdmaphase/hdmaobus cells). Also, opening a new window in `start_hblank` now clears a stale `window_closing` flag left by the previous line's request. Configuration 29's four cells are recorded and frozen; other configurations and prefetcher tests are unchanged.

## §43. Empty-slot multi-register ldm timing and slotdma k = 4-8 mismatches

*Notes: "Slot-code ldm and slotdma k = 4-8: the console runs something else, 2026-10-02"*

**Status:** NOT A DINGBAT BUG (the empty-slot rig is not a valid instrument for these cases; no change) · **Date:** 2026-10-02

Two leftover mismatches from §26 and §29 were chased on the SP. For `ldmia` of 3 or more registers fetched from the empty slot (`tests/roms/payloads/slotldm.s`), the console reads either dingbat's time or 2 cycles more, varying trial by trial, and no phase a payload can set (sled offset, PPU line) decides it; 2-register loads never vary, and the same loads from IWRAM code (`ldmvar.s`) are constant. It is the empty slot's code fetches, so without a cartridge there is no rule to fit. For slotdma k = 4-8 with the prefetcher off (console 1052, dingbat 1049), the console's return address shows it executed one more hop: the forced-nonsequential fetch after the DMA burst floated `addr >> 1` instead of 0xFFFF, so the console ran a different program. The DMA cost itself (DMA + 2) matches. The three one-cycle prefetcher-on cells of §26 (k = 0, 12, 13: 1046 vs 1045) are unchanged.

## §44. HLE BIOS vs Nintendo's, frame by frame: RegisterRamReset, frame ends, copies

*Notes: "The HLE BIOS against Nintendo's, frame by frame: RegisterRamReset, frame ends, copies, 2026-10-03"*

**Status:** PARTLY FIXED (hle_bios.nim, hle_copy.nim, cpu.nim, bus.nim, gba.nim; commit not stated; finished in §48) · **Date:** 2026-10-03

`tools/playtest/hlecmp.py` compares every frame hash of the HLE config against the official-BIOS config across all scripts. Fixes: RegisterRamReset was 826 cycles too long in Banjo-Kazooie and is now a timeline of the console's stores (fixed 135 cycles plus a fixed time per group; exact except one case a cycle late with the prefetch buffer on), which also corrects the register values it leaves. HLE routines now stop at a frame's end instead of running into the next frame. Validation-skip paths and SoundBias(0) cost the console's time, and the registers each routine leaves match the console. CpuSet and CpuFastSet now run as the routine's own instructions, so an interrupt mid-copy is taken on the console's cycle (previously up to about 120 cycles late). Result: 104 of 135 games hash identically on every frame (was 66). The 31 left were the decompressors and other routine bodies writing output up front and mishandling DMA and interrupts inside them; §48 fixes that. New tools: driver `rundigest`, `trace` with absolute cycles, `BD_IOALL`.

## §45. Gradius Galaxies: black screen at first stage after pausing

*Notes: "Gradius Galaxies: black at the first stage, an interrupt return two bytes early, 2026-10-02"*

**Status:** FIXED (cpu.nim `refill_from_head`; commit not stated; regression from 671d1162) · **Date:** 2026-10-02

After START pauses the first stage, the screen went black for good at f1021 in both BIOS configs. A V-blank interrupt was taken right after a Thumb `bx r0` to 0x080003DA, and the handler's return landed at 0x080003D8, two bytes early, in the second half of a `bl`, sending the CPU into open bus above the BIOS. An exception return refills from the prefetcher's buffer when the target matches the prefetcher's head; the target was word-aligned as an ARM address before the compare, so 0x080003DA matched head 0x080003D8. A return whose SPSR is Thumb, to an address with bit 1 set that is not the head, now takes the ordinary refill. Found by `tools/playtest/inputsweep.py`. Seen, not changed: the interrupt was taken with r15 still odd, so LR_irq was odd; only a handler that inspects LR could tell.

## §46. Colin McRae Rally 2.0, TOCA, Starsky & Hutch: crash or reset after menus

*Notes: "Colin McRae Rally 2.0, TOCA, Starsky & Hutch: `movs pc, lr` in System mode restored a stale SPSR, 2026-10-02"*

**Status:** FIXED (arm.nim `exception_return_restore`, `arm_data_processing`; commit not stated) · HARDWARE-CONFIRMED · **Date:** 2026-10-02

After the difficulty menu Colin McRae Rally 2.0 soft-reset (HLE) or crashed to garbage (official BIOS); TOCA World Touring Cars and Starsky & Hutch hung the same way. Their ARM runtime library returns with `movs pc, lr`, called from System mode. User and System mode have no SPSR, but dingbat restored CPSR from a stale `cpu.spsr` field, here a Thumb one, so the CPU came back in Thumb state. An S-bit write to r15 in User or System mode is now a plain branch that leaves the CPSR as it was before the instruction, flags included. The probe `tests/roms/payloads/sysmovs.s` (r0table `sysmovs`, six cells) reads 0x6000029F in every cell on the AGB SP; dingbat matches all six, mGBA keeps the ALU flags (0x2000029F). Frozen as a cycle law (`tests/roms/cyclelaws/sysmovs.gba`).

## §47. Pokémon MurfGreen: semi-transparent OBJ fog drawn opaque inside a window

*Notes: "Semi-transparent OBJ under an effects-off window"*

**Status:** FIXED (ppu.nim `composite_span`; commit not stated) · **Date:** not stated

Overworld fog (semi-transparent OBJ, mode 1) was fully opaque where hardware shows the ground through it. A semi-transparent OBJ pixel alpha-blends with a 2nd-target layer below it even where the window's colour-effect bit is clear; every other effect still needs the bit. The span compositor sent every effects-off span to the opaque loop. Now such a span runs the blend loop when the line has a semi-transparent OBJ pixel and BLDCNT names a 2nd target. `tests/roms/semiobjwin.gba` shows both references agree on the rule; dingbat now matches them on every pixel. Guards: `dingbat/semiobjwin` in the test runner (against `semiobjwin_expected.png`) and `tests/ppucomposite_test.nim` test 10, which checks 96 fuzzed frames against an independent per-pixel model. The rule was lost in a 2022 blending rewrite of the predecessor emulator, and no existing test combined a clear effect bit with a semi-transparent OBJ. One suite checkpoint moved for the better (Aria of Sorrow `castle_corridor`).

## §48. HLE BIOS routines now run step by step as stub-BIOS code

*Notes: "The HLE BIOS's routines as stub-BIOS code, step by step: decompressors, copies, IntrWait, the math, RegisterRamReset, 2026-10-03"*

**Status:** FIXED for the routines listed (hle_unc.nim, hle_bios.nim, hle_copy.nim, bus.nim, gba.nim; commit not stated) · **Date:** 2026-10-03

This finishes §44. Each HLE routine is now a sequence of steps in the stub BIOS (0x0C00-0x152F ARM, 0x3A00-0x3FFF Thumb), each making the console instruction's bus accesses and internal cycles in order, so interrupts, DMA grants, renderer contention, frame ends and save states all fall at the console's instruction boundaries. Covered: IntrWait, VBlankIntrWait, Div, DivArm, Sqrt, ArcTan, ArcTan2, CpuSet, CpuFastSet, GetBiosChecksum, BgAffineSet, ObjAffineSet, BitUnPack, LZ77, Huffman, RL, the Diff filters, SoundBias, MidiKey2Freq, RegisterRamReset. Halt, Stop and the sound driver keep their models. Behaviour corrected along the way includes: LZ77/RL runs are copied whole past the header length; LZ77UnCompVram reads back-references with halfword loads from the destination; Thumb routines read their header with a non-rotating load (Mortal Kombat - Deadly Alliance depends on it); HuffUnComp's bitstream alignment and store count of (size & 7) + 4 leaves; BitUnPack overflow carries into the next unit; spilled words sit above sp; RegisterRamReset keeps SOUNDBIAS's level bits; IntrWait halts at least once. Result: all 135 scripts hash identically under HLE and official BIOS on every frame after f0 (was 104). Tools: `tools/biosdrv/steptrace.nim`, `stepcmp.py`, driver `swilog`, `tools/playtest/swicmp.py`, `digcmp.py`. The reference is the official BIOS running in this core, not a console measurement.

## §49. Harry Potter CoS, Starsky & Hutch: 8 KB EEPROM save file rewritten at 512 bytes

*Notes: "Harry Potter CoS, Starsky & Hutch: an 8 KB save for a 4 Kbit EEPROM came back 512 bytes, 2026-10-03"*

**Status:** FIXED (gba.nim `new_storage`, storage.nim `battery_file_bytes`; commit not stated) · **Date:** 2026-10-03

Loading the second reference's 8192-byte save for a 4 Kbit EEPROM game made dingbat rewrite the file at 512 bytes; the chip data was intact but the harness counts a shortened file as a failure. dingbat sizes the EEPROM from the game's first command, not the file, and shrank the buffer to 512 bytes. The file's bytes past 0x200 are now kept as loaded (`eeprom_file_tail`) and written back after the chip data, so a file is never shortened; a 512-byte file stays 512 bytes and 64 Kbit games are unchanged. Guard: `nimble test_gbartc`.

## §50. Sleep mode: six games never woke from Stop

*Notes: "Sleep mode: six games never woke from Stop, 2026-10-03"*

**Status:** FIXED (interrupts.nim `check_interrupts`, keypad.nim `stop_key_condition`; commit not stated); the direct Stop measurement on hardware is not recorded here, but §61 confirms the KEYCNT rule it rests on · **Date:** 2026-10-03

Ghost Rider, Catwoman, Action Man - Robot Atack, Cabbage Patch Kids - The Patch Puppy Rescue, Puyo Pop Fever and The Santa Clause 3 went black for good after choosing Sleep. Some sleep with KEYCNT 0x8304 (IRQ enable bit 14 clear), and Ghost Rider's group enters a second Stop with KEYCNT 0xC000 after acknowledging IF, so on the console the key condition must end Stop as a level and without bit 14. dingbat now ends Stop while IE's keypad bit is set and KEYCNT's key condition holds (AND over selected keys, true with none selected; OR: any), ignoring bit 14 and raising no interrupt; the keypad IRQ itself is unchanged. All seven games tested (including Powerpuff Girls - Him and Seek) sleep and wake on L+R+SELECT. Both references treat Stop as a halt and never sleep, so they are no guide. Probe: `tests/roms/payloads/keyirq.s` (r0table row `keyirq`), recorded in §61; its Stop cells (arguments 0x80000000, 0x80000001) hang a console that disagrees.

## §51. Sonic Advance: save cross-load failure caused by a reference that never boots

*Notes: "Sonic Advance: a reference that never boots is no witness for the save, 2026-10-03"*

**Status:** NOT A DINGBAT BUG (harness; FIXED in `cross_load_verdict`, commit not stated) · **Date:** 2026-10-03

All four dingbat configs failed the save cross-load with "battery file changed by booting". The second reference never gets past the grey bars in this game, so its save is blank flash, and a blank save makes the game write its "PIRO" header after the language screen; dingbat and mGBA write the same bytes. `cross_load_verdict` now counts a reference as keeping a save only when that reference shows its own save correctly; otherwise the rewrite is a note. Sonic Advance passes; no other game in the corpus was affected.

## §52. Test train: stale-driver check rejected every driver on the second baseline run

*Notes: "The stale-driver check refused the train's second run of base, 2026-10-12"*

**Status:** NOT A DINGBAT BUG (harness; cause in 1239267b; fix commit not stated) · **Date:** 2026-10-12

The train's verdict on 716b7589 listed ten games as noise because every dingbat config failed to play on the second run of the baseline. The stale-driver check compared the driver's modification time with the newest source file, and a cached driver copied into a fresh checkout always looked older. build.sh now stamps each driver with a checksum of its sources (`<binary>.srcsum`: src/dingbat/gba, src/dingbat/common, the driver, nim.cfg, build.sh); emu.py rejects a driver whose stamp does not match, and the train copies the stamp with a cached driver. `denoise` no longer learns from a config the rerun could not play. The 849 bad noise-ledger cells were removed. The ten hidden changes were all neutral; the corpus stood at 129/140.

## §53. Shin Bokura no Taiyou (Boktai 3): sensor notice animation out of phase

*Notes: "Shin Bokura no Taiyou: the sensor notice a phase behind, the second reference on the host clock, 2026-10-12"*

**Status:** NOT A DINGBAT BUG (second reference's driver ignored `--rtc`: FIXED in the harness, commit not stated; mGBA under-charges the boot: no change) · **Date:** 2026-10-12

At `solar_notice` every dingbat config was 15-16 frames behind both references. Cause 1: the boot does a clock-dependent computation, and the second reference ran on the host clock. Its driver now overrides `time()` to return the frozen `--rtc` epoch; it then matches dingbat-bios on 448 of 450 boot frames. This also removed the train's main noise source and fixed host-clock differences in Boktai, Boktai 2 and Rockman EXE 4.5. Cause 2: mGBA reaches the animation 8 frames earlier because it prices ROM code loops (libgcc `__muldi3` and soft-float, EWRAM scans, an IWRAM-to-EWRAM byte copy) below the bus's minimum cost, for example 48 cycles for a copy whose data and fetch cycles alone need 67. dingbat's costs follow `slotexec.s` on the SP and the alyosha prefetcher tests. The sensor and the RTC protocol are not involved. Not chased: the second reference's `first_gameplay` is 29 frames off both dingbat and mGBA.

## §54. Classic NES Zelda II: HLE Halt returned 9 cycles early and once missed a sleep

*Notes: "Zelda II: the HLE Halt came back 9 cycles early, and once slept through an interrupt, 2026-10-12"*

**Status:** FIXED (hle_bios.nim `hle_halt`, stub BIOS 0x164-0x188; commit not stated) · **Date:** 2026-10-12

Zelda II was the last corpus game whose HLE and official-BIOS runs differed (audio only). Cause 1: the HLE's Halt return was a trap at 0x170 that charged 16 internal cycles, so DMA bursts granted there cost nothing, where the official BIOS's `pop {r2, lr}` waits for them. Cause 2: the HLE sampled the interrupt line once, 18 cycles after the comment read, and missed a timer interrupt recognised between the dispatcher's `msr` and the HALTCNT write; it then returned without sleeping (4622 cycles against 79077). The Halt now runs the console's instructions from the dispatcher's `msr` on (`HALT_MSR_START` = 10 cycles after the comment read), parks at 0x164 in the stub, and returns through real instructions with a trap at 0x184 for the one pop that differs. All 8015 Halt calls in the script now match and the audio is identical. The reference is the official BIOS in this core; there is no console measurement.

## §55. Metroid Fusion: hang at boot with HLE on and Nintendo's BIOS image mapped

*Notes: "Metroid Fusion hung at boot over Nintendo's BIOS: the HLE Halt parked in the image, 2026-10-13"*

**Status:** FIXED (`hle_takes`; commit not stated) · **Date:** 2026-10-13

With a real BIOS image mapped and the HLE taking SWIs (the "HLE after BIOS" mode, or HLE mode with a BIOS file present, which every frontend passes), Metroid Fusion hung at f12 with the PC looping at 0x64. The HLE Halt parks in BIOS code at 0x164 with a three-word SVC frame that only the stub's return pops correctly; over Nintendo's image the image's own return pops four words and jumps to the reset vector. The bug dates from 45ec2b82 (2026-09-23). `hle_takes` is now false for Halt over a real image, so the image's own Halt runs; Stop keeps the HLE because it runs no BIOS code. Test: `tests/swihalt_test.nim` (`nimble test_swihalt`, in CI) with `tests/roms/swihalt.s`, over the stub, a stand-in image and Nintendo's image when present. The corpus did not cover this configuration; §60 adds it.

## §56. Deep input sweep over 1625 titles: no title fails in dingbat alone

*Notes: "The deep input sweep on the whole pool: no title fails in dingbat alone, 2026-10-13"*

**Status:** NO DINGBAT BUG FOUND · **Date:** 2026-10-13

`inputsweep.py sweep --pattern deep --frames 12000` ran the whole 1625-title pool against mGBA on main 346c741d (the last ~240 on b7c1e32e), with flagged titles rechecked against the second reference. Of 25 flags, 13 were the game's own sleep option, which the references do not model (§50). The other 12 were dingbat against mGBA only, with the second reference agreeing with dingbat, mostly timing forks where a press lands on another frame. Pitfall - The Lost Expedition was a false `garbage` alarm on dense foliage; the `garbage` detector also misfires on other busy screens. In CROSS CHANGE (J) mGBA alone stays black.

## §57. Summon Night - Swordcraft Story 2: audio differs from both references for 4% of the run

*Notes: "Summon Night - Swordcraft Story 2: the first battle's random numbers part all three emulators, 2026-10-13"*

**Status:** NOT A DINGBAT BUG (timing-seeded randomness; no emulator matches another) · **Date:** 2026-10-13

All four dingbat configs failed on audio alone, longest 2.76 s from f24450. The first battle uses timing-seeded random numbers: frames are identical in all three emulators at f13848 and no two share a frame from f14401 to f26400. The flagged audio falls in and just after that stretch. Saves differ by 6 bytes (HP after the fight) and load everywhere. The script was marked known for the audio; after §65's driver fix that entry no longer matched and was removed.

## §58. Klonoa 2: level start two game frames early; lone gamepak data load priced sequential

*Notes: "Klonoa 2: Nintendo's HuffUnComp ran fast, a lone gamepak byte load priced sequential, 2026-10-13"*

**Status:** FIXED (bus.nim `ROM_DATA_NONSEQ`; commit not stated) · HARDWARE-CONFIRMED · **Date:** 2026-10-13

`level_start` and `gameplay` failed in all four configs: the game's frame counter (0x03004CA4) ran two counts ahead of mGBA's. During loads, Nintendo's HuffUnComp (ARM, in the BIOS) reads its tree from the cartridge with single `ldrb` loads; dingbat charged 4 cycles on 11-16% of them where mGBA charged 6. `rom_access_cycles` treated a CPU data access as sequential whenever it hit the address after the previous gamepak access, however long ago, and a byte load at an odd address left that address in place. Now a CPU data access from the gamepak is sequential only directly after the previous gamepak access (later transfers of an LDM/STM); opcode fetches are unchanged. `-d:ROM_DATA_NONSEQ=false` restores the old rule. The AGB SP agrees (`tests/roms/payloads/romdataseq.s`, r0table row `romdataseq`, recorded with the slot empty): all 32 timing cells equal their controls and the four float cells read `addr >> 1`, a nonsequential access. Side effects on the train: Donkey Kong Country `kongo_jungle_map` went to one frame ahead (see §66), and Castlevania - Circle of the Moon `shaft_bottom` went to a major difference (explained in §59 as random draws).

## §59. Castlevania - Circle of the Moon: skeleton bone throws differ in every emulator

*Notes: "Castlevania - Circle of the Moon: the skeletons' bones are an idle-loop RNG, and no two emulators share it, 2026-10-13"*

**Status:** NOT A DINGBAT BUG (idle-loop-seeded randomness; no core change) · **Date:** 2026-10-13

After §58 `shaft_bottom` became a major difference in all four configs: a bone knocks Nathan elsewhere in the shaft. The game's RNG state at 0x0200A260 is incremented once per idle-loop pass (0x080057D4), so it counts idle passes since boot, and each skeleton throw is `rand(0x3D)`, one of 61. Every draw differs between the two references and between each of them and dingbat; the old build's milder result was a draw that happened to miss. mGBA runs 11-13% more idle passes a frame because it charges the loop 76 cycles where the bus minimum is 82 and dingbat charges 84; the 6 missing cycles are two opcode fetches after gamepak loads charged 1 instead of 4 (alyosha prefetcher_branch_thumb_2, hardware-verified). The second reference counts the same passes per frame as dingbat on the boot screen but starts a frame earlier. The script marks `shaft_bottom` as known. Not chased: during the white flash at f7035-f7054 dingbat and mGBA differ by one 5-bit step in red only, a brighten-rounding question.

## §60. Test corpus gains a fifth config: HLE over Nintendo's BIOS image

*Notes: "The corpus plays the HLE over Nintendo's image too (dingbat-hleimg), 2026-10-13"*

**Status:** DONE (harness; commit not stated) · **Date:** 2026-10-13

§55's hang lived in a configuration the harness never ran: HLE with a real BIOS image mapped, which is what frontends run when a player installs a BIOS file and keeps the HLE on. `dingbat-hleimg` is now the fifth config (driver `--hle` keeps the BIOS file mapped, idle-loop skipping on), paired with `dingbat` for comparison. On Metroid Fusion both pass on main; with §55's fix reverted, `dingbat-hleimg` fails every checkpoint.

## §61. Keypad interrupt reaches IF about 60 cycles late on the console

*Notes: "The keypad interrupt reaches IF late on the console: keyirq recorded, 2026-10-13"*

**Status:** HARDWARE-CONFIRMED and modelled (keypad.nim `KEYPAD_IRQ_HOLD` = 64; commit not stated); one phase question OPEN, not visible to games · **Date:** 2026-10-13

§50's `keyirq` probe, recorded on the SP, showed dingbat setting IF bit 12 on the KEYCNT store itself where the console sets it later. `keyirq2` timed it: the keypad interrupt is a rising edge that reaches IF only after the condition has held about 60 cycles (0x4F or 0x46 poll counts); a true condition shorter than about 40 cycles is never caught, 67 or more always is; it never fires again after an acknowledge; and KEYCNT with bit 14 clear never sets IF. That last result confirms the 0x8304 sleep games in §50 can only wake through Stop's own key condition. dingbat now raises IF 64 cycles after the condition turns true unless it turned false in between (any hold from 62 to 68 gives the same results). All `keyirq` cells and 16 of 18 `keyirq2` cells match. `keyirq3` showed the remaining 9-cycle phase (0x46 vs 0x4F) depends on the store's cycle position, not on the last KEYCNT write, and fits no single divided clock up to period 16; dingbat gets 16 of 32 cells, the most a fixed hold can. `keyirq2` and `keyirq3` stay out of the cycle-law gate (`OPEN_ROWS`). A next probe would anchor the store to the H-blank flag edge.

## §62. Phantasy Star Collection: 29-frame slip is a one-field phase of a two-field screen

*Notes: "Phantasy Star Collection: SLIP(-29) is one field of a two-field screen, and the field is set by a VRAM fill under contention, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (references under-charge console-measured costs; no core change); classifier FIXED in the harness (commit not stated) · **Date:** 2026-10-14, 2026-10-15

All five dingbat configs slipped 29 frames at `camineet`, `field_menu`, `save_slot` and `save_name`. The game draws every screen as two alternating fields, and the real difference is one frame: the field flag (0x02020FF0) starts at f1692 in mGBA and f1693 in dingbat. Two costs push dingbat's init past a V-blank: the 256-call EEPROM read (+138 cycles a call from EWRAM and gamepak loads under the prefetcher, as measured by `slotexec.s`), and a 96 KB DMA3 VRAM clear during active display that costs 110,465 cycles in dingbat against 74,168 in mGBA because of renderer contention (console-measured, `contmap.s`, `dmavram.s`). With `-d:CONTENTION=false` dingbat matches. The second reference is an even number of frames from mGBA, so their agreement is a parity coincidence. Harness changes: `classify` reports the slip nearest the window centre, and screens that repeat every 4 frames or fewer are compared field by field with a `field_phase` note; the runner saves extra field screenshots. Re-scoring moved 15 pair verdicts from a one-frame slip to identical, with no game status change.

## §63. Metal Slug Advance: landing scene one V-blank behind both references

*Notes: "Metal Slug Advance: the landing a frame late, a load that pays EWRAM's wait states, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA under-charges EWRAM access from ROM code; no core change) · **Date:** 2026-10-14

`landing` (f1322) slips 2 frames in all five configs because the main loop is one V-blank behind in a 30 Hz scene. A load in Thumb ROM code (WAITCNT 0x4314) ends 15,159 cycles after the V-blank in dingbat and 8,165 before it in mGBA; over identical instructions dingbat charges 14.6k cycles more, mostly EWRAM data access under the prefetcher. `slotexec.s` on the SP (rows 6, 9, 12: 22, 22, 21 cycles) matches dingbat and the second reference; mGBA reads 17. In a scratch timing ROM mGBA charges 90 cycles for 16 EWRAM word loads whose data cycles alone need 96. Ruled out: contention, `ROM_DATA_NONSEQ` and `BRANCH_COMMIT_WAIT` do not move it. The second reference reaches the same phase as mGBA by a different path (its EWRAM already differs before the load), so it is no witness.

## §64. Mario vs. Donkey Kong: level-clear tally two frames early; flash program time

*Notes: "Mario vs. Donkey Kong: the level-clear tally two frames early, the flash chip's program time, 2026-10-14"*

**Status:** OPEN (needs a real-cart flash measurement; no core change) · **Date:** 2026-10-14

`level_clear` (f7087) is 2 frames ahead of mGBA and 1 ahead of the second reference in all five configs; the references match only at the checkpoint's centre frame. The game programs a 4 KB flash sector one byte at a time and polls after each byte. dingbat's flash has no busy state (1,427 cycles a byte, one status call); mGBA holds a byte program about 640 cycles after a sector erase has run (1,552 cycles a byte, 1.95 calls), 1.8 frames longer per sector. This is §35's open question. The second reference identifies its flash as SST (ID D4BF) and writes at dingbat's rate. The probe `tests/roms/payloads/flashprog.s` (r0table row `flashprog`, needs a flash cart, kept out of the cycle-law gate) is designed but not run: a console busy time under about 510 cycles gives dingbat's frame, about 640 gives mGBA's, each further 125 about 2 frames later. A measured time per chip ID belongs in `storage/flash.nim`.

## §65. Second reference's screenshots were one frame stale

*Notes: "The second reference's pictures are a frame stale: its frames end before the V-blank, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (harness driver for the second reference; FIXED in the driver, commit not stated) · **Date:** 2026-10-14

The second reference's driver ran a fixed cycle count per frame and stopped a few lines before line 160 (VCOUNT 142-159, drifting), while the core presents its picture at the end of V-blank, so each captured picture was the previous frame's. In Donkey Kong Country its IWRAM matched dingbat's at offset 0 while its picture matched one frame later. So "both references identical" on an animated screen could mean mGBA a frame behind in game state and the second reference agreeing with dingbat but showing a stale picture. `run_frame` now runs to VCOUNT 160 exactly and copies the buffer being drawn. Corpus effect: checkpoints where all three agree rose from 814 to 957. Six known-difference entries were removed (Harvest Moon `farm_intro`, Yoshi Topsy-Turvy `confirm`, The Sims `language`, and audio entries for Harmony of Dissonance, KH Chain of Memories, Swordcraft Story 2); Advance Wars now passes. Four checkpoints became diagnostic and are chased in their own sections: Rockman EXE 4.5 `pet_menu`, Aria of Sorrow `select_data`, Koro Koro Puzzle `title`, Mario & Luigi `06_f19428`. Not corrected: the second reference runs one V-blank ahead of both others through Donkey Kong Country's boot, from its own BIOS-boot timing.

## §66. Donkey Kong Country: Kongo Jungle map one frame ahead of mGBA

*Notes: "Donkey Kong Country: the Kongo Jungle map a frame ahead is mGBA's cheap load, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA under-charges a load; no core change) · **Date:** 2026-10-14

`kongo_jungle_map` (f4626) is one frame ahead of both references in every config. The second reference's game state actually matches dingbat's (EWRAM byte for byte, f2601-f2800); its matching picture was §65's stale capture. A 37-frame load from f2386 ends 10,350 cycles after the f2423 V-blank in dingbat and 8,469 before it in mGBA, an 18,466-cycle (0.18%) gap from EWRAM loads and stores and a stack `pop` after a refill in Thumb ROM code under the prefetcher. mGBA's V-blank count (0x03000058) then stays one ahead. Writing dingbat's count into mGBA at f2500 makes mGBA draw the checkpoint as dingbat does. `slotexec.s` on the SP supports dingbat's cost; the exact 3/1 wait-state cells cannot be run on the empty-slot rig. The script passes, since a one-frame slip counts as a pass.

## §67. Super Mario Advance: title one frame ahead; first-boot EEPROM format time

*Notes: "Super Mario Advance: the title a frame ahead is the first boot's EEPROM format, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (cart EEPROM time unmeasured; no core change) · **Date:** 2026-10-14

`quit_to_title` (f2400) is one frame ahead of both references in every config; the second reference's state matches dingbat's and its picture was §65's stale capture. On a blank cart the game formats its 4 Kbit EEPROM with 36 block writes: 108,432 cycles a block in dingbat, 115,091 in mGBA, and a wait for VCOUNT 159 turns the 240k-cycle difference into a whole frame that mGBA stays behind for the rest of the run. Built with `-d:EEPROM_SETTLE_CYCLES=115005` dingbat matches both references on all 61 frames of the window. Same open measurement as §36 and §40: run `tests/roms/payloads/eesettle4k.s` (r0table row `eesettle4k`) with this cart (AMZE) in the SP. A value near 108k sides with dingbat, near 115k with mGBA. The script passes.

## §68. Car Battler Joe: sprite shadows on the opposite flicker frame

*Notes: "Car Battler Joe: the shadows' flicker phase, moved by mGBA's cheap map loads, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA under-charges map loads; second reference's phase unexplained; no core change) · **Date:** 2026-10-14

At `field_menu` (f20454) and `takah` (f22100) dingbat differs from the references only in shadows the game draws on alternate frames (flicker byte 0x03002A6C). Every scene load builds a 128x64 map in a Thumb ROM loop at 0x08013190 with EWRAM loads and stores: 1,277,643 cycles in dingbat, 1,101,525 in mGBA, so mGBA finishes eight loads a frame earlier and the flicker phase ends up opposite from f17485 on. mGBA charges an EWRAM word load 2 cycles where the bus needs 6; `slotexec.s` on the SP gives dingbat's figure, and the second reference takes every load in dingbat's number of frames. The second reference is in the opposite flicker phase from f2346 for a reason not chased, and shows Takah on a different idle-animation frame. The first-boot EEPROM format (148 blocks, 3.5 frames longer in mGBA) does not reach the checkpoints. `eesettle.s` would measure this cart's block time; not run.

## §69. Starsky & Hutch: menus and car chase a frame apart from mGBA

*Notes: "Starsky & Hutch: the menus are the EEPROM's programming time, the chase is the race loop's pricing, 2026-10-14"*

**Status:** NO CORE CHANGE; menu timing OPEN (needs a cartridge measurement) · **Date:** 2026-10-14

At `chase` dingbat is one frame off mGBA and differs from the second reference. The menus differ because of the 4 Kbit EEPROM's block programming time: a block takes 108,095 cycles in dingbat (GBATEK's ca. 108368) and 114,733 in mGBA; a build with `-d:EEPROM_SETTLE_CYCLES=115005` matches mGBA on every frame f1-f4599. The chase is separate: the race runs a 12 fps loop, and one iteration costs 18.2k cycles more in dingbat, mostly console-measured VRAM contention (`contmap.s`) and prefetcher pricing (§29), so two of mGBA's iterations take 4 frames where dingbat's take 5. The second reference shares no race frame with either. The chip's real programming time is unmeasured; the probe `tests/roms/payloads/eesettle4k.s` (r0table row `eesettle4k`) with the cartridge in the slot decides it (near 108k keeps dingbat, near 114.7k means dingbat moves).

## §70. Rockman EXE 4.5: PET menu differs from both references

*Notes: "Rockman EXE 4.5: the PET menu is the install bar's dice again, and the second reference threw its own, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA's EWRAM pricing; the references agree by coincidence) · **Date:** 2026-10-14

`pet_menu` (f4734) shows the same menu with scroll, arrows and pose on other frames. It is §39's cause: the game's RNG words (0x02003F6C, 0x02003C84) differ after the boot's EWRAM clear, where dingbat's cost matches the console (`slotexec.s`, AGB SP) and mGBA is 4-5 cycles short. Poking dingbat's two RNG words into mGBA at f3200 makes it show dingbat's install bar frame for frame. The second reference has its own RNG sequence and only happens to end the install on mGBA's frame, so it is not a timing witness. The script marks `pet_menu` as a known difference (`@known`).

## §71. Mario & Luigi: Bowser battle animation on different frames

*Notes: "Mario & Luigi: the battle at 06 is §34's main-loop count, and the second reference keeps dingbat's count, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA under-charges cartridge code at scene loads) · **Date:** 2026-10-14

At `06_f19428` (f19758) and `07_mark` Bowser and the fountain are on other idle-animation frames than in both references. The poses follow the main-loop counter at 0x03000368, which mGBA has 5 ahead of dingbat after §34's five scene loads; poking mGBA's counter to dingbat's value plus 1 or plus 5 gives mGBA's picture, dingbat's value gives dingbat's. The second reference takes every load in dingbat's number of frames and is only +1 from a boot lead, which happens to land on the same animation phase as mGBA's +5. Both checkpoints are marked `@known`.

## §72. Castlevania: Aria of Sorrow: Select Data differs by one colour step

*Notes: "Castlevania: Aria of Sorrow: Select Data is the alpha blend's rounding, 2026-10-14"*

**Status:** NOT A DINGBAT BUG; HARDWARE-CONFIRMED by SP photographs (digital video capture still wanted) · **Date:** 2026-10-14

`select_data` (f965) differs from both references on the blended panels (BLDCNT 0x0844, BLDALPHA 0x0A06, EVA 6, EVB 10). dingbat truncates the alpha blend, (t·6 + b·10) >> 4; mGBA widens the colours to 8 bits first, and the second reference rounds, with green one step lower on some pixels. The SP `blendprobe.gba` photographs (`tests/roms/expected/blendprobe-agb-sp-1.txt`) fit truncation on all 16 alpha cells; rounding and mGBA's form each miss five. Frame counts also differ: mGBA gains a frame at two loads (f155, f432) through cheaper cartridge-code data accesses (§29, §66 class), while the second reference takes dingbat's frame counts. A `@known` was added and removed the same day, once the fixed second-reference driver (§82, §83) read within one step of dingbat.

## §73. Koro Koro Puzzle: title fails the text comparison

*Notes: "Koro Koro Puzzle: the title is the alpha blend's rounding, read by the text comparison, 2026-10-14"*

**Status:** NOT A DINGBAT BUG; resolved by a classifier change · **Date:** 2026-10-14

`title` (f940, `compare=text`) read as a major difference because OCR read the faded PUSH START row differently. Every differing pixel is one 5-bit step with dingbat lower: the alpha-blend truncation of §72 (BLDCNT 0x3A45, BLDALPHA 0x0C04), which the SP photographs confirm. A scratch build with mGBA's blend formula matches mGBA on every frame f831-f959. The frame counts differ by the boot, where mGBA under-charges an EWRAM word load from cartridge code (`slotexec.s` row 9: console and dingbat 22, mGBA 17). The classifier now applies the one-step rounding rule to text-judged screens before OCR, so the checkpoint reads as a minor difference and the `@known` was removed.

## §74. Survey of the 72 checkpoints where all three emulators differ

*Notes: "The checkpoints where all three emulators differ, 2026-10-14"*

**Status:** NO CORE CHANGE; no dingbat bug found · **Date:** 2026-10-14

In baseline `e9739f858dc3-src-baecd9352478` (164 games), 72 checkpoints in 53 games have dingbat, mGBA and the second reference all disagreeing. Each was classified: 22 are rendering at equal state (14 alpha blends and 5 darkens with dingbat one step lower, 2 brightens, 1 Klonoa 2 window column where mGBA is alone), 2 are CPU-timing races in the visible frame, 15 follow an earlier classified divergence, 25 are timing-seeded randomness or animation phase, and 8 are harness artefacts. The archive holds the per-game table. Most rounding cases are reported as a zero-frame slip because the classifier tests for a shared frame before its one-step rule. The four most suspicious cases are §75-§77.

## §75. Mega Man Zero 4 and Rayman 10th Anniversary: brighten one step lower

*Notes: "Mega Man Zero 4 and Rayman 10th Anniversary: the brighten is truncated in every channel, as the SP photographs say, 2026-10-14"*

**Status:** NOT A DINGBAT BUG for red, blue and low-fraction green (HARDWARE-CONFIRMED by SP photographs); green at high fractions OPEN · **Date:** 2026-10-14

Both checkpoints use brighten with BLDY 5 (BLDCNT 0x3F82 and 0x0090) and differ from the references by one 5-bit step. dingbat truncates, `t + ((31 - t) * 5 >> 4)`; the references are truncation or one step higher depending on the pixel. The SP `blendprobe` photographs show truncation in all three channels at fractions 0.5625-0.75, and in red and blue at 0.8125 and above. Green at 0.8125 and above is not settled on the photographs ("Brighten green anomaly", docs/hwprobe-questions.md). It needs a video-signal capture or a single-channel photo probe; the CPU cannot read a blend result back.

## §76. Medabots AX: a green strip differs on rows 39-45

*Notes: "Medabots AX: a palette write during the visible frame lands on three lines, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (references lack VRAM contention and prefetcher pricing) · **Date:** 2026-10-14

At `intro` (f958) the game rewrites palette entries 0x050001F8 and 0x050001FA while the screen is drawn, and each emulator's write lands on a different line: mGBA before line 39, the second reference on line 45, dingbat at line 45 in H-blank (visible from line 46). dingbat reaches the palette loop 8,590 cycles later than mGBA. Half is the BIOS CpuSet storing into BG VRAM during drawn lines (5 cycles against 2), which is console-measured renderer contention (`contmap.s`, `dmavram.s`); the rest is cartridge-code prefetch pricing (§29). The second reference lands within about 300 cycles of dingbat.

## §77. Klonoa 2: world map window column and Vision map cloud edge

*Notes: "Klonoa 2: the world map's window column is mGBA's alone, the Vision map's cloud is a one-line race, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (world map: mGBA alone; cloud: mGBA's cartridge-code pricing) · **Date:** 2026-10-14

`world_map` (f2240): 7 pixels at x 106-107, lines 103-107, inside a one-column WIN1. State is identical and the game writes nothing during the drawn frame; mGBA draws BG0 colours 2-4 pixels off, while the second reference matches dingbat bit for bit at the same game state. `vision_map` (f3590): 1 pixel of a cloud edge, because code that runs during the drawn frame starts on line 38 in dingbat and line 36 in mGBA (+1,691 cycles, cartridge and EWRAM code pricing of §29 and §63, where the SP agrees with dingbat). Turning contention off changes nothing here.

## §78. Dragon Ball Z - Buu's Fury: Grand Kai's planet ten frames off

*Notes: "Dragon Ball Z - Buu's Fury: Grand Kai's planet ten frames off is one lost frame and a blink seeded from the RNG, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA under-charges EWRAM loads from cartridge code) · **Date:** 2026-10-14

At `grand_kai_planet` (f19934) only Goku's blink differs, by 10-11 frames. The blink counter (0x02031366) is seeded at f17852 by `random(255)`: 0x92 in dingbat, 0x7E in both references. dingbat's RNG is one step behind because at f15800 a sprite-unpack frame overruns the V-blank by 6,326 cycles and one main-loop iteration is lost. mGBA never reaches that frame in the same state: its object counters are two ahead after f14266 and f14441, where EWRAM word loads from cartridge code cost 2 cycles against dingbat's 8-9 (`slotexec.s` row 9 on the AGB SP gives dingbat's cost). Poking dingbat's four object counters into mGBA at f15500 makes it lose the same frame and draw dingbat's checkpoint. The HLE and Nintendo's BIOS run the frame in identical cycles. The second reference keeps dingbat's counters yet makes the frame; it has no trace, so why was not measured.

## §79. Seven "only the console answers" timing items re-examined

*Notes: "The console cells nobody reproduces, worked from the recorded data alone, 2026-10-14"*

**Status:** NO CORE CHANGE; checker fixed; six probes since run on the console (timergeo, obusdma16, hdmarace and s0age as dingbat predicted; psgrace a run-to-run lottery; fifolog 292/560); FIFO at timer periods 1-3 OPEN; `wakehb` 8/8 as dingbat predicted (47abe8ee, 2026-10-16) · **Date:** 2026-10-14, 2026-10-15; console runs 2026-11-04, 2026-11-05

Each item was first checked against all recorded cells with no console run. The probes written then were later recorded on the AGB SP with an empty slot (psgrace and s0age on 2026-11-04; timergeo, obusdma16, hdmarace and fifolog on 2026-11-05, table in §91).

- hdmaobus's six racing cells are the phase of the 7-cycle VCOUNT poll at arming; every word the console gave is among dingbat's answers over the 7 phases, and mGBA shares none. `tables.check` now scores such a cell by phase sweep (`r0table.RACES`, variant `hdmarace.s`, frozen in `tests/roms/cyclelaws/hdmarace.gba`): `r0table.py --check` 2001 to 2007 of 2025, cycle laws 2124 to 2130; the 18 misses left were keyirq2 and keyirq3 (§61). Console run of hdmarace: 42/42 as predicted with the table unrotated (mGBA 0/42), so the console wakes from the park on the core's cycle.
- The "halted H-blank wake +19" was a test that never halted (its HALTCNT write is cartridge code, which the console ignores); dingbat now reads it exactly (`03DD`). A running CPU's H-blank interrupt from a controlled cycle is unmeasured; probe `wakehb.s` (8 cells) has since been recorded on the AGB SP: dingbat 8/8, mGBA 0/8, now a cycle law (47abe8ee).
- The ÷64 timer phase is matched (24/24 timergeo cells; fix 80a88cd2, skip-BIOS entry at prescaler phase 776). Console run of the seven edge cells: 7/7 (mGBA 3/7); the edge on line 103 is at e = 7 and line 100's at e = 55. Now a cycle law.
- HLE call costs are matched (fixes ccb964c5, e6a453d1, df656c3e); IWCYCLE +10 is poll-anchor phase, not a cost.
- Post-DMA open bus is matched since 6f0ac75f and 83aa0391: the DMA's word stays until the CPU's next bus access, per halfword lane. §11's "still open" and the comment in bus.nim are out of date. Console run of `obusdma16.s`: 12/12, a 16-bit DMA leaves its halfword on both lanes. Now a cycle law.
- Sound FIFO at timer periods 1-3: OPEN. dingbat scored 76/264 on fifoffff here (111 after §91's refill rules). Console run of `fifolog.s` (560 cells): dingbat 292, the October four-rule model 366, mGBA 0. dingbat matches all of period 4 and period 3 with three words stored. At period 1 the console chains bursts back to back with the CPU off the bus; dingbat gives the CPU cycles between them, because `run_pending` re-checks the level at the grant and events due during a chain are dispatched 3 cycles late. At period 2 with three words stored the console makes more refills than any rule here explains. Prototypes moved 250 cells, none onto the console's answer; not in the core. No game runs a sound timer at 1-4 cycles.
- dbsuite's six failures (878/884): four depend on the dot each page starts on (all sixteen CONTEND2 values match at one of 36 phases, 72008a06); §91 parks those pages and brings dbsuite to 872/872. Two are PSG. Console run of `psgrace.s`: 232 of 256 cells answer more than one way over nine runs from a fixed entry cycle, so the PSG's phase at master-on varies from run to run and `apu/psg-ch1-after-ch2-lives` asks for one side of a coin toss; dingbat's answer is among the console's in 163 cells. The test should accept the console's set (done in §91). Console run of `s0age.s`: dingbat as it is matches all 256 cells; the slow shift-0 timing does not run out by itself, nor end on a length-ended note or an NR10 write. Now a gated law. The d33 sweep-trigger case is settled in §91.

Predictions for every probe are in `tools/hwlink/predicted.py`, set down before each run and not edited afterwards; `r0table.py --score` and `--drift` compare them with recorded answers. The cartridge probes (sramloop, eesettle, eesettle4k, flashprog) still await retail cartridges (§104).

## §80. Gradius Galaxies: stage 1 one frame behind both references

*Notes: "Gradius Galaxies: stage 1 a frame behind is the load queue's service order, a phase race at one V-blank; the +1 was the classifier's sign, 2026-10-14"*

**Status:** NOT DIAGNOSTIC (a race in the game); classifier sign bug FIXED (commit not stated) · **Date:** 2026-10-14

dingbat is one frame behind both references from f3773 at both stage checkpoints. The main thread scans a 16-slot load queue (0x03000028) while the game runs in the V-blank interrupt. At the f3755 V-blank seven requests are queued; mGBA's scan was at slot 14 and wraps to slot 0 first, dingbat's had just passed slot 0 and serves it last, which costs one game frame at f3768. Stalling dingbat's CPU 80-400 cycles at f3740 gives the references' order; the outcome repeats every ~530 cycles and depends on the scan's position to within ~28 cycles, so no measured rule decides it. Separately, `classify`'s shared-frame path reported offsets with the wrong sign; fixed in tools/playtest/classify.py with a test. Every shared-frame offset recorded before this section has its sign inverted; no verdict changed.

## §81. Rockman EXE 4.5: save screen reads three frames off

*Notes: "Rockman EXE 4.5: save_screen's SLIP(+3) is the install's ten-frame lead, read through the cursor's blink, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (same cause as §39 and §70) · **Date:** 2026-10-14

`save_screen` (f5092) reports +3 frames, but the real gap is ten frames with dingbat ahead, read through a 17-frame cursor blink. The PET scene's sprite tables (0x0200DAC0-0x0200DB1F) run ten frames ahead of mGBA from f3420, which is the install ending ten frames early (§39). Poking dingbat's two RNG words into mGBA at f3200 makes mGBA match dingbat on every frame f4948-f5272. `saved` (f6258) was not investigated.

## §82. Super Mario Advance 3: 1-1 made independent of the EEPROM format

*Notes: "Super Mario Advance 3: 1-1 after a soft reset, 2026-10-14"*

**Status:** Script and second-reference driver FIXED; HLE SoftReset timing FIXED (commits not stated); remaining 1-1 difference NOT DIAGNOSTIC · **Date:** 2026-10-14

The script now soft-resets (A+B+SELECT+START, frames 151-160) after the first-boot EEPROM format, so the chip's programming time no longer affects later frames; builds with `EEPROM_SETTLE_CYCLES` 101000, 108368 and 115005 are identical from f152. The second reference came out two frames ahead because its driver's `run_frame` swallowed V-blank starts when a long DMA (the 458,761-cycle EWRAM fill) ran past line 160; the driver now counts presentations and owes the extra frames back. That moves the second reference's frames in most of the corpus, and much of the boot lead §65 measured was this accounting. The remaining 1-1 differences (which way the first Shy Guy walks) come from an RNG at 0x03004BD8 that adds live VCOUNT ten times a frame; all three emulators differ from f1884, so those checkpoints compare random draws. Found on the way: dingbat's HLE SoftReset was 812 cycles short and now charges `SOFTRESET_BODY` = 810.

## §83. Mega Man Battle Network 2: title one frame behind both references

*Notes: "Mega Man Battle Network 2: the title a frame behind is mGBA's boot clear and the second reference's double frame, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (mGBA's EWRAM store cost; second-reference driver bug, FIXED in `tools/playtest/drivers/nba_driver.cpp`) · **Date:** 2026-10-14

mGBA is a frame ahead from f7: the boot's 256 KB EWRAM clear at 0x080001C8 costs 26 cycles an iteration in dingbat and 22 in mGBA, the 4-cycle EWRAM store under-charge of `slotexec.s` row 12 (console matches dingbat, measured at 4/2 waits; the game runs at 3/1). The second reference's lead was the harness: a 16,409-cycle DMA jumped VCOUNT from 159 to 172, the driver waited for exactly 160, and one harness frame ran two. The driver now stops at the first VCOUNT of 160 or more; the second reference is then identical to dingbat at `title` and `main_menu`. The same double frames occurred in 78 of 164 games (161 frames), so the baseline's second-reference results needed recording again.

## §84. Hamtaro - Rainbow Rescue: "Bye-Q" screen one frame early

*Notes: "Hamtaro - Rainbow Rescue: the "Bye-Q" a frame early, the prefetcher read ROM through an SRAM store, 2026-10-14"*

**Status:** OPEN (likely dingbat bug; fix held on branch `sram-holds-gamepak-bus`, 4889b3aa, until a cartridge measurement) · **Date:** 2026-10-14

`bye` (f6212) is one frame early against both references. The quit save copies 19,021 bytes to SRAM in a Thumb loop at 0x081B79BA (WAITCNT 0x4017); a byte costs 27.78 cycles in dingbat and 31.00 in mGBA. dingbat's prefetcher keeps fetching ROM during the SRAM store, although SRAM sits on the cartridge's own pins and holds that bus. The held rule (`SRAM_HOLDS_GAMEPAK_BUS` in bus.nim) makes the loop 29.0 cycles a byte and `bye` identical to both references, with all timing tests unchanged. It is off main because the playtest train cannot decide it (one regression, Dragon Ball Z - The Legacy of Goku II, which is a few-cycle boot race the rule only nudges) and the console's cost is unmeasured. Probe: `tests/roms/payloads/sramloop.s` (r0table row `sramloop`) with the Hamtaro cartridge (A84P); 28 cycles a byte keeps the current rule, 29 lands the held rule, 31 or more lands a variant that also empties the prefetch buffer.

## §85. Rhythm Tengoku: title logo balls land in different places

*Notes: "Rhythm Tengoku: the title's logo balls are drawn from an idle-loop RNG, and the references meet only on the settled logo, 2026-10-14"*

**Status:** NOT DIAGNOSTIC (idle-loop RNG) · **Date:** 2026-10-14

`title` (f996) differs from both references. The five logo balls are drawn at f692 from a 16-bit LCG at 0x030000B4 that the V-blank wait loop steps once per idle pass, about 1.49 million passes since f7; one pass of difference changes every draw. All three emulators hold different states and the two references match only once the logo has settled. A pass costs 100 cycles in dingbat and 98 in mGBA (dingbat's extra is hardware-verified prefetcher behaviour, alyosha prefetcher_branch_thumb_2). The second reference enters the ROM on line 225, not the console's line 126. The script marks `title` as `@known`.

## §86. Final Fight One: intro story one frame behind both references

*Notes: "Final Fight One: intro_story a frame behind is §29's load, now that the second reference keeps mGBA's frame, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (§29's load; references under-charge) · **Date:** 2026-10-14

`intro_story` (f630) is one frame behind from the load at f280: mGBA enters the idle loop 17,564 cycles before the V-blank, dingbat 26,684 after it. The 44k-cycle gap is renderer contention on the LZ decompressor's VRAM accesses and the branch commit wait (both console-measured), EWRAM word stores from cartridge code (`slotexec.s` on the SP agrees with dingbat), and the fetch after cartridge `ldmia`. With contention and the commit wait both turned off dingbat still misses the V-blank by 2,956 cycles. The second reference now keeps mGBA's frame; it has no trace, so its margin is unmeasured.

## §87. The Sims - Bustin' Out: language screen one frame behind

*Notes: "The Sims - Bustin' Out: the language screen a frame behind is the first boot's EEPROM format against mGBA's cheap memset, 2026-10-14"*

**Status:** OPEN (needs EEPROM programming time measured on the cartridge); checkpoint now passes after classifier change 53668273 · **Date:** 2026-10-14

`language` (f632) is one frame behind both references because the boot reaches the main loop just after a V-blank. Two things set that: the first-boot format of 22 blocks of the 64 Kbit EEPROM (a block takes 115,686 cycles in dingbat with `EEPROM_SETTLE_CYCLES` 108,368, and 122,140 in mGBA), and a memset at 0x08027A8A into EWRAM (18 cycles an iteration in dingbat and the second reference, 14 in mGBA, which is below the bus cost). The second reference reaches mGBA's frame with a faster chip (101,392) and dingbat's memset cost. A dingbat build with a programming time of 104,800 or less lands on the references' frame; 105,100 or more stays behind. Probe: `eesettle` with The Sims cartridge (ASIE): about 104,790 or less means dingbat's constant is wrong for this chip, about 105,090 or more means the references are wrong. The text comparison now treats a picture found in the other side's window as a frame slip, so the checkpoint passes.

## §88. Yu-Gi-Oh! - The Eternal Duelist Soul: duel start 40 frames off

*Notes: "Yu-Gi-Oh! - The Eternal Duelist Soul: start_duel forty frames off is a rock-paper-scissors draw, the RNG one step behind since the boot load, 2026-10-14"*

**Status:** NOT A DINGBAT BUG (§33's boot load; mGBA below bus cost) · **Date:** 2026-10-14

`start_duel` (f2956) is 40 frames off and `duel_field` differs because the opponent throws scissors in dingbat and rock in both references, so the references replay the rock-paper-scissors round. The RNG word at 0x03000040 is one step behind in dingbat from f582, where §33's boot load ends 21k cycles after the V-blank in dingbat and 55k before it in mGBA. Poking dingbat's RNG value into mGBA at f2441 makes both checkpoints identical to dingbat. The second reference takes dingbat's eight frames for the load and is on mGBA's frame only through its boot lead. The script carries `@known` for `duel_field` and the audio. A four-frame difference in the opponent's deal after the poke was not traced.

## §89. Gunstar Super Heroes, Klonoa 2, Mario Party Advance: three text-comparison failures

*Notes: "Gunstar Super Heroes, Klonoa 2, Mario Party Advance: three text comparisons that read rounding and sparkles, 2026-10-14"*

**Status:** NOT A DINGBAT BUG; scripts changed to pixel comparison; Mario Party's EEPROM time OPEN · **Date:** 2026-10-14

All three failed only on what OCR read. Gunstar `new_data`: alpha-blend truncation (§72; BLDALPHA 0x0510), identical state. Klonoa 2 `pause`: darken truncation (§40; BLDY 9), plus one lost frame at the pause menu load, where dingbat misses the V-blank by about 255 cycles because of console-measured VRAM contention on two DMA3 copies; a `-d:CONTENTION=false` build lands on the references' frame. Mario Party Advance `secret`: a star's sparkles from an RNG (0x0203A4B8) whose phase follows the first-boot format of the 64 Kbit EEPROM; a build with `EEPROM_SETTLE_CYCLES=101000` matches the second reference bit for bit. The probe `eesettle` with the Mario Party cartridge (B8ME) would measure the chip. The three scripts now judge these screens by pixels and all pass.

## §90. The Urbz: goals screen one frame behind both references

*Notes: "The Urbz: goals a frame behind is the street's random load, seeded from the frame the first-boot flash format ended, 2026-10-14"*

**Status:** NOT DIAGNOSTIC (random seed from boot length); flash program time OPEN (needs cartridge measurement) · **Date:** 2026-10-14

`goals` (f8643) is one frame behind because the street's 30 Hz logic phase differs after two street loads. The loads are random: an MT19937-style generator is seeded at f1812 from the V-blank counter at 0x0300489C, which starts when the boot ends (f58 dingbat, f60 second reference, f81 mGBA). Poking a reference's boot counters into dingbat at f1800 gives that reference's `goals` frames 60 of 60; sweeping the offset gives no pattern. The boot length is the first-boot flash format of about 20,000 bytes: dingbat's flash (ID 1B32) has no busy time, mGBA models one, and the second reference identifies as SST (D4BF). Real flash is not instant, so the console almost certainly boots later than dingbat by an unknown number of frames. Probe: `flashprog` with The Urbz cartridge (BOCE); a measured busy time per chip ID belongs in `storage/flash.nim`.

## §91. alyosha gba-tests and dbsuite: the last failing tests, FIFO refill and interrupt rules

*Notes: "alyosha's last three rows: a crash, a retracted model, and the refill that comes right behind the first, 2026-10-14"*

**Status:** FIXED in core and HARDWARE-CONFIRMED: alyosha 125/125, dbsuite 872/872 on dingbat and on the console (commits not stated here; §79 mentions 6b79b303 for the FIFO refill rules); 10 FIFO interrupt cells and fifolog OPEN · **Date:** 2026-10-14, 2026-11-04, 2026-11-05

alyosha stood at 123/126. `unsafe/prefetcher_branch_thumb_arm_2` crashes on a console by the suite's own README, so it is not scored. `fifo_dma/fifo`: a flashcart run on the AGB SP (`tests/roms/alyfifo.py`, 2026-11-04) read 104 / 139 / 104 / 104 / 165, so the ROM's expected 0x68 is the console's. The author's explanation (a fixed ROM source uses all non-sequential accesses) stays refuted: it would give 0x98 at the second read, and `payloads/fifoslot.s` shows a fixed source bursts like an incrementing one, 32 cycles. The real rule is `FIFO_CART_CHAIN_LATE` (apu/dma_channels.nim): with the CPU fetching from the cartridge, a request on the cycle after a burst's hand-back is chained; `run_pending` also keeps the CPU's fetch stream sequential behind it. Measured with the prefetcher off only; `tests/roms/alyfifo2.py` holds the neighbouring periods, with no console result stated. `fifo_dma/fifo_6` passes on the flashcart (the handler reads TM1 = 0x7B; dingbat was 3 cycles late and read 0x9C). It passes in dingbat with `FIFO_FETCH_WINDOW` (a FIFO request landing in an opcode fetch from board WRAM or the gamepak is granted at the fetch's end), `FIFO_IRQ_PF_EXTRA` = 1 and `IRQ_PIPE_STRICT` = 2, on top of `FIFO_IRQ_CREDIT` = 1 and `IRQ_FETCH_STOPPED_BUFFER`. `IRQ_PIPE_STRICT` bit 0 is off: it silenced Earthworm Jim (USA).

The interrupt rules were measured with the slot empty: ARM words fetched there are condition NV and run as one-cycle no-ops (`payloads/nvcond.s`), which gives a gamepak NOP sled at WAITCNT 0x4000 (`f6slot.s`, `dmairqv.s`, `f6q.s`; 452 cells), and from a flashcart at 3/1 waits (`tests/roms/fifokit.py`, kit3, 449 cells). A second round (2026-11-05) added `IRQ_WINDOW_KEEP`, `IRQ_LINE_KEEPS_STAMP`, `IMM_FAST_FETCH_GRANT` (`dmairqk.s`), `IRQ_PIPE_PER_SOURCE` and the first half of `PF_WAIT_UNDER_BURST`; the whole of that rule fails fifo_2 to fifo_4. Missed cells over all recorded tables went from 512 to 290 per BIOS, 251 of them psgrace's lottery. Still open: f6slot_open 1, f6q_open 6, f6q3@KIT3 3. mGBA suite 0/13996 failing under both BIOSes; train (230 games) no regression.

Refill rules, from `fifoslot.s` (644 cells, now `cyclelaws/fifoslot.gba`): `FIFO_LEVEL_AT_OVERFLOW` (an overflow inside a refill burst counts only the words written so far), `FIFO_DROP_BUSY` (a request inside the channel's own burst is lost), `FIFO_HANDBACK_CHAIN` (a request on the burst's hand-back cycle takes the next burst's first read). Fitted on 430 cells; 266 new predicted cells all matched. fifoffff goes from 75 to 111 of 264. Library sweep identical on 7898 of 7899 ROMs; GBA save-state payload revision 11.

dbsuite: 872/872 in dingbat, the multiboot image 775/775 and the cartridge build 872/872 on the console (2026-11-05; build.py now pads the cartridge image with 0xFF to 128 KiB, after a 114864-byte image hung on the flashcart). The last failures were placement: CONTEND2, DMATIME and sweeptrig now park on a V-count match, and three PSG tests accept the console's lottery (new case kind `K_ZRANGE`: 0 or the range). Two core fixes came out of it. `FB_EXIT_HOLD_LINES` = 3 (`c2fb.s`, 48 cells): after forced blank is cleared on line L, BG and palette fetching resume on line L+3, where dingbat drew from L+1; only contention is measured, so what the two held lines show still needs a photograph and the OBJ layer is unchanged. `s0_after_shift`, a third case of `ch1_s0_kill_at` (`stphase.s` to `stphase4.s`, 1280 cells, all matched, from 492): a shift-0 sweep check after a shift-1 trigger depends on the pair of 16-cycle APU phases; it is a fit to the cells, not a circuit. The irqlat differences are not model gaps: `irqpoll.s` (512 cells) and `anchorpoll.s` (192) are dingbat's at every phase, and each difference is under one poll period, so the fix belongs to the test (park its anchors; not stated as made).

§79's last four probes were also recorded here (timergeo 7/7, obusdma16 12/12, hdmarace 42/42, fifolog 292/560; see §79). fifolog stays open at periods 1 and 2; turning off any existing FIFO rule loses more cells than it gains.

## §92. Fire Emblem: The Sacred Stones: two menus over fog never match

*Notes: "Fire Emblem: The Sacred Stones: the two menus are the blend's rounding over lag frames, 2026-10-15"*

**Status:** NOT A DINGBAT BUG as far as measured; two small points OPEN · **Date:** 2026-10-15

Closes section 6. At `select_mode` (f1395) and `slots_empty` (f1561) every differing pixel is the alpha blend (BLDCNT 0x0844, BLDALPHA 0x1006, fog BG2 over BG3; section 6's 0x3C42 / 0x030D were from an older timeline). Applying mGBA's widened formula to dingbat's layers reproduces mGBA exactly; rounding with green at 6 bits reproduces the second reference exactly, bar 3 pixels. The SP photographs confirm dingbat's truncation (§72). The fog's phase differs because of lag frames: mGBA lags none at f1500-f1506 where dingbat lags 3 and the second reference 2, as dingbat is 3% dearer on cartridge code (§29 class). Open: which of dingbat and the second reference is on the console's side of that one frame (3/1 wait prefetch costs are unrecorded), and when a text BG takes BG2HOFS for its first tile (3 pixels).

## §93. Six new game scripts (Max Payne, Driv3r, Harry Potter 3, Ty 2, Earthworm Jim 2, Super Robot Taisen OG2)

*Notes: "Six licensed games with video-style scenes: two reference saves that never come back, and Super Robot Taisen OG2's frame counter one behind at a 24 KB LZ77, 2026-10-15"*

**Status:** NO CORE CHANGE; all dingbat configurations pass · **Date:** 2026-10-15

Max Payne: the second reference writes 8192 bytes for the 4 Kbit EEPROM and cannot read its own file (fixed in §94). Driv3r: the second reference never shows a picture (fixed in §94). Super Robot Taisen OG2: the frame counter in the quick-save (0x02001B64) is one behind in dingbat, lost at f1099 where LZ77UnCompWram of 24,576 bytes from cartridge to EWRAM takes 388,008 cycles (1.38 frames) and the references finish inside the frame; same class as §29 and §33, and the HLE's LZ77 steps match the console. Other differences are between references or between all three.

## §94. Second reference: black screen in three games and 8 KB files for 4 Kbit EEPROMs

*Notes: "The second reference's skipped boot entered the cartridge with interrupts masked, and sized 4 Kbit EEPROMs as 64 Kbit, 2026-10-15"*

**Status:** FIXED in the harness (second-reference driver and emu.py; commit not stated) · **Date:** 2026-10-15

Asterix & Obelix XXL, V-Rally 3 and Driv3r stayed black in the second reference because its skipped boot enters the cartridge with CPSR 0xDF (IRQ and FIQ masked) where the BIOS hands over 0x1F, and these games never clear the I bit. The driver now clears I and F after reset. With a third witness, V-Rally 3's and Asterix's differences are mGBA alone; Driv3r's traffic is random in all three. Separately, the second reference sized most 4 Kbit EEPROMs as 64 Kbit (49 corpus games) and then read its own file as blank; emu.py now passes `--backup eeprom4` for the game codes in `EEPROM_4K`. Neither change touches dingbat.

## §95. Columns Crown: dingbat lost every save (4 Kbit EEPROM sized as 64 Kbit)

*Notes: "Columns Crown: three stray CPU stores at boot size the 4 Kbit EEPROM as 64 Kbit, and dingbat loses every save, 2026-10-15 (fixed 2026-10-16)"*

**Status:** FIXED 2026-10-16 (commit not stated); console probe not yet recorded · **Date:** 2026-10-15, 2026-10-16

dingbat booted every save as a blank cartridge and wrote an 8 KB file with scattered bytes. At boot the game probes for flash with three CPU `strh` stores to 0x0DFFFFFE (0xFF, 0x90, 0xFF). dingbat's EEPROM took them as serial bits 1, 0, 1 (a write command), sized the chip from a stale DMA3CNT_L as 64 Kbit, and parsed every later command with 14 address bits. Fix (storage/eeprom.nim, bus.nim): a store to the EEPROM outside a DMA burst is a transfer of its own that shifts nothing in and drops an unfinished command; a byte store counts as a store; the chip can only be sized by a DMA3 command. Save-state format unchanged. Train 20261016-040222-1c: Columns Crown fail to pass, all emulators write the same 512-byte file, no other game of 206 moved; unit tests in tests/gba_rtc_test.nim. What one stray bit really does to the chip is unmeasured (the rule is inferred from GBATEK's pin-out and the game saving on hardware); probe `tests/roms/payloads/eestray.s` (rows `eestray4k`, `eestray`), to record with the Columns Crown cartridge (ACGE).

## §96. Save cross-load check could not tell "did not read the save"

*Notes: "The [load] matrix had no way to tell "did not read the save": a blank-cart control in each reference, 2026-10-16"*

**Status:** FIXED in the harness (pipeline.py `cross_load_verdict`; commit not stated) · **Date:** 2026-10-16

Columns Crown (§95) passed because every rule compared readers with each other, and the second reference also booted the save as blank. Each reference now also plays `[load]` with no battery file (`load/blank-in-<reference>`). dingbat fails when it shows a blank cartridge's screens for a non-blank save that a reference reads, and when its own save loads as blank while a reference reads it or both references round-trip their own. Two exemptions: Classic NES Series Metroid and Super Mario Bros. (dingbat shows the save as its writer does), and Mario & Luigi (one reference also loses its own save). Re-scoring baseline 722d1703b1f2 (188 games) changed no verdict except Columns Crown. Tests: `tests/test_crossload.py`.

## §97. Famicom Mini Akumajou Dracula black top lines; Xevious clicks; ChuChu Rocket one frame behind

*Notes: "Famicom Mini: a 128-tall OBJ at Y=154 belongs at the top (fixed), and Xevious's FIFO DMA reads past its buffer; ChuChu Rocket's save CRC, 2026-10-16"*

**Status:** Akumajou Dracula FIXED 2026-10-16 (commit not stated); Xevious FIXED in §99; ChuChu Rocket OPEN · **Date:** 2026-10-16

Akumajou Dracula (FADJ): lines 0-25 were black. Four 128-tall affine OBJs at Y=154 belong at the top of the screen (GBATEK: a 128-tall OBJ at Y>128 is treated as negative), where they use up the 954-cycle OBJ line budget so that four full-width masking OBJs never draw; dingbat put them on lines 154-159. Fix in ppu.nim (`obj_row`): a line is inside an OBJ when ((L - Y) & 0xFF) < drawn height. Whether such an OBJ also shows on lines Y..159 is unmeasured (docs/hwprobe-questions.md). Train 20261016-005726-2c: fail to pass, nothing else moved. Xevious (FXVJ): single-sample clicks in silences, because the FIFO DMA read one word past its buffer (cause and fix in §99). ChuChu Rocket (ACRE): `continue_title` is a frame behind because a boot CRC-32 over 32,800 bytes costs 2 cycles a byte more than in mGBA (cartridge prefetch accounting at 3/1 waits, unmeasured on the console); the script passes.

## §98. The Lord of the Rings - The Third Age: two battle scenes one frame off

*Notes: "The Lord of the Rings - The Third Age: the two battle scenes a frame off are the map's 30 Hz phase, flipped by two-frame overruns in all three emulators, 2026-10-16"*

**Status:** NOT DIAGNOSTIC (30 Hz phase races in all three emulators) · **Date:** 2026-10-16

`melee_attack` is a frame late and `ranged_attack` a frame early against both references. The battle map runs at 30 Hz and reads keys once per iteration, so the press is seen a frame apart when the iteration parity differs. The parity flips whenever an iteration overruns into a third frame, which happens at different iterations in each emulator (15 times in dingbat, 11 in each reference over f2400-5000), each decided by 4-5k cycles and by sparkle content that already differs. Poking the iteration-start count (0x030047A0) in mGBA to dingbat's phase puts the scenes on dingbat's frames. The two references reach the same phase by different routes. One flagged audio window (f2985-3000) has the same cause. No console probe could settle which frame is right.

## §99. Driv3r audio failure (harness) and Xevious clicks (core)

*Notes: "Driv3r's audio was the second reference's capture running 0.24% short; Xevious's click was an immediate DMA armed without its enable edge, 2026-10-16"*

**Status:** Driv3r FIXED in the harness; Xevious FIXED in core, `IMM_NEEDS_EDGE` (commits not stated) · **Date:** 2026-10-16

Driv3r failed on audio only (81 of 703 windows). The second reference's audio dump was 0.24% short (547.28 samples a frame, not 548.58) because the driver pulled samples for the cycles it requested, not the cycles the core ran; its audio was read progressively early. Fixed in the driver; this affected all 182 games (0.09-0.42% short). `audio.py` now reports any dump more than 0.05% off 548.58 samples a frame (`rate_off`). mGBA really does start Driv3r's sound 1-2 frames late after loads and 6 late in the video, mGBA alone. With aligned dumps, Kingdom Hearts - Chain of Memories (§30, FIFO reset; the SP agrees with dingbat), Swordcraft Story 2 (§57) and Iridion 3D became `@known`. In 11 games dingbat's and mGBA's dumps are both 0.05-0.08% short; not investigated.

Xevious (§97): the timer 1 interrupt rewrites DMA1CNT with enable kept and timing set to immediate (0x8440) for 24 cycles. If an H-blank DMA0 burst ended in that window, dingbat's DMA chaining (`chain_next`, and `request_immediate`) ran DMA1 for one 4-word burst past the buffer end. A transfer should start only on the enable bit's 0-to-1 change (GBATEK). `IMM_NEEDS_EDGE` in gba/dma.nim blocks such a channel (`DMA.imm_blocked`) until it is disabled or edge-enabled; the mask is saved in a spare nibble with no save-state revision change. Train (206 games): Xevious and Driv3r fixed, nothing regressed in dingbat.

## §100. Famicom Mini Disk System games hang; Nazo no Murasamejou click

*Notes: "Famicom Mini Disk System: the file lookup's walk through unmapped memory never ends in dingbat (Metroid, Shin Onigashima and Palutena's game over hang), and Nazo no Murasamejou's timer interrupt waits 39,000 cycles behind a preempted H-blank DMA, 2026-10-16"*

**Status:** (1) NOT A DINGBAT BUG (truncated ROM dumps); (2) FIXED in core (commit not stated) · **Date:** 2026-10-16

(1) Metroid (FMRJ) and Shin Onigashima (FFMJ) showed a black screen, and Palutena (FPTJ) hung at game over, in dingbat and the second reference. The Disk System volumes are 4 MB cartridges and the 1 MB files are only their first megabyte; the game's file directory lies past it (Metroid 0x08160000, Palutena 0x08200000, Shin Onigashima 0x08170000). On the 1 MB files the lookup reads mirrored data and walks unmapped memory until an open-bus value happens to end it, which mGBA's open-bus rule does (in a case where the SP answers differently) and dingbat's does not. On the 4 MB "[o1]" files all three emulators play, so the corpus scripts moved to those. An earlier theory in this section blaming H-blank DMA request timing was wrong.

(2) Nazo no Murasamejou: one click at f1306, FIFO DMA1 reading 64 bytes past its buffer. A timer 1 interrupt raised one cycle before an H-blank DMA burst that was preempted by FIFO DMAs was taken 39,272 cycles late with IME, CPSR.I and IE all open: the interrupt check was drained inside the burst and never booked again. Fix in dma.nim `run_pending`: at the outermost burst's end, book a check whenever a raise is pending and no check is scheduled at or before it. Before the fix 23 corpus games hit the hole, none after. Regression test `tests/irqburst_test.nim` (`nimble test_irqburst`). Recorded timing tables and cycle laws unchanged (756/774, 2782/2782). Train (229 games): five games moved, none regressed.

## §101. Six new scripts: bit Generations, Polarium Advance, Puyo Pop

*Notes: "bit Generations (Coloris, Dial Hex, Boundish, Digidrive), Polarium Advance, Puyo Pop: six new scripts; random boards from timer 1, and an SIO transfer dingbat never clocks, 2026-10-16"*

**Status:** NO CORE CHANGE; one suspected dingbat bug OPEN (SIO clock switch, unverified) · **Date:** 2026-10-16

All dingbat configurations agree in all six. Coloris: the board seed is TM1CNT_L, read 14.8k cycles earlier in mGBA (cheaper ROM `ldmia` in BIOS CpuFastSet, no VRAM contention); not diagnostic. Dial Hex: seeded from timer 1 at prescaler 1024; dingbat counts the prescaler on one free-running divider, as the AGB SP does (hwprobe TIMPHASE), mGBA from the enable, so they differ by one tick; `@known`. Coloris and Dial Hex also start a normal 32-bit SIO transfer on the external clock, then switch to the internal clock with Start still set (SIOCNT 0x5084 to 0x5085); both references complete the transfer and dingbat never clocks it (`serial.nim` `write_siocnt` starts only on Start's rising edge). Nothing visible depends on it, confidence that dingbat is wrong is moderate, and a link-rig test would settle it. Boundish: mGBA drops one lag frame fewer; the second reference matches dingbat. Digidrive: random draws differ from the first frames, not traced. Polarium Advance: the second reference crashes at boot (its own problem). Puyo Pop (APYE) is a 4 Kbit EEPROM missing from emu.py's `EEPROM_4K`.

## §102. The Pinball of the Dead: three checkpoints differ from both references

*Notes: "The Pinball of the Dead: the table's tasks start in another order because three task creations land 1,302 cycles later in dingbat, 2026-10-16"*

**Status:** OPEN (`@known`; needs a cartridge-side measurement at 3/1 wait states) · **Date:** 2026-10-16

`paused`, `data_save` and `saved` differ in every dingbat configuration; saves are byte-identical. When the first table loads (f2855) three task-create calls (0x08002B20) land 1,302 cycles later in dingbat, so the third falls after the line-0 VCOUNT interrupt and the tasks start in another order (0x03001ED0 / 0x03001F48 read 02/82 against 82/02). The extra cycles are two Thumb loops in ROM that load and store EWRAM (0x08012338, 0x08003326; WAITCNT 0x4314). This is §63's question of whether the prefetcher keeps fetching ROM during EWRAM data accesses: at 4/2 waits the console agreed with dingbat (`slotexec`), but no recorded measurement covers 3/1. It is not interrupt or DMA latency (§100's fix does not move it).

## §103. Full corpus rerun at main 42a555d5, with mGBA master as an extra reference

*Notes: "The whole corpus again at main, every difference qualified, and mGBA master as a second mGBA, 2026-11-11"*

**Status:** NO CORE CHANGE; 223 PASS, 7 KNOWN, 0 FAIL; one lead OPEN (Derby Stallion Advance, traced in §104) · **Date:** 2026-11-11

All 233 scripts were run in every default configuration with both references played live; three new scripts (Sennen Kazoku, Hello Kitty Collection, Kim Possible 2) have no `[new]` yet and are skipped. Of 1,860 checkpoints all three emulators agree on 1,436 and dingbat stands alone on 29 (32 on 16 October). Circle of the Moon, Iridion 3D, Swordcraft Story 2 and Rhythm Tengoku went from KNOWN to PASS and their `@known` lines were removed. New tool `tools/playtest/divergences.py` lists every frame, load, save and harness difference with a tier (S1 act, S2 chase, S3 watch, S4 noted, R reference-side): no S1, and the three S2 items are mGBA's own run diverging (Earthworm Jim 2) and the phases of §69 (Starsky & Hutch) and §87 (The Sims). dingbat's save differs alone in 2 of 180 games (The Sims, §87; Yu-Gi-Oh! EDS, §33). mGBA master 662dada8 was built headless (the driver needs two changes for 0.11) and played on the 189 games with any difference: it matches 1,078 of 6,295 console cells in r0-agb.json (0.10.5: 1,060; dingbat 5,743) and moves none of the load-pricing games (§29, §63, §78, §88). With it, three games fail on animation phases (Tony Hawk's Underground, Digidrive, Advance Wars 2; the last two fixed in the harness in §106). Derby Stallion Advance is the one lead: both references pick the same advisor line at `stallion_fee` and write the same Flash 512 save, 54 bytes from dingbat's.

## §104. Every dingbat-side difference checked against the console rig

*Notes: "Every divergence against the console rig: what reproduces with the slot empty, what needs a cartridge, 2026-11-11"*

**Status:** SIO clock switch (§101) FIXED and HARDWARE-CONFIRMED (commit not stated); Banjo Pilot and Derby Stallion Advance OPEN (need a cartridge); Shin Onigashima NOT A DINGBAT BUG (the second reference) · **Date:** 2026-11-11

Each dingbat-involving item of §103 was sorted by the mechanism under it. Run on the AGB SP: `payloads/sioclk.s`, a 32-bit normal SIO transfer started on the external clock and then switched to the internal clock with Start still set. The console completes it 2,065 cycles after the start store, with the serial IRQ; dingbat never did (it started only on Start's rising edge), mGBA completes it in 12-14 cycles and the second reference 12 cycles early. Fixed in serial.nim `write_siocnt`; cycle laws 5,086/5,086 under both BIOSes; the train's one change is Pokémon Emerald's audio, neutral. Every recorded console cell the earlier readings rest on still matches; dingbat's 552 misses in r0-agb.json are all in tests marked open or racing, none under a game difference. Banjo Pilot `select_cup`: 9.9k cycles over the frame, about 8.8k of them single EWRAM loads and stores from Thumb code in ROM at WAITCNT 0x4314 (3/1, prefetch on), the same unmeasured class as §33, §39, §70, §78, §88 and §102; the flashcart probe is `tests/roms/ewrombench.{s,py,gba}`. Derby Stallion Advance: the first-boot flash format takes 100 black frames in dingbat (no busy time), 123 in mGBA 0.10.5, 265 in mGBA master and 244 in the second reference, which then deals a different mare; `flashprog` with the retail cartridge (A8PJ) would give the chip's program time. Shin Onigashima `saved_title`: dingbat and mGBA master match on every frame and the second reference is a frame ahead. Probes with registered predictions await retail cartridges for The Sims, Mario Party Advance, Custom Robo GX, Super Mario Advance, Starsky & Hutch, Hamtaro, The Urbz, Mario vs. Donkey Kong, Advance Wars, Derby Stallion and Columns Crown.

## §105. Save chip detection: Breath of Fire (J) freezes, Famicom Mini Excitebike (J) cannot save

*Notes: "Save chips the ROM does not name: a census of 7,899 ROMs, Breath of Fire (J)'s SRAM and Excitebike (J)'s EEPROM, 2026-11-11"*

**Status:** FIXED in core (storage/pending.nim; commit not stated) · **Date:** 2026-11-11

dingbat chose the backup chip from the save library strings in the ROM, with EEPROM first when several are named and SRAM when none is. Breath of Fire (J) (ABFJ) names EEPROM, flash and SRAM but uses SRAM, so its settings save never verified and the options screen froze. Famicom Mini Excitebike (J) (FEBJ) names no library but saves to a 64 Kbit EEPROM, so it reported a failed save and wrote no file. In the 7,899-ROM library 1,573 name no library and 102 name two or more, 31 of them EEPROM beside another type; 7 of those 31 probe SRAM or flash first and then use EEPROM, so "the first access decides" would be wrong. New rule: with no battery file, an EEPROM-plus-other cartridge starts undecided with the SRAM region answering as no chip (reads 0xFF, writes dropped); any access to the EEPROM window settles EEPROM, and a CPU write to 0x0E after 256 CPU reads with no write settles SRAM. A cartridge naming no library settles on its first access: the EEPROM window gives EEPROM, 0xAA to 0x0E005555 a 64 KB flash, any other CPU access to 0x0E/0x0F SRAM. DMA accesses to 0x0E/0x0F never decide, a battery file of a chip's size decides first, and a cartridge that never touches save memory writes no file. Save states carry the undecided chip (kind 4). Checked: Breath of Fire (J) saves 92 bytes of SRAM and plays on; Excitebike (J)'s script (`ad9a633c`) passes; the 23 corpus games of these two kinds all pass; eight other probing games write the same chip and bytes as before. Random-input sweeps of 35 conflicting-string and 625 no-string games in three emulators found no other lost save.

## §106. Digidrive and Advance Wars 2: two cross-load false alarms

*Notes: "Two cross-load false alarms: a screen that shows no save, and a map whose units idle at each reader's phase, 2026-11-11"*

**Status:** NOT A DINGBAT BUG; FIXED in the harness (pipeline.py `shows_save_elsewhere`; Advance Wars 2 script; commit not stated) · **Date:** 2026-11-11

Both appeared only when mGBA master (662dada8) was played (§103). Digidrive: at `menu_loaded` the menu shows no save data over a background each emulator animates at its own phase, so §96's blank-cartridge control judged that mGBA read the save and dingbat did not. dingbat does read it: at `play_menu_loaded` and `ranking_loaded` it differs from every blank run and agrees with the references. New rule: a `[load]` cell that shows the save at one checkpoint has read it, and its blank-looking picture at another checkpoint is noted as not diagnostic. A save lost for good looks blank at every checkpoint, so Columns Crown (§95) still fails; tests in `tests/test_crossload.py`. Advance Wars 2: at `resumed_map` each reader draws every writer's save the same way and the three saves are byte-identical, but units and cursor animate at each reader's own phase and no ±30-frame window shares a frame. The script now judges that checkpoint by text (`compare=text`: funds, day, HQ panel); a lost save would draw the prologue. The OCR score on the busy map is near its threshold (0.77 against mGBA 0.10.5).

## §107. Library sweep: 1,181 games outside the corpus under random input

*Notes: "The library outside the corpus: 1,181 games under random input in three emulators, 2026-11-12"*

**Status:** NOT A DINGBAT BUG (27 flagged, none dingbat's); NO CORE CHANGE · **Date:** 2026-11-12

`inputsweep.py sweep --pattern deep --frames 12000` ran every library title that no script or games.json covers (tag `lib-2026-11-11`) in dingbat, mGBA 0.10.5 and the second reference, with §105's save-chip rule in the core. 27 of 1,181 were flagged and each was read against its screenshots. Eleven are the game's own sleep option picked by the random input: dingbat stays in Stop until the wake keys, as the console does, and the references take the next interrupt. In nine dingbat agrees with one reference where the other took another path. In six all three differ. One has dingbat alone, Pro Mahjong Tsuwamono Advance (J): dingbat returns to the publisher logo where both references go on to player select. Traced to the scene number at 0x02015854 leaving the rules screen on a different key press (f5145 in dingbat, f5149 in mGBA) after the paths had already split in the rules menu; shifting the keys a few frames swaps the outcomes, and the final saves are byte-identical. Nothing here needs the console. The harness also gained gyro and tilt input (`gyro RATE`, `tilt X Y`); WarioWare: Twisted! now plays its first stage, identical to mGBA at every checkpoint.
