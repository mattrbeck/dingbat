## MP2K HLE pass detection and FIFO level control (src/dingbat/gba/mp2k.nim
## "Runtime detection", render_frame). No ROMs: a synthetic cartridge, a
## SoundInfo built in IWRAM, and the stores the driver makes, sent through
## the bus exactly as the CPU's would be. Each case is a rule the archive
## census or a sweep established; the comments name where.
## Run with: nimble test_mp2kpass
import std/os
import std/math
import dingbat/gba/gba
import dingbat/common/scheduler

var failures = 0

proc check(cond: bool; what: string) =
  if cond:
    echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

const
  SIP      = 0x03001000'u32         # SoundInfo, published at 0x03007FF0
  IDLE     = 0x68736D53'u32
  LOCK     = 0x68736D54'u32
  RING_A   = SIP + 0x350'u32        # pcmBuffer half A (FIFO A)
  RING_B   = SIP + 0x350'u32 + 1584'u32

proc make_emu(stereo = true): GBA =
  # Every word is ARM `b .`: the one check that steps a frame runs a
  # branch-to-self, and no other code touches the stores the test makes.
  let rom_path = getTempDir() / "dingbat_mp2kpass_loop.gba"
  if not fileExists(rom_path):
    var rom = newString(0x8000)
    for i in countup(0, rom.len - 4, 4):
      rom[i] = '\xFE'; rom[i + 1] = '\xFF'; rom[i + 2] = '\xFF'; rom[i + 3] = '\xEA'
    writeFile(rom_path, rom)
  result = new_gba("", rom_path, run_bios = false, use_hle = true)
  result.post_init()
  result.mp2k_hle = true
  let bus = result.bus
  bus.write_word_internal(0x03007FF0'u32, SIP)
  bus.write_word_internal(SIP, IDLE)
  bus.write_byte_internal(SIP + 0x06, 0)            # maxChans: no voices
  bus.write_byte_internal(SIP + 0x0B, 7)            # pcmDmaPeriod
  bus.write_half_internal(SIP + 0x10, 224)          # pcmSamplesPerVBlank
  bus.write_word_internal(SIP + 0x14, 13379)        # pcmFreq
  # The sound DMAs the driver programs: special timing, FIFO A (and B).
  for c in 1 .. 2:
    if c == 2 and not stereo: continue
    result.dma.dmacnt_h[c].enable = true
    result.dma.dmacnt_h[c].start_timing = 3
    result.dma.dmadad[c] = (if c == 1: 0x040000A0'u32 else: 0x040000A4'u32)
    result.dma.dmasad[c] = (if c == 1: RING_A else: RING_B)
    # the replay cursor a slot into the ring, so the latency estimate and the
    # FIFO target are a real frame's worth, as in a running game
    result.dma.src[c] = result.dma.dmasad[c] + 224'u32
  result.mp2k.mp2k_frame_poll()                     # opens the sound window

proc lock(emu: GBA) = emu.bus.write_word_internal(SIP, LOCK)
proc unlock(emu: GBA) = emu.bus.write_word_internal(SIP, IDLE)
proc ring_store(emu: GBA; off = 0'u32) = emu.bus.write_byte_internal(RING_A + off, 0)

proc pass(emu: GBA) =
  ## One SoundMain pass: lock, the sequencer's channel stores, the mixer's
  ## first ring store (the seed), the rest of the frame, unlock.
  emu.lock()
  emu.bus.write_byte_internal(SIP + 0x50 + 0x10, 0x3C)   # a sequencer store
  emu.ring_store()
  emu.ring_store(1)
  emu.unlock()

proc passes(emu: GBA): int = emu.mp2k.dbg_hook_fires

echo "window"
block:
  let emu = make_emu()
  check(emu.bus.snd_wbase == SIP and emu.bus.snd_wlen == 4,
        "between passes the window is the ident word")
  emu.lock()
  check(emu.bus.snd_wlen > 0x350'u32 + 1584'u32,
        "the lock opens it through the end of the rings")
  emu.ring_store()
  check(emu.bus.snd_wlen == 4, "the first ring store closes it again")
  emu.unlock()
  emu.mp2k_hle = false
  emu.step_frame()
  check(emu.bus.snd_wlen == 0, "turning the HLE off closes it")

echo "engaging"
block:
  let emu = make_emu()
  emu.pass()
  check(not emu.mp2k.engaged and emu.passes == 0,
        "one pass does not engage (initialisation clears the buffer once)")
  emu.pass()
  check(emu.mp2k.engaged and emu.passes == 1, "a second consecutive pass engages")
  emu.mp2k.mp2k_frame_poll()
  emu.pass()
  check(emu.passes == 2, "engaged, every pass counts")

echo "not passes"
block:
  let emu = make_emu()
  emu.pass()
  emu.lock()
  emu.unlock()
  emu.pass()
  check(not emu.mp2k.engaged,
        "a lock with no ring store (a song change) breaks the streak")
  emu.pass()
  check(emu.mp2k.engaged, "two uninterrupted passes after it engage")

block:
  let emu = make_emu()
  emu.ring_store()
  emu.ring_store()
  check(emu.mp2k.pass_streak == 0, "ring stores without the lock are not passes")

block:
  let emu = make_emu(stereo = false)
  # Beast Shooter: mono, the sequencer keeps scratch words in the unplayed half.
  emu.lock()
  emu.bus.write_word_internal(RING_B + 400, 0x12345678'u32)
  check(emu.mp2k.armed and emu.mp2k.pass_streak == 0,
        "a store into the half no DMA plays is not the mixer")
  emu.ring_store()
  check(emu.mp2k.pass_streak == 1, "the store into the played ring is")
  emu.unlock()

block:
  let emu = make_emu()
  emu.dma.dmasad[1] = 0x02010000'u32
  emu.dma.dmasad[2] = 0x02010630'u32
  emu.pass()
  emu.pass()
  check(not emu.mp2k.engaged,
        "a DMA playing from outside pcmBuffer (a game streaming around the engine) never engages")

block:
  let emu = make_emu()
  emu.pass()
  emu.pass()
  emu.lock()
  emu.mp2k.mp2k_state_loaded()
  emu.ring_store()
  check(emu.passes == 1, "a state loaded inside a pass does not run it")
  emu.mp2k.mp2k_frame_poll()
  check(emu.bus.snd_wlen == 4, "the next frame poll reopens the window")
  emu.unlock()
  emu.pass()
  check(emu.passes == 2, "the next locked pass runs")

proc set_counter(emu: GBA; cnt: int) =
  ## A V-blank: pcmDmaCounter steps, and the DMA's replay cursor keeps its
  ## place 100 bytes before the slot the pass fills, as it does in a game.
  emu.bus.write_byte_internal(SIP + 0x04, uint8(cnt))   # pcmDmaCounter
  let slot = (if cnt <= 1: 0 else: 7 - (cnt - 1)) mod 7
  let off = (slot * 224 - 100 + 7 * 224) mod (7 * 224)
  for c in 1 .. 2:
    if emu.dma.dmacnt_h[c].enable:
      emu.dma.src[c] = emu.dma.dmasad[c] + uint32(off)

proc level(emu: GBA): int = emu.mp2k.fifo_w - emu.mp2k.fifo_r

proc drain(emu: GBA) =
  ## What the APU would have played by the next pass: the FIFO back at its
  ## target (no APU runs in this test).
  emu.mp2k.fifo_r = emu.mp2k.fifo_w - emu.mp2k.fifo_target

proc engaged_emu(): GBA =
  ## Engaged, primed, and a few passes in so the FIFO target is steady.
  result = make_emu()
  # A measured latency, as four DMA crossings into a running game give
  # (no DMA runs here): the FIFO target is a frame and a bit.
  result.mp2k.lat_count = 4
  result.mp2k.lat_avg = 560
  for i in 0 ..< 6:
    result.set_counter(7 - (i mod 7))
    if result.mp2k.fifo_primed: result.drain()
    result.pass()
  result.drain()
  result.mp2k.mp2k_frame_poll()

echo "extra passes (mixer_pass)"
block:
  let emu = engaged_emu()
  let before = emu.level()
  emu.pass()                       # the counter did not move: the same slot again
  check(emu.mp2k.dbg_replaced == 1, "a pass that finds the counter unmoved is a replacement")
  check(abs(emu.level() - before) <= 1,
        "its frame takes the previous frame's place instead of adding one")
  emu.set_counter(3)
  emu.drain()
  let before2 = emu.level()
  emu.pass()
  check(emu.mp2k.dbg_replaced == 1 and emu.level() - before2 >= 540,
        "a pass after the counter moved adds a frame of its own (level " & $before2 & " -> " & $emu.level() & ")")

echo "level control (render_frame)"
block:
  let emu = engaged_emu()
  let m = emu.mp2k
  let target = m.fifo_target
  m.fifo_r = m.fifo_w - 2          # the FIFO ran dry: a V-blank with no pass
  emu.set_counter(1)                 # the counter moved: a new slot
  emu.pass()
  let filled = emu.level() - m.frame_n - 2
  check(filled > 0 and filled mod 548 == 0,
        "a jump of half a frame or more is filled in whole frames (Santa Claus Saves the Earth; filled " &
        $filled & ", target " & $target & ")")
  check(m.fifo_target == target, "the target did not move meanwhile")

block:
  let emu = engaged_emu()
  let m = emu.mp2k
  m.fifo_r = m.fifo_w - (m.fifo_target - 120)
  emu.set_counter(1)                 # the counter moved: a new slot
  emu.pass()
  check(emu.level() - m.frame_n == m.fifo_target,
        "a smaller jump is taken up exactly to the target (" & $(emu.level() - m.frame_n) & " vs " & $m.fifo_target & ")")

block:
  let emu = engaged_emu()
  let m = emu.mp2k
  m.lat_hw_ref = m.hw_latency() + 200
  emu.set_counter(1)                 # the counter moved: a new slot
  emu.pass()
  check(m.hw_latency() > 0 and m.lat_count == 0 and m.fifo_target == max(m.hw_latency(), 16),
        "a DMA re-timed by more than 96 samples restarts the latency measurements (Tarzan)")

echo "slot timing (slot_timing)"
proc advance(emu: GBA; n: int) =
  ## n output samples go by: both clocks move and the FIFO plays them.
  let m = emu.mp2k
  m.apu_clock += n
  emu.scheduler.cycles += CycleCount(n * APU_SAMPLE_PERIOD)
  m.fifo_r = min(m.fifo_r + n, m.fifo_w)

proc hear(emu: GBA) =
  ## The byte the newest watched pass stored first leaves the FIFO now.
  let dc = emu.apu.dma_channels
  var k = -1
  for i in 0 .. 3:
    if dc.watch_addr[i] != 0'u32 and dc.watch_clock[i] < 0 and
       (k < 0 or emu.mp2k.watch_pass_cyc[i] > emu.mp2k.watch_pass_cyc[k]): k = i
  doAssert k >= 0 and dc.watch_addr[k] == RING_A
  dc.watch_clock[k] = emu.mp2k.apu_clock
  dc.watch_cyc[k] = int64(emu.scheduler.cycles)

proc heard_emu(): GBA =
  ## Engaged, and one pass's slot heard 400 samples after the pass; the
  ## next pass comes a frame (548 samples) after that one, a slot later.
  result = engaged_emu()
  result.set_counter(3)
  result.drain()
  result.pass()
  result.advance(400)
  result.hear()
  result.advance(148)
  result.set_counter(2)

# 400 + the reconstruction's two DMA periods less half a sample + a frame
# (224 bytes at 13379 Hz) - the 548 samples since the pass
const PLACED = 400.0 + 2.0 * 548.625 / 224.0 - 0.5 + 224.0 * 32768.0 / 13379.0 - 548.0

block:
  let emu = heard_emu()
  let m = emu.mp2k
  m.fifo_r = m.fifo_w - (int(PLACED) + 40)
  emu.pass()
  check(m.dbg_steps == 1 and abs(float(emu.level() - m.frame_n) - PLACED) <= 1.0,
        "a frame 40 samples later than its slot plays is stepped there at once (placed " &
        $(emu.level() - m.frame_n) & ", slot " & $PLACED & ")")

block:
  let emu = heard_emu()
  let m = emu.mp2k
  m.fifo_r = m.fifo_w - (int(round(PLACED)) + 3)
  let before = emu.level()
  emu.pass()
  check(m.dbg_steps == 0 and emu.level() - m.frame_n == before,
        "one reading of a 3-sample error moves nothing (it is averaged first)")
  # The next passes, a frame apart, keep finding their frames 3 samples late
  # against the same slot heard (k frames after it).
  var trims = 0
  for k in 2 .. 7:
    emu.advance(548)
    emu.set_counter(3 - k + (if 3 - k < 1: 7 else: 0))
    let slot_at = PLACED + float(k - 1) * (224.0 * 32768.0 / 13379.0 - 548.0)
    let want = int(round(slot_at)) + 3
    m.fifo_r = m.fifo_w - want
    emu.pass()
    if emu.level() - m.frame_n == want - 1: inc trims
  check(m.dbg_steps == 0 and trims >= 3,
        "a persisting one is trimmed a sample a frame once the average passes 0.6 (" & $trims & " of 6 frames)")

block:
  let emu = heard_emu()
  let m = emu.mp2k
  m.fifo_r = m.fifo_w - (int(PLACED) + 300)
  emu.pass()
  check(m.dbg_steps == 0, "an error of half a frame or more is not stepped on one pass's word")
  emu.advance(548)
  emu.set_counter(1)
  m.fifo_r = m.fifo_w - (int(PLACED) + 300)
  emu.pass()
  check(m.dbg_steps == 1 and abs(float(emu.level() - m.frame_n) - PLACED) <= 1.0,
        "the next pass seeing it too steps it")

block:
  let emu = engaged_emu()
  let m = emu.mp2k
  emu.set_counter(3)
  emu.drain()
  emu.pass()
  m.apu_clock += 400                 # the output clock ran, the scheduler did not:
  emu.hear()                         # heard across a pause in substitution
  emu.advance(148)
  emu.set_counter(2)
  m.fifo_r = m.fifo_w - (int(PLACED) + 40)
  emu.pass()
  check(m.dbg_steps == 0 and not m.meas_valid, "a slot heard across a pause in the output clock is ignored")

block:
  let emu = heard_emu()
  let m = emu.mp2k
  emu.lock()
  m.mp2k_state_loaded()
  emu.unlock()
  check(not m.meas_valid and emu.apu.dma_channels.watch_addr == [0'u32, 0, 0, 0],
        "a state load forgets the slots heard and watched")

echo "summary: ",(if failures == 0: "all checks passed" else: $failures & " check(s) FAILED")
if failures > 0: quit(1)
