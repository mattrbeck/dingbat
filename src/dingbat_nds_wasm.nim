## WASM entry for the DS prototype (web/nds.html). Separate from
## dingbat_wasm.nim while the DS core is a prototype: no saves, rewind or
## link yet. Build: nim c -d:emscripten src/dingbat_nds_wasm.nim

import dingbat/nds/nds
from std/strutils import toHex

var core: NDS
var fbTop, fbBottom: seq[uint32]
var status: string

proc copy_in(p: pointer; len: cint): seq[uint8] =
  result = newSeq[uint8](int(len))
  if len > 0: copyMem(addr result[0], p, int(len))

proc nds_load(rom: pointer; rom_len: cint; b9: pointer; b9_len: cint;
              b7: pointer; b7_len: cint; fw: pointer; fw_len: cint): cint {.exportc.} =
  core = new_nds(copy_in(rom, rom_len), copy_in(b9, b9_len), copy_in(b7, b7_len),
                 copy_in(fw, fw_len))
  fbTop.setLen(256 * 192)
  fbBottom.setLen(256 * 192)
  1

proc nds_run_frame() {.exportc.} =
  if core == nil: return
  core.run_frame()
  for i in 0 ..< 256 * 192:
    fbTop[i] = bgr555_to_rgba(core.gpu.top[i])
    fbBottom[i] = bgr555_to_rgba(core.gpu.bottom[i])

proc nds_fb_top(): pointer {.exportc.} = addr fbTop[0]
proc nds_fb_bottom(): pointer {.exportc.} = addr fbBottom[0]

proc nds_set_button(id: cint; pressed: cint) {.exportc.} =
  if core != nil and id >= 0 and id <= ord(high(NdsButton)):
    core.set_button(NdsButton(id), pressed != 0)

proc nds_set_touch(x, y, down: cint) {.exportc.} =
  if core != nil: core.set_touch(int(x), int(y), down != 0)

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

proc nds_status(): cstring {.exportc.} =
  if core == nil: return "no ROM"
  status = "frame " & $core.gpu.frame_count & "  arm9 pc " &
           toHex(core.arm9.next_pc, 8) & "  arm7 pc " & toHex(core.arm7.next_pc, 8)
  cstring(status)


when isMainModule:
  discard
