# GB/GBC emulator main file
# All types are declared here; implementation files are `include`d.

import std/[bitops, os, strutils, times]
import ../common/[input, scheduler, emu, resampler, serialize, timestretch, cheats]
import ../common/lut_macros
when defined(test_harness):
  import ../common/test_output

# ---- Timing constants -------------------------------------------------------
#
# Every knob below is `-d:NAME=n` overridable so it can be swept without editing
# the tree. The shipping value is the one written here.
#
# **Derivations live in docs/gb-timing-constants.md, keyed by constant name** --
# the ROMs that bracket each value, the sweep tables, and the alternatives that
# were built and refused. Read that before changing a number; the comments here
# say only what the constant IS.

const LY_BLIND_SCOPE* {.intdefine.} = 1
  ## Which LY advances open the LY=LYC comparator's blind window
  ## (`ly_advance_close`, ppu.nim): -1 none, 0 rendered line boundaries, 1 also
  ## vblank-to-vblank, 2 also the mode 0 -> 1 entry on line 144.

# STAT knobs live here rather than beside their write-ups in ppu.nim because the
# GbPpu fields they gate are in the type block below.
const STAT_IRQ_LEAD* {.intdefine.} = 0
  ## Dots the LYC, mode 0 and mode 1 STAT sources rise before their own edge.
const STAT_LYC_LEAD* {.intdefine.} = 0
  ## The same lead for the LYC source alone.
const STAT_IRQ_SPLIT* = STAT_IRQ_LEAD != 0 or STAT_LYC_LEAD != 0
static:
  # Both drive one early-advancing domain (irq_ly / irq_mode), so they cannot ask
  # for different leads at once. Either may be 0.
  doAssert STAT_IRQ_LEAD == 0 or STAT_LYC_LEAD == 0 or
           STAT_IRQ_LEAD == STAT_LYC_LEAD,
    "STAT_IRQ_LEAD and STAT_LYC_LEAD drive one domain: set one, or set both equal"
const STAT_DOMAIN_LEAD* = max(STAT_IRQ_LEAD, STAT_LYC_LEAD)

const STAT_READ_SAMPLE*     {.intdefine.} = 2
  ## A CPU STAT read samples the mode bits on dot `cc - STAT_READ_SAMPLE`.
const STAT_READ_SAMPLE_DS_ADD* {.intdefine.} = 1
  ## Double-speed addend, separate so the read stays branchless:
  ## `T = SAMPLE + DS_ADD * speed`.

const STAT_M0_FIELD_TAIL* {.intdefine.} = 3
  ## Dots the STAT mode FIELD keeps reading 3 after the PPU enters mode 0, on
  ## DMG, on a line with no object fetch. The field alone -- the mode-0 STAT
  ## source, HBlank DMA trigger, VRAM/OAM unlock and pipeline all switch on the
  ## PPU's own dot. Spent on `stat_chg_dot`.
const STAT_M0_FIELD_TAIL_CGB* {.intdefine.} = 0
  ## The same on CGB. Zero, derived and shipping: the CGB's field owes nothing.
const STAT_M0_TAIL_MAX_MC* {.intdefine.} = 2
  ## Last M-cycle of its own instruction on which an IO read still sees the tail.
  ## 0 disables the gate. The tail must be charged at the READ, not the mode
  ## change: the three suites that disagree about it use different read idioms.
const STAT_M0_FIELD_TAIL_ABSORB* {.booldefine.} = true
  ## Whether an object fetch absorbs the tail: `max(0, tail - object dots)`.
const STAT_MODE3_LAG* {.intdefine.} = 0
  ## Dots the STAT mode field keeps reading 2 after the PPU enters mode 3. Must
  ## stay 0.
const STAT_MODE3_LAG_CGB* {.intdefine.} = 0
  ## CGB-only addend, meant to be negative. Refused; one row wants it, five on
  ## the same device refuse it.

# True when any field tail is set. The object accumulator and the absorption path
# hang off this, not off STAT_M0_FIELD_TAIL_ABSORB, so a default build carries
# neither the field nor the add in the object-fetch path.
const STAT_M0_TAIL_ANY* = STAT_M0_FIELD_TAIL != 0 or STAT_M0_FIELD_TAIL_CGB != 0

const STAT_MODE_LAG_ANY* = STAT_M0_TAIL_ANY or
                           STAT_MODE3_LAG != 0 or STAT_MODE3_LAG_CGB != 0

const STAT_NO_HOLD* = -1024'i32
  ## `stat_chg_dot` for "no mode change is inside any read's sampling window". A
  ## line is 456 dots and the counter rebases at every wrap, so this can never
  ## come back within STAT_READ_SAMPLE of it.

const GDMA_SETUP_MCYCLES* {.intdefine.} = 0
  ## Fixed setup cost of a CGB general-purpose VRAM DMA, on top of the 8 M-cycles
  ## per $10 bytes (ppu_start_hdma). Ships at 0 because NO value works -- the
  ## residual tracks SCX, so the missing time is not setup. Needs a model.

const SERIAL_TAP_DMG* {.intdefine.} = 4
const SERIAL_TAP_CGB* {.intdefine.} = 2
  ## Phase, in T-cycles, on the free-running divider the serial unit watches; its
  ## falling edge shifts one bit. Raising the tap makes every edge land earlier.
  ## The DMG value is hardware-verified and costs three gambatte rows that want
  ## [0,3] -- deliberately quarantined, not reconciled.
const SERIAL_START_ARM* {.intdefine.} = 0
  ## Spend the first falling edge after SC.7 rises on arming the shifter rather
  ## than shifting (+512 T). Off: it fixes step 1 of the `start_wait_*` cluster
  ## and breaks step 2. That residual needs a bus-side instrument, not this.

const CGB_HALT_EXIT_MCYCLES* {.intdefine.} = 0
  ## The M-cycle a CGB spends leaving HALT that a DMG does not, charged as TIME.
  ## Stays 0 -- 42 `tima/*` rows refuse a charge. CGB_HALT_PPU_LEAD spends the
  ## same M-cycle as PHASE and is the one that ships.
const CGB_HALT_LEAD_LYC_ONLY* {.intdefine.} = 0
  ## EXPERIMENT. Restrict CGB_HALT_PPU_LEAD to halts where the LYC comparator is
  ## the only armed STAT source. See the test it gates in cpu.nim.
const CGB_HALT_LEAD_SKIP_LYC0* {.intdefine.} = 1
  ## Exempt a halt woken by the LY 153 -> 0 snapback's `LYC = 0` match from
  ## CGB_HALT_PPU_LEAD. 0 is the control (lead on every wake).
const CGB_HALT_PPU_LEAD* {.intdefine.} = 1
  ## While a CGB CPU is halted the PPU runs one M-cycle of dots behind the rest
  ## of the machine and gets them back on the way out: the first halted M-cycle
  ## ticks the bus half only, the wake ticks those dots into the PPU with no bus
  ## half (cpu_halt_tick and `tick`, cpu.nim). Nothing is created or destroyed.
  ## `halt_ppu_debt` is the memo, reconstructed on state load rather than
  ## serialized since it is constant per halt.
  ##
  ## Costs +1.33% retired instructions on cgb-acid-hell, +0.44% Pokemon Blue: the
  ## `cpu_halt_tick` block no longer compiles out. To pay that back, decide at
  ## halt ENTRY rather than per halted M-cycle.

const CGB_OAM_DMA_START_T* {.intdefine.} = 8
  ## T-cycles between the FF46 write and the OAM DMA unit taking the bus, on CGB
  ## (mem_dma_tick). Both devices ship with 8; the knob only records that
  ## `strikethrough` once wanted 4 T taken out of here, and that it was refused.
const GB_POWERUP_WRAM_PATTERN* {.intdefine.} = 1
  ## Fill WRAM with a fixed pseudo-random pattern at power-up instead of zeroes,
  ## which Pan Docs calls an emulator shortcut and BullyGB's InitRAMTest catches.
  ## Fixed xorshift, never a seeded RNG: the screenshot gates, save-state
  ## round-trips and rollback netplay all need two runs to start from the bytes.

const HDMA_STEAL_DELAY_M* {.intdefine.} = 1
  ## CPU instruction boundaries an HBlank DMA block waits after the mode-0 edge
  ## before taking the bus. Paid at instruction boundaries (a per-dot deadline
  ## measured +1.36% and was declined) and BEFORE handle_interrupts -- the DMA
  ## takes the bus ahead of the dispatch, and paying it after costs the whole
  ## `irq_precedence` hdma family.
const HDMA_BLOCK_OVERHEAD_BUS* {.intdefine.} = 4
  ## CPU-clock cycles a block costs beyond its sixteen byte copies: the bus
  ## acquire/release. Unscaled, unlike the copies -- that is the measured part.
const HDMA_BLOCK_OVERHEAD_DOTS* {.intdefine.} = 2
  ## PPU dots for the same overhead; separate because they are separate clocks.
const HDMA_VISIBLE_DOTS* {.intdefine.} = 4 + 4 * CGB_HALT_PPU_LEAD
  ## Dots a block's BYTES take to appear in VRAM after the last one transfers.
  ## Data only; held bytes land lazily wherever VRAM can be observed
  ## (ppu_land_hdma_if_due). The lead term is the argument OBJ_DMA_BUS_LEAD makes
  ## for the OAM DMA unit: the engine runs on machine time and this window is
  ## measured against the pipeline, so advancing the pipeline moves the window.
const CGB_HALT_PPU_LEAD_DOTS* {.intdefine.} = 4 * CGB_HALT_PPU_LEAD
  ## The halt lead in DOTS, which is the unit the code reads. Setting this
  ## directly reaches the three values between whole M-cycles -- though the halt
  ## exit is sampled on the M-cycle grid, so a sub-M-cycle lag moves the wake by
  ## a whole M-cycle for some sources and by nothing for the rest.
const CGB_HALT_PPU_LEAD_ANY* = CGB_HALT_PPU_LEAD_DOTS != 0

# ---- CGB per-register PPU write latency -------------------------------------
#
# Dots into its own M-cycle that a CPU write to a pipeline register lands on CGB
# over where DMG puts it. Here rather than beside mem_tick_ppu_latched only
# because the GbMemory fields they gate are in the type block below.
#
# DMG is the zero of this scale, not the origin: dingbat commits a write's byte
# at the top of its M-cycle and every DMG family agrees, so what is modelled is
# the CGB *delta* alone -- invariant to whatever constant offset this dot grid
# carries against anyone else's.
#
# The scroll pair ships at the documented 2; the rest ship at 0 because every
# nonzero value is refused by some family. SCY is the only register in the file
# whose instruments move at all, so there is no global absorber to look for.
const CGB_WX_LATENCY*         {.intdefine.} = 0
const CGB_WY_LATENCY*         {.intdefine.} = 0
  ## No instrument at any value. Note the SIGN before reaching for a latency: the
  ## CGB expectation flips one step EARLIER in 13 of the 14 `late_wy` families,
  ## so CGB samples WY sooner, and every constant here is a positive delay.
const CGB_SCY_LATENCY*        {.intdefine.} = 2
const CGB_SCX_LATENCY*        {.intdefine.} = 2
const CGB_LCDC_LATENCY*       {.intdefine.} = 0
  ## The WHOLE-register latency. Four of LCDC's bits carry their own per-reader
  ## delay instead (below). Every nonzero value here costs `window/late_disable*`
  ## rows, which are SameBoy's CGB-only fetcher abort and a missing mechanism
  ## rather than a wrong dot -- implement the abort first.
const CGB_LCDC_TDSEL_LATENCY* {.intdefine.} = 0
const CGB_OBJ_SIZE_LATENCY*   {.intdefine.} = 3
  ## Dots LCDC.2 takes to reach the OBJECT FETCH on CGB over DMG. Derived and
  ## swept at OBJ_PLANE1_LAG in fifo_ppu.nim.
const CGB_OBJ_SCAN_LEAD*      {.intdefine.} = 2
  ## Dots before its own sample dot that a CGB's OAM SCAN takes a second look at
  ## LCDC.2, keeping the object if either look puts it on the line. A different
  ## reader from CGB_OBJ_SIZE_LATENCY -- that is the mode-3 fetch, this the
  ## mode-2 range comparator. Same sign: the bit arrives later on CGB.
const CGB_MAP_LATENCY*        {.intdefine.} = 2
  ## Dots LCDC.3 / LCDC.6 take to reach the background fetcher's MAP ADDRESS
  ## read on CGB over DMG. CPU-clock, spent at the write as
  ## `max(0, CGB_MAP_LATENCY - current_speed)`, so a double-speed M-cycle spends
  ## it inside itself. Confined to the map read, which is the only reader the
  ## instrument sees. Costs +0.20% retired instructions -- one compare in
  ## `fsGetTile`, which a DMG pays too (gated at compile time).
const CGB_TDSEL_LATENCY*      {.intdefine.} = 1
  ## Dots LCDC.4 takes to reach the BACKGROUND FETCHER on CGB over DMG. Separate
  ## from CGB_LCDC_TDSEL_LATENCY, which is a WRITE latency and drags the other
  ## six bits with it.
const CGB_TDSEL_GLITCH*       {.booldefine.} = true
  ## An LCDC.4 change landing ON a background bitplane read glitches it: a RESET
  ## delivers the TILE INDEX as that bitplane's byte, a SET delivers the byte at
  ## the address of the most recent $8000-region tile-data read. The address
  ## latch is a bus register that H-Blank does NOT clear.
const CGB_TDSEL_IDX_DOTS*     {.intdefine.} = 8
  ## How long a RESET glitch leaves the INDEX path armed: a SET glitch inside the
  ## window delivers the current tile's index instead of the address latch. 0 is
  ## the control. Bracketed to 8..15 and no narrower; 8 is the fetch pitch.
  ##
  ## In the shipping world this constant fires on nothing and every trigger
  ## hypothesis -- including deleting it -- scores identically. The rule is
  ## believed (it is what an earlier world measured) but nothing here can now
  ## falsify it. Do not read that agreement as support.
const CGB_TDSEL_ANY* = CGB_TDSEL_LATENCY != 0 or CGB_TDSEL_GLITCH
const CGB_MAP_ANY* = CGB_MAP_LATENCY != 0

const CGB_WY_LATCH_LATENCY*   {.intdefine.} = 0
const WIN_EN_ABORT*           {.intdefine.} = 1
  ## Clearing LCDC.5 mid-mode-3 returns the fetcher to background tiles on this
  ## line. DMG behaviour, not CGB, despite reading like SameBoy's CGB-only abort.
  ## Rule and citation at tick_bg_fetcher.
const WIN_EN_HOLD*            {.intdefine.} = 2
  ## Dots a WX match that LCDC.5 refused stays live, waiting for the bit. The
  ## match is neither dropped nor committed: it WAITS, and the window then starts
  ## on the dot the bit ARRIVES, not the dot it matched. A refused match costs no
  ## dots.
const CGB_WIN_EN_HOLD*        {.intdefine.} = 0
  ## WIN_EN_HOLD on CGB. DMG holds, CGB does not; one gambatte family separates
  ## them and mealybug cannot. This is what moves if a CGB ruler turns up.
const WIN_EN_HOLD_BACK*       {.intdefine.} = 1
  ## A match that WAITED starts the window one pixel left of the pixel the
  ## shifter has reached -- the same slot the comparator sits in
  ## (WIN_START_PRE_PIXEL). The dot it costs is taken at the SERVE, not the match.
const WIN_EN_HOLD_ZERO*       {.intdefine.} = 1
  ## A refused match landing on the fetcher's PUSH dot puts one pixel of colour 0
  ## on the front of the FIFO. Replaced rather than inserted, so nothing stalls.
  ##
  ## Gated on `window_trigger_en` (a WY match seen while LCDC.5 was set this
  ## frame) because a game that never enables its window must not glitch -- this
  ## is the Star Trek 25th Anniversary insertion glitch. Where this model still
  ## differs from SameBoy and DocBoy is a hardware question: see
  ## docs/hwprobe-questions.md.
const WIN_LINE_START_WX*      {.intdefine.} = 6
  ## The WX below which a line STARTS as a window line instead of reaching the
  ## window through the shifter's equality. mealybug is its only oracle --
  ## gambatte brackets WX 0 and 7 and has nothing between.
const WIN_HEAD_ABSORB*        {.intdefine.} = 1
  ## A line that starts as a window line pays its `7 - WX` fine-scroll discard
  ## OUT OF the window's own six-dot startup fetch, so mode 3 is `172 + 6` for
  ## every WX below WIN_LINE_START_WX -- the length a WX >= 7 start already has.
const WIN_WX0_PHASE*          {.intdefine.} = 1
  ## Where WX = 0's line-start window puts its first tile, and where the extra
  ## dot that goes with SCX > 0 is spent. Both spellings cost the same DOTS; they
  ## differ by one pixel of tile phase, which one ROM can see.
const WIN_LINE_START_LATCH*   {.intdefine.} = 1
  ## Which dot WX is read on for that decision: the last dot of the throw-away
  ## fetch at the head of mode 3 (1) or the mode 2 -> 3 edge six dots earlier (0).
const WIN_START_PRE_PIXEL*    {.intdefine.} = 1
  ## Let the WX comparator match one pixel slot LEFT of the shifter's first pixel
  ## (screen x = -1 at SCX & 7 = 0, i.e. WX = 6). Not a `>=`: the comparator is an
  ## equality whose counter runs one lower than the emitted-pixel index. Written
  ## as a clamp because the compare is in the mode 3 dot loop.
const WIN_PRE_PX_PHASE*       {.intdefine.} = 1
  ## What a match on that pre-pixel slot does with the window's TILE. 1 keeps the
  ## tile at its own first pixel; the clamp is only about which dot the shifter
  ## can notice the match on. Mode 3's length is identical either way.
const WIN_RESTART_COUNTER*    {.intdefine.} = 0
const CGB_WIN_RESTART_COUNTER* {.intdefine.} = 0
  ## Which fetcher step a window start's restarted fetch resumes at, per model.
  ## 0 is fetch_counter 0, making the startup fetch six dots (Pan Docs); 1 makes
  ## it five. Two knobs because probe (f) says the DMG's is six and the CGB's is
  ## five. Separate from the LINE-START reset, which is the head cycle and starts
  ## at 0 whatever these say.
const WIN_TAIL_FETCH*         {.intdefine.} = 1
  ## A window START holds mode 3 open for the fetch it restarts when the start
  ## lands inside the last pixels of the line. The old behaviour -- the restart
  ## absorbed by the tail burst, costing nothing -- was an accident of
  ## `fetcher_retired`'s shape, not a rule.
const DMG_WIN_START_LAST_PX* {.intdefine.} = 0
  ## CGB_WIN_TAIL_LAST's split carried to the SHIFTER: on DMG a window START on
  ## the line's last pixel does not happen at all. Refused by the frames;
  ## superseded by DMG_WIN_LAST_PX_CARRY, which is the half that survives.
const DMG_WIN_LAST_PX_CARRY* {.intdefine.} = 1
  ## The DMG's window start on the line's LAST pixel is not lost -- it is owed to
  ## the next line, and consumed at that line's head if LCDC.5 is set there. Only
  ## WX = 166 can put a match there, so the affected set is
  ## `window/on_screen/wxA6_*`. Costs +0.29% retired instructions; every per-dot
  ## term is behind `not ppu.cgb`.
const WIN_CARRY_TILE*        {.intdefine.} = 1
  ## The window tile column a carried start draws first. 1, not 0: the aborted
  ## start on the previous line ran column 0's map read and the counter moved.
const WIN_CARRY_REACT_LINES* {.intdefine.} = 1
  ## Extra window LINES a carried start counts when it has to REACTIVATE the
  ## window -- LCDC.5 went low between the match that owed the start and the head
  ## that spends it.
const CGB_WIN_TAIL_LAST*      {.intdefine.} = 1
  ## A window restart issued on the line's LAST PIXEL holds mode 3 open, which
  ## only the CGB does: the DMG's mode 3 ends with the last PIXEL and the CGB's
  ## with the last FETCH. Everywhere else the two coincide. Six dots because six
  ## is a fetch -- five scores the same net and is refused as a fit.

const OBJ_BG_RUN*             {.intdefine.} = 4
  ## Which dots of an object penalty the BG fetcher may run on: 0 none, 1 the
  ## wait dots, 2 all, 3 the wait dots but only to finish a fetch in flight,
  ## 4 the tile-boundary rule (ships). Derivation at tick_sprite_fetcher.
const M3_THROWAWAY_DOTS*      {.intdefine.} = 4
  ## Dots the DISCARDED fetch at the head of mode 3 lasts: 4 (`B0`) or 6 (`B01`).
  ## The head budget is 12 either way, so this changes only where inside them the
  ## first real tile's three VRAM reads fall.
const OBJ_ABORT*              {.intdefine.} = 1
  ## Clearing LCDC.1 mid-stall CANCELS the object fetch. Derivation and the dot
  ## the shifter resumes on: `fifo_obj_abort`.
const CGB_OBJ_ABORT*          {.intdefine.} = 0
  ## Whether the CGB cancels too. One row measures it and says no -- though it
  ## cannot separate "no cancel" from "LCDC.1 reaches the fetcher 4+ dots later".
const OBJ_ABORT_LEAD*         {.intdefine.} = 2
  ## Dots the object fetcher's view of LCDC.1 leads the CPU's write dot by on an
  ## abort. Not a new constant: it is M3_PIPE_DELAY, which the pipeline already
  ## carries over the CPU's register view for the whole line.
const OBJ_ABORT_FLAG_HOLD*    {.intdefine.} = 1
  ## Dots the mode 3 -> 0 FLAG keeps after an abort that the shifter does not:
  ## the cancelled VRAM cycle still owns the bus for its last dot. The pair
  ## (2, 1) is what makes the pixel and flag instruments agree.

const MIXER_PRIORITY_BACK*    {.intdefine.} = 1
  ## Mixer-tail stages LCDC's priority bits are read at the far end of.
const BG_EN_AT_MIX*           {.intdefine.} = 1
  ## Sample LCDC.0 at the MIXER, once per emitted pixel, rather than at the FIFO
  ## push once per eight -- sampling at the push can only ever blank whole tiles.
const MIXER_PALETTE_BACK*     {.intdefine.} = 2
  ## Stages BGP/OBP0/OBP1 are read at. One more than the priority bits: the mixer
  ## resolves BG-vs-OBJ first and looks the shade up after.
const MIXER_PALETTE_OR*       {.intdefine.} = 1
  ## A DMG palette write puts ONE pixel of `old or new` at the far end of the
  ## tail. Derivation at the FF47..FF49 write in ppu.nim.
const MIXER_DOT_LAG*          {.intdefine.} = 1
  ## Whether the pixel mixer runs a dot behind the FIFO pop. On or off only, not
  ## a dot count -- a second dot is refused by the rows the first is required by.
  ## See fifo_recompose_last.
const MIXER_TAIL_HBLANK*      {.intdefine.} = 1
  ## The mixer keeps CLOCKING after the mode 3 -> 0 edge, so a register write on
  ## the first dots of H-Blank still reaches pixels whose shade the tail has not
  ## latched. Not a second lag and it moves no edge: it fixes an accounting error
  ## in `fifo_burst_tail`, which emits the line's last pixels all on one dot.

const NO_LCDC2_FLIP*          = int32.low
  ## `lcdc2_flip` entry for "LCDC.2 has not changed since this mode 3 began". A
  ## dot in the far past, so `flip > dot` is false for every dot an object fetch
  ## can ask about and the empty history costs no branch of its own.
const OBJ_FIX_OFF*            = int32.high
  ## `obj_fix_from` for "no object fetch is still reachable by an LCDC.2 write".
const NO_TDSEL_CHANGE*        = int32.low
  ## `tdsel_dot` for "LCDC.4 has not changed on this line" -- what a DMG carries
  ## all frame, since only a CGB records a change.
const NO_MAP_CHANGE*          = int32.low
  ## `map_dot` for "neither tile-map select bit has changed on this line".
const TDSEL_ADDR_OFF*         = -1'i32
  ## `tdsel_addr` for "nothing has driven an $8000-region tile-data address yet".
  ## Only reachable before the first such read of a frame; no reference here
  ## reaches it.
const TDSEL_ADDR_BANK*        = 13
  ## Bit `tdsel_addr` carries the VRAM bank in. Offsets are 13 bits, so the bank
  ## rides above them and the whole latch is one store on the fetch path.
const TDSEL_IDX_SHIFT*        = 14
  ## Bit `tdsel_addr` carries CGB_TDSEL_IDX_DOTS' arming in, as the first dot
  ## PAST the window, so the test is `(latch shr 14) > cycle_counter` -- one
  ## compare answering the unarmed case and the negative sentinel alike. Packed
  ## rather than given a field because a field grows GbFifoPpu past 632 bytes and
  ## moves the fetch path's offsets: +0.22% with the rule compiled out.

const MIXER_TAIL_DOTS*        {.intdefine.} = 1
  ## Clock the mixer tail in DOTS rather than emitted PIXELS. The two agree
  ## except across an object fetch and the tail burst; mealybug says dots, so a
  ## write reaches a pixel iff that pixel left the FIFO within `back` DOTS.
  ## `tail_dot0` is the dot pixel 0 of the current run would have left on.
const MIXER_HEAD_LINGER*      {.intdefine.} = 1
  ## The line's FIRST pixel holds the SHALLOW tail stages open until the deepest
  ## is read. Not "pixel 0 lingers a dot" -- the two stages COINCIDE there, which
  ## is why it is written as `back < head` and not as a lag.
const MIX_HOLD*               {.intdefine.} = 4
  ## Entries in the mixer's held-pair ring, a power of two so the shifter's store
  ## indexes with an `and`. Must cover the deepest stage plus the pipeline lead;
  ## fifo_ppu.nim static-asserts that sum. A bound, not a model.
const CGB_MIXER_LATENCY*      {.intdefine.} = 1
  ## Dots a C-class CGB's write to a register the MIXER reads takes to arrive
  ## over the DMG's, subtracted from every mixer stage. The QUANTITY only --
  ## whether a machine is charged it is `quirks.mixer_write_immediate`, which
  ## exempts CGB D and later. `gb_mixer_latency` is where the two meet.
const CGB_LCDC_MIXER_LATENCY* {.intdefine.} = 1
  ## The same for LCDC specifically. One dot of CGB latency cancels the mixer's
  ## one dot exactly, so the repaint is skipped rather than delayed. Only LCDC --
  ## the three DMG palettes take the mixer's dot on both consoles.
const CGB_LATENCY_CAP*        {.intdefine.} = 1
  ## Dots at the end of the M-cycle no latency may reach into. Only double speed
  ## can tell 0 from 1. It keeps a register latency from being scored against the
  ## CGB CPU-to-PPU phase axis, which is what those `_ds_` rows actually read.
const CGB_LCDC_LATENCY_ANY* = CGB_LCDC_LATENCY != 0 or CGB_LCDC_TDSEL_LATENCY != 0
const CGB_WY_LATENCY_ANY*   = CGB_WY_LATENCY != 0 or CGB_WY_LATCH_LATENCY != 0
const CGB_WRITE_LATENCY_ANY* = CGB_WX_LATENCY != 0 or CGB_SCY_LATENCY != 0 or
                               CGB_SCX_LATENCY != 0 or
                               CGB_LCDC_LATENCY_ANY or CGB_WY_LATENCY_ANY

const LCD_ON_LINE0_TRIM* {.intdefine.} = 0'i32
const LCD_ON_LINE1_TRIM* {.intdefine.} = 0'i32
  ## Dots the first and second line after an LCD enable are short of 456. Both
  ## ship at 0, which compiles the field and every branch out.
  ##
  ## They exist because three ROM families want the mode 3 -> 0 edge two dots
  ## earlier and a fourth refuses each constant that could give it to them --
  ## line 0 says 0, line 1 says -2, the steady state says -2, later frames say 0.
  ## `(2, -2)` is +33 / -5 and is NOT shipped because nothing derives it: a line
  ## is 456 dots and no mechanism makes one 454 and the next 458.
  ##
  ## Wired into the FIFO renderer only (`gb_line_end`, ppu.nim). Note that the
  ## HLE boot hand-off writes LCDC through write_byte, so the LCD-enable branch
  ## fires there too and `ppu.skip_boot` must clear the window it opens -- without
  ## that reset a trim silently retimes the first two lines after BOOT as well.
const LCD_ON_TRIM_ANY* = LCD_ON_LINE0_TRIM != 0 or LCD_ON_LINE1_TRIM != 0

const SCX_FINE_LATCH_LIVE* {.booldefine.} = true
  ## A store to SCX joins the line's fine-scroll discard for as long as the
  ## discard still has pixels to throw away. The window is the DISCARD, not a
  ## fixed number of dots, so the condition is just `lx < 0`. Derivation in
  ## fifo_ppu.nim.
const SCX_FINE_LATCH_WRAP* {.intdefine.} = 8'i32
  ## Dots the discard costs when a mid-line SCX store lands AFTER it has walked
  ## past the new `SCX and 7`. The discard is a three-bit SLOT COUNTER compared
  ## each dot against the live value, so a slot-7 miss wraps into a whole further
  ## pass -- which is what "SCX banging" abuses. Rides SCX_FINE_LATCH_LIVE's
  ## window and grows a field of its own.
const SCX_STORE_STALL_DOTS* {.intdefine.} = 0'i32
  ## Dots the pipeline stalls when a mid-line SCX store LOWERS `SCX and 7`. Off.
  ## `gambatte/scx_m3_extend` says hardware's mode 3 is longer after such a store
  ## and its `_ds` member prices one store at 8 dots.
type
  # ---- Cartridge / MBC ----
  CgbFlag* = enum
    cgbNone, cgbSupport, cgbExclusive

  # Boot-state model. Selects the per-hardware-revision CPU register / DIV
  # seed table applied at the boot-ROM handoff (skip_boot). Real users only
  # ever get bmDmgABC (any DMG/SGB cart) or bmCgbABCDE (any CGB cart) — those
  # reproduce the values dingbat has always used. The other variants exist so
  # the mooneye boot_regs-*/boot_div-* acceptance ROMs (which each target one
  # specific hardware revision) can be driven by the test harness via --model.
  # Sources: mooneye-test-suite acceptance/misc boot_regs-*.s / boot_div-*.s
  # asserts, and Pan Docs "Power-Up Sequence".
  # The three buses an OAM DMA can own, and that a CPU access can collide with.
  # Pan Docs "OAM DMA bus conflicts" states the separation for the CGB
  # ("the cartridge and WRAM are on separate buses"), and the memory map plus
  # the PPU's dedicated video bus (Pan Docs "Accessing VRAM and OAM") give the
  # third. On DMG, WRAM hangs off the same external bus as the cartridge, which
  # is why the DMG advice degenerates to "the CPU can access only HRAM".
  GbDmaBus* = enum
    dbNone      # OAM / unusable / IO / HRAM / IE — never conflicts
    dbExternal  # cartridge ROM $0000-$7FFF and cartridge SRAM $A000-$BFFF
    dbVideo     # VRAM $8000-$9FFF
    dbWram      # WRAM + echo $C000-$FDFF (CGB only; DMG folds it into dbExternal)

  GbBootModel* = enum
    bmDmg0       # original DMG (no serial number)
    bmDmgABC     # DMG rev A/B/C  (dingbat default DMG)
    bmMgb        # Game Boy Pocket / Light
    bmSgb        # Super Game Boy
    bmSgb2       # Super Game Boy 2
    bmCgb0       # original CGB
    bmCgbABCDE   # CGB rev A..E   (dingbat default CGB)
    bmAgb        # Game Boy Advance / SP running a GB(C) cart

  GbRevision* = enum
    ## The silicon revision the machine is. This is FINER than GbBootModel,
    ## which is a boot-handoff *table* selector: mooneye ships one
    ## `boot_regs-cgbABCDE` and one `boot_regs-dmgABC`, so five CGB revisions
    ## and three DMG revisions hand off identical registers while behaving
    ## differently once running (SameSuite's extra-length-clocking split at CGB
    ## C, mooneye `stat_irq_blocking`'s "pass: DMG ABC / fail: DMG 0"). Every
    ## GbBootModel value is reachable from some revision, so the two are not
    ## independent axes -- gb_set_revision derives the boot model, and nothing
    ## sets the boot model to something the revision disagrees with.
    ##
    ## Do not branch on this in emulation code. Resolve it once, at
    ## construction, into GbQuirks; see gb_quirks_for.
    grDmg0, grDmgABC, grMgb, grSgb, grSgb2
    grCgb0, grCgbAB, grCgbC, grCgbD, grCgbE
    grAgb

  GbUnusableRegion* = enum
    ## What `$FEA0..$FEFF` -- the "prohibited" tail of the OAM page -- answers
    ## a CPU read, and whether a CPU write to it is kept. Pan Docs' "FEA0-FEFF
    ## range" splits this three ways and this enum is that split, one member
    ## per bullet:
    ##
    ##   "This area returns $FF when OAM is blocked, and otherwise the
    ##    behavior depends on the hardware revision.
    ##    - On DMG, MGB, SGB, and SGB2, reads during OAM block trigger OAM
    ##      corruption. Reads otherwise return $00.
    ##    - On CGB revisions 0-D, this area is a unique RAM area, but is masked
    ##      with a revision-specific value.
    ##    - On CGB revision E, AGB, AGS, and GBP, it returns the high nibble of
    ##      the lower address byte twice, e.g. FFAx returns $AA, FFBx returns
    ##      $BB, and so forth."
    ##
    ## (Pan Docs' `FFAx`/`FFBx` there is a typo for `FEAx`/`FEBx`; the formula
    ## in the same sentence is unambiguous.)
    urZero
      ## DMG / MGB / SGB / SGB2: reads answer `$00`, writes are dropped. This
      ## is also what dingbat answered on *every* model before the split, so it
      ## is what a DMG machine keeps bit for bit.
    urRamMasked
      ## CGB 0 / A / B / C: real RAM, with address bits 3 and 4 masked off, so
      ## the 96 addresses fold onto 24 distinct cells, each reachable from four
      ## of them.
      ##
      ## Pan Docs states the RAM and states that the mask is
      ## "revision-specific" without giving any mask value, so the quantity is
      ## sourced from the ROM that measures it rather than from the book:
      ## `cgb-acid-hell` writes `$55` to `$FEA0` and `$44` to `$FEB8`, reads
      ## `$FEA0` back, and draws a *different picture* depending on whether it
      ## sees `$55`. Two hardware captures bracket it -- the author's bundled
      ## reference (and dingbat's scored PNG) is the not-`$55` branch, and the
      ## repo's issue tracker carries a photo of a real device taking the
      ## `$55` branch. So on the reference device the `$FEB8` store must land
      ## on `$FEA0`, which is exactly `addr and not 0x18`. SameBoy agrees, and
      ## was checked after the fact, not copied; see docs/gb-failure-triage.md
      ## "the CGB-D gate, with the semantics spelled out".
    urRamPlain
      ## CGB D: the same RAM with no mask, so `$FEA0` and `$FEB8` are distinct
      ## cells and the readback above is `$55`. This is the one revision
      ## `cgb-acid-hell` refuses outright ("the bugs in the PPU this test
      ## relies on work differently on CGB-D"): it draws its SORRY YOU CAN'T
      ## GET TO PLAY screen instead of the test pattern, which is CORRECT
      ## behaviour for the machine and not a dingbat failure.
    urNibbleEcho
      ## CGB E / AGB / AGS / GBP: not RAM at all. Reads answer the high nibble
      ## of the low address byte, doubled (`$FEAx` -> `$AA`), and writes are
      ## dropped. Pan Docs gives this one outright, formula included.

  GbQuirks* = object
    ## Per-revision behaviour, resolved from GbRevision once by gb_quirks_for
    ## and thereafter read as a plain bool off the GB the caller already has.
    ##
    ## Flags, not a revision comparison, for three reasons: a flag names the
    ## behaviour at the site that implements it (`if gb.quirks.x` reads as an
    ## assertion about hardware, `if gb.revision <= grCgbAB` reads as trivia);
    ## two revisions that share a behaviour share a flag instead of repeating a
    ## set literal; and a comparison in a hot path is a range check where a
    ## flag is a load. Every flag is FALSE on the default revisions
    ## (grCgbC / grDmgABC), so the default machine is byte-identical to the one
    ## dingbat shipped before revisions existed. `unusable_region` is the one
    ## member that is not a bool, because the behaviour it names has three
    ## states and no natural "off". It is also the one member whose default is
    ## NOT what dingbat did before revisions existed: the CGB default moved
    ## from `urZero` (the region unmodelled) to `urRamMasked` (the region
    ## modelled, on the revision the tree is scored against), which is a
    ## deliberate, measured change -- see docs/gb-failure-triage.md.
    length_clock_any_nrx4*: bool
      ## CGB 0 and CGB A/B. SameSuite `*_extra_length_clocking-cgb0B.asm`:
      ## "Extra length clocking occurs when writing to NRx4 when the frame
      ## sequencer's next step is one that doesn't clock the length counter.
      ## In this case, if the length counter was PREVIOUSLY disabled and now
      ## enabled and the length counter is not zero, it is decremented. On
      ## revisions <= CPU CGB B, the length counter only has to have been
      ## disabled before; the current length enable state doesn't matter. This
      ## breaks at least one game (Prehistorik Man), and was fixed on CPU CGB
      ## C." So the extra clock drops its `and len_enable` term: the ROMs write
      ## NRx4 = $00 (CH3: $03), with bit 6 clear, and still expect the counter
      ## to move.
    mixer_write_immediate*: bool
    scy_fetch_latch*: bool
      ## CGB-D and later latch SCY ONCE per BG fetch, at the map read, and both
      ## bitplane reads of that tile use the latched value. CGB-C and earlier
      ## sample it live on each of the three read dots.
      ##
      ## Derived two-sided from mealybug `m3_scy_change`, whose two captures
      ## invert exactly (docs/gb-mealybug-sources.md 3.4 -- each tile IS the
      ## triple (SCY at B, SCY at 0, SCY at 1), because the map is
      ## `65 + row + col`, BGP is identity and SCX is 0). Live-per-read is
      ## pixel-exact on `_cgb_c` and 6217 px wrong on `_cgb_d`; the per-fetch
      ## latch is pixel-exact on `_cgb_d` and the same 6217 px wrong on
      ## `_cgb_c`. Two models, two captures, no overlap and no fitted constant.
      ## CGB D and later. The CGB takes a mid-mode-3 write to a PALETTE
      ## register one dot later than the DMG does -- that dot is
      ## `CGB_MIXER_LATENCY`, and this flag is the revision that stops taking
      ## it, so the write reaches the mixer at the DMG's phase again.
      ##
      ## Palettes only. LCDC is read by the same mixer and keeps its dot on
      ## every revision; mealybug's `_cgb_c` and `_cgb_d` captures of the LCDC
      ## ROMs are byte-identical to each other, and that is the whole argument.
      ## See gb_lcdc_mixer_latency, which is the other half.
      ##
      ## The evidence is one pair of mealybug reference captures of the same
      ## ROM on two devices. `m3_bgp_change` is pixel-exact against
      ## `m3_bgp_change_cgb_c.png` with the dot and against
      ## `m3_bgp_change_cgb_d.png` without it; the two PNGs differ by exactly
      ## one pixel per write edge, which is the dot. So C-class keeps it, D
      ## drops it, and mealybug shipped both pictures because both devices
      ## exist. See CGB_MIXER_LATENCY for what the dot is and which rows pin
      ## its value on the C side.
      ##
      ## `grAgb` is deliberately NOT in this set even though AGB is silicon
      ## later than CGB-E. Nothing has measured an AGB against these captures
      ## -- mealybug ships no `_agb` reference for this ROM -- and the tree's
      ## AGE `agb` rows are scored against the current behaviour. A guess that
      ## moves scored rows is worse than an honest gap.
    unusable_region*: GbUnusableRegion
      ## What `$FEA0..$FEFF` does on this machine; see GbUnusableRegion, which
      ## carries the Pan Docs quote and the per-member evidence.

  Mbc* = ref object of RootObj
    gb_ref* {.cursor.}: GB   # back-ref to the owning GB; non-owning to avoid a
                             # reference cycle (the GB owns the cartridge)
    rom_identity*: uint32    # FNV-1a of the ROM as loaded, taken once. The
                             # save-state identity reads this, not `rom`,
                             # which cheats patch in place. See
                             # gb_rom_checksum.
    rom*:          seq[uint8]
    ram*:          seq[uint8]
    sav_path*:     string
    has_battery*:  bool
    ram_dirty*:    bool
    save_error_reported*: bool
    # Flat-ROM window cache -- see mbc_sync_rom_map in mbc/mbc.nim. Derived
    # state, never serialized: it is recomputed from the banking registers
    # after every cartridge write and after a state load. `flat_rom` defaults
    # to false so an Mbc that has not been synced falls back to the method.
    flat_rom*:     bool
    rom_lo_base*:  int   # byte offset in `rom` that address 0x0000 maps to
    rom_hi_base*:  int   # byte offset in `rom` that address 0x4000 maps to

  MbcRom* = ref object of Mbc

  Mbc1* = ref object of Mbc
    ram_enabled*: bool
    mode*:        uint8
    reg1*:        uint8   # 5-bit rom bank lo
    reg2*:        uint8   # 2-bit secondary
    multicart*:   bool    # MBC1M: only 4 bits of reg1 are wired; reg2 shifts by 4

  Mbc2* = ref object of Mbc
    ram_enabled*: bool
    rom_bank*:    uint8

  Mbc3* = ref object of Mbc
    ram_enabled*:    bool
    rom_bank_num*:   uint8
    ram_bank_num*:   uint8
    # MBC3 real-time clock
    has_rtc*:            bool
    rtc_live*:           array[5, uint8]  # S, M, H, DL, DH
    rtc_latched*:        array[5, uint8]
    rtc_latch_prev*:     uint8  # DEAD: the latch fires on any write (see
                                # mbc3.nim), so nothing reads this. It is still
                                # written and still serialized so the GB
                                # save-state payload keeps its current layout.
    rtc_halt_remaining*: int  # scheduler cycles left on the pending tick while halted

  Mbc5* = ref object of Mbc
    ram_enabled*:    bool
    rom_bank_num*:   uint16
    ram_bank_num*:   uint8

  Mbc7* = ref object of Mbc
    # Cart type 0x22 (Kirby Tilt 'n' Tumble, Command Master). There is no cart
    # RAM: 0xA000-0xAFFF is a register file exposing a two-axis accelerometer
    # and the serial port of a 93LC56 EEPROM, and that EEPROM (128 words =
    # 256 bytes, held in `ram`) is what the battery backs up.
    ram_enabled*:      bool  # 0x0A written to 0x0000-0x1FFF
    secondary_enable*: bool  # 0x40 written to 0x4000-0x5FFF; BOTH must be set
    rom_bank_num*:     uint8
    # Accelerometer. accel_x/accel_y are the frontend's tilt in the range
    # -1.0 .. 1.0, 0.0 = level; they are live input, not saved state.
    accel_x*, accel_y*: float
    x_latch*, y_latch*: uint16  # sampled by the 0x55/0xAA latch sequence
    latch_ready*:       bool     # a 0x55 has armed the latch; the 0xAA only
                                 # samples when it has (Pan Docs: re-latching
                                 # without erasing first yields no change)
    # 93LC56 serial EEPROM port. One bit is shifted per rising clock edge;
    # eeprom_command is an 11-bit shift register (start bit, 2 opcode bits,
    # 8 address bits) and read_bits shifts data back out on DO.
    eeprom_do*, eeprom_di*, eeprom_clk*, eeprom_cs*: bool
    eeprom_command*:       uint16
    read_bits*:            uint16
    argument_bits_left*:   int
    eeprom_write_enabled*: bool

  Huc1* = ref object of Mbc
    # Cart type 0xFF (Hudson HuC1). Not the MBC1 relative it is usually said to
    # be: cart RAM has no enable line, and the register that would be MBC1's RAM
    # enable instead chooses whether 0xA000-0xBFFF sees RAM or the cartridge's
    # infrared transceiver. See mbc/huc1.nim.
    bank_low*:  uint8  # 0x4000-0x7FFF bank; NOT remapped away from 0
    bank_high*: uint8  # RAM bank (it never reaches the ROM)
    ir_mode*:   bool   # 0x0E written to 0x0000-0x1FFF maps IR in at 0xA000
    cart_ir*:   bool   # emitter drive; transient, like Mbc5Rumble.rumble

  Huc3* = ref object of Mbc
    # Cart type 0xFE (Hudson HuC3). MBC5-shaped banking plus a 4-bit
    # microcontroller — clock, alarm and tone generator — reached through a
    # mailbox at 0xA000-0xBFFF. See mbc/huc3.nim for the protocol.
    rom_bank_num*: uint8
    ram_bank_num*: uint8
    mode*:         uint8   # what 0xA000-0xBFFF currently decodes to
    regs*:         array[256, uint8]  # the MCU's memory window, one nibble each
    access_addr*:  uint8   # nibble the next read/write command targets
    mailbox*:      uint8   # last value written to the command window (7 bits)
    response*:     uint8   # nibble the last executed command produced
    last_second*:  int64   # unix second the clock has been advanced through
    cart_ir*:      bool

  Mmm01* = ref object of Mbc
    # Cart types 0x0B-0x0D (Taito Variety Pack, Momotarou Collection 2 and the
    # other multi-game compilations). Powers up showing a menu program held in
    # the last 32 KiB of the cartridge, then turns into an MBC1 for whichever
    # contained game the menu selected. See mbc/mmm01.nim.
    ram_enabled*:   bool
    mapped*:        bool   # Mapping Enable: the menu has handed over to a game
    rom_bank_low*:  uint8  # 5 bits; the MBC1 bank register
    rom_bank_mid*:  uint8  # 2 bits; game select (swaps with ram_bank_low when
                           # multiplex is on)
    rom_bank_high*: uint8  # 2 bits; game select
    ram_bank_low*:  uint8  # 2 bits; the MBC1 RAM bank register
    ram_bank_high*: uint8  # 2 bits; game select
    rom_bank_mask*: uint8  # write-lock over rom_bank_low; bit 0 is always clear
    ram_bank_mask*: uint8  # write-lock over ram_bank_low
    mbc1_mode*:     bool
    mode_locked*:   bool   # MBC1 Mode Write Lock
    multiplex*:     bool
    rom_rotate*:    int    # dump-order fix-up; see mbc/mmm01.nim

  Mbc6* = ref object of Mbc
    # Cart type 0x20 (Net de Get - Minigame @ 100). Two independently banked
    # 8 KiB ROM windows and two independently banked 4 KiB RAM windows, either
    # ROM window switchable onto an 8 Mbit flash chip that the game downloads
    # minigames into over the Mobile Adapter. See mbc/mbc6.nim.
    ram_enabled*: bool
    ram_bank_a*, ram_bank_b*: uint8         # 3 bits each; 4 KiB banks
    rom_bank_a*, rom_bank_b*: uint8         # 7 bits each; 8 KiB banks
    flash_select_a*, flash_select_b*: bool  # window shows flash rather than ROM
    flash_enabled*:       bool   # /CE to the flash chip
    flash_write_enabled*: bool   # /WP; guards sector 0 and the hidden region
    flash*:        seq[uint8]    # 1 MiB main array, battery-backed
    flash_hidden*: seq[uint8]    # the 256 bytes behind the hidden-region commands
    flash_sector0_protected*: bool  # set by the Protect Sector 0 command;
                                    # non-volatile on the real chip
    flash_read_mode*:      uint8 # array / JEDEC ID / status / hidden region
    flash_status*:         uint8
    flash_cmd_step*:       int   # position in the JEDEC unlock sequence
    flash_setup*:          uint8 # command byte awaiting its second unlock
    flash_program_addr*:   int   # last address programmed; a repeat commits it
    flash_program_hidden*: bool

  PocketCamera* = ref object of Mbc
    # Cart type 0xFC (Game Boy Camera / Pocket Camera). MBC3-shaped banking plus
    # 54 registers that take over 0xA000-0xBFFF when bit 4 of the RAM bank
    # register is set: a shutter, five of the M64282FP image sensor's own
    # registers, and a 4x4x3 threshold matrix. See mbc/camera.nim.
    ram_enabled*:   bool
    rom_bank_num*:  uint8
    ram_bank_num*:  uint8
    regs_mapped*:   bool
    regs*:          array[0x36, uint8]
    capture_cycles_left*: int  # non-zero while a capture is running or paused
    # The image source. nil means the built-in synthetic scene; a frontend with
    # a real camera installs its own through set_camera_source. Live input, not
    # state, so it is left out of save states as Mbc7.accel_x is.
    sensor*: proc(x, y: int): uint8

  Tama5* = ref object of Mbc
    # Cart type 0xFD (Game de Hakken!! Tamagotchi Osutchi to Mesutchi). A
    # nibble-at-a-time port onto a 4-bit microcontroller that owns 32 bytes of
    # SRAM and a TC8521AM real-time clock. See mbc/tama5.nim.
    reg_index*:   uint8                      # last write to 0xA001
    regs*:        array[16, uint8]           # the nibble register file
    rtc_pages*:   array[4, array[13, uint8]] # timer, alarm, two free pages
    page_reg*:    uint8   # the PAGE register, shared across all four pages
    last_second*: int64   # unix second the clock has been advanced through

  # ---- CPU ----
  GbCpu* = ref object
    af*:         uint16
    bc*:         uint16
    de*:         uint16
    hl*:         uint16
    pc*:         uint16
    sp*:         uint16
    ime*:        bool
    halted*:     bool
    halt_bug*:   bool
    # Set by the eleven undefined opcodes (see opcodes.nim). Distinct from
    # `halted`: nothing short of a reset clears it, not even an interrupt.
    # `locked` always implies `halted`, so the fetch/dispatch path never has
    # to test it.
    locked*:     bool
    # Set by STOP when it enters STOP mode (see stop_instr in memory.nim), on
    # top of `halted` and `locked`. What it adds to those two is that the rest
    # of the machine is stopped as well, and that this halt IS exitable: a
    # joypad line going low clears all three.
    #
    # NOT serialized. savestate.nim writes `halted` and `locked` as the states
    # they mean without it, so a state captured inside STOP mode loads as a
    # running CPU at the instruction after the STOP. Carrying it properly would
    # be a GB CPU payload revision, and the value of one is close to zero: no
    # licensed ROM uses STOP for anything but a speed switch (Pan Docs, "Using
    # the STOP Instruction"), and a speed switch never survives an instruction
    # boundary, let alone a state boundary.
    stopped*:    bool
    # Dots of PPU time a HALTED CGB CPU is holding back from the PPU; see
    # CGB_HALT_PPU_LEAD in this file and cpu_halt_tick. Nonzero only while
    # `halted` is set on a CGB, and always the same value for a whole halt, so
    # it is NOT serialized: load_cpu_state reconstructs it from `halted` and
    # the speed, which is exact for every state a halt can be captured in bar
    # the single M-cycle between the HALT fetch and the first halted tick.
    halt_ppu_debt*: int32
    # Scheduler cycle EI's delayed IME actually landed on (etIME), so an
    # instruction can ask what IME was at its own fetch rather than what it is
    # now. Only HALT reads it (cpu_halt) and only over the 4 T-cycles of that
    # fetch, so like `cached_hl` it is scratch: it is NOT serialized, and a
    # state loaded with it at 0 answers "IME was not set during this fetch",
    # which is the right answer for every instruction boundary a state can be
    # captured on.
    ime_set_cycle*: CycleCount
    cached_hl*:  int   # -1 = invalid
    # The opcode currently executing, kept only when STAT_M0_TAIL_IDIOM needs
    # it: an IO read has to be able to say which M-cycle of its own instruction
    # it is. Guarded so a default build carries neither the field nor the store.
    when STAT_M0_TAIL_MAX_MC != 0:
      cur_opcode*: uint8

  # ---- Interrupts ----
  GbInterrupts* = ref object
    vblank_interrupt*:   bool
    lcd_stat_interrupt*: bool
    timer_interrupt*:    bool
    serial_interrupt*:   bool
    joypad_interrupt*:   bool
    vblank_enabled*:     bool
    lcd_stat_enabled*:   bool
    timer_enabled*:      bool
    serial_enabled*:     bool
    joypad_enabled*:     bool
    top_3_ie_bits*:      uint8

  # ---- Serial ----
  GbSerialDriver* = ref object of RootObj
    ## Whatever is plugged into the link port (see serial.nim). The base
    ## instance is the no-cable default; a link coordinator subclasses it.

  GbSerial* = ref object
    sb*:             uint8   # 0xFF01 shift register
    sc*:             uint8   # 0xFF02 control (bits 7, 1 [CGB], 0)
    out_latch*:      uint8   # outgoing byte latched at transfer start
    bits_remaining*: int     # 8..1 while a started transfer has bits left
    clock_history*:  uint8   # per-cycle samples of the DIV clock bit; bit 0
                             # = newest (see serial.nim: the shift clock is
                             # the divider tap delayed by 4 cycles)
    shifting*:       bool    # cached: internal-clock transfer in progress
    driver*:         GbSerialDriver

  # ---- Timer ----
  GbTimer* = ref object
    tdiv*:         uint16
    tima*:         uint8
    tma*:          uint8
    enabled*:      bool
    clock_select*: uint8
    bit_for_tima*: int
    previous_bit*: bool
    countdown*:    int

  # ---- Joypad ----
  GbJoypad* = ref object
    button_keys*:    bool
    direction_keys*: bool
    down*:           bool
    up*:             bool
    left*:           bool
    right*:          bool
    start*:          bool
    jselect*:        bool
    b*:              bool
    a*:              bool
    prev_lines*:     uint8  # last P1 low nibble, for joypad-interrupt edges

  # ---- Super Game Boy ----
  # Everything the ICD2 + SNES side of an SGB holds on the Game Boy's behalf.
  # nil on every machine whose cart header does not unlock SGB functions, which
  # is what keeps the hooks in the renderer and the joypad free. See sgb.nim.
  SgbState* = ref object
    # Command-packet receiver (P1 pulse decode)
    prev_lines*:  uint8              # last (P15,P14) pair written to P1
    receiving*:   bool
    # A low pulse is in flight: one select line went low FROM both-high, and
    # the release back to both-high will latch a bit. Not serialized — it is
    # reconstructed from prev_lines on load, which is exact for every pulse a
    # program actually sends (see load_sgb_state).
    pending*:     bool
    bit_count*:   int
    packet*:      array[16, uint8]   # the packet being clocked in
    group*:       array[7 * 16, uint8]  # packets 1..7 of one command
    pkt_index*:   int
    pkt_total*:   int
    # Game-screen colour: 4 palettes x 4 colours, and the 20x18 attribute map
    # that says which palette each character cell of the GB screen uses.
    pal*:         array[4 * 4, uint16]
    attr*:        array[20 * 18, uint8]
    # SNES-side stores filled by the _TRN commands
    syspal*:      array[512 * 4, uint16]   # PAL_TRN system colour palettes
    atf*:         array[45 * 90, uint8]    # ATTR_TRN attribute files
    chr*:         array[256 * 32, uint8]   # CHR_TRN border tiles (4bpp SNES)
    map*:         array[32 * 28, uint16]   # PCT_TRN border tilemap
    border_pal*:  array[3 * 16, uint16]    # PCT_TRN border palettes 4-6
    # Decoded 256x224 border image; bit 15 of each word is "opaque".
    border*:      seq[uint16]
    border_valid*: bool
    border_dirty*: bool
    # Bumped every time `border` is re-rendered. A frontend uploads its border
    # texture only when this moves -- the image changes a handful of times in
    # a whole session, and it is 112 KiB.
    border_gen*:   uint32
    # MASK_EN, and the frame it freezes
    mask*:        uint8
    frozen*:      seq[uint16]
    # ICON_EN bit 2: "suppress all further packets/commands" (Pan Docs,
    # SGB_Command_System). Multi-game paks set it before chain-loading so a
    # game's stray P1 traffic cannot re-program the SNES side. Nothing in the
    # documented command set clears it.
    packets_locked*: bool
    # MLT_REQ
    players*:     uint8
    cur_player*:  uint8
    when defined(sgb_trace):
      trace_watch*: int

  # ---- PPU pixel types ----
  GbPixel* = object
    color*:     uint8
    palette*:   uint8
    oam_idx*:   uint8
    obj_to_bg*: uint8

  # One mixer stage's worth of held FIFO output: the BG entry and the OBJ entry
  # popped on the same dot. Kept as a PAIR rather than as two parallel arrays so
  # the shifter's store is one eight-byte store at a computed offset rather than
  # two four-byte ones eight bytes apart -- worth 0.37% of retired instructions
  # on the mode 3 dot loop, measured, which is half of what the whole mechanism
  # costs.
  GbMixHold* = object
    bg*: GbPixel
    sp*: GbPixel

  GbPixelFifo* = object
    data: array[16, GbPixel]
    head: int
    tail: int
    size: int

  GbSprite* = object
    y*:          uint8
    x*:          uint8
    tile_num*:   uint8
    attributes*: uint8
    oam_idx*:    uint8

  # ---- PPU (base + subclasses) ----
  GbPpu* = ref object of RootObj
    # registers
    lcd_control*:   uint8   # 0xFF40
    lcd_status*:    uint8   # 0xFF41
    scy*:           uint8   # 0xFF42
    scx*:           uint8   # 0xFF43
    ly*:            uint8   # 0xFF44
    lyc*:           uint8   # 0xFF45
    bgp*:           array[4, uint8]   # 0xFF47
    obp0*:          array[4, uint8]   # 0xFF48
    obp1*:          array[4, uint8]   # 0xFF49
    wy*:            uint8   # 0xFF4A
    wx*:            uint8   # 0xFF4B
    vram_bank*:     uint8
    # CGB palette RAM
    pram*:              array[64, uint8]
    palette_index*:     uint8
    auto_increment*:    bool
    obj_pram*:          array[64, uint8]
    obj_palette_index*: uint8
    obj_auto_increment*: bool
    # VRAM (2 banks)
    vram*:          array[2, seq[uint8]]
    sprite_table*:  seq[uint8]         # OAM 160 bytes
    # HDMA. HDMA1-4 are not registers the transfer merely reads at its start:
    # they ARE the transfer's address counters, which is why a second transfer
    # started without rewriting them continues where the first one stopped
    # (same-suite dma/gbc_dma_cont) and why a write to one of them part way
    # through moves the remaining blocks. So the source/destination pair below
    # is the whole of HDMA1-4 -- a write to any of the four edits one byte of
    # it, and each copied block advances it.
    hdma5*:         uint8
    hdma_src*:      uint16  # HDMA1:HDMA2, low nibble always 0
    hdma_dst*:      uint16  # HDMA3:HDMA4, masked into VRAM only where it is used
    hdma_active*:   bool
    hdma_copying*:  bool   # re-entrancy guard; see ppu_step_hdma
    # A block this HBlank owes an armed transfer, which only a halted CPU can
    # leave unpaid (see the mode-0 edge in `mode_flag=`). Cleared on the way out
    # of mode 0, so it is never set at a frame boundary — where every state,
    # rewind snapshot and rollback snapshot is captured — and is not serialized.
    hdma_block_due*: bool
    # CPU instruction boundaries still owed before a due HBlank DMA block may
    # take the bus. See HDMA_STEAL_DELAY_M.
    hdma_due_delay*: int8
    # A copied block whose bytes have not reached VRAM yet: they land
    # HDMA_VISIBLE_DOTS dots after the block's last byte (see that constant).
    # The window is 4 dots inside an HBlank and the next PPU tick closes it, so
    # like hdma_block_due none of this can be live at a frame boundary — where
    # every state, rewind snapshot and rollback snapshot is captured — and none
    # of it is serialized.
    hdma_bytes_held*: bool
    hdma_hold_from*:  int32   # dot the hold was armed on (a smaller dot = the
                              # line wrapped, i.e. the hold is long expired)
    hdma_hold_until*: int32   # dot the bytes land on
    hdma_held_dst*:   int32   # VRAM address the held block starts at
    hdma_held*:       array[16, uint8]
    # The frame the PPU draws right after LCDC.7 goes high is not shown: the
    # panel stays blank until the first vblank (Pan Docs LCDC; SameBoy
    # GB_FRAMESKIP_LCD_TURNED_ON paints it white). Not on SGB, where the TV
    # keeps showing the frozen picture instead. Transient (one frame), not
    # serialized.
    lcd_on_first_frame*: bool
    # window state
    window_trigger*:     bool
    window_trigger_en*:  bool # window_trigger's stricter sibling: a WY match
                              # SEEN WITH LCDC.5 SET this frame. Gates the
                              # WIN_EN_HOLD_ZERO pixel void only — a frame whose
                              # window was never enabled must not glitch (WX=7 +
                              # window-off is Pokemon Blue's resting state, and
                              # its intro proves silicon draws nothing).
                              # SameBoy wy_check / DocBoy w.active_for_frame
                              # carry the same enable term. Not serialized:
                              # cleared every VBlank, and a mid-frame load only
                              # re-arms it a frame late in the rare
                              # window-then-disabled scene.
    current_window_line*: int
    old_stat_flag*:      bool
    # A CPU write to LCDC/STAT/LYC changed one of the STAT interrupt line's
    # inputs and the line has not been re-evaluated yet. The byte itself lands
    # at the top of its M-cycle (mem_write), because that is where the pixel
    # pipeline has to see it; the interrupt line is part of the mode machinery,
    # which was never out of phase with the CPU, so its edge is still taken at
    # the M-cycle boundary. Never set across an instruction boundary -- mem_write
    # consumes it in the same M-cycle -- so it is not serialized.
    stat_write_pending*: bool
    # The dots of the last two mid-mode-3 changes of LCDC.2 (the OBJ size bit),
    # most recent first, or NO_LCDC2_FLIP for "no change since mode 3 began".
    # An object fetch reads that bit ONCE PER BITPLANE and the two reads are
    # OBJ_PLANE_GAP dots apart, so the merge -- which happens on one dot -- has
    # to be able to ask what the bit was a few dots ago; see obj_height_at and
    # sprite_fetch_merge in fifo_ppu. Two entries is exact for the window it is
    # asked over: the lookback never exceeds OBJ_FETCH_DOTS dots and a CPU
    # cannot store to $FF40 more often than every 8 dots (4 in double speed).
    # Per-line scratch, cleared at every mode 2 -> 3 edge; not serialized.
    lcdc2_flip*:         array[2, int32]
    first_line*:         bool
    when LCD_ON_TRIM_ANY:
      lcdon_lines*:      uint8   # lines left in the LCD-on trim window
    cycle_counter*:      int32
    # The mode as it stood when this M-cycle's dots began, snapshotted at each
    # tick entry because the emulator ticks the PPU forward by the whole
    # M-cycle before read_byte runs. This is what the CPU's VRAM/OAM locks are
    # decided on (cpu_vram_open / cpu_oam_open); the mode bits a STAT READ
    # returns are NOT this -- they come off stat_chg_dot below, which is a
    # different dot. It was this latch until 2026-08-09, and the dot it lands on
    # (one before the M-cycle's first) is where the "one unaccounted-for dot" in
    # docs/gb-failure-triage.md's bucket 15 was hiding.
    #
    # Bit 7 (LY_JUST_CHANGED) rides along in the same byte: it is set by an LY
    # advance and cleared by the next tick's snapshot, i.e. it marks "LY changed
    # during the M-cycle this read belongs to". Packing it here rather than into
    # its own field keeps the per-M-cycle cost at the one store the latch
    # already paid. See ppu_read 0xFF41 for what it suppresses.
    read_mode*:          uint8
    # ---- What a STAT read's mode bits are sampled from ---------------------
    # The dot the mode last changed on and what it changed away from, which is
    # everything stat_read_mode needs: a read at dot `cc` reports the new mode
    # once `cc - stat_chg_dot >= STAT_READ_SAMPLE` and `stat_prev_mode` until
    # then. Written only by `mode_flag=` (three times a line) and rebased by
    # the line wrap, so nothing per-dot or per-M-cycle maintains it. Not
    # serialized: a state is captured at VBlank, where no mode change is inside
    # a read's sampling window, so load_ppu_state just retires the hold.
    stat_chg_dot*:       int32
    stat_prev_mode*:     uint8
    # ---- Sweep scratch: the STAT interrupt line's own phase ----------------
    # Gone from the shipping build -- the knob that gates it ships at the value
    # that needs neither field, so GbPpu's layout is untouched by its existing.
    # See the write-up at STAT_IRQ_LEAD in ppu.nim.
    when STAT_IRQ_SPLIT:
      # The mode and LY the STAT interrupt SOURCES compare against, as opposed
      # to the ones the CPU reads back out of lcd_status/LY. Not serialized:
      # re-derived from the flag domain on load (load_ppu_state), which is
      # exact at the VBlank a state is captured at.
      irq_mode*:         uint8
      irq_ly*:           uint8
    # Dots since the last frame was pushed, counted whether or not the PPU is
    # driving the panel. The panel refreshes at a fixed rate regardless, so
    # this is what keeps frame output steady across an LCD that switches off
    # and on again — see lcd_off_frame and ppu_lcd_enabled.
    dots_since_frame*:   int32
    # ---- Super Game Boy colorization hooks ----
    # Both nil on every non-SGB machine. When they are set, the emitted pixel
    # takes its colour from sgb_pal[attr * 4 + shade] instead of PRAM, where
    # `attr` is the SGB attribute of the 8x8 SCREEN cell the pixel lands in.
    # That is the whole of SGB screen colour: the SNES sees the composited
    # 2-bit GB video signal, so background and objects share one palette per
    # cell. See sgb.nim and docs/research_sgb.md.
    sgb_pal*:       ptr UncheckedArray[uint16]
    sgb_attr*:      ptr UncheckedArray[uint8]
    # output
    framebuffer*:   seq[uint16]   # 160×144 BGR555
    frame*:         bool
    ran_bios*:      bool
    # Speed-mode frameskip: render only every (frameskip+1)th frame. Honored
    # ONLY by the scanline renderer — its mode/LY/STAT timing is analytic, so
    # skipping do_scanline's pixel work is timing-neutral by construction. The
    # FIFO renderer ignores these: its mode-3 length comes from actually
    # running the pixel pipeline, so its rendering cannot be skipped. Decided
    # once per frame at LY 0 (whole frames only — do_scanline's cross-line
    # window state resets there); not serialized (render scratch). 0 = off.
    frameskip*:     int
    fs_counter*:    int
    forced_skip*:   bool

  GbScanlinePpu* = ref object of GbPpu
    scanline_color_vals*: array[160, tuple[color: uint8, priority: bool]]

  FetchStage* = enum
    fsSleep, fsGetTile, fsGetTileDataLow, fsGetTileDataHigh, fsPushPixel

  GbFifoPpu* = ref object of GbPpu
    fifo*:                GbPixelFifo
    fifo_sprite*:         GbPixelFifo
    fetch_counter*:       int
    fetcher_x*:           int
    # `SCX and 7` as it stood when this line's fine scroll was latched
    # (fifo_sample_smooth_scroll). The BG fetcher's map column is formed from
    # the line's SCREEN position plus the LIVE SCX, not from a tile index plus
    # a scroll, so the low three bits take part in the carry into the tile
    # address -- see SCX_FINE_BORROW in fifo_ppu.nim, which is where the whole
    # gambatte `scx_during_m3` family derives it. Per-line scratch, like
    # `dropped_first_fetch`: none of this block is serialized, because states
    # are captured at vblank and `reset_render_scratch` re-establishes it.
    scx_fine*:            int
    # The whole SCX term the BG fetcher adds to `fetcher_x`, borrow included:
    # `(SCX shr 3) - borrow`. Derived state kept by `fifo_arm_scx`, exactly as
    # `win_lx` is kept by `fifo_arm_window` and for the same reason -- SCX is
    # written a handful of times a line and read at every tile-map fetch, so
    # deciding the borrow at the write leaves the mode 3 dot loop the single
    # add it already was. It may be -1, which `and 0x1F` wraps to column 31,
    # which is what a borrow off column 0 means.
    scx_tile*:            int
    lx*:                  int32
    # The one `lx` on this line either window rule can fire on -- the start
    # (WX - 7) while the window is not running, the re-trigger edge (WX - 8,
    # which is the same dot one pixel earlier in the shifter) while it is -- or
    # WIN_LX_OFF when neither can. Derived state, kept by fifo_arm_window from
    # the four inputs that decide it (LCDC.5, WX, the WY latch,
    # fetching_window), none of which moves outside a register write or a fetch
    # restart. It exists so the shifter spends ONE compare per mode 3 dot on
    # the window instead of two conjunctions: measured on blargg 01-special,
    # the second per-dot branch alone is +1.7% of retired instructions.
    # Next to `lx` on purpose -- the two are compared on every mode 3 dot, and
    # putting it after the bool block instead measured +0.6% on its own.
    win_lx*:              int32
    smooth_scroll_sampled*: bool
    dropped_first_fetch*: bool
    # The line's FIRST `B01s` cycle -- the one that follows the discarded fetch
    # at the head of mode 3 -- is running. It is the one fetch on a line that
    # may not push early: see M3_THROWAWAY_DOTS in fifo_ppu, where the 12-dot
    # head budget forces it to run all the way to its push slot. Set when the
    # discarded fetch is aborted, cleared by that push. Per-line scratch, like
    # dropped_first_fetch next to it.
    head_cycle*:          bool
    fetching_window*:     bool
    fetching_sprite*:     bool
    # The CONSOLE, cached off GB.cgb_enabled when the FIFO PPU is built. The
    # end of mode 3 is per-device for one window start (CGB_WIN_TAIL_LAST) and
    # the two procs that decide it -- fetcher_retired and fifo_irq_m0_ready --
    # are reached from the dot loop with no `gb` in hand; a bool inside the
    # bool block costs the object nothing. Not serialized: a machine cannot
    # change model under a running core, so a loaded state re-derives it the
    # same way GB.cgb_enabled does.
    cgb*:                 bool
    # An object was fetched on the LINE'S LAST PIXEL. Per-line scratch, like
    # dropped_first_fetch: set at the object trigger, cleared at the mode 2 ->
    # 3 edge. Read only by fetch_work_pending, and only on a CGB, where a
    # window restart on that pixel and an object's fetch on it are one fetch
    # slot and not two -- see CGB_WIN_TAIL_LAST.
    obj_last_px*:         bool
    # A window START is owed to the next line: the WX comparator matched on the
    # line's LAST pixel, where a DMG's end-of-line cleanup cannot clear it
    # (DMG_WIN_LAST_PX_CARRY). Set at the end of mode 3, consumed at the head of
    # the next line whose LCDC.5 is set -- which may be several lines later, or
    # in the next FRAME, so unlike its neighbours here it is NOT per-line
    # scratch. Cleared with the rest of the render scratch, and never set on a
    # CGB.
    #
    # NOT serialized: see the deferred-payload note on the GB save state. A
    # state captured at vblank can only carry this from LY 143's own match, and
    # loading one without it costs at most the first line of one frame.
    win_carry*:           bool
    # LCDC.5 has been low since the carry above was owed, so spending it has to
    # REACTIVATE the window and not merely continue it -- worth
    # WIN_CARRY_REACT_LINES on the window line counter. Same lifetime as
    # win_carry and not serialized for the same reason.
    win_carry_gap*:       bool
    # Dots of WIN_EN_HOLD left on a WX match that LCDC.5 refused. Zero means
    # no match is waiting, which is every dot of almost every line; while it is
    # nonzero `win_lx` is the hold's own retry pixel and fifo_arm_window leaves
    # it alone. Per-line scratch.
    #
    # DOWN HERE, in the bool block, and not next to `win_lx` where it is read:
    # inserting a byte between `lx` and `win_lx` splits the pair the shifter
    # compares on every mode 3 dot and measured **+0.6% of retired
    # instructions** on Pokemon Blue, Pokemon Crystal and Link's Awakening DX
    # -- the same 0.6% the note on `win_lx` above records for moving `win_lx`
    # itself. This field is touched a handful of times a line and pays nothing
    # for sitting with the flags.
    win_hold*:            uint8
    # The last dot on which a store to SCX still moves this line's fine
    # scroll, or -1 outside that window. Only `SCX_FINE_LATCH_LIVE` reads it,
    # and it exists only when that is on: an unconditional field here measured
    # +0.21% of retired instructions with the mechanism itself compiled out,
    # which is the object-layout cliff `win_lx` and `win_hold` both record.
    when SCX_FINE_LATCH_LIVE:
      scx_latch_until*:   int32
    # The LOW THREE BITS of the dot the line latched its fine scroll on. The
    # wrap needs how many of the window's eight slots the discard has already
    # walked, and that is a slot index, so three bits are the whole of it --
    # `scx_latch_until` cannot supply them once a store has moved the window's
    # end. A byte because three bits is honestly all it is -- NOT for layout:
    # as an `int32` it benches the same to within the noise (0.232% against
    # 0.246%), so the mechanism's price is the branch in `fifo_arm_scx` and not
    # this field, which is the one thing the `win_lx` layout cliff would have
    # predicted and does not happen here.
    when SCX_FINE_LATCH_WRAP != 0:
      scx_latch_slot*:    uint8
    # Dots left in the stall a mid-line SCX store armed. Same layout argument
    # as the field above: it exists only when the mechanism is on.
    when SCX_STORE_STALL_DOTS != 0:
      scx_stall*:         int32
    # Dots left in the object fetch the shifter is stalled on, and which BG
    # tile last paid the "wait for the BG fetch" half of an object's penalty.
    # Both are the OBJ penalty algorithm's state; see tick_shifter's trigger.
    obj_penalty*:         int32
    obj_tile_fx*:         int32
    # Dots of OBJ penalty charged on this line so far. Only the field tail
    # reads it; per-line scratch, cleared at the mode 2 -> 3 edge. Present only
    # when that mechanism is on, and DOWN HERE with the rest of the object
    # scratch rather than up beside `scx_tile`: a word between the fields the
    # fetch reads costs more than the mechanism itself does, which is the same
    # layout cliff `win_lx` and `win_hold` each record.
    when STAT_M0_TAIL_ANY:
      obj_dots_line*:     int32
    # ---- The object fetch's two bitplane reads, as dots ---------------------
    #
    # `sprite_fetch_merge` runs on one dot, but the fetch it stands for reads
    # the two bitplanes OBJ_PLANE_GAP dots apart and reads LCDC.2 separately for
    # each of them. `obj_hi_dot` is the dot the HIGH plane's read samples that
    # bit on, latched at the trigger because it depends on which end of the
    # penalty the fetch sits at (see OBJ_PLANE1_LAG in fifo_ppu). The low
    # plane's is always OBJ_PLANE_GAP dots before it, and always in the past.
    #
    # The high plane's can be in the FUTURE -- up to OBJ_PLANE1_LAG dots after
    # the merge -- so the merge uses the bit as it stands and the write path
    # redoes the plane if a later write moves it, exactly as fifo_recompose_last
    # redoes the mixer's tail. `obj_fix_from` is the first dot such a write can
    # land on (the merge dot + 1) and is OBJ_FIX_OFF when nothing is in flight;
    # the rest is the whole of what a redo needs -- the low byte the merge kept,
    # the height the high plane used, its VRAM bank and the object. No snapshot
    # of the FIFO goes with them: the merge is undoable from the entries
    # themselves, see fifo_obj_size_write. All per-line scratch, live for at most
    # OBJ_PLANE1_LAG dots, and not serialized.
    obj_hi_dot*:          int32
    obj_fix_from*:        int32
    obj_fix_bank*:        int32
    obj_fix_lo*:          uint8
    obj_fix_h*:           uint8
    obj_fix_s*:           GbSprite
    # Idle dots left at the head of mode 3 (the pipeline's lead over the CPU's
    # register view; see M3_PIPE_DELAY in fifo_ppu). A byte, not an int, and
    # for one reason: the mode 3 branch of fifo_tick_slow's dot loop asks
    # "is the head spent?" once per M-cycle of mode 3 -- ~6,200 times a frame
    # -- and a byte answers it in `ldrb`+`cbz` where a signed int needs
    # `ldr`+`cmp`+`b.le`. The value is 0..12 by construction (M3_PIPE_MCYCLES
    # * 4 + M3_PIPE_DELAY).
    m3_delay*:            uint8
    # Dots the mode 3 -> 0 FLAG still owes after the fetcher has retired, so
    # that a line whose pipeline started early (LY0_PIPE_MCYCLES in fifo_ppu:
    # line 0, and only line 0) still leaves mode 3 on the dot every other line
    # does. Zero on every other line, and a byte for the same reason m3_delay
    # is one. Transient per-line state, like m3_delay and m3_lead: not
    # serialized.
    m3_hold*:             uint8
    # How far the pipeline lags the CPU's view of the PPU registers on THIS
    # line, in dots. Latched at the mode 2 -> 3 edge because the CPU M-cycle it
    # is derived from is 4 dots at normal speed and 2 in double speed. See
    # M3_PIPE_MCYCLES in fifo_ppu.
    m3_lead*:             int32
    # ---- LCDC.4 against the two bitplane reads (CGB only) -------------------
    #
    # `tdsel_dot` is the dot LCDC.4 last CHANGED on, NO_TDSEL_CHANGE when it
    # has not changed on this line. The fetcher reads the bit
    # CGB_TDSEL_LATENCY dots later than the CPU wrote it and glitches a read
    # that lands on that dot exactly; both need the dot, and nothing else does.
    # Only a CGB records it, which is what keeps the DMG path at one compare.
    #
    # `tdsel_addr` is the most recent $8000-region tile-data read's VRAM
    # address -- an object bitplane, an LCDC.4 = 1 background bitplane, or a
    # RESET-glitched read, which drove its $8000-region address before the
    # reset arrived. A SET-glitched read delivers the byte there.
    # TDSEL_ADDR_OFF when nothing has driven one yet.
    #
    # BANK IS PACKED IN, at bit 13, rather than kept in a field of its own:
    # this is written by EVERY unsigned bitplane read of every frame, and the
    # second store cost +0.20% of retired instructions on blargg cpu_instrs
    # where the packed one costs +0.20% for the whole rule. Unpacking happens
    # once per glitched read, which is a handful of dots a frame at most.
    #
    # THE INDEX PATH'S ARMING IS PACKED IN TOO, at bit 14 and above: the last
    # dot a SET-glitched read may still answer with the tile INDEX rather than
    # the byte at the address (CGB_TDSEL_IDX_DOTS, TDSEL_IDX_SHIFT). A field of
    # its own costs 8 bytes of object and moves the whole fetch path's offsets,
    # which measured more than the rule does.
    #
    # `tdsel_dot` is per-line scratch cleared at the mode 2 -> 3 edge, and so
    # are the arming bits -- they are a dot on this line's clock. The ADDRESS
    # deliberately is NOT, because H-Blank does not clear the bus register it
    # stands for (see CGB_TDSEL_GLITCH). Neither field is serialized: a state is
    # captured in vblank.
    tdsel_dot*:           int32
    tdsel_addr*:          int32
    # ---- LCDC.3 / LCDC.6 against the map address read (CGB only) ------------
    #
    # `map_dot` is the dot the last change to either TILE MAP select bit goes
    # LIVE on at the fetcher -- the dot it was written on plus
    # CGB_MAP_LATENCY -- and NO_MAP_CHANGE when neither has moved on this line.
    # `map_old` is bits 3 and 6 as they stood before that write, which is what
    # a map read before `map_dot` uses. One dot and one byte covers both bits
    # because the writes that move them are the same store; when a later write
    # lands inside an earlier one's latency the newest wins, which is the same
    # corner (and the same resolution) `tdsel_dot` has.
    #
    # Per-line scratch cleared at the mode 2 -> 3 edge, and not serialized: a
    # state is captured in vblank. Only a CGB ever records a change.
    map_dot*:             int32
    map_old*:             uint8
    tile_num*:            uint8
    tile_attrs*:          uint8
    fetch_scy*:           uint8   ## SCY as of this fetch's map read; read
                                  ## back only when quirks.scy_fetch_latch
    tile_data_low*:       uint8
    tile_data_high*:      uint8
    # The FIFO entries the mixer is still holding: the pairs popped on the last
    # MIX_HOLD dots that emitted a pixel, indexed by the pixel's own low bits.
    # The mixer stage runs one dot behind the
    # pop (see fifo_recompose_last in fifo_ppu), so a mid-mode-3 write to a
    # register the mixer reads -- the palettes, LCDC's OBJ-enable and
    # BG-priority bits -- still reaches the pixel already written out. Kept
    # here rather than re-read from the ring because the BG ring is rewound and
    # overwritten by the next push and the OBJ ring is only popped when it is
    # non-empty, so neither can be indexed backwards safely.
    #
    # The ring is MIX_HOLD deep rather than as deep as the deepest stage
    # because the tail burst emits the last `m3_lead` pixels of a line ahead of
    # their own dots, and a write on the first dots of H-Blank still reaches
    # them (MIXER_TAIL_HBLANK).
    mix*:                 array[MIX_HOLD, GbMixHold]
    # Which dot this line's pixel 0 would have left the shifter on, if the
    # shifter's current unbroken run of one-pixel-per-dot emissions had started
    # there: `cycle_counter - lx`, written at each of the three places the
    # shifter STOPS (mixer_note_stop), which is everywhere that quantity can
    # change. While a stall is in progress it therefore still describes the run
    # the stall interrupted, and the shifter's position reads back as
    # `cycle_counter - tail_dot0` -- which keeps counting through an object
    # fetch and through the tail burst, where `lx` does not.
    # That is the whole of MIXER_TAIL_DOTS; see fifo_recompose_last.
    tail_dot0*:           int32
    # The first `lx` of that run, i.e. the `lx` the NEXT run starts at once the
    # stall clears. Pixels before it left the FIFO at least one dot further back
    # than `tail_dot0` says, so nothing may reach them -- the stall that broke
    # the run is 6..11 dots long (an object fetch) and the deepest mixer stage
    # is two.
    mix_run*:             int32
    sprites*:             seq[GbSprite]
    # The mode-2 OAM scan's progress: the index of the next OAM entry the scan
    # will examine, and the line the partial result in `sprites` belongs to.
    # The scan normally runs as one burst at the end of mode 2 (nothing can
    # change OAM while it is in progress, so where in mode 2 it runs is
    # unobservable) -- these two only carry it when an OAM DMA *is* changing
    # OAM underneath it, and the scan then has to be walked forward to the
    # dot of each transferred byte. See oam_scan_advance in fifo_ppu.nim.
    # Per-line scratch like everything above: not serialized, and rebuilt by
    # the burst on the next mode 2 -> 3 transition.
    scan_next*:           int32
    scan_line*:           int32

  # ---- APU Channels (base types) ----
  GbSoundChannel* = ref object of RootObj
    enabled*:        bool
    dac_enabled*:    bool
    length_counter*: int
    length_enable*:  bool

  GbVolumeEnvChannel* = ref object of GbSoundChannel
    starting_volume*:        uint8
    envelope_add_mode*:      bool
    period*:                 uint8
    volume_envelope_timer*:  uint8
    current_volume*:         uint8
    vol_env_is_updating*:    bool
    # "Enabling the envelope triggers an APU bug - in the next *even* DIV-APU
    # tick, the APU will tick the volume envelope of that appropriate channel,
    # even if it would not tick volume envelope at that tick otherwise"
    # (SameSuite channel_1_nrx2_speed_change). Set by an NRx2 write that takes
    # the envelope period from zero to non-zero, consumed by the next even
    # frame-sequencer step. See write_NRx2 and tick_frame_sequencer.
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it lives for at most
    # one 512 Hz step (~2 ms) and it is set only by a register write, so a
    # rollback that replays that write reconstructs it.
    env_extra_tick*:         bool

  GbChannel1* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    # The square channel's LATCHED duty output (0 or 1). Hardware does not read
    # the duty table continuously: it samples it once per duty step and holds
    # that bit until the next one, so a mid-sample NR11 duty change is not
    # audible until the step after it (SameSuite channel_1_duty_delay: "Changing
    # the duty becomes effective only after the current sample finishes"), and a
    # trigger keeps emitting the PREVIOUS sample -- zero, if the channel was off
    # -- for the whole startup delay (channel_1_duty / channel_1_align). See
    # ch1_catchup_slow, which is the only place that refreshes it.
    #
    # Deliberately NOT serialized, for the same reason as GbApu.tick_phase: it
    # is refreshed by the next duty step, so a loaded state is at most one duty
    # period (4 us to 2 ms) of one channel's sample away from exact, and it
    # errs towards silence rather than towards a wrong level.
    sample_bit*:         uint8
    # Absolute scheduler cycle of the next duty step, or GB_NO_STEP when the
    # channel has never been triggered. Replaces a per-period scheduler event:
    # the duty counter is advanced in closed form when something observes it
    # (see ch1_catchup). NOT serialized as a field -- savestate.nim converts
    # it to/from an etAPUChannel1 event so the state format is unchanged.
    next_step*:          CycleCount
    sweep_period*:       uint8
    negate*:             bool
    shift*:              uint8
    sweep_timer*:        uint8
    frequency_shadow*:   uint16
    sweep_enabled*:      bool
    negate_used*:        bool
    # Absolute scheduler cycle at which the sweep's SECOND overflow check falls
    # due, or GB_NO_STEP when none is pending. The check trails the frequency
    # writeback by 7 M-cycles and re-reads NR10 when it runs; see
    # GB_SWEEP_CHECK_DELAY for the three SameSuite sources that say so.
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it is pending for 8
    # M-cycles at most (2 us) once per sweep period, it is written only by a
    # sweep step, and a rollback snapshot that replays that step reconstructs
    # it. A state loaded from disk mid-window loses one overflow check, which
    # can at worst leave a channel audible until the next sweep step re-arms it.
    # Serializing it would cost a GB payload revision bump. The three sweep-unit
    # deadlines below are unserialized for exactly the same reason and are part
    # of the same deferred batch.
    sweep_check_at*:     CycleCount
    # Absolute scheduler cycle at which a sweep overflow STOP reaches NR52, or
    # GB_NO_STEP when none is in flight. Every sweep calculation's stop is one
    # APU tick behind the calculation itself; see GB_SWEEP_STOP_DELAY.
    sweep_stop_at*:      CycleCount
    # A trigger's frequency-shadow load in flight: the value NR13/NR14 held when
    # the channel was triggered, and the absolute scheduler cycle it reaches the
    # sweep unit's shadow register (GB_NO_STEP when none is pending). The load
    # does NOT happen on the write; see GB_SWEEP_SHADOW_DELAY.
    sweep_load_at*:      CycleCount
    sweep_load_value*:   uint16
    # Absolute scheduler cycle of the most recent duty step, or GB_NO_STEP when
    # none has happened since the last trigger. Only ch1_reload_is_now reads it,
    # and only to tell "the frequency timer is reloading on this very cycle"
    # apart from "the trigger's start delay happens to be one period away",
    # which next_step alone cannot distinguish.
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it decides a one-cycle
    # tie on an NR13/NR14 write and is rewritten by the next duty step, i.e.
    # within one sample. Serializing it would cost a GB payload revision bump.
    # GbChannel2 carries its own copy for the same reason.
    last_step_at*:       CycleCount
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel2* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    sample_bit*:         uint8        # see GbChannel1.sample_bit
    next_step*:          CycleCount   # see GbChannel1.next_step
    last_step_at*:       CycleCount   # see GbChannel1.last_step_at; unserialized
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel3* = ref object of GbSoundChannel
    next_step*:              CycleCount   # see GbChannel1.next_step
    wave_ram*:               array[16, uint8]
    wave_ram_position*:      uint8
    # Whether CH3 has fetched a byte since its last trigger. A trigger reloads
    # the frequency timer with period + 6 (Pan Docs: "triggering does not
    # immediately start playing wave RAM"), so for that whole window there is no
    # "byte CH3 is currently reading" -- which on DMG means a CPU access to wave
    # RAM has nothing to land on. See ch3_wave_open; it is the only thing that
    # separates "the pointer is at 0 because we just triggered" from "the
    # pointer is at 0 because it just wrapped".
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it is false only
    # inside a startup window a few T-cycles long, and it defaults to the value
    # a running channel has.
    wave_fetched*:           bool
    wave_ram_sample_buffer*: uint8
    length_load*:            uint8
    volume_code*:            uint8
    volume_code_shift*:      uint8
    frequency*:              uint16

  GbChannel4* = ref object of GbVolumeEnvChannel
    next_step*:    CycleCount   # see GbChannel1.next_step
    lfsr*:         uint16
    length_load*:  uint8
    clock_shift*:  uint8
    width_mode*:   uint8
    divisor_code*: uint8
    # The noise channel's frequency timer is not one counter, it is two, and
    # NR43 selects a different view of BOTH without restarting either. See
    # ch4_steps_to_rise: `div_counter` is a free-running counter clocked by the
    # divisor stage, and `clock_shift` picks which of its bits clocks the LFSR;
    # `div_next` is the divisor stage itself, the absolute cycle of the next
    # increment. `next_step` stays the derived "next LFSR shift" deadline so the
    # catch-up guard is still one comparison.
    #
    # Deliberately NOT serialized, and joining the batch of GB fields already
    # waiting on one payload-revision bump rather than spending a bump each.
    # A state is loaded with both re-derived from `next_step` (gb_apply_state,
    # ch4_resync_divisor), which reproduces the LFSR schedule exactly and can
    # only differ if the game writes NR43 inside the first period after a load.
    div_counter*:  uint16
    div_next*:     CycleCount

  GbApu* = ref object
    sound_enabled*:       bool
    buffer*:              seq[float32]
    buffer_pos*:          int
    frame_sequencer_stage*: int
    # Phase of the APU's own 1 MHz tick grid, in scheduler cycles: a tick edge
    # lands on every cycle congruent to this modulo (4 shl speed). The square
    # channels' frequency timers are clocked by that grid, not by the CPU, so a
    # trigger written between two edges does not start counting until the next
    # one -- which is what SameSuite channel_1_align_cpu measures ("Channel 1 is
    # aligned to the APU's enable time, not the CPU's start time"): inserting
    # nops BEFORE the NR52 power-on moves the whole grid with the write and
    # changes nothing, while the nops between power-on and trigger in
    # channel_1_align shift the result by one CPU cycle. Reset by an APU
    # power-on; see apu_write and gb_trigger_deadline.
    #
    # Deliberately NOT serialized. It is only ever written by a power-on, so a
    # rollback snapshot that replays one reconstructs it exactly; a state loaded
    # from disk falls back to the scheduler's own grid, which costs at most half
    # an APU tick (~0.25 us) of pulse phase and is inaudible. Serializing it
    # would cost a GB payload revision bump, which is worth spending on a batch
    # of fields rather than on this one.
    tick_phase*:          CycleCount
    # Phase of the HALF-rate grid the noise channel's divisor stage is clocked
    # by, in scheduler cycles: this is the power-on cycle taken modulo
    # (8 shl speed), and an edge of that 512 kHz grid lands on every cycle
    # congruent to `noise_phase + (4 shl speed)` -- i.e. on the ODD 1 MHz ticks
    # counted from the power-on. NR43's divisor field counts on this grid and a
    # trigger cannot reset it, which is what SameSuite
    # channel_4_frequency_alignment measures; see gb_noise_deadline for the
    # derivation and the cross-checks. Reset by an APU power-on, exactly like
    # tick_phase.
    #
    # Deliberately NOT serialized, for the same reasons as tick_phase: written
    # only by a power-on, worth at most one 1 MHz tick of noise phase, and
    # serializing it would cost a GB payload revision bump.
    noise_phase*:         CycleCount
    # "The first DIV-APU event after a power-on is skipped when DIV's tap bit
    # was already high" (SameSuite div_write_trigger_10). The divider is what
    # actually clocks the sequencer, so powering the APU on part-way through a
    # tap period leaves the divider half a step ahead of the sequencer: the
    # edge that ends that period has already been accounted for and produces no
    # step. See apu_write's NR52 arm and tick_frame_sequencer.
    #
    # Deliberately NOT serialized, like tick_phase: it is true only between an
    # APU power-on and the next 512 Hz edge (under 2 ms), it is written only by
    # a power-on, and a rollback that replays one reconstructs it exactly.
    div_skip*:            bool
    # Whether the sequencer's NEXT step is one that does NOT clock the length
    # counter -- the "extra length clocking" gate on an NRx4 write. Note it is
    # a property of the DIVIDER's phase, not of frame_sequencer_stage: while
    # div_skip is pending the two disagree, and div_write_trigger_10 is exactly
    # the test that can tell.
    first_half_of_length_period*: bool
    left_enable*:         bool
    left_volume*:         uint8
    right_enable*:        bool
    right_volume*:        uint8
    nr51*:                uint8
    sync*:                bool
    channel_mask*:        array[4, bool]  # pulse 1/2, wave, noise; true = enabled
    # Master volume as a precomputed factor (1.0 = unity), applied per
    # buffer at the queue point
    master_volume_factor*: float32
    master_muted*:        bool
    # 2x speed: drop every other stereo frame at the queue point so
    # audio-driven pacing runs emulation twice as fast
    turbo*:               bool
    turbo_parity:         bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward (WSOLA); presentation-only, see the GBA APU.
    pitch_correct_ff*:    bool
    stretch:              TimeStretch
    stretch_engaged:      bool
    audio_dev*:           uint32
    channel1*:            GbChannel1
    channel2*:            GbChannel2
    channel3*:            GbChannel3
    channel4*:            GbChannel4
    # Output-stage DC blocker (see GB_DC_CHARGE and get_sample). Charge held on
    # the coupling capacitor, one per stereo side. Deliberately NOT serialized:
    # it is presentation state, not emulated state, and the filter re-converges
    # within ~6 ms of a state load — inaudible, and a state that restores it
    # would only be restoring the tail of a filter, not anything about the
    # machine. (It would no longer be expensive to add: since v7 the container
    # version describes only the header and each core carries its own payload
    # revision, so a GB field costs a GB migration and nothing on the GBA side.
    # It is left out because it does not belong in the file, not because the
    # format makes it costly.)
    dc_cap_left*:         float32
    dc_cap_right*:        float32
    left_resampler*:      Resampler[float32]
    right_resampler*:     Resampler[float32]
    resample_freq*:       int
    output_freq*:         int

  # ---- Memory ----
  GbMemory* = ref object
    wram*:                 array[8, seq[uint8]]
    wram_bank*:            uint8
    rp*:                   uint8 # RP ($FF56) stored bits 0/6/7 — the LED and
                                 # the read-enable pair. Readback ORs $3E:
                                 # bits 2-5 read set and bit 1 is "no IR
                                 # signal", which is all this models (no IR
                                 # link). An AGS with no IR window still
                                 # carries the register and reads $3E at boot
                                 # (gbedge p00, 2026-08-17). Not serialized —
                                 # cosmetic readback state.
    svbk_raw*:             uint8 # the bits the SVBK write actually carried:
                                 # readback is raw, only the MAPPING aliases
                                 # 0 -> 1 (SameBoy stores `value | ~7`, DocBoy
                                 # reads the stored bank; a written 0 reads
                                 # back $F8, not $F9). Not serialized — the
                                 # payload keeps wram_bank, and a post-load
                                 # readback of an explicitly-written 0 is the
                                 # only divergence.
    hram*:                 array[0x7F, uint8]
    # $FEA0-$FEFF, the "prohibited" tail of the OAM page. On CGB revisions 0-D
    # it is real RAM (Pan Docs, "FEA0-FEFF range": "On CGB revisions 0-D, this
    # area is a unique RAM area"); on DMG and on CGB-E and later nothing here
    # is read. Which of the three models applies is GbQuirks.unusable_region.
    #
    # NOT SERIALIZED, deliberately, and for the same reason `revision` is not:
    # a byte-array in GB_SEC_MEM costs a GB payload revision bump, which is
    # being taken once for a batch (notes/samesuite-apu.md, "Unserialized
    # state"). The consequence is bounded -- a state saved after a ROM seeded
    # this region loads with it zeroed -- and the only ROMs known to seed it
    # do so once during setup, before any state a user would take.
    # IF A GB PAYLOAD BUMP HAPPENS FOR ANY OTHER REASON, ADD THIS ONE.
    unusable*:             array[0x60, uint8]
    bootrom*:              seq[uint8]
    cycle_tick_count*:     int
    # A CPU write this M-cycle has left something for the M-cycle boundary to
    # do (an IF store, a STAT interrupt-line edge). mem_write applies the byte
    # BEFORE the M-cycle's PPU dots, because that is the phase the pixel
    # pipeline needs; the interrupt machinery was never out of phase with the
    # CPU, so the half of a write that feeds IT stays on the boundary. One flag
    # for both so the write path pays a single test. See mem_flush_deferred.
    write_deferred*:       bool
    # The register write that flag stands for, when it is a whole store and not
    # just a STAT edge: FF41 or FF55, the two that GATE a PPU event (see
    # ppu_write_machinery). 0 = none. One slot is enough -- the CPU
    # writes one byte per M-cycle -- and it is drained before a second one can
    # be recorded, so the non-M-cycle callers cannot lose one either. Never live
    # across an instruction boundary, so it is not serialized.
    deferred_reg*:         uint16
    deferred_val*:         uint8
    when CGB_WRITE_LATENCY_ANY:
      # The other direction: a CGB pipeline-register store that lands PART WAY
      # THROUGH this M-cycle's PPU dots rather than at either end of them. Same
      # one-slot, drained-before-refilled discipline as the pair above, and for
      # the same reason. 0 = none. See mem_tick_ppu_latched.
      pipe_reg*:           uint16
      pipe_val*:           uint8
    ff72*, ff73*, ff74*, ff75*: uint8
    dma*:                  uint8
    current_dma_source*:   uint16
    internal_dma_timer*:   int
    dma_position*:         int
    requested_oam_dma*:    bool
    next_dma_counter*:     uint8
    # Derived from dma_position, maintained by mem_dma_tick: true for exactly
    # the M-cycles in `dma_position in 1 .. 0xA0`, i.e. while the OAM DMA unit
    # owns a bus. Every CPU read and write tests it, so it is one bool load
    # instead of the pair of range compares that used to sit on that path; it
    # is a cache of existing state, not new state (see gb_recompute_dma_derived).
    dma_busy*:             bool
    # Which bus the running OAM DMA owns (a GbDmaBus ordinal), the byte it last
    # put on that bus, and what the source memory does to the data lines when
    # the CPU writes over them (a Drive* constant). All three are derived: the
    # bus and drive class from current_dma_source, the latch from the source
    # memory at dma_position-1.
    dma_bus*:              uint8
    dma_latch*:            uint8
    dma_drive*:            uint8
    dma_openbus*:          bool
    requested_speed_switch*: bool
    current_speed*:        uint8

  # ---- Main GB type ----
  GB* = ref object of EmuObj
    bootrom_path*:   string
    rom_path*:       string
    # The two model axes, and they are NOT the same question.
    #
    # `cgb_enabled` is the CONSOLE: a CGB (or AGB) is in front of you. It decides
    # timing and the SoC's quirks -- the DMG STAT-write glitch, the OAM bus release
    # inside mode 2, the serial tap, the line-144 STAT lead. None care what
    # cartridge is inserted.
    #
    # `cgb_native` is the MODE: the CGB's own graphics and register set are in use.
    # A DMG cart on CGB hardware runs in DMG-compatibility mode -- the boot ROM sets
    # KEY0 at handoff -- where KEY1/HDMA/SVBK/VBK/BCPD/OCPD/PCM12/PCM34 read as
    # unmapped (mooneye misc/bits/unused_hwio-C), BG map attributes and the OBJ
    # attribute's palette/bank nibble are not decoded, LCDC.0 is DMG's "BG on/off"
    # rather than the CGB's master priority, objects are ordered by X again, and
    # every pixel goes through BGP/OBP before indexing palette 0. The boot ROM
    # itself always runs native, which is how it writes the compatibility palettes
    # it is about to hand over.
    #
    # So a DMG-compatibility CGB is CGB timing with a DMG picture, and collapsing
    # either axis onto the other gets one half wrong. `cgb_native` is a cached
    # derivation of `cgb_enabled and (cgb_flag != cgbNone or the boot ROM is still
    # mapped)` rather than a proc because it is read per pixel; keep it in step via
    # `gb_sync_cgb_native` at every point those three inputs move.
    #
    # ---- Documented model splits this tree does NOT model -------------------
    #
    # Audited 2026-08-03 against Pan Docs, the mealybug PPU document and the
    # per-model expectations in mooneye/AGE/gambatte filenames; re-checked
    # 2026-08-20, when four entries were struck because they had since shipped
    # (OBJ_ABORT / CGB_OBJ_ABORT, CGB_TDSEL_GLITCH, GbUnusableRegion's per-revision
    # $FEA0-$FEFF, and the WX = 166 window family -- see CGB_WIN_TAIL_LAST and
    # DMG_WIN_LAST_PX_CARRY). Re-verify against the constants above before trusting
    # a line of it.
    #
    # Measurable today, unfixed:
    #  * LCDC.5 clear resets the window's Y condition on CGB, so WY must be met
    #    again in the same frame; on DMG the latch persists (Pan Docs, Window
    #    rendering criteria). ppu_latch_wy has no such reset.
    #  * OAM DMA source above $DFFF folds down into $C000-$DFFF on DMG and fills
    #    OAM with $FF on CGB (mooneye acceptance/oam_dma/sources-GS). Only the DMG
    #    fold is modelled.
    #  * OPRI ($FF6C) is unimplemented -- it reads as unmapped rather than as
    #    itself. It only matters for a cart writing it while the boot ROM is
    #    mapped, which no test ROM here does.
    #  * The APU has no model branch, and three are documented (Pan Docs, Audio
    #    Registers): wave RAM is only accessible on the dot CH3 reads it on
    #    monochrome consoles, retriggering CH3 corrupts wave RAM on monochrome
    #    only, and NRx1 length timers stay writable with the APU off on monochrome
    #    only.
    #
    # Not measurable by anything this tree runs:
    #  * HALT entry/wake granularity (2 T on DMG, 4 on CGB, plus a CGB termination
    #    M-cycle) -- mooneye halt_ime1_timing2-GS is "fail: CGB".
    #  * DI's delay on CGB. mooneye acceptance/di_timing-GS asserts one; Pan Docs
    #    describes DI as immediate with no model note. Left alone deliberately --
    #    the sources disagree and nothing here can arbitrate.
    #  * The joypad line-switch settling delay (DMG/MGB only) and contact bounce.
    #  * The IR port ($FF56) -- CGB-only hardware, unimplemented.
    #  * STOP outside a speed switch: a DMG keeps drawing a black line, a CGB
    #    blanks unless it is in mode 3.
    #
    # Out of scope: everything splitting CGB REVISIONS rather than consoles (SCY
    # bitplane caching from CGB-D, the LY=153 and OAM-read boundaries, half the
    # APU). dingbat models one CGB and is scored against CPU CGB C references.
    #
    # SCY keeps being re-opened, so: reading SCY LIVE at each of a tile fetch's
    # three VRAM reads -- map row, then again per bitplane -- is the specified
    # behaviour of every device this tree models, not an omission. Pan Docs,
    # "Mid-frame behavior": the scroll registers are re-read on each tile fetch,
    # and all models before CGB-D read Y once per bitplane while CGB-D and later
    # use one Y for both. Caching into a per-fetch latch would be CGB-D behaviour,
    # wrong for CPU CGB C and for DMG. Confirmed, not just documented: decoded per
    # tile, the mealybug m3_scy_change DMG reference has the map fetch and low
    # bitplane on one write and the high bitplane on the next wherever a write
    # lands between them, and fifo_ppu's live reads reproduce that band exactly.
    cgb_enabled*:    bool
    cgb_native*:     bool
    # Frontend opt-in for Super Game Boy emulation. Default OFF, and off for
    # every caller that does not say otherwise -- the test harnesses, the
    # benchmark and the ROM sweeps all build a GB directly, and stock DMG
    # behaviour is what they are scoring against. Only ever consulted at
    # post_init; the cart header still has the final say after that.
    sgb_requested*:  bool
    fifo*:           bool
    headless*:       bool
    run_bios*:       bool
    cartridge*:      Mbc
    rom_size*:       uint32
    ram_size*:       int
    cgb_flag*:       CgbFlag
    boot_model*:     GbBootModel
    # The silicon revision, and the behaviour resolved from it. Set once by
    # gb_set_revision (new_gb, then any --model= override) and never touched
    # again, which is why the emulation code can read `quirks` without a
    # dispatch and why neither field is in the save state.
    #
    # NOT SERIALIZED, deliberately, and the same is true of `boot_model` next
    # door: both are construction-time properties of the *machine*, and a
    # state is loaded into a machine that was already constructed. The
    # consequence is real but narrow -- a state saved on `--model=cgb0` and
    # loaded by a default-revision process runs the loaded state on a CGB E,
    # silently. Nothing in the shipping frontends can reach a non-default
    # revision (there is no UI for it), so today this is only reachable from
    # the test harness. Serializing `revision` (one byte, next to
    # `cgb_enabled` in GB_SEC_MEM, with older states reading back the default)
    # costs a GB payload revision bump, which is being taken once for a batch;
    # see notes/samesuite-apu.md "Unserialized state". IF A GB PAYLOAD BUMP
    # HAPPENS FOR ANY OTHER REASON, ADD THIS ONE.
    revision*:       GbRevision
    quirks*:         GbQuirks
    rom_title*:      string
    scheduler*:      Scheduler
    cpu*:            GbCpu
    interrupts*:     GbInterrupts
    joypad*:         GbJoypad
    ppu*:            GbPpu
    # The same object as `ppu` when the FIFO renderer is selected, nil for the
    # scanline one. Lets the per-M-cycle component tick reach the shipping
    # renderer as a direct call instead of a method dispatch (which showed up
    # as ~2-3% of a profile in chckNilDisp alone). Non-owning: `ppu` owns it.
    fifo_ppu* {.cursor.}: GbFifoPpu
    timer*:          GbTimer
    serial*:         GbSerial
    memory*:         GbMemory
    apu*:            GbApu
    # Non-nil only when the cart header unlocks SGB functions and the machine
    # is not in CGB mode; every SGB hook tests it. See sgb.nim.
    sgb*:            SgbState
    cheats*:         CheatEngine
    cheat_hooks:     MemHooks       # built once, reused each frame
    when defined(test_harness):
      test_output*:  TestOutput

# ==================== FETCHER ORDER ====================
const FETCHER_ORDER*: array[-5 .. 7, FetchStage] = [
  # Steps -5..-1 are the window startup fetch's IDLE HEAD, and only a line that
  # starts as a window line ever enters there (WIN_HEAD_ABSORB in fifo_ppu):
  # the head is six dots whatever WX is, the `7 - WX` fine-scroll discard eats
  # that many of them at the shifter, and the fetcher waits out the other
  # `WX - 1`. Spelling it as negative steps of the fetcher's own order costs
  # the mode 3 dot loop nothing -- the `case` on it is dispatched every dot
  # already, and fsSleep's `inc` walks the counter back up to 0 on its own.
  # WX < WIN_LINE_START_WX, so five entries covers every threshold up to 7.
  fsSleep, fsSleep, fsSleep, fsSleep, fsSleep,
  fsSleep, fsGetTile, fsSleep, fsGetTileDataLow,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
]
static: doAssert WIN_LINE_START_WX - 2 <= 5,
  "WIN_HEAD_ABSORB idles WX - 1 dots; FETCHER_ORDER's negative head must cover it"

# DMG default colors (BGR555)
const DMG_COLORS*: array[4, uint16] = [0x6BDF'u16, 0x3ABF'u16, 0x35BD'u16, 0x2CEF'u16]

# The CGB's DMG-compatibility palettes, shade 0 (lightest) to shade 3.
#
# A DMG cart on CGB hardware still produces a 2-bit shade per pixel; what the
# CGB adds is that BGP/OBP0/OBP1 then index a real colour palette, which the
# boot ROM loads before handoff. Which one it loads depends on the cart header:
# Nintendo-published titles get a themed palette picked by the header checksum,
# and everything else — every homebrew and every test ROM — gets the fallback
# below. That fallback is what the bundled test suites specify as "LCD shades
# for CGB compatibility mode" (game-boy-test-roms' mealybug howto, and the same
# six colours appear in the AGE `ncm*` and mbc3-tester-cgb references):
#
#   background  #000000  #0063C6  #7BFF31  #FFFFFF   (shade 3 -> 0)
#   objects     #000000  #943939  #FF8484  #FFFFFF
#
# converted to BGR555 by the inverse of the (X shl 3) or (X shr 2) expansion
# those same suites specify, which is exact for all six.
#
# Only the fallback is here. Reproducing the per-title table would mean lifting
# Nintendo's boot ROM data, and it buys nothing measurable: it changes the
# colours of thirty-odd licensed monochrome carts and nothing else — not one
# test ROM, since none of them carry a Nintendo licensee code.
const CGB_COMPAT_BG_COLORS*:  array[4, uint16] =
  [0x7FFF'u16, 0x1BEF'u16, 0x6180'u16, 0x0000'u16]
const CGB_COMPAT_OBJ_COLORS*: array[4, uint16] =
  [0x7FFF'u16, 0x421F'u16, 0x1CF2'u16, 0x0000'u16]

const GB_WIDTH*  = 160
const GB_HEIGHT* = 144
const GB_CLOCK_SPEED* = 4194304

# Queue-push block, in float32s (128 stereo frames = 3.9 ms); small so
# audio-sync pacing sees a fine-grained queue level (see gba/apu.nim)
const GB_APU_BUFFER_SIZE* = 256
# Audio-sync pacing levels in bytes of queued f32 stereo (8 bytes/frame);
# fixed rather than derived from the push block: 4096 B = 512 frames ≈ 15.6 ms.
# The backstop is runaway protection only — far above the normal operating
# range so it never blocks emulation mid-frame (see gba/apu.nim)
const GB_SYNC_AHEAD_BYTES*    = 4096'u32
const GB_SYNC_BACKSTOP_BYTES* = 32768'u32
const GB_SAMPLE_RATE*     = 32768
const GB_SAMPLE_PERIOD*   = GB_CLOCK_SPEED div GB_SAMPLE_RATE

# The share of the output's -1..1 range given to one channel's DAC (get_sample).
#
# The mixer adds up to four DAC outputs, each spanning -1..1, so one side of the
# mix spans -4..4 (Pan Docs, Audio Details: "the analog range of those outputs
# is 4x that of each channel"). Nothing in the hardware pins that to a host's
# full scale -- there is an amplifier and a volume knob in between -- so this is
# a headroom decision, and it is made by the DC blocker downstream.
#
# The blocker emits `mix - cap`, where the stored charge tracks the mix's local
# MEAN. Both terms are independently bounded by the mixer range, so the output
# can reach twice it. That is not a corner case here: a channel that is switched
# off but whose DAC is still powered parks at analog +1 (see GB_DAC_LUT), so the
# mean genuinely does sit near a rail for long stretches, and a waveform
# excursion to the other rail then spans the full 2x. At 1/4 -- what the mixer
# used before the DC blocker existed, where a full-scale mix was exactly
# full-scale output -- that clips. 1/8 makes overflow arithmetically impossible:
# |mix| <= 1/2 and |cap| <= 1/2, so |out| <= 1.
#
# 1/8 is also exactly SameBoy's level (its MAX_CH_AMP is 0xFF0, so its four
# channels sum to half of int16 range), which means its dumps and ours are
# directly comparable without renormalising.
const GB_MIX_SCALE* = 1.0'f32 / 8.0'f32

# NR50 master volume, indexed by the register's 3-bit field, already folded
# together with GB_MIX_SCALE.
#
# Pan Docs, NR50: "A value of 0 is treated as a volume of 1 (very quiet), and a
# value of 7 is treated as a volume of 8 (no volume reduction). Importantly, the
# amplifier NEVER MUTES a non-silent input." So the scale is (V+1)/8, not V/7:
# volume 0 is one eighth of full, and a driver that fades NR50 down to 0 does
# not reach silence on hardware.
const GB_MASTER_VOLUME* = block:
  var t: array[8, float32]
  for v in 0 .. 7: t[v] = float32(float64(v + 1) / 8.0) * GB_MIX_SCALE
  t

# Output-stage DC blocker.
#
# A Game Boy channel's DAC does not idle at the middle of its range: the 4-bit
# digital value 0 is one RAIL, not silence (see GB_DAC_LUT). A 12.5%-duty square
# therefore sits at the top of its swing seven eighths of the time, and a
# channel that is switched off but still has its DAC powered sits there
# permanently. So the mixer's output carries a large DC component that moves
# every time a DAC is powered up or down, or panning or master volume changes.
# Measured on 60 s of in-game audio, the raw mix sits at 0.85 full scale in
# Link's Awakening DX and pins against a rail for a quarter of all samples.
#
# The hardware couples the mixer to the output jack through a capacitor, which
# removes that offset. Without it every one of those DC shifts reaches the
# speaker as a step, and a step is what a listener hears as a click. This is the
# standard one-pole model: the capacitor charges toward the input, and only the
# difference is passed on.
#
#     out = in - cap;   cap = in - out * charge
#
# `charge` is per output sample, so it is the per-T-cycle constant raised to the
# number of T-cycles between samples: 0.999958 ** (GB_CLOCK_SPEED / rate). At
# 32768 Hz that is 0.9946383, a 28 Hz corner with a 5.7 ms time constant --
# below anything the APU can play, so it removes offset and nothing else.
#
# Verified against SameBoy on identical 60 s in-game runs (tools/popscan.py, the
# same threshold on both sides since the two now share an output level): the DC
# trajectory matches to within a few per cent on every title measured. Pokemon
# Crystal 16 steps / 5969 per-second total variation / 195 DC rms against
# SameBoy's 20 / 5934 / 195; Link's Awakening DX 12 / 4859 / 167 against 10 /
# 4832 / 165; Prehistorik Man 150 / 9620 / 339 against 178 / 9877 / 345.
const GB_DC_CHARGE* = 0.9946383125'f32
const GB_FRAME_SEQ_RATE*  = 512
const GB_FRAME_SEQ_PERIOD* = GB_CLOCK_SPEED div GB_FRAME_SEQ_RATE

# Post-boot VRAM tile data ($8000-$819F): blank tile $00, the Nintendo logo
# ($01-$18), and the ® trademark tile ($19). Several Mealybug PPU tests place
# these on screen without loading them, relying on the boot ROM having left them
# in VRAM (the reference images were captured on hardware that ran the boot ROM).
#
# We deliberately do NOT hardcode Nintendo's logo here — reproducing their
# trademark logo as source data is avoidable. Instead we decompress it at boot
# from the LOADED cartridge's own header (every valid GB ROM carries it at
# 0x104-0x133; the real boot ROM verifies it), exactly as the boot ROM does.
# This ships no Nintendo logo data and is more faithful (a ROM with a corrupted
# header logo renders the corrupted logo, like real hardware). The ® tile is a
# generic registered-trademark glyph (circle-R), not Nintendo-specific IP.
const POST_BOOT_RA_TILE*: array[16, uint8] = [
  0x3C'u8, 0x00, 0x42, 0x00, 0xB9, 0x00, 0xA5, 0x00,
  0xB9, 0x00, 0xA5, 0x00, 0x42, 0x00, 0x3C, 0x00,
]

proc write_boot_logo*(rom: openArray[byte]; vram: var openArray[uint8]) =
  ## Expand the 48-byte header logo (rom[0x104..0x133]) into the 384 bytes of
  ## tile data at tiles $01-$18 (vram[16..399]), mirroring the DMG boot ROM's
  ## nibble-doubling decompressor: each header byte's two nibbles are each
  ## spread to a full 8-pixel row (bit i -> pixels 2i,2i+1) and written to two
  ## consecutive tile rows (2x vertical), low bitplane only.
  if rom.len < 0x134 or vram.len < 400: return
  proc double_bits(n: uint8): uint8 =
    for i in 0 ..< 4:
      if (n and (1'u8 shl i)) != 0:
        result = result or (0b11'u8 shl (i * 2))
  var pos = 16  # tile $01, byte 0
  for k in 0 ..< 48:
    let v = rom[0x104 + k]
    for nib in [v shr 4, v and 0x0F]:
      let e = double_bits(nib)
      vram[pos] = e; pos += 2   # low plane, row N (high plane stays 0)
      vram[pos] = e; pos += 2   # low plane, row N+1 (2x vertical)

# ==================== PIXEL FIFO HELPERS ====================

proc fifo_push*(f: var GbPixelFifo; p: GbPixel) {.inline.} =
  f.data[f.tail] = p
  f.tail = (f.tail + 1) and 15
  inc f.size

proc fifo_shift*(f: var GbPixelFifo): GbPixel {.inline.} =
  result = f.data[f.head]
  f.head = (f.head + 1) and 15
  dec f.size

proc fifo_clear*(f: var GbPixelFifo) {.inline.} =
  f.head = 0; f.tail = 0; f.size = 0

proc fifo_get*(f: var GbPixelFifo; idx: int): GbPixel {.inline.} =
  f.data[(f.head + idx) and 15]

proc fifo_set*(f: var GbPixelFifo; idx: int; p: GbPixel) {.inline.} =
  f.data[(f.head + idx) and 15] = p

# ==================== CPU REGISTER ACCESSORS ====================

proc a*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.af shr 8)
proc `a=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.af = (cpu.af and 0x00FF'u16) or (uint16(v) shl 8)
proc f*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.af and 0xF0)
proc `f=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.af = (cpu.af and 0xFF00'u16) or uint16(v and 0xF0)
proc b*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.bc shr 8)
proc `b=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.bc = (cpu.bc and 0x00FF'u16) or (uint16(v) shl 8)
proc c*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.bc and 0xFF)
proc `c=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.bc = (cpu.bc and 0xFF00'u16) or uint16(v)
proc d*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.de shr 8)
proc `d=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.de = (cpu.de and 0x00FF'u16) or (uint16(v) shl 8)
proc e*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.de and 0xFF)
proc `e=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.de = (cpu.de and 0xFF00'u16) or uint16(v)
proc h*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.hl shr 8)
proc `h=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.hl = (cpu.hl and 0x00FF'u16) or (uint16(v) shl 8)
proc l*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.hl and 0xFF)
proc `l=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.hl = (cpu.hl and 0xFF00'u16) or uint16(v)

# Flags: Z=bit7, N=bit6, H=bit5, C=bit4
proc fz*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0080'u16) != 0
proc `fz=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0080'u16
  else: cpu.af = cpu.af and not 0x0080'u16
proc fn*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0040'u16) != 0
proc `fn=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0040'u16
  else: cpu.af = cpu.af and not 0x0040'u16
proc fh*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0020'u16) != 0
proc `fh=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0020'u16
  else: cpu.af = cpu.af and not 0x0020'u16
proc fc*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0010'u16) != 0
proc `fc=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0010'u16
  else: cpu.af = cpu.af and not 0x0010'u16

# ==================== MBC HELPERS (shared) ====================

proc mbc_rom_bank_offset*(cart: Mbc; bank_num: int): int =
  (bank_num * 0x4000) mod int(cart.rom.len)

proc mbc_rom_offset*(idx: int): int = idx - 0x4000

proc mbc_ram_bank_offset*(cart: Mbc; bank_num: int): int =
  if cart.ram.len == 0: return 0
  (bank_num * 0x2000) mod cart.ram.len

proc mbc_ram_offset*(cart: Mbc; idx: int): int =
  ## Offset inside the selected 8 KiB RAM window. RAM smaller than the window
  ## (header code $01, 2 KiB — "PD" ROMs use it) has its high address lines
  ## unwired, so the window mirrors the array (Pan Docs, MBCs: accesses wrap)
  ## instead of indexing past it.
  if cart.ram.len >= 0x2000 or cart.ram.len == 0: idx - 0xA000
  else: (idx - 0xA000) mod cart.ram.len

const
  RTC_SECOND_CYCLES* = 4194304  # one RTC tick per emulated second
  MINUTES_PER_DAY*   = 60 * 24

# Deterministic-RTC override for lockstep/rollback netplay. With two peers the
# MBC3 clock must NOT read the local wall clock (it would differ between peers)
# and must NOT free-run (the tick count differs between a straight run and its
# rollback re-simulation — a determinism gap that diverges Crystal's DIV/RTC-
# seeded RNG). When set >= 0 it is the shared "now" (unix seconds) both peers
# pass at connect: the load-time catch-up uses it, and the clock is then FROZEN
# (no ticks). Mirrors the GBA core's enable_deterministic_rtc. -1 = real clock,
# free-running (single-player default).
var gbRtcNowOverride*: int64 = -1

proc enable_deterministic_gb_rtc*(epoch: int64) =
  ## Freeze the MBC3 RTC to a shared epoch. Both peers must pass the SAME
  ## value. Call before loading the cartridge/state.
  gbRtcNowOverride = epoch

proc gb_rtc_now(): int64 {.inline.} =
  if gbRtcNowOverride >= 0: gbRtcNowOverride else: getTime().toUnix()

proc gb_rtc_frozen(): bool {.inline.} = gbRtcNowOverride >= 0

proc rtc_halted*(cart: Mbc3): bool =
  (cart.rtc_live[4] and 0x40) != 0

proc rtc_schedule_full*(cart: Mbc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc rtc_remaining*(cart: Mbc3): int =
  ## Scheduler cycles until the pending RTC tick
  let s = cart.gb_ref.scheduler
  for ev in s.events:
    if ev.kind == etRtcSecond:
      return int(ev.cycles - s.cycles)
  RTC_SECOND_CYCLES

proc rtc_increment(cart: Mbc3) =
  # Hardware counters roll over at their natural boundaries with carry, but
  # out-of-range values (writable because registers are wider than needed)
  # count up to the register limit and wrap without carrying
  let s = cart.rtc_live[0] and 0x3F
  if s != 59:
    cart.rtc_live[0] = if s == 63: 0'u8 else: s + 1
    return
  cart.rtc_live[0] = 0
  let m = cart.rtc_live[1] and 0x3F
  if m != 59:
    cart.rtc_live[1] = if m == 63: 0'u8 else: m + 1
    return
  cart.rtc_live[1] = 0
  let h = cart.rtc_live[2] and 0x1F
  if h != 23:
    cart.rtc_live[2] = if h == 31: 0'u8 else: h + 1
    return
  cart.rtc_live[2] = 0
  let day = (uint16(cart.rtc_live[4] and 1) shl 8) or uint16(cart.rtc_live[3])
  let new_day = (day + 1) and 0x1FF
  cart.rtc_live[3] = uint8(new_day and 0xFF)
  cart.rtc_live[4] = (cart.rtc_live[4] and 0xC0) or uint8(new_day shr 8)
  if day == 511:  # day counter overflow: sticky carry flag
    cart.rtc_live[4] = cart.rtc_live[4] or 0x80

proc rtc_tick*(cart: Mbc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  cart.rtc_increment()

proc rtc_catch_up(cart: Mbc3; elapsed: int64) =
  ## Advance the clock by wall time that passed while the emulator was off
  if cart.rtc_halted() or elapsed <= 0: return
  let secs  = int64(cart.rtc_live[0] and 0x3F) + elapsed
  cart.rtc_live[0] = uint8(secs mod 60)
  let mins  = int64(cart.rtc_live[1] and 0x3F) + secs div 60
  cart.rtc_live[1] = uint8(mins mod 60)
  let hours = int64(cart.rtc_live[2] and 0x1F) + mins div 60
  cart.rtc_live[2] = uint8(hours mod 24)
  let days  = (int64(cart.rtc_live[4] and 1) shl 8) + int64(cart.rtc_live[3]) + hours div 24
  cart.rtc_live[3] = uint8(days and 0xFF)
  cart.rtc_live[4] = (cart.rtc_live[4] and 0xC0) or uint8((days shr 8) and 1)
  if days > 511:
    cart.rtc_live[4] = cart.rtc_live[4] or 0x80

proc rtc_footer(cart: Mbc3): string =
  ## BGB/VBA-compatible .sav footer: live regs, latched regs, unix timestamp
  proc add_u32(s: var string; v: uint32) =
    for i in 0 .. 3: s.add(char((v shr (8 * i)) and 0xFF))
  result = ""
  for i in 0 .. 4: result.add_u32(uint32(cart.rtc_live[i]))
  for i in 0 .. 4: result.add_u32(uint32(cart.rtc_latched[i]))
  let ts = uint64(gb_rtc_now())
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))

proc rtc_load_footer(cart: Mbc3; data: string) =
  ## BGB, mGBA and 64-bit VBA builds all write exactly RAM + 48 bytes, and old
  ## 32-bit VBA builds RAM + 44 (32-bit timestamp). Any other tail is NOT a
  ## clock — typically a forum download padded out to a power of two — and
  ## parsing padding as a footer scrambles the RTC (an all-zero tail reads as
  ## "saved January 1970" and catch-up then walks the day counter through five
  ## decades), so only the two exact lengths are accepted.
  proc get_u32(data: string; off: int): uint32 =
    for i in 0 .. 3: result = result or (uint32(data[off + i]) shl (8 * i))
  let base = cart.ram.len
  let extra = data.len - base
  if extra != 44 and extra != 48: return  # no footer, or a tail that isn't one
  for i in 0 .. 4: cart.rtc_live[i]    = uint8(get_u32(data, base + i * 4) and 0xFF)
  for i in 0 .. 4: cart.rtc_latched[i] = uint8(get_u32(data, base + 20 + i * 4) and 0xFF)
  var ts: int64 = int64(get_u32(data, base + 40))
  if extra == 48:
    ts = ts or (int64(get_u32(data, base + 44)) shl 32)
  # A timestamp before 2000 cannot be a real dump time (the footer format and
  # every RTC cartridge postdate it): the field is zeroed or garbage. Keep the
  # register values the footer states, but skip the decades of "catch-up" the
  # bogus timestamp implies. Future timestamps already no-op inside catch-up.
  if ts >= 946684800:
    cart.rtc_catch_up(gb_rtc_now() - ts)

# HuC3's clock lives inside the cartridge's microcontroller, in the same nibble
# window its other registers do: a minute-of-day counter at 0x10-0x12 and a day
# counter at 0x13-0x15, both little-endian nibble triples. Everything below
# knows that layout; mbc/huc3.nim knows the protocol that reaches it.

const
  # Nibble addresses inside that window. Only these have been pinned down; the
  # games use plenty more that nobody has identified.
  HUC3_SNAPSHOT*  = 0x00  # 0x00-0x06, where the clock is copied to be read
  HUC3_CLOCK*     = 0x10  # 0x10-0x12 minute of day, 0x13-0x15 days, 0x16 unknown
  HUC3_CLOCK_LEN* = 7     # a cartridge dump shows 0x10-0x16 copied across whole
  HUC3_EVENT*     = 0x58  # 0x58-0x5A event minutes, 0x5B-0x5D event days
  HUC3_DAY_WRAP*  = 0x1000  # the day counter is three nibbles and no more

proc nyb3*(cart: Huc3; at: int): int =
  int(cart.regs[at]) or (int(cart.regs[at + 1]) shl 4) or (int(cart.regs[at + 2]) shl 8)

proc set_nyb3*(cart: Huc3; at, v: int) =
  cart.regs[at]     = uint8(v and 0xF)
  cart.regs[at + 1] = uint8((v shr 4) and 0xF)
  cart.regs[at + 2] = uint8((v shr 8) and 0xF)

proc huc3_now_minutes*(cart: Huc3): int =
  ## The clock as one number, for arithmetic that has to cross a day boundary
  cart.nyb3(HUC3_CLOCK + 3) * MINUTES_PER_DAY + cart.nyb3(HUC3_CLOCK)

proc huc3_advance_minutes(cart: Huc3; count: int) =
  if count <= 0: return
  let minutes = cart.nyb3(HUC3_CLOCK) + count
  cart.set_nyb3(HUC3_CLOCK, minutes mod MINUTES_PER_DAY)
  cart.set_nyb3(HUC3_CLOCK + 3,
                (cart.nyb3(HUC3_CLOCK + 3) + minutes div MINUTES_PER_DAY) mod HUC3_DAY_WRAP)

proc huc3_advance_to(cart: Huc3; now: int64) =
  ## Step the clock over every whole minute between last_second and now. Keeping
  ## last_second rather than resetting it means the minute ticks stay on the
  ## host's minute boundaries across a save and reload, instead of restarting
  ## the minute every time the game is launched.
  let elapsed = now div 60 - cart.last_second div 60
  if elapsed <= 0: return
  cart.last_second += elapsed * 60
  # A whole day-counter cycle is as far as the clock can meaningfully move, and
  # capping there also keeps a nonsense timestamp out of a 32-bit int (the web
  # build's) on the way into the nibble arithmetic.
  cart.huc3_advance_minutes(int(min(elapsed, HUC3_DAY_WRAP * MINUTES_PER_DAY)))

proc huc3_rtc_schedule*(cart: Huc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc huc3_rtc_tick*(cart: Huc3) =
  if gb_rtc_frozen(): return
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  cart.huc3_advance_to(cart.last_second + 1)

# Battery footer: the unix second the clock was last stepped through, then the
# whole 256-nibble register window packed two nibbles to a byte. The window is
# the state — clock, event time, tone selection and whatever else that
# cartridge's microcontroller keeps there — so saving a hand-picked subset of it
# would lose whatever a given game happens to use. This is dingbat's own layout;
# no other emulator writes it, because no other emulator keeps the window whole.
const HUC3_FOOTER_LEN = 8 + 128

proc huc3_footer(cart: Huc3): string =
  result = newStringOfCap(HUC3_FOOTER_LEN)
  let ts = uint64(cart.last_second)
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))
  for i in 0 ..< 128:
    result.add(char(cart.regs[i * 2] or (cart.regs[i * 2 + 1] shl 4)))

proc huc3_load_footer(cart: Huc3; data: string) =
  let base = cart.ram.len
  # Exact length only: this is dingbat's own layout, so any other tail is a
  # padded download or another emulator's footer, not this one.
  if data.len - base != HUC3_FOOTER_LEN: return  # RAM-only save: keep the power-on clock
  var ts: int64 = 0
  for i in 0 .. 7: ts = ts or (int64(uint8(data[base + i])) shl (8 * i))
  for i in 0 ..< 128:
    let b = uint8(data[base + 8 + i])
    cart.regs[i * 2]     = b and 0x0F
    cart.regs[i * 2 + 1] = b shr 4
  cart.last_second = ts
  let now = gb_rtc_now()
  if ts > now:
    # Saved in the future: the clock would sit still until the host caught up,
    # so treat the host as authoritative and carry on from here instead.
    cart.last_second = now
  else:
    cart.huc3_advance_to(now)

# TAMA5's clock is a TC8521AM reached through the cartridge's microcontroller.
# Its layout is four pages of thirteen 4-bit registers plus three registers
# shared between the pages, all from endrift's tables in the gbdev thread
# (https://gbdev.gg8.se/forums/viewtopic.php?id=469, post #1). mbc/tama5.nim
# knows the protocol that reaches them; what is here is the clock itself.
#
#   page 0, TIMER   0 sec 1s   1 sec 10s  2 min 1s  3 min 10s  4 hour 1s
#                   5 hour 10s 6 weekday  7 day 1s  8 day 10s  9 month 1s
#                   A month 10s          B year 1s  C year 10s
#   page 1, ALARM   same fields where an alarm has one, plus A = 24-hour mode
#                   and B = the leap-year counter
#   pages 2 and 3   "free pages, which are effectively just 13 4-bit RAM
#                   addresses each"

const
  # Per-register wired-bit widths: "RTC registers only have a certain number of
  # bits wired up, so writing to bits that aren't used during normal function
  # won't do anything and will read out as zero" (endrift, post #1).
  TAMA5_RTC_MASK*: array[4, array[13, uint8]] = [
    [0xF'u8, 0x7, 0xF, 0x7, 0xF, 0x3, 0x7, 0xF, 0x3, 0xF, 0x1, 0xF, 0xF],
    # Alarm page: registers 0, 1, 9 and C have no bits at all; A is the 1-bit
    # 24-hour mode flag and B the 2-bit leap-year counter.
    [0x0'u8, 0x0, 0xF, 0x7, 0xF, 0x3, 0x7, 0xF, 0x3, 0x0, 0x1, 0x3, 0x0],
    [0xF'u8, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF],
    [0xF'u8, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF]]

  # A cartridge that has been in a drawer for a decade should not spend that
  # long in a catch-up loop, and the Tamagotchi has nothing useful to say about
  # a gap this size anyway.
  TAMA5_MAX_CATCHUP_DAYS = 4000

proc tama5_24h(cart: Tama5): bool =
  ## Alarm page register A. endrift, post #1: "A: 24-hour mode when set (1-bit)"
  (cart.rtc_pages[1][0x0A] and 1) != 0

proc tama5_get_minutes*(cart: Tama5): int =
  int(cart.rtc_pages[0][3]) * 10 + int(cart.rtc_pages[0][2])

proc tama5_set_minutes*(cart: Tama5; v: int) =
  cart.rtc_pages[0][3] = uint8((v div 10) and 0x7)
  cart.rtc_pages[0][2] = uint8(v mod 10)

proc tama5_get_hours*(cart: Tama5): int =
  ## The register pair as the game wrote it, which in 12-hour mode carries the
  ## PM flag in the tens digit rather than being a plain number.
  int(cart.rtc_pages[0][5]) * 10 + int(cart.rtc_pages[0][4])

proc tama5_set_hours*(cart: Tama5; v: int) =
  cart.rtc_pages[0][5] = uint8((v div 10) and 0x3)
  cart.rtc_pages[0][4] = uint8(v mod 10)

proc tama5_hour24(cart: Tama5): int =
  ## The hour as a 0-23 number, for arithmetic that has to cross midnight.
  let t = cart.rtc_pages[0]
  if cart.tama5_24h(): (int(t[5] and 3) * 10 + int(t[4])) mod 24
  else:
    # endrift, post #1: "in 12 hour mode, the high bit signals PM, so 11 PM/23
    # 10s digit would be 0b10 in 24 hour mode, but 0b11 in 12 hour mode, as it's
    # 1X:XX PM". So bit 0 of the tens digit is the digit and bit 1 is PM.
    let h12 = int(t[5] and 1) * 10 + int(t[4])
    ((h12 mod 12) + (if (t[5] and 2) != 0: 12 else: 0)) mod 24

proc tama5_set_hour24(cart: Tama5; h: int) =
  if cart.tama5_24h():
    cart.rtc_pages[0][5] = uint8((h div 10) and 3)
    cart.rtc_pages[0][4] = uint8(h mod 10)
  else:
    var h12 = h mod 12
    if h12 == 0: h12 = 12
    cart.rtc_pages[0][5] = uint8((h12 div 10) or (if h >= 12: 2 else: 0))
    cart.rtc_pages[0][4] = uint8(h12 mod 10)

proc tama5_days_in_month(month, leap_counter: int): int =
  # endrift, post #1: the alarm page's register B is a 2-bit counter and "the
  # year is treated as a leap year if 0". It is separate from the year so that
  # software can still call year 00 a common year, as 2100 will be.
  case month
  of 2:                      (if leap_counter == 0: 29 else: 28)
  of 4, 6, 9, 11:            30
  else:                      31

proc tama5_advance*(cart: Tama5; seconds: int64) =
  ## Step the clock forward. Written as arithmetic rather than a per-second loop
  ## so that catching up after the emulator has been closed for a month costs
  ## the same as one tick.
  if seconds <= 0: return
  var total = int64(int(cart.rtc_pages[0][1]) * 10 + int(cart.rtc_pages[0][0])) +
              int64(cart.tama5_get_minutes()) * 60 +
              int64(cart.tama5_hour24()) * 3600 + seconds
  var days = int(min(total div 86400, int64(TAMA5_MAX_CATCHUP_DAYS)))
  let tod = int(total mod 86400)

  cart.rtc_pages[0][0] = uint8((tod mod 60) mod 10)
  cart.rtc_pages[0][1] = uint8((tod mod 60) div 10)
  cart.tama5_set_minutes((tod div 60) mod 60)
  cart.tama5_set_hour24(tod div 3600)
  if days <= 0: return

  var t = addr cart.rtc_pages[0]
  var dow   = int(t[6]) mod 7
  var day   = max(int(t[8]) * 10 + int(t[7]), 1)
  var month = clamp(int(t[0x0A]) * 10 + int(t[9]), 1, 12)
  var year  = int(t[0x0C]) * 10 + int(t[0x0B])
  var leap  = int(cart.rtc_pages[1][0x0B] and 3)
  while days > 0:
    dec days
    inc day
    dow = (dow + 1) mod 7
    if day > tama5_days_in_month(month, leap):
      day = 1
      inc month
      if month > 12:
        month = 1
        year = (year + 1) mod 100
        # The leap counter has to move with the year or February would be 29
        # days long forever. Nobody has published what the TC8521AM does with it
        # on rollover; counting it up is the only reading that keeps the "0 means
        # leap" rule meaningful.
        leap = (leap + 1) and 3
  t[6]      = uint8(dow)
  t[7]      = uint8(day mod 10)
  t[8]      = uint8(day div 10)
  t[9]      = uint8(month mod 10)
  t[0x0A]   = uint8(month div 10)
  t[0x0B]   = uint8(year mod 10)
  t[0x0C]   = uint8(year div 10)
  cart.rtc_pages[1][0x0B] = uint8(leap)

proc tama5_seed_clock*(cart: Tama5) =
  ## Power-on state when there is no battery file. The TC8521AM runs off its own
  ## cell whether or not the Game Boy is on, so a cartridge always has *some*
  ## time in it; seeding from the host clock is the same choice HuC3 makes here,
  ## and spares the player setting a date the host already knows. UTC rather
  ## than local time so that the deterministic-RTC override gives both netplay
  ## peers the same answer.
  let now = utc(fromUnix(gb_rtc_now()))
  cart.rtc_pages[1][0x0A] = 1   # 24-hour mode, so the seeded hour reads plainly
  cart.tama5_set_hour24(now.hour)
  cart.tama5_set_minutes(now.minute)
  cart.rtc_pages[0][0] = uint8(now.second mod 10)
  cart.rtc_pages[0][1] = uint8(now.second div 10)
  cart.rtc_pages[0][6] = uint8(ord(now.weekday) mod 7)
  cart.rtc_pages[0][7] = uint8(now.monthday mod 10)
  cart.rtc_pages[0][8] = uint8(now.monthday div 10)
  cart.rtc_pages[0][9] = uint8(ord(now.month) mod 10)
  cart.rtc_pages[0][0x0A] = uint8(ord(now.month) div 10)
  cart.rtc_pages[0][0x0B] = uint8((now.year mod 100) mod 10)
  cart.rtc_pages[0][0x0C] = uint8((now.year mod 100) div 10)
  cart.rtc_pages[1][0x0B] = uint8(now.year mod 4)   # 0 = this year is a leap year
  cart.last_second = gb_rtc_now()

proc tama5_rtc_schedule*(cart: Tama5) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc tama5_rtc_tick*(cart: Tama5) =
  if gb_rtc_frozen(): return
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  # PAGE register bit 3 is TIMER ENABLE (endrift, post #1); with it clear the
  # counters stand still, which is the state a cartridge powers up in until the
  # game issues TAMA6 command 0x41.
  if (cart.page_reg and 0x08) != 0:
    cart.tama5_advance(1)
    cart.ram_dirty = true
  cart.last_second += 1

# Battery footer. Unlike HuC3's, this layout is not dingbat's own: FlashGBX (a
# cartridge reader/writer) and mGBA both write a TAMA5 .sav as 32 bytes of SRAM
# followed by four pages of sixteen nibbles packed low-nibble-first, then a
# 64-bit little-endian unix timestamp. No document specifies it — the clock
# lives in the TC8521AM, not in a file — but matching those two means a save can
# move between dingbat, mGBA and a real cartridge.
const TAMA5_FOOTER_LEN = 4 * 8 + 8

proc tama5_page_nibble(cart: Tama5; page, reg: int): uint8 =
  if reg <= 0x0C: cart.rtc_pages[page][reg]
  elif reg == 0x0D: cart.page_reg and 0x0F   # shared across pages; stored in each
  else: 0'u8                                 # E and F read back as zeros

proc tama5_footer(cart: Tama5): string =
  result = newStringOfCap(TAMA5_FOOTER_LEN)
  for p in 0 .. 3:
    for i in 0 .. 7:
      result.add(char(cart.tama5_page_nibble(p, i * 2) or
                      (cart.tama5_page_nibble(p, i * 2 + 1) shl 4)))
  let ts = uint64(cart.last_second)
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))

proc tama5_load_footer(cart: Tama5; data: string) =
  let base = cart.ram.len
  # Exact length only: FlashGBX and mGBA write exactly this and nothing more,
  # so a longer tail is padding, not a footer with extras.
  if data.len - base != TAMA5_FOOTER_LEN: return  # RAM-only save: keep the seeded clock
  for p in 0 .. 3:
    for i in 0 .. 7:
      let b = uint8(data[base + p * 8 + i])
      if i * 2 <= 0x0C: cart.rtc_pages[p][i * 2] = b and 0x0F
      if i * 2 + 1 <= 0x0C: cart.rtc_pages[p][i * 2 + 1] = b shr 4
      if i * 2 + 1 == 0x0D and p == 0: cart.page_reg = b shr 4
  var ts: int64 = 0
  for i in 0 .. 7: ts = ts or (int64(uint8(data[base + 32 + i])) shl (8 * i))
  let now = gb_rtc_now()
  # Saved in the future (or with no timestamp at all): treat the host as
  # authoritative and carry on from here, as the HuC3 loader does.
  if ts <= 0 or ts > now:
    cart.last_second = now
  else:
    cart.last_second = now
    if (cart.page_reg and 0x08) != 0: cart.tama5_advance(now - ts)

# MBC6's flash is as much a part of the save as its SRAM is — it is what the
# game downloaded — so it rides along in the same file. dingbat's own layout;
# no other emulator implements MBC6 at all.
const MBC6_FOOTER_LEN = 0x100000 + 0x100 + 1

proc mbc6_footer(cart: Mbc6): string =
  result = newStringOfCap(MBC6_FOOTER_LEN)
  for b in cart.flash: result.add(char(b))
  for b in cart.flash_hidden: result.add(char(b))
  result.add(char(if cart.flash_sector0_protected: 1 else: 0))

proc mbc6_load_footer(cart: Mbc6; data: string) =
  let base = cart.ram.len
  # Exact length only, same reasoning as the RTC footers: nobody else writes
  # an MBC6 footer at all, so any other tail length is not this layout.
  if data.len - base != MBC6_FOOTER_LEN: return  # RAM-only save: keep blank flash
  for i in 0 ..< cart.flash.len: cart.flash[i] = uint8(data[base + i])
  for i in 0 ..< cart.flash_hidden.len:
    cart.flash_hidden[i] = uint8(data[base + cart.flash.len + i])
  cart.flash_sector0_protected =
    data[base + cart.flash.len + cart.flash_hidden.len] != '\0'

proc mbc_save*(cart: Mbc) =
  if cart.ram_dirty and cart.has_battery and cart.sav_path.len > 0 and cart.ram.len > 0:
    try:
      var data = cast[string](cart.ram)
      if cart of Mbc3 and Mbc3(cart).has_rtc:
        data.add(rtc_footer(Mbc3(cart)))
      elif cart of Huc3:
        data.add(huc3_footer(Huc3(cart)))
      elif cart of Tama5:
        data.add(tama5_footer(Tama5(cart)))
      elif cart of Mbc6:
        data.add(mbc6_footer(Mbc6(cart)))
      writeFile(cart.sav_path, data)
      cart.ram_dirty = false
    except IOError, OSError:
      if not cart.save_error_reported:
        cart.save_error_reported = true
        echo "Failed to write save file: ", cart.sav_path

proc mbc_load*(cart: Mbc) =
  if cart.has_battery and cart.sav_path.len > 0 and fileExists(cart.sav_path):
    let data = readFile(cart.sav_path)
    for i in 0 ..< min(data.len, cart.ram.len):
      cart.ram[i] = uint8(data[i])
    if cart of Mbc3 and Mbc3(cart).has_rtc:
      rtc_load_footer(Mbc3(cart), data)
    elif cart of Huc3:
      huc3_load_footer(Huc3(cart), data)
    elif cart of Tama5:
      tama5_load_footer(Tama5(cart), data)
    elif cart of Mbc6:
      mbc6_load_footer(Mbc6(cart), data)

proc gb_mixer_latency*(gb: GB): int32 {.inline.} =
  ## Dots this machine's write to a PALETTE register arrives at the mixer after
  ## the DMG's. The one reader of `CGB_MIXER_LATENCY` outside its own
  ## declaration, so the compile-time constant stays the C-class QUANTITY and
  ## the revision decides only whether it is charged.
  ##
  ## Here rather than beside gb_quirks_for, its natural neighbour, because the
  ## PPU files are INCLUDED below and Nim needs the declaration first.
  if gb.cgb_enabled and not gb.quirks.mixer_write_immediate:
    int32(CGB_MIXER_LATENCY)
  else:
    0'i32

proc gb_lcdc_mixer_latency*(gb: GB): int32 {.inline.} =
  ## The same dot for LCDC, which the mixer also reads -- and which CGB-D does
  ## NOT drop. Not revision-gated, and mealybug's two CGB reference sets are
  ## why: run every ROM that ships both a `_cgb_c` and a `_cgb_d` capture and
  ## the two sets disagree on the palette rows and agree on the LCDC ones.
  ##
  ##   ROM                        _cgb_c vs _cgb_d
  ##   ------------------------   ----------------------------------
  ##   m3_bgp_change              differ  (864 px)   <- palette
  ##   m3_bgp_change_sprites      differ  (716 px)   <- palette
  ##   m3_obp0_change             differ  (42 px)    <- palette
  ##   m3_lcdc_bg_en_change       IDENTICAL          <- LCDC
  ##   m3_lcdc_obj_en_change      IDENTICAL          <- LCDC
  ##
  ## A reference pair that is identical on two devices is hardware saying the
  ## behaviour did not change between them, so gating LCDC on the revision
  ## would be inventing a difference the captures deny. Measured: gating it
  ## anyway takes `m3_lcdc_bg_en_change` 23040 -> 22637 and
  ## `m3_lcdc_obj_en_change` 23040 -> 22980 on BOTH references at once, which
  ## is the signature of moving a stage no reference wanted moved.
  ##
  ## This is also what `CGB_LCDC_MIXER_LATENCY` was declared for. It sat unread
  ## while both stages shared `CGB_MIXER_LATENCY` -- the two constants are both
  ## 1, so nothing showed -- and the C/D split is the first thing that tells
  ## them apart.
  if gb.cgb_enabled: int32(CGB_LCDC_MIXER_LATENCY) else: 0'i32

# ==================== INCLUDES ====================
# Textual includes, not imports: the whole GB core compiles as this one
# module (a single C translation unit), so the files below share one
# namespace and the C compiler inlines across them without LTO — see
# notes/architecture.md. Ordering is mostly freed by the forward
# declarations interleaved below; the one hard constraint is noted at the
# CPU group.

# Cartridge mappers: base methods + factory + the flat-ROM window fast path
# (mbc/mbc), then one file per mapper overriding them
include mbc/mbc
include mbc/rom
include mbc/mbc1
include mbc/mbc2
include mbc/mbc3
include mbc/mbc5
include mbc/mbc7
include mbc/huc1
include mbc/huc3
include mbc/mmm01
include mbc/mbc6
include mbc/camera
include mbc/tama5
# Audio: the four PSG channels, then the mixer
include apu/abstract_channels
include apu/channel1
include apu/channel2
include apu/channel3
include apu/channel4
include apu
# Peripherals: interrupt controller, link port, timer, input
proc gb_sync_cgb_native*(gb: GB) {.inline.} =
  ## Recompute GB.cgb_native. Three inputs: the console, the cart header, and
  ## whether the boot ROM is still mapped — so this belongs after construction,
  ## after the FF50 unmap, and after a state load.
  gb.cgb_native = gb.cgb_enabled and
    (gb.cgb_flag != cgbNone or (gb.memory != nil and gb.memory.bootrom.len > 0))
include interrupts
include serial
include timer
include sgb
include joypad
# Video: shared PPU base + the two interchangeable renderers
# Forward declarations needed by ppu.nim (defined in memory.nim included later).
# hot_bus_inline is defined here rather than in memory.nim because the forward
# declarations below must carry the same pragma as their implementations: on
# non-clang targets it expands to `inline`, and Nim rejects an implementation
# whose pragmas the forward declaration lacks (the clang codegenDecl form
# happens to slip through, which is why only the gcc/mingw CI builds broke).
# The rationale for the pragma itself lives with mem_tick_bus in memory.nim.
when defined(clang):
  {.pragma: hot_bus_inline,
    codegenDecl: "__attribute__((always_inline)) inline $# $#$#".}
else:
  {.pragma: hot_bus_inline, inline.}
proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.}
proc mem_tick_bus*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true) {.hot_bus_inline.}
proc mem_tick_ppu*(mem: GbMemory; gb: GB; cycles: int; ignore_speed = false) {.hot_bus_inline.}
proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int)
proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8
proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8)
include ppu
include scanline_ppu
include fifo_ppu
# Memory bus (mem_read/mem_write dispatch, DMA/HDMA, I/O registers)
include memory
# CPU decode/execute. One hard ordering constraint: cb_opcodes before
# opcodes — the 0xCB handler in opcodes.nim indexes the CB_PREFIXED const
# (built at compile time in cb_opcodes.nim), and a const cannot be
# forward-declared.
# Forward declarations needed by opcodes.nim (defined in cpu.nim included later)
proc cpu_memory_at_hl*(cpu: GbCpu; gb: GB): uint8
proc `cpu_memory_at_hl=`*(cpu: GbCpu; gb: GB; val: uint8)
proc cpu_inc_pc*(cpu: GbCpu)
proc cpu_halt*(cpu: GbCpu; gb: GB)
proc cpu_lock*(cpu: GbCpu)
include cb_opcodes
include opcodes
include cpu

# ==================== HARDWARE REVISION ====================

const GB_UNUSABLE_ZERO* = defined(gb_unusable_zero)
  ## Control arm: answer `$00` for `$FEA0..$FEFF` on every revision, the way
  ## dingbat did before the region was modelled at all.
  ##
  ## It exists because it is the arm that PROVES the revision axis is otherwise
  ## behaviour-neutral, and re-establishing that later is a two-run experiment.
  ## Measured 2026-08-10 on the full local runner: `-d:gb_unusable_zero` is
  ## byte-identical to the pre-revision tree (981 rows, 769 pass, gambatte
  ## 3850/5005, results.md identical but for its timestamp), and without it the
  ## only thing that moves anywhere is gambatte `oamdma` at 3850 -> 3876. So
  ## every row the revision work moved, the `$FEA0` model moved.

proc gb_quirks_for*(rev: GbRevision): GbQuirks =
  ## The whole revision -> behaviour table, in one place. A revision that names
  ## no flag here behaves exactly like the default machine; adding a revision
  ## therefore costs nothing until some test ROM proves it differs.
  GbQuirks(
    length_clock_any_nrx4: rev in {grCgb0, grCgbAB},
    mixer_write_immediate: rev in {grCgbD, grCgbE},
    scy_fetch_latch: rev in {grCgbD, grCgbE},
    unusable_region:
      if GB_UNUSABLE_ZERO: urZero
      else:
        case rev
        of grCgb0, grCgbAB, grCgbC: urRamMasked
        of grCgbD:                  urRamPlain
        of grCgbE, grAgb:           urNibbleEcho
        else:                       urZero,   # DMG / MGB / SGB / SGB2
  )

proc gb_boot_model_for*(rev: GbRevision): GbBootModel =
  ## Which boot-handoff table a revision uses. Many-to-one on purpose: mooneye
  ## ships one `boot_regs-` ROM per group of revisions that hand off the same
  ## registers, and this is that grouping.
  case rev
  of grDmg0:  bmDmg0
  of grDmgABC: bmDmgABC
  of grMgb:   bmMgb
  of grSgb:   bmSgb
  of grSgb2:  bmSgb2
  of grCgb0:  bmCgb0
  of grCgbAB, grCgbC, grCgbD, grCgbE: bmCgbABCDE
  of grAgb:   bmAgb

proc gb_set_revision*(gb: GB; rev: GbRevision) =
  ## The only way to change the machine's identity. Call before post_init:
  ## skip_boot reads boot_model, and the quirks are read from the first
  ## register write onward.
  gb.revision   = rev
  gb.boot_model = gb_boot_model_for(rev)
  gb.quirks     = gb_quirks_for(rev)

proc gb_revision_from_name*(name: string): (GbRevision, bool) =
  ## Parse a `--model=` / test-row token. Returns (revision, ok). Accepts the
  ## names the suites themselves use: mooneye's filename suffixes (`dmg0`,
  ## `mgb`, `S`, `A`, `cgb0`), AGE's device tokens and SameSuite's
  ## `-cgb0B` / `-cgbDE` style ranges. A range resolves to its HIGHEST member:
  ## the newest silicon that still shows the behaviour is the strongest claim
  ## the ROM makes, and it is what keeps a `-cgb0` / `-cgbB` pair (SameSuite
  ## ships both for CH3) resolving to two different revisions instead of
  ## collapsing onto grCgb0.
  case name.toLowerAscii()
  of "dmg0":                         (grDmg0, true)
  of "dmg", "dmga", "dmgb", "dmgc", "dmgabc", "dmgabcmgb": (grDmgABC, true)
  of "mgb":                          (grMgb, true)
  of "sgb", "s":                     (grSgb, true)
  of "sgb2":                         (grSgb2, true)
  of "cgb0":                         (grCgb0, true)
  of "cgb0b", "cgba", "cgbab", "cgbb": (grCgbAB, true)
  of "cgbc", "cgb0bc", "cgbbc":      (grCgbC, true)
  of "cgbd", "cgbcd":                (grCgbD, true)
  of "cgb", "cgbe", "cgbde", "cgbcde", "cgbabcde", "c": (grCgbE, true)
  of "agb", "ags", "a":              (grAgb, true)
  else:                              (grCgbE, false)

# ==================== NEW_GB + POST_INIT ====================

proc new_gb*(bootrom_path: string; rom_path: string; fifo: bool; headless: bool; run_bios: bool; force_cgb = false; force_dmg = false): GB =
  ## force_cgb runs a DMG-flagged cart in CGB mode (a DMG cart inserted in a
  ## Game Boy Color) — mooneye's misc/ tests assert that hardware's behavior.
  ## force_dmg is the other direction: run a CGB-flagged cart as a DMG. No
  ## real console does that, but gambatte's test suite selects the device from
  ## the *runner* (its `CGB_MODE` load flag), not the cart header, and most of
  ## its ROMs carry a CGB header while still shipping a `dmg08` expectation —
  ## so scoring the DMG half of that suite needs it (tests/dingbat_test.nim,
  ## --mode=gambatte). force_cgb wins if both are set.
  result = GB(
    bootrom_path: bootrom_path,
    rom_path:     rom_path,
    fifo:         fifo,
    headless:     headless,
    run_bios:     run_bios,
    sgb_requested: false,
  )
  result.cartridge = load_cartridge(rom_path)
  result.cheats = new_cheat_engine(cpGB)
  let cgb_byte = result.cartridge.rom[0x0143]
  result.cgb_flag = case cgb_byte
    of 0x80'u8: cgbSupport
    of 0xC0'u8: cgbExclusive
    else:       cgbNone
  # A boot ROM only implies CGB mode when it *is* a CGB boot ROM: the DMG one
  # is 256 bytes, the CGB one 0x900. Sizing it (rather than assuming CGB for
  # any boot ROM) lets a DMG boot ROM boot a DMG cart as a DMG.
  let cgb_bootrom = bootrom_path.len > 0 and run_bios and
                    fileExists(bootrom_path) and getFileSize(bootrom_path) > 0x100
  result.cgb_enabled = force_cgb or
    ((cgb_bootrom or result.cgb_flag != cgbNone) and not force_dmg)
  # Default revision, which fixes both the boot model and the quirk set. The
  # test harness may override this (via --model) before post_init to drive the
  # model-specific mooneye boot_regs/boot_div rows and SameSuite's
  # per-revision APU ROMs.
  #
  # CGB C and DMG ABC are not arbitrary: they are the revisions dingbat is
  # already scored against, and on the CGB side the tree now says so in three
  # places at once.
  #
  #  * The mealybug PPU references this tree scores are the `_cgb_c` set, and
  #    mealybug ships a `_cgb_d` set beside it that differs. `m3_bgp_change` is
  #    pixel-exact on `_cgb_c` at `CGB_MIXER_LATENCY = 1`, which is the value
  #    that ships -- so the pixel pipeline has been a C-class machine all
  #    along, and `quirks.mixer_write_immediate` is now where that is written
  #    down.
  #  * `cgb-acid-hell` picks its tile data off a `$FEA0` readback, dingbat is
  #    scored against the branch a C-class device takes, and
  #    `quirks.unusable_region` is now what takes it (see GbUnusableRegion).
  #  * docs/gb-derivations.md has said "every reference it is scored against is
  #    CPU CGB C" since before this axis existed.
  #
  # This default was `grCgbE` when the axis was introduced, on the strength of
  # SameSuite's `apu/README.md` ("CPU-CGB-E -- passes all tests"). That reading
  # does not survive contact with the pixel references above, and it never
  # bound anything: SameSuite's nine per-revision APU ROMs each carry their own
  # `--model=` token, so they never ran on the default in the first place. The
  # move from E to C changes no behaviour by itself -- both resolve to
  # `bmCgbABCDE` and to the same `length_clock_any_nrx4 = false` -- it only
  # stops the default from claiming to be a machine the tree does not model.
  # DMG: mooneye's `boot_regs-dmgABC` / `boot_div-dmgABCmgb` are green and
  # `stat_irq_blocking.s` reads "pass: DMG ABC, MGB, CGB, AGB, AGS / fail:
  # DMG 0".
  result.gb_set_revision(if result.cgb_enabled: grCgbC else: grDmgABC)
  result.rom_title = block:
    var s = ""
    for i in 0x0134 ..< 0x013F:
      let ch = result.cartridge.rom[i]
      if ch >= 0x20'u8 and ch <= 0x7E'u8: s.add(char(ch))
    s.strip()
  result.rom_size = 0x8000'u32 shl result.cartridge.rom[0x0148]
  result.ram_size = case result.cartridge.rom[0x0149]
    of 0x01: 0x0800
    of 0x02: 0x2000
    of 0x03: 0x2000 * 4
    of 0x04: 0x2000 * 16
    of 0x05: 0x2000 * 8
    else:    0

proc gb_skip_boot(gb: GB) =
  # IF reads 0xE1 at PC=0x100 on DMG and CGB (gambatte
  # display_startstate/irq): the boot ROM leaves a VBlank interrupt pending
  gb.interrupts.vblank_interrupt = true
  gb.cpu.skip_boot(gb)
  gb.memory.skip_boot(gb)
  gb.ppu.skip_boot(gb)
  gb.timer.skip_boot(gb)

proc handle_saves*(gb: GB) =
  ## Flush battery-backed cart RAM once per frame (when dirty) so progress
  ## isn't lost if the emulator exits without the game disabling cart RAM
  gb.scheduler.schedule_gb(70224, etSaves)
  gb.cartridge.mbc_save()

proc gb_dispatch(gb: GB): proc(kind: EventType) {.closure.} =
  # Non-owning capture: this closure is stored on the GB's scheduler, so an
  # owning capture would form a reference cycle back to the GB.
  let gb {.cursor.} = gb
  result = proc(kind: EventType) =
    case kind
    of etAPUFrameSeq:
      # Models the falling edge of the divider's APU tap. Free-running at the
      # tap's own period; a DIV write re-aims it (timer.nim).
      tick_frame_sequencer(gb.apu, gb)
      gb.scheduler.schedule(apu_div_period(gb), etAPUFrameSeq)
    of etAPUSample:    get_sample(gb.apu, gb)
    # The GB core no longer schedules per-waveform-period channel events --
    # each channel carries a next_step deadline advanced in closed form at the
    # points that can observe it (see gb/apu/channel1.nim). These arms stay
    # reachable only for a state saved by an older build, whose etAPUChannel*
    # events gb_apply_state drains into next_step before the first tick; if one
    # ever slips through, dropping it is strictly better than restarting a
    # 4-cycle event chain that nothing reads.
    of etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4: discard
    of etIME:
      # Stamp the cycle a delayed EI actually raises IME on, so the instruction
      # it lands inside can still see the IME it was fetched with (cpu_halt).
      # Only a false -> true transition is stamped: a second EI while IME is
      # already set changes nothing an instruction could observe.
      if not gb.cpu.ime:
        gb.cpu.ime = true
        gb.cpu.ime_set_cycle = gb.scheduler.cycles
    of etSaves:        gb.handle_saves()
    of etRtcSecond:
      if gb.cartridge of Mbc3: Mbc3(gb.cartridge).rtc_tick()
      elif gb.cartridge of Huc3: Huc3(gb.cartridge).huc3_rtc_tick()
      elif gb.cartridge of Tama5: Tama5(gb.cartridge).tama5_rtc_tick()
    of etCameraDone:
      if gb.cartridge of PocketCamera: PocketCamera(gb.cartridge).camera_done()
    else: discard

proc post_init*(gb: GB) =
  gb.scheduler  = new_scheduler()
  gb.interrupts = new_gb_interrupts()
  gb.apu        = new_gb_apu(gb, gb.headless)
  gb.joypad     = new_gb_joypad()
  if gb.fifo:
    let p = new_gb_fifo_ppu(gb)
    gb.ppu = p
    gb.fifo_ppu = p
  else:
    gb.ppu = new_gb_scanline_ppu(gb)
    gb.fifo_ppu = nil
  gb.timer  = new_gb_timer()
  gb.serial = new_gb_serial()
  gb.memory = new_gb_memory(gb)
  # Needs the memory: whether the boot ROM is mapped is one of its three inputs.
  gb_sync_cgb_native(gb)
  gb.cpu    = new_gb_cpu()
  # Super Game Boy. A cart that unlocks SGB functions and is NOT being run as
  # a CGB gets the adapter: the two are mutually exclusive on hardware (an SGB
  # has no CGB in it, and a CGB ignores the packet stream), so a CGB-flagged
  # cart that also carries the SGB flag runs as a CGB here, which is what
  # happens when you put one in a Game Boy Color.
  if gb.sgb_requested and not gb.cgb_enabled and sgb_unlocked(gb.cartridge.rom):
    gb.sgb = new_sgb_state()
    # The GB in an SGB reports itself through the boot handoff registers
    # (C = 0x14); a cart that probes for SGB that way has to see it.
    if gb.boot_model == bmDmgABC: gb.boot_model = bmSgb
    sgb_attach(gb)
  gb.scheduler.dispatch = gb_dispatch(gb)
  gb.cartridge.gb_ref = gb
  if gb.cartridge of Mbc3:
    let c = Mbc3(gb.cartridge)
    if c.has_rtc and not c.rtc_halted():
      c.rtc_schedule_full()
  elif gb.cartridge of Huc3:
    Huc3(gb.cartridge).huc3_rtc_schedule()
  elif gb.cartridge of Tama5:
    Tama5(gb.cartridge).tama5_rtc_schedule()
  gb.handle_saves()
  if gb.bootrom_path.len == 0 or not gb.run_bios:
    gb_skip_boot(gb)
  # Align the frame sequencer to the divider's phase. It models the falling
  # edge of DIV bit 4 (5 in double speed), so where it lands depends on tdiv,
  # which gb_skip_boot has just seeded per hardware model.
  gb.scheduler.clear(etAPUFrameSeq)
  gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)

proc apply_cheats*(gb: GB) =
  ## Push every enabled RAM-write cheat into memory. Run once per frame.
  if gb.cheats == nil or gb.cheats.cheats.len == 0: return
  if gb.cheat_hooks.read8 == nil:    # build the capturing closures once
    let mem = gb.memory
    let gb {.cursor.} = gb   # non-owning: the closures live on gb.cheat_hooks
    gb.cheat_hooks = MemHooks(
      read8: proc(a: uint32): uint8 =
        read_byte(mem, gb, int(a and 0xFFFF)),
      read16: proc(a: uint32): uint16 =
        uint16(read_byte(mem, gb, int(a and 0xFFFF))) or
        (uint16(read_byte(mem, gb, int((a + 1) and 0xFFFF))) shl 8),
      read32: proc(a: uint32): uint32 =
        var v = 0'u32
        for i in 0u32 ..< 4u32:
          v = v or (uint32(read_byte(mem, gb, int((a + i) and 0xFFFF))) shl (i * 8))
        v,
      write8: proc(a: uint32; v: uint8) =
        # A GameShark code's SRAM bank rides bits 16-23 (parse_gb_gameshark).
        # An external-RAM target writes THAT bank's storage directly: going
        # through the MBC would need the bank latch flipped mid-frame, which
        # the game would observe. The MBC's own modular bank math reproduces
        # the hardware masking (a $91 code lands in bank 1 on any cart).
        let idx = int(a and 0xFFFF)
        let cart = gb.cartridge
        if idx in 0xA000..0xBFFF and cart != nil and cart.ram.len > 0:
          cart.ram[mbc_ram_bank_offset(cart, int((a shr 16) and 0xFF)) +
                   mbc_ram_offset(cart, idx)] = v
          cart.ram_dirty = true
        else:
          write_byte(mem, gb, idx, v),
      write16: proc(a: uint32; v: uint16) =
        write_byte(mem, gb, int(a and 0xFFFF), uint8(v))
        write_byte(mem, gb, int((a + 1) and 0xFFFF), uint8(v shr 8)),
      write32: proc(a: uint32; v: uint32) =
        for i in 0u32 ..< 4u32:
          write_byte(mem, gb, int((a + i) and 0xFFFF), uint8(v shr (i * 8))),
    )
  gb.cheats.apply_ram(gb.cheat_hooks)
  # A poke into IF or LCDC/STAT/LYC leaves something deferred and is not a CPU
  # M-cycle, so nothing else would apply it (see mem_flush_deferred).
  mem_flush_deferred(gb.memory, gb)

proc refresh_cheat_rom_patches*(gb: GB) =
  ## Apply (or re-apply) Game Genie ROM edits. Call at load and whenever the
  ## cheat set changes.
  if gb.cheats != nil:
    gb.cheats.apply_rom(gb.cartridge.rom)

proc step_frame*(gb: GB) =
  gb.apply_cheats()
  while not gb.ppu.frame:
    gb.cpu.tick(gb)
  gb.ppu.frame = false
  if gb.sgb != nil: sgb_frame_end(gb)
  gb.gb_rebase()

method run_until_frame*(gb: GB) = gb.step_frame()

method handle_input*(gb: GB; inp: Input; pressed: bool) {.base.} =
  gb.joypad.handle_input(gb, inp, pressed)

method toggle_sync*(gb: GB) =
  gb.apu.toggle_sync()

# Save-state visitor over every component above (also serves rewind/rollback)
include savestate
