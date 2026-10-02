## WASM entry for the DS core: the main web app (web/index.js, lazy-loads
## web/nds/nds.js when a .nds game starts) and the standalone dev page
## (web/nds.html). Separate from dingbat_wasm.nim while the DS core is a
## prototype. Built MODULARIZE'd (createNdsCore) so its Module never meets
## em.js's global one. Build: nim c -d:emscripten src/dingbat_nds_wasm.nim
##
## Loading a game: nds_rom_alloc(len) returns a buffer inside the core, the
## page writes the ROM there once, then nds_boot(...) builds the core on it
## (moved, not copied: a 128 MB ROM must not exist twice in the heap).

import dingbat/nds/[nds, savestate]
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

proc boot_with(rom: sink seq[uint8]; save: pointer; save_len: cint) =
  core = new_nds(rom, lastBios9, lastBios7, lastFirmware)
  if save_len > 0: core.cart.backup.set_data(copy_in(save, save_len))

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
  ## the old one) and BIOS/firmware, starting from `save`.
  if core == nil or core.cart.rom.len == 0: return 0
  var rom = move(core.cart.rom)
  core = nil
  boot_with(move(rom), save, save_len)
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

proc nds_run_frame() {.exportc.} =
  if core != nil: core.run_frame()

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

proc nds_fb555_top(): pointer {.exportc.} =
  if core == nil: nil else: addr core.gpu.top[0]

proc nds_fb555_bottom(): pointer {.exportc.} =
  if core == nil: nil else: addr core.gpu.bottom[0]

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

proc nds_state_data(): pointer {.exportc.} =
  if stateImage.len > 0: addr stateImage[0] else: nil

proc nds_state_load(data: pointer; len: cint): cint {.exportc.} =
  ## Apply a state (packed or plain). 1 on success; 0 on refusal with the
  ## machine untouched (nds_state_error_kind / nds_state_error say why).
  last_state_error = ""
  if core == nil or data == nil or len <= 0: return 0
  var image = newString(int(len))
  copyMem(addr image[0], data, int(len))
  if core.load_state_bytes(image): 1 else: 0

proc nds_state_error_kind(): cint {.exportc.} =
  ## The last refusal as a StateRejectKind ordinal (common/serialize.nim).
  cint(ord(last_state_reject_kind))

proc nds_state_error(): cstring {.exportc.} =
  cstring(last_state_error)

when isMainModule:
  discard
