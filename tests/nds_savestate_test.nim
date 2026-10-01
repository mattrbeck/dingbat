## DS save states (src/dingbat/nds/savestate.nim): a state taken at an
## awkward moment -- mid-frame, with a DMA channel running, GX FIFO entries
## queued, a card transfer in flight, sound channels playing -- loaded into a
## fresh machine runs on to the same screens and sound as the machine it was
## taken from, and saving it again gives the same bytes. Plus the refusals:
## another game, damage, another layout, another BIOS.
##
## Test ROMs come from ${DINGBAT_NDS_ROMS:-~/.cache/dingbat-nds/roms}
## (tests/nds/README.md); BIOS dumps from $DINGBAT_NDS_BIOS when set (the HLE
## BIOS otherwise).
##
## Run with: nimble test_ndssavestate

import std/[os, strutils, monotimes, times]
import dingbat/nds/[nds, savestate]
import dingbat/nds/io/dma
import dingbat/nds/gpu3d/gpu3d
import dingbat/common/serialize

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

let rom_dir = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms")
let bios_dir = getEnv("DINGBAT_NDS_BIOS")

proc machine(rom: string; force_hle = false): NDS =
  let b = if bios_dir.len > 0: bios_dir else: ""
  proc file(p: string): seq[uint8] =
    if p.len == 0 or not fileExists(p): @[] else: cast[seq[uint8]](readFile(p))
  new_nds(file(rom), file(b / "bios9.bin"), file(b / "bios7.bin"),
          file(b / "firmware.bin"), force_hle = force_hle)

proc run_hash(n: NDS; frames: int): uint32 =
  ## Both screens after every frame and all the sound, hashed together.
  result = 0x811C9DC5'u32
  for _ in 0 ..< frames:
    n.run_frame()
    result = fnv1a_more(result, cast[ptr array[256 * 192 * 2, byte]](addr n.gpu.top[0])[])
    result = fnv1a_more(result, cast[ptr array[256 * 192 * 2, byte]](addr n.gpu.bottom[0])[])
    let s = n.spu.take_samples()
    if s.len > 0:
      result = fnv1a_more(result, toOpenArray(cast[ptr UncheckedArray[byte]](unsafeAddr s[0]),
                                              0, s.len * 4 - 1))

proc step_until(n: NDS; cond: proc (n: NDS): bool; limit_frames = 600): bool =
  ## Run in 64-cycle slices until `cond` holds between two of them.
  let limit = n.sched.now + int64(limit_frames) * FRAME_CYCLES
  while n.sched.now < limit:
    if cond(n): return true
    n.run_until(n.sched.now + 61)   # odd steps: land anywhere in a slice
  false

type Case = object
  name, rom: string
  frames: int                       ## whole frames before the awkward part
  moment: string                    ## what the state catches
  cond: proc (n: NDS): bool         ## step until this holds (nil: mid-frame)
  setup: proc (n: NDS)              ## pokes the machine first (nil: none)

proc gx_dma_setup(n: NDS) =
  ## A geometry-FIFO DMA (mode 7) of 1000 words behind a pending
  ## SWAP_BUFFERS: the FIFO fills past half and the channel stops
  ## mid-block until the V-blank swap drains it.
  let bus = Arm9Bus(nds: n)
  for i in 0'u32 ..< 1000: bus.write32(0x0220_0000'u32 + 4 * i, 0x1515_1515'u32)  # MTX_IDENTITY x4
  bus.write32(0x0400_0540'u32, 0)                       # SWAP_BUFFERS
  bus.write32(0x0400_00D4'u32, 0x0220_0000'u32)         # DMA3 source
  bus.write32(0x0400_00D8'u32, 0x0400_0400'u32)         # GXFIFO
  bus.write32(0x0400_00DC'u32, 0xBC40_0000'u32 or 1000) # on, GX mode, 32-bit, fixed dest
  n.run_until(n.sched.now + 100_003)

proc dma_running(n: NDS): bool =
  for d in [n.dma9, n.dma7]:
    for c in d.ch:
      if c.enabled and c.cur_count > 0 and d.timing(0) != dtNone: return true

proc gx_queued(n: NDS): bool =
  let st = n.gpu3d.read_reg(0x600'u32)
  ((st shr 16) and 0x1FF) > 0 or (st and (1'u32 shl 27)) != 0 and n.gpu3d.swap_pending

proc card_busy(n: NDS): bool = (n.cart.romctrl and 0x8000_0000'u32) != 0

proc sound_playing(n: NDS): bool =
  var k = 0
  for c in n.spu.ch:
    if c.active: inc k
  k >= 2

proc round_trip(c: Case) =
  let path = rom_dir / c.rom
  echo c.name, " (", c.moment, ")"
  if not fileExists(path):
    check(false, "missing " & path)
    return
  let a = machine(path)
  for _ in 0 ..< c.frames: a.run_frame()
  if c.setup != nil: c.setup(a)
  if c.cond == nil:
    a.run_until(a.sched.now + 517_331)          # part-way down the screen
  elif not a.step_until(c.cond):
    check(false, c.name & ": never reached " & c.moment)
    return
  let t0 = getMonoTime()
  let image = a.state_bytes()
  let t_save = (getMonoTime() - t0).inMicroseconds
  a.spu.clear_samples()
  let want = a.run_hash(90)

  let b = machine(path)
  b.run_frame()                                  # a machine with a past of its own
  let t1 = getMonoTime()
  let ok = b.load_state_bytes(image)
  let t_load = (getMonoTime() - t1).inMicroseconds
  check(ok, c.name & ": loads into a fresh machine", last_state_error)
  if not ok: return
  check(b.state_bytes() == image, c.name & ": save -> load -> save gives the same bytes")
  let got = b.run_hash(90)
  check(got == want, c.name & ": 90 frames on, screens and sound match the original",
        toHex(got) & " vs " & toHex(want))
  check(b.state_payload() == a.state_payload(),
        c.name & ": and so does every saved field of the two machines")

  let packed = pack_state(image)
  let p = machine(path)
  check(p.load_state_bytes(packed) and p.run_hash(90) == want,
        c.name & ": the packed state does the same")
  echo "    state ", image.len, " bytes, packed ", packed.len, "; save ", t_save,
       " us, load ", t_load, " us"

proc refusals() =
  echo "refusals"
  let path = rom_dir / "3d" / "3d_sort.nds"
  let other = rom_dir / "3d" / "3d_fog.nds"
  if not fileExists(path) or not fileExists(other):
    check(false, "missing " & path & " / " & other)
    return
  let a = machine(path)
  for _ in 0 ..< 20: a.run_frame()
  let image = a.state_bytes(thumbnail = true)
  let before = a.state_payload()
  check(parse_state_thumbnail(image).w == THUMB_W and
        parse_state_thumbnail(image).h == THUMB_H, "the thumbnail trailer reads back")
  check(a.state_is_for(image) and a.state_is_for(pack_state(image)), "names its game")

  let o = machine(other)
  check(not o.state_is_for(image), "another game's machine does not claim it")
  check(not o.load_state_bytes(image) and last_state_reject_kind == srkWrongRom,
        "another game refuses it (srkWrongRom)", last_state_error)

  var damaged = image
  damaged[STATE_HEADER_SIZE + 4000] = char(uint8(damaged[STATE_HEADER_SIZE + 4000]) xor 0x5A)
  check(not a.load_state_bytes(damaged) and last_state_reject_kind == srkCorrupt and
        a.state_payload() == before, "a damaged payload is refused, machine untouched")
  check(not a.load_state_bytes(image[0 ..< image.len div 3]) and
        last_state_reject_kind == srkTruncated and a.state_payload() == before,
        "a cut-off state is refused (srkTruncated)")
  check(not a.load_state_bytes("not a state") and last_state_reject_kind == srkNotAState,
        "garbage is not a state")

  # the payload's preamble: magic, layout hash, BIOS kind, BIOS hashes
  proc remade(payload: string): string =
    make_state_bytes(ckNDS, rom_identity(a.cart.rom), uint32(a.cart.rom.len), payload)
  var other_layout = before
  other_layout[4] = char(uint8(other_layout[4]) xor 1)
  check(not a.load_state_bytes(remade(other_layout)) and
        last_state_reject_kind == srkIncompatible and a.state_payload() == before,
        "another build's layout is refused (srkIncompatible)", last_state_error)
  var other_bios = before
  other_bios[12] = char(uint8(other_bios[12]) xor 1)
  check(not a.load_state_bytes(remade(other_bios)) and
        last_state_reject_kind == srkIncompatible and a.state_payload() == before,
        "another BIOS's state is refused (srkIncompatible)", last_state_error)
  var bad_field = before
  # first byte of the scheduler section after its marker: an event count
  # past any machine's
  let sched_at = before.find(char(2), 20)
  discard sched_at
  var wrong_end = before
  wrong_end[^1] = char(0x7E)
  check(not a.load_state_bytes(remade(wrong_end)) and a.state_payload() == before,
        "a section marker out of place is refused, machine untouched", last_state_error)
  discard bad_field
  if not a.hle_bios9:
    # with dumps: the HLE BIOS's state does not load on the real BIOS (a
    # CPU caught inside one BIOS's IRQ or SWI code would resume in the
    # other's), nor the reverse
    let h = machine(path, force_hle = true)
    for _ in 0 ..< 20: h.run_frame()
    check(not a.load_state_bytes(h.state_bytes()) and
          last_state_reject_kind == srkIncompatible and a.state_payload() == before,
          "an HLE-BIOS state is refused on the real BIOS (srkIncompatible)", last_state_error)
    check(not h.load_state_bytes(image) and last_state_reject_kind == srkIncompatible,
          "and a real-BIOS state on the HLE BIOS", last_state_error)
  check(a.load_state_bytes(image) and a.state_payload() == before, "and the good one loads")

when isMainModule:
  let cases = [
    Case(name: "3d_sort", rom: "3d/3d_sort.nds", frames: 10, moment: "mid-frame"),
    Case(name: "3d_timing_fifo", rom: "3d/3d_timing_fifo.nds", frames: 2,
         moment: "GX FIFO entries queued", cond: gx_queued),
    Case(name: "fb_both + GX DMA", rom: "fb_both.nds", frames: 5,
         moment: "a GX FIFO DMA stopped mid-block", setup: gx_dma_setup,
         cond: dma_running),
    Case(name: "snd_suite", rom: "snd_suite.nds", frames: 30,
         moment: "sound channels playing, mid-frame", cond: sound_playing),
    Case(name: "cardread", rom: "built/cardread.nds", frames: 0,
         moment: "a card transfer in flight", cond: card_busy),
    Case(name: "Simple_Quad", rom: "built/Simple_Quad.nds", frames: 25, moment: "mid-frame"),
    Case(name: "2Dplus3D", rom: "homebrew-ex/2Dplus3D.nds", frames: 40, moment: "mid-frame"),
  ]
  for c in cases: round_trip(c)
  refusals()
  if failures > 0:
    echo failures, " check(s) failed"
    quit(1)
  echo "all DS save-state checks passed"
