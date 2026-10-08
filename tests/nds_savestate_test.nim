## DS save states (src/dingbat/nds/savestate.nim): a state taken at an
## awkward moment -- mid-frame, with a DMA channel running, GX FIFO entries
## queued, a card transfer in flight, sound channels playing -- loaded into a
## fresh machine runs on to the same screens and sound as the machine it was
## taken from, and saving it again gives the same bytes. Plus the refusals:
## another game, damage, another layout, another BIOS, and hostile values in
## the fields the core indexes or runs its clocks by.
##
## Test ROMs come from ${DINGBAT_NDS_ROMS:-~/.cache/dingbat-nds/roms}
## (tests/nds/README.md); BIOS dumps from $DINGBAT_NDS_BIOS when set (the HLE
## BIOS otherwise).
##
## Run with: nimble test_ndssavestate

import std/[os, strutils, monotimes, times]
import dingbat/nds/[nds, savestate]
import std/importutils
import dingbat/nds/air
import dingbat/nds/io/[dma, rtc, cart, slot2, wifi]
import dingbat/gba/rtc_calendar
import dingbat/nds/gpu3d/[gpu3d, geometry]
import dingbat/nds/[sched, timing]
import dingbat/gba/storage_chip
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

proc file(p: string): seq[uint8] =
  if p.len == 0 or not fileExists(p): @[] else: cast[seq[uint8]](readFile(p))

proc machine(rom: string; force_hle = false; boot = nbDirect;
             firmware: seq[uint8] = @[]): NDS =
  let b = if bios_dir.len > 0: bios_dir else: ""
  let fw = if firmware.len > 0: firmware else: file(b / "firmware.bin")
  result = new_nds(file(rom), file(b / "bios9.bin"), file(b / "bios7.bin"), fw,
                   force_hle = force_hle, boot = boot)
  # the RTC on emulated time (as ndsrun --rtc): on the host clock two runs
  # read different times, and the clock's last-update time is saved
  result.rtc.set_fixed_clock(result.sched, to_calendar_seconds(2004, 1, 1, 0, 0, 0))

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
  prep: proc (n: NDS)               ## supplies both machines (a slot-2 cart...)
  boot: NdsBoot                     ## nbFirmware: needs the dumps

proc gx_dma_setup(n: NDS) =
  ## A geometry-FIFO DMA (mode 7) of 1000 words behind a pending
  ## SWAP_BUFFERS: the FIFO fills past half and the channel stops
  ## mid-block until the V-blank swap drains it.
  let bus = Arm9Bus(nds: n)
  bus.write32(0x0400_0304'u32, 0x820F)                  # fb_both powers 2D only
  for i in 0'u32 ..< 1000: bus.write32(0x0220_0000'u32 + 4 * i, 0x1515_1515'u32)  # MTX_IDENTITY x4
  bus.write32(0x0400_0540'u32, 0)                       # SWAP_BUFFERS
  bus.write32(0x0400_00D4'u32, 0x0220_0000'u32)         # DMA3 source
  bus.write32(0x0400_00D8'u32, 0x0400_0400'u32)         # GXFIFO
  bus.write32(0x0400_00DC'u32, 0xBC40_0000'u32 or 1000) # on, GX mode, 32-bit, fixed dest
  n.run_until(n.sched.now + 100_003)

proc dma_running(n: NDS): bool =
  for d in [n.dma9, n.dma7]:
    for i in 0 .. 3:
      if d.ch[i].enabled and d.ch[i].cur_count > 0 and d.timing(i) != dtImmediate:
        return true

proc gx_queued(n: NDS): bool =
  let st = n.gpu3d.read_reg(0x600'u32)
  ((st shr 16) and 0x1FF) > 0 or (st and (1'u32 shl 27)) != 0 and n.gpu3d.swap_pending

proc card_busy(n: NDS): bool = (n.cart.romctrl and 0x8000_0000'u32) != 0

proc sound_playing(n: NDS): bool =
  var k = 0
  for c in n.spu.ch:
    if c.active: inc k
  k >= 2

proc key1_transfer(n: NDS): bool =
  ## The BIOS talking to the card in KEY1 mode, a command in flight.
  n.cart.mode == cmKey1 and card_busy(n)

proc gba_cart(): seq[uint8] =
  ## A synthetic 1 MB GBA cart with a FLASH 128K save (its ID string).
  result = newSeq[uint8](0x10_0000)
  for i in 0 ..< result.len: result[i] = uint8((i * 7 + (i shr 8)) and 0xFF)
  for i, ch in "TEST": result[0xAC + i] = uint8(ch)
  for i, ch in "FLASH1M_V103": result[0x1000 + i] = uint8(ch)

proc mic_setup(n: NDS) =
  var tone = newSeq[int16](8000)
  for i in 0 ..< tone.len: tone[i] = int16(((i * 37) mod 2000) - 1000)
  n.push_mic(tone, 16000)

proc sleep_setup(n: NDS) =
  n.sleeping = true          # ARM7 HALTCNT sleep: only the RTC runs

proc round_trip(c: Case) =
  let path = rom_dir / c.rom
  echo c.name, " (", c.moment, ")"
  if not fileExists(path):
    check(false, "missing " & path)
    return
  if c.boot == nbFirmware and bios_dir.len == 0:
    echo "  (no BIOS/firmware dumps: skipped)"
    return
  proc machine(path: string): NDS =
    result = machine(path, boot = c.boot)
    if c.prep != nil: c.prep(result)
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

proc wifi_pair() =
  ## Two machines on one Air with the wifi_link ROM, saved while frames are
  ## in flight; the pair rebuilt from the two states and linked again runs on
  ## as the original pair did. (The Air holds no frames of its own: each
  ## machine's transmitter and receiver keep theirs, in its state.)
  echo "wifi_link pair (frames in flight between two machines)"
  let path = rom_dir / "wifi_link.nds"
  if not fileExists(path):
    check(false, "missing " & path)
    return
  var fw = file(if bios_dir.len > 0: bios_dir / "firmware.bin" else: "")
  if fw.len == 0: fw = synth_firmware()
  var mac2: array[6, uint8]
  for i in 0..5: mac2[i] = fw[0x36 + i]
  mac2[5] = mac2[5] xor 0x5A
  let fw2 = firmware_with_mac(fw, mac2)
  let host = machine(path, firmware = fw)
  let client = machine(path, firmware = fw2)
  host.set_button(nbA, true)
  let link = new_air_link(@[host, client])
  link.run_frames(10)
  host.set_button(nbA, false)
  var steps = 0
  privateAccess(Wifi)
  while steps < 600 * 300 and host.wifi.tx_frame == nil and client.wifi.rx.len == 0:
    link.step(1001)
    inc steps
  check(host.wifi.tx_frame != nil or client.wifi.rx.len > 0, "a frame is in flight")
  let sh = host.state_bytes()
  let sc = client.state_bytes()
  link.run_frames(120)
  let h2 = machine(path, firmware = fw)
  let c2 = machine(path, firmware = fw2)
  check(h2.load_state_bytes(sh) and c2.load_state_bytes(sc), "both states load", last_state_error)
  let link2 = new_air_link(@[h2, c2])
  link2.run_frames(120)
  check(h2.state_payload() == host.state_payload() and
        c2.state_payload() == client.state_payload(),
        "120 frames on, both machines match the original pair in every saved field")

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
  let g = machine(path)
  g.insert_slot2(s2GbaCart, gba_cart())
  check(not a.load_state_bytes(g.state_bytes()) and last_state_reject_kind == srkIncompatible and
        a.state_payload() == before,
        "a state with a GBA cart in the slot is refused by a machine without it", last_state_error)
  check(a.load_state_bytes(image) and a.state_payload() == before, "and the good one loads")

proc hostile_fields() =
  ## A file is outside input: the payload hash is an integrity check, so a
  ## state can say anything. Every field the core later indexes, shifts or
  ## divides with, or runs its clocks by, is refused at load, never handed
  ## on, because the core is quirky (nds/quirky.nim): past a failed check it
  ## goes on, and a wild index is a SIGSEGV, not an IndexDefect. Each value
  ## is written by the real saver from a machine holding it, then offered to
  ## another one, which has to refuse it and stay as it was.
  ## tools/statefuzz.nim finds these; each is one it found, or the audit
  ## that followed.
  echo "hostile fields: a state's indexes and clocks are checked at load"
  let path = rom_dir / "fb_both.nds"
  let path3d = rom_dir / "3d" / "3d_texfmt.nds"
  if not fileExists(path) or not fileExists(path3d):
    check(false, "missing " & path & " / " & path3d)
    return
  privateAccess(NdsScheduler)
  privateAccess(TagCache)
  privateAccess(Geometry)
  proc offer(what: string; poke: proc (n: NDS); rom = path; prep: proc (n: NDS) = nil) =
    proc made(): NDS =
      result = machine(rom)
      if prep != nil: prep(result)
      for _ in 0 ..< 30: result.run_frame()
    let src = made()
    poke(src)
    let img = src.state_bytes()
    let dst = made()
    let before = dst.state_payload()
    check(not dst.load_state_bytes(img) and dst.state_payload() == before,
          what & " is refused, machine untouched", last_state_error)
  offer("an ARM9 clock far behind the master clock",
        proc (n: NDS) = n.arm9.cycles -= 1'i64 shl 56)
  offer("an ARM7 clock far ahead of it",
        proc (n: NDS) = n.arm7.cycles += 1'i64 shl 50)
  offer("a master clock past 2^55 cycles",
        proc (n: NDS) =
          n.sched.now += 1'i64 shl 56
          n.arm9.cycles += 1'i64 shl 56
          n.arm7.cycles += 1'i64 shl 56)
  offer("an event booked a second in the past",
        proc (n: NDS) = n.sched.schedule(n.sched.now - MASTER_HZ, evRtc))
  offer("the sound mixer's tick far in the past",
        proc (n: NDS) = n.spu.next_tick -= 1'i64 shl 56)
  offer("a line that began a second ago",
        proc (n: NDS) = n.line_start -= MASTER_HZ)
  offer("an ARM7 instruction that turns its clock back",
        proc (n: NDS) = n.arm7.base_cycles = -1)
  offer("a timer unit booking another unit's events",
        proc (n: NDS) = n.timers9.first_event = evRtc)
  offer("a data-cache line past main RAM",
        proc (n: NDS) = n.tm.dline[5].line1 = 0x0040_0000)
  offer("a data-cache line outside its set",
        proc (n: NDS) = n.tm.dline[5].line1 = 1)
  offer("a main RAM line in two data-cache slots",
        proc (n: NDS) =
          n.tm.dline[4].line1 = 2
          n.tm.dline[5].line1 = 2)
  offer("an empty data-cache slot holding a dirty line",
        proc (n: NDS) =
          n.tm.dline[5].line1 = 0
          n.tm.dline[5].dirty = true)
  offer("a cache round-robin pointer past its set",
        proc (n: NDS) = n.tm.icache.rr[3] = 7)
  offer("a cache victim past the cache",
        proc (n: NDS) = n.tm.dcache.victim = 4096)
  offer("a polygon past the end of its vertices",
        proc (n: NDS) = n.gpu3d.polys.add(Polygon(first: int32(n.gpu3d.verts.len), count: 3)),
        path3d)
  offer("a 3D frame drawn to line -16777216",
        proc (n: NDS) = n.gpu3d.done_lines = -16777216, path3d)
  offer("an ARM7 instruction with 2^62 internal cycles to charge",
        proc (n: NDS) = n.arm7.icycles = 1'i64 shl 62)
  offer("a sound channel 2^32 - 84 words long",
        proc (n: NDS) = n.spu.ch[3].len = 0xFFFF_FFAC'u32)
  offer("a sound channel that has read 2^31 words ahead",
        proc (n: NDS) = n.spu.ch[3].fetched = high(int32))
  offer("a DMA block of 2^32 - 1 words",
        proc (n: NDS) = n.dma9.ch[1].cur_count = 0xFFFF_FFFF'u32)
  offer("a viewport 2^31 dots wide",
        proc (n: NDS) = n.gpu3d.geo.vp_x2 = high(int32), path3d)
  offer("a second FLASH bank on a 64 KB GBA-slot FLASH",
        proc (n: NDS) =
          privateAccess(Slot2)
          n.slot2.save_type = stFLASH
          n.slot2.save.setLen(0x10000)
          n.slot2.flash_bank = 1,
        rom_dir / "slot2_probe.nds",
        proc (n: NDS) = n.insert_slot2(s2GbaCart, gba_cart()))

  # `next` (the earliest booking) is rebuilt, not trusted: one later than
  # the first event would stop the clock there for good
  let a = machine(path)
  for _ in 0 ..< 30: a.run_frame()
  let want = a.state_payload()
  a.sched.next = high(int64)
  let img = a.state_bytes()
  let b = machine(path)
  check(b.load_state_bytes(img) and b.state_payload() == want,
        "a state's stale earliest booking is put right at load", last_state_error)
  let f = b.gpu.frame_count
  b.run_frame()
  check(b.gpu.frame_count == f + 1, "and the machine runs on")

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
    Case(name: "slot2_probe + GBA cart", rom: "slot2_probe.nds", frames: 3,
         moment: "mid-frame, a GBA cart with FLASH in the slot",
         prep: proc (n: NDS) = n.insert_slot2(s2GbaCart, gba_cart())),
    Case(name: "slot2_probe + Expansion Pak", rom: "slot2_probe.nds", frames: 3,
         moment: "mid-frame, 8 MB of pak RAM",
         prep: proc (n: NDS) = n.insert_slot2(s2ExpansionPak)),
    Case(name: "periph_suite + mic", rom: "periph_suite.nds", frames: 20,
         moment: "microphone samples queued, mid-frame", setup: mic_setup),
    Case(name: "fb_both asleep", rom: "fb_both.nds", frames: 5,
         moment: "the ARM7 in sleep mode", setup: sleep_setup),
    Case(name: "firmware boot", rom: "built/hello_world.nds", frames: 0,
         moment: "the BIOS's KEY1 card handshake in flight", cond: key1_transfer,
         boot: nbFirmware),
  ]
  for c in cases: round_trip(c)
  wifi_pair()
  refusals()
  hostile_fields()
  if failures > 0:
    echo failures, " check(s) failed"
    quit(1)
  echo "all DS save-state checks passed"
