## WASM entry for the DS prototype (web/nds.html). Separate from
## dingbat_wasm.nim while the DS core is a prototype: no rewind or link yet.
## Build: nim c -d:emscripten src/dingbat_nds_wasm.nim

import dingbat/nds/[nds, savestate]
from std/strutils import toHex

var core: NDS
var fbTop, fbBottom: seq[uint32]
var status: string
var stateImage: string     # the last nds_state_size() result

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
