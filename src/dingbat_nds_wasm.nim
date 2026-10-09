## WASM entry for the DS core: the main web app (web/index.js, lazy-loads
## web/nds/nds.js when a .nds game starts) and the standalone dev page
## (web/nds.html). Separate from dingbat_wasm.nim while the DS core is a
## prototype. Built MODULARIZE'd (createNdsCore) so its Module never meets
## em.js's global one. Build: nim c -d:emscripten src/dingbat_nds_wasm.nim
##
## Loading a game: nds_rom_alloc(len) returns a buffer inside the core, the
## page writes the ROM there once, then nds_boot(...) builds the core on it
## (moved, not copied: a 128 MB ROM must not exist twice in the heap).

import dingbat/nds/[nds, savestate, cheats, rewinding]
import dingbat/common/rewind
from std/strutils import toHex

var core: NDS
var romBuf: seq[uint8]
var fbTop, fbBottom: seq[uint32]
var status: string
var stateImage: string     # the last nds_state_size() result

proc copy_in(p: pointer; len: cint): seq[uint8] =
  result = newSeq[uint8](int(len))
  if len > 0: copyMem(addr result[0], p, int(len))

proc nds_rom_alloc(len: cint): pointer {.exportc.} =
  ## The ROM's buffer, `len` bytes, for the page to fill before nds_boot.
  ## Drops the running core first: it holds the previous ROM.
  core = nil
  romBuf = newSeqUninit[uint8](int(len))
  if len > 0: addr romBuf[0] else: nil

var lastBios9, lastBios7, lastFirmware: seq[uint8]  ## what nds_reboot reuses

proc rewind_reset()
proc cheats_follow_game()

proc boot_with(rom: sink seq[uint8]; save: pointer; save_len: cint) =
  core = new_nds(rom, lastBios9, lastBios7, lastFirmware)
  if save_len > 0: core.cart.backup.set_data(copy_in(save, save_len))
  rewind_reset()
  cheats_follow_game()

proc nds_boot(b9: pointer; b9_len: cint; b7: pointer; b7_len: cint;
              fw: pointer; fw_len: cint; save: pointer; save_len: cint): cint {.exportc.} =
  ## Build the core on the buffer nds_rom_alloc handed out. A BIOS/firmware
  ## left out (len 0) gets the HLE BIOS / synthesized firmware. `save` is the
  ## cart backup to start from (io/backup.nim set_data: an EEPROM/FRAM size
  ## names the chip, other sizes are fitted to the one the game addresses,
  ## a .dsv footer is stripped; 0 = detect).
  if romBuf.len == 0: return 0
  lastBios9 = copy_in(b9, b9_len)
  lastBios7 = copy_in(b7, b7_len)
  lastFirmware = copy_in(fw, fw_len)
  boot_with(move(romBuf), save, save_len)
  1

proc nds_reboot(save: pointer; save_len: cint): cint {.exportc.} =
  ## Power-cycle the running game: a fresh core on the same ROM (moved out of
  ## the old one) and BIOS, starting from `save`. The firmware is the flash
  ## as the old core left it: a power cycle keeps what the game or the menu
  ## wrote to it (GBATEK "DS Firmware Serial Flash Memory": flash, not RAM),
  ## still dirty if the page has not stored it yet.
  if core == nil or core.cart.rom.len == 0: return 0
  var rom = move(core.cart.rom)
  let fw_dirty = core.spi.firmware_dirty
  lastFirmware = move(core.spi.firmware)
  core = nil
  boot_with(move(rom), save, save_len)
  core.spi.firmware_dirty = fw_dirty
  1

proc nds_unload() {.exportc.} =
  ## Drop the core and its ROM (a GB/GBA game takes over).
  core = nil
  romBuf = @[]

proc nds_load(rom: pointer; rom_len: cint; b9: pointer; b9_len: cint;
              b7: pointer; b7_len: cint; fw: pointer; fw_len: cint): cint {.exportc.} =
  ## One-call load from a page-owned ROM copy (small homebrew; tests).
  romBuf = copy_in(rom, rom_len)
  nds_boot(b9, b9_len, b7, b7_len, fw, fw_len, nil, 0)

proc step_frame()

proc nds_run_frame() {.exportc.} =
  ## One frame (to the next V-blank), the cheats after it, and a rewind
  ## snapshot when one is due.
  if core != nil: step_frame()

proc nds_frame_count(): cint {.exportc.} =
  if core == nil: 0 else: cint(core.gpu.frame_count)

proc nds_powered_off(): cint {.exportc.} =
  ## 1 once the program has shut the DS down (power manager register 0 bit
  ## 6): both screens are black, nothing runs and no sound comes out; only
  ## nds_reboot (or another nds_boot) turns it back on.
  if core != nil and core.powered_off(): 1 else: 0

# Video: each screen is 256x192 BGR555 (bit 15 unused), read in place by the
# app's WebGL presenter (web/glpresent.js). nds_fb_top/nds_fb_bottom convert
# to RGBA8888 on demand for 2D-canvas pages.

# Run-ahead's screens (nds_runahead, below): what the page shows instead of
# the machine's own until the next frame runs.
var aheadTop, aheadBottom: seq[uint16]
var aheadValid = false

proc nds_fb555_top(): pointer {.exportc.} =
  if core == nil: nil
  elif aheadValid: addr aheadTop[0]
  else: addr core.gpu.top[0]

proc nds_fb555_bottom(): pointer {.exportc.} =
  if core == nil: nil
  elif aheadValid: addr aheadBottom[0]
  else: addr core.gpu.bottom[0]

proc nds_fb_top(): pointer {.exportc.} =
  fbTop.setLen(256 * 192)
  if core != nil:
    for i in 0 ..< 256 * 192: fbTop[i] = bgr555_to_rgba(core.gpu.top[i])
  addr fbTop[0]

proc nds_fb_bottom(): pointer {.exportc.} =
  fbBottom.setLen(256 * 192)
  if core != nil:
    for i in 0 ..< 256 * 192: fbBottom[i] = bgr555_to_rgba(core.gpu.bottom[i])
  addr fbBottom[0]

proc nds_set_button(id: cint; pressed: cint) {.exportc.} =
  if core != nil and id >= 0 and id <= ord(high(NdsButton)):
    core.set_button(NdsButton(id), pressed != 0)

proc nds_set_touch(x, y, down: cint) {.exportc.} =
  if core != nil: core.set_touch(int(x), int(y), down != 0)

proc nds_set_lid(closed: cint) {.exportc.} =
  ## Close (1) or open (0) the hinge: EXTKEYIN bit 7, and opening raises the
  ## ARM7's lid IRQ (docs/nds/peripherals.md "Sleep and the lid").
  if core != nil: core.set_lid(closed != 0)

proc nds_push_mic(samples: ptr UncheckedArray[int16]; n: cint; rate: cint) {.exportc.} =
  ## Queue `n` mono int16 microphone samples at `rate` Hz behind what is
  ## queued (io/mic.nim plays them out against emulated time; at most
  ## 250 ms stays queued).
  if core != nil and samples != nil and n > 0 and rate > 0:
    core.push_mic(toOpenArray(samples, 0, int(n) - 1), int(rate))

# Audio: interleaved stereo float32 at 33513982 / 1024 = 32728.5 Hz
# (io/spu.nim). The page reads nds_audio_frames() frames from
# nds_audio_ptr() after each run, then calls nds_audio_clear().

proc nds_audio_frames(): cint {.exportc.} =
  if core == nil: 0 else: cint(core.spu.sample_count)

proc nds_audio_ptr(): pointer {.exportc.} =
  if core == nil or core.spu.samples.len == 0: nil else: addr core.spu.samples[0]

proc nds_audio_clear() {.exportc.} =
  if core != nil: core.spu.clear_samples()

# GBA slot (io/slot2.nim): kind 0 = empty, 1 = GBA cart (rom + its .sav),
# 2 = Rumble Pak, 3 = Memory Expansion Pak. Insert right after nds_load
# (power-on insertion). The cart's save is read from nds_slot2_save_ptr /
# _len when nds_slot2_save_dirty() is 1 (reading clears it).

proc nds_insert_slot2(kind: cint; rom: pointer; rom_len: cint; save: pointer;
                      save_len: cint): cint {.exportc.} =
  if core == nil or kind < 0 or kind > ord(high(Slot2Kind)): return 0
  core.insert_slot2(Slot2Kind(kind), copy_in(rom, rom_len), copy_in(save, save_len))
  1

proc nds_slot2_save_len(): cint {.exportc.} =
  if core == nil: 0 else: cint(core.slot2.save.len)

proc nds_slot2_save_ptr(): pointer {.exportc.} =
  if core == nil or core.slot2.save.len == 0: nil else: addr core.slot2.save[0]

proc nds_slot2_save_dirty(): cint {.exportc.} =
  if core == nil or not core.slot2.dirty: return 0
  core.slot2.dirty = false
  1

proc nds_rumble(): cint {.exportc.} =
  ## Slot-2 rumble strength 0..255 (Rumble Pak, or a GBA cart's GPIO motor),
  ## for navigator.vibrate / gamepad rumble; polled once per frame.
  if core == nil: 0 else: cint(core.slot2_rumble())
# The cart's save chip (io/backup.nim). The page polls nds_save_dirty and
# stores nds_save_size bytes from nds_save_ptr, then nds_save_clean. Size 0
# until the game first touches the chip (the type is detected then).
proc nds_save_size(): cint {.exportc.} =
  if core == nil: 0 else: cint(core.cart.backup.data.len)
proc nds_save_ptr(): pointer {.exportc.} =
  if core == nil or core.cart.backup.data.len == 0: nil
  else: addr core.cart.backup.data[0]
proc nds_save_dirty(): cint {.exportc.} =
  if core != nil and core.cart.backup.dirty: 1 else: 0
proc nds_save_clean() {.exportc.} =
  if core != nil: core.cart.backup.dirty = false

# The firmware flash (io/spi.nim): the DS menu's settings and a game's
# Nintendo WFC setup write it. When nds_firmware_dirty() is 1 the page
# stores nds_firmware_len() bytes from nds_firmware_ptr() and passes them as
# the firmware on the next nds_boot, then calls nds_firmware_clean().
proc nds_firmware_len(): cint {.exportc.} =
  if core == nil: 0 else: cint(core.spi.firmware.len)
proc nds_firmware_ptr(): pointer {.exportc.} =
  if core == nil or core.spi.firmware.len == 0: nil else: addr core.spi.firmware[0]
proc nds_firmware_dirty(): cint {.exportc.} =
  if core != nil and core.spi.firmware_dirty: 1 else: 0
proc nds_firmware_clean() {.exportc.} =
  if core != nil: core.spi.firmware_dirty = false

var synthFw: seq[uint8]
proc nds_synth_firmware(): pointer {.exportc.} =
  ## The firmware a boot without one gets (boot.nim synth_firmware), 256 KB,
  ## for the page to edit the user settings of before any DS game has run
  ## (Settings > Nintendo DS). Needs no core.
  synthFw = synth_firmware()
  addr synthFw[0]

proc nds_status(): cstring {.exportc.} =
  if core == nil: return "no ROM"
  status = "frame " & $core.gpu.frame_count & "  arm9 pc " &
           toHex(core.arm9.next_pc, 8) & "  arm7 pc " & toHex(core.arm7.next_pc, 8)
  cstring(status)

# Save states (nds/savestate.nim, docs/nds/savestate.md): the same packed
# bytes a desktop .state file holds. JS calls nds_state_size() then copies
# nds_state_size() bytes from nds_state_data() before the next call.

proc nds_state_size(thumbnail: cint): cint {.exportc.} =
  ## Serialize the machine (packed, with a 128x192 thumbnail of both
  ## screens when `thumbnail` != 0) into a retained buffer; its length, 0
  ## when no ROM runs.
  stateImage = if core == nil: "" else: pack_state(core.state_bytes(thumbnail != 0))
  cint(stateImage.len)

proc nds_state_plain_size(): cint {.exportc.} =
  ## As nds_state_size, the image left plain (about a millisecond, where
  ## packing takes 20-30): the page deflates it in a worker
  ## (web/ckptworker.js) or keeps it in memory as an undo.
  stateImage = if core == nil: "" else: core.state_bytes()
  cint(stateImage.len)

proc nds_state_data(): pointer {.exportc.} =
  if stateImage.len > 0: addr stateImage[0] else: nil

proc nds_state_load_keep(data: pointer; len: cint; keep_rewind: cint): cint {.exportc.} =
  ## Apply a state (packed or plain). 1 on success; 0 on refusal with the
  ## machine untouched (nds_state_error_kind / nds_state_error say why).
  ## Success empties the rewind ring unless keep_rewind (undoing a
  ## scrubber commit, whose ring is this state's past).
  last_state_error = ""
  if core == nil or data == nil or len <= 0: return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  if core.load_state_bytes(image):
    # Rewinding from here must not walk into the old timeline.
    if keep_rewind == 0: rewind_reset()
    1
  else: 0

proc nds_state_load(data: pointer; len: cint): cint {.exportc.} =
  nds_state_load_keep(data, len, 0)

proc nds_state_error_kind(): cint {.exportc.} =
  ## The last refusal as a StateRejectKind ordinal (common/serialize.nim).
  cint(ord(last_state_reject_kind))

proc nds_state_error(): cstring {.exportc.} =
  cstring(last_state_error)

# --- Cheats (nds/cheats.nim: Action Replay DS, unencrypted CodeBreaker DS).
# The list lives here, not in the core: a reset (nds_reboot) keeps it. Run
# after every frame while one is on; with none on nothing runs, so frames,
# sound and states are what they are without cheats.

var cheatList: DsCheats = nil   # made on first use: a heap global set at
                                 # module scope dangles once main() returns
var cheatErr: string

proc the_cheats(): DsCheats =
  if cheatList == nil: cheatList = DsCheats()
  cheatList

proc cheat_mem(n: NDS): DsCheatMem =
  DsCheatMem(
    read8: proc(a: uint32): uint32 = n.cheat_read(a, 8),
    read16: proc(a: uint32): uint32 = n.cheat_read(a, 16),
    read32: proc(a: uint32): uint32 = n.cheat_read(a, 32),
    write8: proc(a: uint32; v: uint32) = n.cheat_write(a, v, 8),
    write16: proc(a: uint32; v: uint32) = n.cheat_write(a, v, 16),
    write32: proc(a: uint32; v: uint32) = n.cheat_write(a, v, 32))

proc cheats_follow_game() =
  ## The CodeBreaker header check needs this game's code and header CRC.
  let rom = core.cart.rom
  if rom.len >= 0x160:
    discard the_cheats()
    cheatList.gamecode = uint32(rom[0x0C]) or (uint32(rom[0x0D]) shl 8) or
      (uint32(rom[0x0E]) shl 16) or (uint32(rom[0x0F]) shl 24)
    cheatList.crc16 = uint32(rom[0x15E]) or (uint32(rom[0x15F]) shl 8)

proc nds_load_cheats(text: pointer; len: cint): cstring {.exportc.} =
  ## Replace the cheat list with `.cht` text (UTF-8, `len` bytes): the
  ## refused cheats as "name: why" lines, "" when every one parsed.
  var t = newString(max(0, int(len)))
  if len > 0: copyMem(addr t[0], text, int(len))
  the_cheats().load(t)
  cheatErr = cheatList.errors()
  cstring(cheatErr)

# --- Rewind (common/rewind.nim, nds/rewinding.nim): a payload every
# REWIND_INTERVAL frames into a ring of XOR deltas, popped while the rewind
# button is held, with a thumbnail of both screens once a second for the
# scrubber and Report a Bug's timeline. A DS payload is ~6-7 MB raw; the
# ring keeps the newest whole and the rest as sparse zlib'd deltas.

var rewindWanted = false
var rewindCap = REWIND_CAP_BYTES
var rewindRing: Rewind = nil

proc rewind_reset() =
  aheadValid = false
  rewindRing = if rewindWanted and core != nil: new_nds_rewind(rewindCap) else: nil

proc nds_rewind_enable(on: cint; cap_bytes: cint) {.exportc.} =
  ## Rewind on (1) or off (0), its memory cap in bytes (0: the default).
  ## Off drops the ring and its cost; turning it on starts an empty one.
  rewindCap = if cap_bytes > 0: int(cap_bytes) else: REWIND_CAP_BYTES
  let was = rewindWanted
  rewindWanted = on != 0
  if not rewindWanted: rewindRing = nil
  elif not was or rewindRing == nil: rewind_reset()

proc nds_rewind_pop(): cint {.exportc.} =
  ## Step back one snapshot (REWIND_INTERVAL frames). 1 when applied, 0
  ## when the history is used up.
  if core == nil or rewindRing == nil: return 0
  let snap = rewindRing.pop()
  if snap.len == 0: return 0
  aheadValid = false
  if core.load_own_payload(snap): 1 else: 0

proc nds_rewind_depth(): cint {.exportc.} =
  ## Snapshots held (tests, the debug overlay).
  if rewindRing == nil: 0 else: cint(rewindRing.len)

proc nds_rewind_bytes(): cint {.exportc.} =
  if rewindRing == nil: 0 else: cint(rewindRing.mem_used)

# --- The rewind scrubber and Report a Bug's timeline: the GB/GBA core's
# wasm_rewind_scrub_* (src/dingbat_wasm.nim) for the DS ring. Samples are
# held by snapshot ID, so one evicted since the strip was drawn is gone
# rather than another moment. A look at a sample and straight back keeps
# the save chips' dirty flags (as_new = false): the same timeline.

var scrubThumbs: seq[byte]
var scrubIds: seq[int]

proc nds_rewind_scrub_generate(max_samples: cint): cint {.exportc.} =
  ## Up to max_samples thumbnails spread evenly across the history, newest
  ## first; how many.
  scrubThumbs = @[]
  scrubIds = @[]
  if core == nil or rewindRing == nil: return 0
  let count = rewindRing.thumb_count
  if count == 0: return 0
  let n = min(max(1, int(max_samples)), count)
  for s in 0 ..< n:
    let i = if n == 1: 0 else: s * (count - 1) div (n - 1)
    let t = rewindRing.thumb_at(i)
    if t.pixels.len == 0: continue
    scrubThumbs.add t.pixels
    scrubIds.add rewindRing.thumb_id(i)
  cint(scrubIds.len)

proc nds_rewind_scrub_thumb_w(): cint {.exportc.} = NDS_RW_THUMB_W
proc nds_rewind_scrub_thumb_h(): cint {.exportc.} = NDS_RW_THUMB_H
proc nds_rewind_scrub_thumbs_ptr(): pointer {.exportc.} =
  ## Packed little-endian BGR555, w*h*2 bytes each, in sample order.
  if scrubThumbs.len > 0: addr scrubThumbs[0] else: nil

proc scrub_snap(sample: cint): string =
  if sample < 0 or sample >= scrubIds.len or rewindRing == nil: ""
  else: rewindRing.snapshot_by_id(scrubIds[sample])

proc nds_rewind_scrub_seconds_ago(sample: cint): cint {.exportc.} =
  ## Age in tenths of a second, counted in snapshots back from the newest.
  if sample < 0 or sample >= scrubIds.len or rewindRing == nil: return 0
  let index = rewindRing.index_of_id(scrubIds[sample])
  if index < 0: return 0
  cint(index * rewindRing.snapshot_interval * 10 div 60)

proc nds_rewind_scrub_state_size(sample: cint): cint {.exportc.} =
  ## The sample's whole .state image (packed, with its thumbnail) into the
  ## nds_state_data() buffer, the live machine put back; its size (0 when
  ## the sample is gone). Report a Bug attaches it.
  stateImage = ""
  let snap = scrub_snap(sample)
  if snap.len == 0: return 0
  let stash = core.state_payload()
  if core.load_own_payload(snap, as_new = false):
    stateImage = pack_state(core.state_bytes(thumbnail = true))
  discard core.load_own_payload(stash, as_new = false)
  cint(stateImage.len)

proc nds_rewind_scrub_save_differs(sample: cint): cint {.exportc.} =
  ## 1 when committing to `sample` would change the cart's save chip: the
  ## scrubber's second confirmation, as for GB/GBA.
  let snap = scrub_snap(sample)
  if snap.len == 0: return 0
  let now = core.nds_save_chip()
  if now.len == 0: return 0
  let stash = core.state_payload()
  var differs = false
  if core.load_own_payload(snap, as_new = false):
    differs = core.nds_save_chip() != now
  discard core.load_own_payload(stash, as_new = false)
  if differs: 1 else: 0

proc nds_rewind_commit(sample: cint): cint {.exportc.} =
  ## Rewind the machine to `sample` and drop every newer snapshot (the
  ## page keeps its own state from before, for Undo). 1 when applied.
  if core == nil or rewindRing == nil: return 0
  if sample < 0 or sample >= scrubIds.len: return 0
  let snap = rewindRing.rewind_to_id(scrubIds[sample])
  if snap.len == 0: return 0
  aheadValid = false
  if core.load_own_payload(snap): 1 else: 0

proc step_frame() =
  aheadValid = false
  core.run_frame()
  if cheatList.active(): cheatList.run(core.cheat_mem())
  rewindRing.nds_rewind_tick(core)

# --- Run-ahead: after a frame is run (and its sound taken by the page),
# nds_runahead(n) snapshots the machine, runs n more frames with the same
# input, keeps their screens for the presenter, drops their sound and goes
# back to the snapshot. The page shows the future frame, so a press shows n
# frames sooner. The canonical timeline is untouched: the snapshot holds
# every saved field, and the save chips' dirty flags are kept as they were.

proc nds_runahead(n: cint): cint {.exportc.} =
  ## 1 when the screens now come from n frames ahead (nds_fb555_* point
  ## at them until the next frame), 0 when nothing was done.
  aheadValid = false
  if core == nil or n <= 0 or core.powered_off(): return 0
  let snap = core.state_payload()
  let fw_dirty = core.spi.firmware_dirty
  for _ in 0 ..< int(n):
    core.run_frame()
    if cheatList.active(): cheatList.run(core.cheat_mem())
  aheadTop.setLen(256 * 192)
  aheadBottom.setLen(256 * 192)
  copyMem(addr aheadTop[0], addr core.gpu.top[0], 256 * 192 * 2)
  copyMem(addr aheadBottom[0], addr core.gpu.bottom[0], 256 * 192 * 2)
  if not core.load_own_payload(snap, as_new = false): return 0
  core.spi.firmware_dirty = fw_dirty
  aheadValid = true
  1

# --- Payload timing (the page's bench: what rewind and run-ahead cost).
var benchPayload: string
proc nds_payload_take(): cint {.exportc.} =
  ## state_payload into a buffer; its length.
  if core == nil: return 0
  benchPayload = core.state_payload()
  cint(benchPayload.len)
proc nds_payload_restore(): cint {.exportc.} =
  ## The buffer back into the machine (load_own_payload); 1 = ok.
  if core == nil or benchPayload.len == 0: return 0
  if core.load_own_payload(benchPayload, as_new = false): 1 else: 0
proc nds_payload_restore_checked(): cint {.exportc.} =
  ## The same through load_state_payload (with its backup walk).
  if core == nil or benchPayload.len == 0: return 0
  if core.load_state_payload(benchPayload): 1 else: 0

when isMainModule:
  discard
