## A DS game on the desktop (Settings > General > Advanced > DS Beta): the
## parts of running one that need no window, so tests/desktop_nds_test.nim
## builds them headless. The web's src/dingbat_nds_wasm.nim + web/index.js
## "Nintendo DS" and the iOS app's src/dingbat_ios.nim "Nintendo DS" are the
## other two front ends; this follows them (docs/nds/desktop.md):
##
## - optional BIOS / firmware dumps, the HLE BIOS and the built-in firmware
##   without them;
## - the cart's save chip in `<rom>.sav` beside the ROM, as the GB/GBA
##   battery is;
## - the console's firmware flash (the user's name, birthday, language,
##   Wi-Fi settings a game or the DS menu wrote) kept once per computer in
##   the config folder, shared by every DS game;
## - the sound, queued to SDL's legacy audio device as the GB/GBA APUs queue
##   theirs (not under -d:test_harness: no SDL there);
## - save states in the desktop's slot files;
## - HD 3D: the screens the presenter shows at the 3D resolution set.

import std/[os, strformat, strutils]
import ../common/[atomicfile, input, rom_exts, serialize, timestretch]
import ../nds/nds except Input  # the DS core's Input object, not common/input's
import ../nds/savestate
when not defined(test_harness):
  import ../common/audio_out

const
  NDS_W* = 256                    ## the picture: top screen over bottom
  NDS_SCREEN_H* = 192
  NDS_H* = 2 * NDS_SCREEN_H
  NDS_FRAME_CYCLES* = FRAME_CYCLES  ## master cycles a frame (59.8261 Hz)
  NDS_MASTER_HZ* = MASTER_HZ
  NDS_SAVE_EVERY = 60
    ## Frames between battery writes while the game keeps writing its chip
    ## (a GB/GBA battery is written every frame; a DS save is up to 8 MB)

type
  NdsPaths* = object
    ## Where the dumps and the flash are: "" = none (HLE BIOS, built-in
    ## firmware; a flash with nowhere to go lasts until the game closes).
    bios9*, bios7*, firmware*: string
    flash*: string

  NdsGame* = ref object
    core*:       NDS
    rom_path*:   string
    save_path*:  string    ## the cart's battery file
    flash_path:  string
    fw_base:     string    ## the firmware base the flash is written on
    lid_closed*: bool      ## the hinge as the player set it
    stylus*:     bool      ## a touch is down (it started on the bottom screen)
    sync*:       bool      ## paced by audio; false = Fast Forward
    turbo*:      bool      ## 2x Speed
    # The cart's save, as the GB cart and GBA storage report theirs
    # (persist.nim BatteryNotice)
    save_error*:     string
    save_error_new*: bool
    frames_unsaved:  int
    # Sound (queue_audio)
    out_buf:        seq[float32]
    stretch:        TimeStretch
    stretch_on:     bool
    stretch_in:     int
    stretch_out:    int
    turbo_parity:   bool

  BuiltNds* = object
    ## `game` set, or nil and `error` says why (game_load.nim BuiltCore)
    game*:   NdsGame
    error*:  string
    detail*: string

proc read_bytes(path: string): seq[uint8] =
  ## A file's bytes straight into a seq (a 128 MB ROM read once, not via a
  ## string copy); empty for "" or a missing file.
  if path.len == 0 or not fileExists(path): return @[]
  var f: File
  if not open(f, path, fmRead): return @[]
  try:
    let n = int(getFileSize(f))
    result = newSeqUninit[uint8](n)
    if n > 0 and readBuffer(f, addr result[0], n) != n: result = @[]
  finally:
    close(f)

proc to_str(b: openArray[uint8]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc looks_like_nds_rom*(head: openArray[uint8]): bool =
  ## GBATEK's header checks, as the web's NdsUtil.looksLikeNdsRom: the logo's
  ## CRC CF56h at 15Ch, or the header CRC16 at 15Eh over 000h..15Dh.
  if head.len < 0x200: return false
  let logo = uint16(head[0x15C]) or (uint16(head[0x15D]) shl 8)
  if logo == 0xCF56'u16: return true
  let crc = uint16(head[0x15E]) or (uint16(head[0x15F]) shl 8)
  crc == crc16(head.toOpenArray(0, 0x15D))

proc is_nds_file*(path: string): bool =
  ## A DS game: `.nds`, or a file of another name (not a GB/GBA one or a
  ## zip) whose header passes the DS checks.
  let ext = path.splitFile().ext.toLowerAscii()
  if ext == ".nds": return true
  if ext in ROM_EXTS or ext == ".zip" or not fileExists(path): return false
  var f: File
  if not open(f, path, fmRead): return false
  var head = newSeq[uint8](0x200)
  try:
    if readBuffer(f, addr head[0], 0x200) != 0x200: return false
  finally:
    close(f)
  looks_like_nds_rom(head)

# ──────────────────────────── The firmware flash ────────────────────────────
# What a game or the DS menu writes to the flash is one console's, kept with
# the firmware base it was written on: "built-in" or the user's dump's
# signature (fnv1a32 ":" length, the web's saveSignature). The next boot gets
# it only on that base: over a dump, the written image whole; on the
# built-in firmware, only its user area (Wi-Fi connections and both
# user-settings copies) laid over this build's synth_firmware, so a later fix
# to the built-in header or wifi calibration still reaches it. The record is
# the iOS app's: the image, then the base, its length (u32 LE) and a magic.

const NDS_FW_BUILTIN = "built-in"
const NDS_FLASH_MAGIC = "DGBNDSFW"

proc fw_base_of(dump: openArray[uint8]): string =
  if dump.len == 0: return NDS_FW_BUILTIN
  var h = 0x811c9dc5'u32
  for b in dump: h = (h xor uint32(b)) * 0x01000193'u32
  $h & ":" & $dump.len

proc fw_user_area(img: openArray[uint8]): (int, int) =
  ## [020h]*8 - 400h to + 200h: the three access points and both user
  ## settings copies (3FE00h when the header says nothing usable).
  var u = if img.len >= 0x22: (int(img[0x20]) or (int(img[0x21]) shl 8)) * 8 else: 0
  if u <= 0 or u + 0x200 > img.len: u = 0x3FE00
  (max(0, u - 0x400), u + 0x200)

proc fw_overlay_user(base, written: seq[uint8]): seq[uint8] =
  ## `base` with `written`'s user area; empty when the two place it apart.
  let (s, e) = fw_user_area(base)
  let (ws, we) = fw_user_area(written)
  if s != ws or e != we or written.len < e or base.len < e: return @[]
  result = base
  copyMem(addr result[s], unsafeAddr written[s], e - s)

proc read_flash_record(path: string): tuple[data: seq[uint8]; base: string] =
  let raw = read_bytes(path)
  let m = NDS_FLASH_MAGIC.len
  if raw.len < m + 4: return
  if to_str(raw.toOpenArray(raw.len - m, raw.len - 1)) != NDS_FLASH_MAGIC: return
  let lp = raw.len - m - 4
  let blen = int(raw[lp]) or (int(raw[lp + 1]) shl 8) or (int(raw[lp + 2]) shl 16) or
             (int(raw[lp + 3]) shl 24)
  if blen < 0 or blen > lp: return
  result.base = to_str(raw.toOpenArray(lp - blen, lp - 1))
  result.data = raw[0 ..< lp - blen]

proc write_flash_record(path: string; data: openArray[uint8]; base: string) =
  var s = to_str(data)
  s.add base
  let n = uint32(base.len)
  for i in 0 ..< 4: s.add char((n shr (8 * i)) and 0xFF)
  s.add NDS_FLASH_MAGIC
  createDir(path.parentDir)
  write_file_atomic(path, s)

proc firmware_for(flash_path: string; dump: seq[uint8]; base: string): seq[uint8] =
  ## The firmware the next boot gets: the written record on this base, else
  ## the dump, else empty (the core synthesizes one).
  let rec = read_flash_record(flash_path)
  if rec.base != base or rec.data.len == 0: return dump
  if dump.len > 0: return rec.data
  let laid = fw_overlay_user(synth_firmware(), rec.data)
  if laid.len > 0: laid else: rec.data

# ──────────────────────────── Loading, saving ────────────────────────────

proc build_nds*(rom_path: string; paths: NdsPaths): BuiltNds =
  ## Builds a DS on `rom_path` without touching the running game: a file
  ## that is not a DS ROM, or a core that cannot be built, says why. The
  ## cart's chip starts from `<rom>.sav` (the core's set_data rules,
  ## docs/nds/saves.md); every boot starts with the lid open.
  let name = rom_path.extractFilename()
  try:
    var rom = read_bytes(rom_path)
    if not looks_like_nds_rom(rom):
      return BuiltNds(error: &"{name} isn't a DS ROM.",
                      detail: "no DS header (the logo or header CRC)")
    let dump = read_bytes(paths.firmware)
    let base = fw_base_of(dump)
    let g = NdsGame(rom_path: rom_path, save_path: rom_path.changeFileExt("sav"),
                    flash_path: paths.flash, fw_base: base, sync: true)
    g.core = new_nds(move(rom), read_bytes(paths.bios9), read_bytes(paths.bios7),
                     firmware_for(paths.flash, dump, base))
    let save = read_bytes(g.save_path)
    if save.len > 0: g.core.cart.backup.set_data(save)
    g.core.set_lid(false)
    result.game = g
  except CatchableError as e:
    result = BuiltNds(error: &"Couldn't load {name}.", detail: e.msg)

proc flush*(g: NdsGame): string =
  ## The battery file when the game wrote the chip, and the flash when a
  ## game wrote it. A write that fails stays dirty for the next flush;
  ## returns its reason ("" when nothing failed).
  if g == nil or g.core == nil: return ""
  g.frames_unsaved = 0
  let b = g.core.cart.backup
  if b.dirty and b.data.len > 0:
    try:
      write_file_atomic(g.save_path, to_str(b.data))
      b.dirty = false
      g.save_error = ""
    except CatchableError as e:
      if g.save_error.len == 0: g.save_error_new = true
      g.save_error = e.msg
      result = e.msg
  if g.core.spi.firmware_dirty and g.flash_path.len > 0:
    try:
      write_flash_record(g.flash_path, g.core.spi.firmware, g.fw_base)
      g.core.spi.firmware_dirty = false
    except CatchableError as e:
      echo "DS: could not keep the firmware settings: ", e.msg

proc after_frame*(g: NdsGame) =
  ## Once a frame: the battery file follows the chip a second behind while
  ## the game writes it (and at every flush: a game switch, quit).
  if g.core.cart.backup.dirty or g.core.spi.firmware_dirty:
    inc g.frames_unsaved
    if g.frames_unsaved >= NDS_SAVE_EVERY: discard g.flush()

const
  NDS_BUTTON_OF: array[Input, NdsButton] =
    [nbUp, nbDown, nbLeft, nbRight, nbA, nbB, nbSelect, nbStart, nbL, nbR]
  NDS_EXTRA_OF: array[DsInput, NdsButton] = [nbX, nbY]

proc press*(g: NdsGame; inp: Input; pressed: bool) =
  ## A GB/GBA input (bound as the player has them) on the DS's own button.
  g.core.set_button(NDS_BUTTON_OF[inp], pressed)

proc press*(g: NdsGame; inp: DsInput; pressed: bool) =
  g.core.set_button(NDS_EXTRA_OF[inp], pressed)

proc touch_point*(mx, my: int; view: (int, int, int, int)): tuple[x, y: int; bottom: bool] =
  ## A window point (top-left origin) to the bottom screen's pixels, through
  ## the letterboxed rect the picture is drawn in (`view`: x, y from the
  ## top, w, h). `bottom`: the point is on the bottom screen; x and y are
  ## clamped to it either way, for a stylus dragged off its edge.
  let (vx, vy, vw, vh) = view
  if vw <= 0 or vh <= 0: return (0, 0, false)
  let px = (mx - vx) * NDS_W div vw
  let py = (my - vy) * NDS_H div vh
  result.bottom = mx >= vx and mx < vx + vw and py >= NDS_SCREEN_H and py < NDS_H
  result.x = clamp(px, 0, NDS_W - 1)
  result.y = clamp(py - NDS_SCREEN_H, 0, NDS_SCREEN_H - 1)

proc set_touch*(g: NdsGame; x, y: int; down: bool) =
  ## The stylus on the bottom screen (clamped to it). A closed lid has no
  ## touch screen to reach: no touch lands while it is.
  g.stylus = down and not g.lid_closed
  g.core.set_touch(x, y, g.stylus)

proc lift_stylus*(g: NdsGame) =
  ## The stylus comes up where it was.
  g.stylus = false
  g.core.set_touch(g.core.input.touch_x, g.core.input.touch_y, false)

proc set_lid*(g: NdsGame; closed: bool) =
  ## Close or open the hinge (opening raises the ARM7's lid IRQ; a game
  ## typically sleeps while it is shut).
  g.lid_closed = closed
  if closed: g.set_touch(0, 0, false)
  g.core.set_lid(closed)

proc state_identity*(g: NdsGame): uint32 =
  ## What the desktop names this game's slot files by (persist.nim).
  rom_identity(g.core.cart.rom)

proc save_state_file*(g: NdsGame; path: string): bool =
  ## A slot file, with both screens' thumbnail. A DS the game switched off
  ## has nothing to come back to (the web's rule): refused.
  last_state_error = ""
  if g.core.powered_off():
    last_state_error = "the game switched the DS off"
    return false
  try:
    createDir(path.parentDir)
    write_file_atomic(path, pack_state(g.core.state_bytes(thumbnail = true)))
    true
  except CatchableError as e:
    last_state_error = e.msg
    echo "Save state failed: ", e.msg
    false

proc load_state_file*(g: NdsGame; path: string): bool =
  ## A slot file; refused with the machine untouched (`last_state_reject_kind`
  ## says why). The lid stays where the player has it, not where the state
  ## had it.
  last_state_error = ""
  last_state_reject_kind = srkNone
  if not fileExists(path):
    last_state_reject_kind = srkNoFile
    last_state_error = "no file at " & path
    return false
  var data = ""
  try: data = readFile(path)
  except CatchableError as e:
    last_state_reject_kind = srkNoFile
    last_state_error = e.msg
    return false
  result = g.core.load_state_bytes(data)
  if result:
    g.core.set_lid(g.lid_closed)
    if not g.stylus and g.core.input.touching:
      g.core.set_touch(g.core.input.touch_x, g.core.input.touch_y, false)
    g.core.spu.clear_samples()
  else:
    echo "Load state failed: ", last_state_error

proc state_is_for*(g: NdsGame; data: string): bool =
  ## A state image (plain or packed) made for this game; never raises.
  g.core.state_is_for(data)

proc powered_off*(g: NdsGame): bool =
  ## The game shut the DS down: both screens black, no sound, no states.
  g.core.powered_off()

proc asleep*(g: NdsGame): bool =
  ## Asleep (the lid shut, or the game's own sleep) or switched off.
  g.core.asleep()

proc rewind_payload*(g: NdsGame): string =
  ## A rewind ring's snapshot: aligned, so deltas between two line up.
  g.core.state_payload(aligned = true)

proc rewind_apply*(g: NdsGame; snap: string): bool =
  ## A snapshot this game took for the ring; the lid is then where the
  ## snapshot had it.
  result = g.core.load_own_payload(snap)
  g.lid_closed = g.core.input.lid_closed
  g.stylus = false
  if g.core.input.touching:
    g.core.set_touch(g.core.input.touch_x, g.core.input.touch_y, false)

# ──────────────────────────── The screens ────────────────────────────
# HD 3D (Settings > Video > 3D resolution, docs/nds/hd3d.md): at 2..4 the
# core also draws both screens at that multiple of 256x192, the 3D scene
# rendered at that resolution, and those are what is shown. Display only:
# the 1x screens, the machine and its states are the same either way, and
# the window and the touch screen keep to the 1x picture.

proc hd_scale*(g: NdsGame): int = g.core.hd_scale

proc set_hd*(g: NdsGame; scale: int) =
  ## 1 = off, 2..4; nothing when unchanged (the presenter asks every frame).
  ## The HD screens show the 1x ones scaled up until the next frame draws
  ## them (Gpu.hd_restart: what follows is what turning HD on draws), so a
  ## paused game changed shows its picture, not black. The core keeps the
  ## scale through state loads and rewinds; a reboot is a new core, set
  ## again by the frontend.
  let k = clamp(scale, 1, 4)
  if k == g.core.hd_scale: return
  g.core.set_hd_scale(k)
  g.core.gpu.hd_restart()

proc screen_size*(g: NdsGame): (int, int) =
  ## The picture shown, top screen above bottom: 256x384, or 256k x 384k
  ## with HD 3D at k (the presenter's texture).
  let k = g.core.hd_scale
  (NDS_W * k, NDS_H * k)

proc top_screen*(g: NdsGame): ptr uint16 =
  ## The top screen as shown (screen_size's width, half its height).
  if g.core.hd_scale > 1: addr g.core.gpu.hd_top[0] else: addr g.core.gpu.top[0]

proc bottom_screen*(g: NdsGame): ptr uint16 =
  if g.core.hd_scale > 1: addr g.core.gpu.hd_bottom[0] else: addr g.core.gpu.bottom[0]

proc compose*(g: NdsGame; dst: var seq[uint16]; hd = false) =
  ## Both screens as one BGR555 picture, top above bottom: 256x384, or with
  ## `hd` the picture shown (screen_size).
  let (w, h) = if hd: g.screen_size() else: (NDS_W, NDS_H)
  let screen = w * (h div 2)
  if dst.len != w * h: dst.setLen(w * h)
  let (t, b) = if hd: (g.top_screen(), g.bottom_screen())
               else: (addr g.core.gpu.top[0], addr g.core.gpu.bottom[0])
  copyMem(addr dst[0], t, screen * 2)
  copyMem(addr dst[screen], b, screen * 2)

# ──────────────────────────── Sound ────────────────────────────
# The SPU's interleaved float32 stereo at 33513982 / 1024 Hz (io/spu.nim),
# queued after each frame to the audio queue (common/audio_out.nim), which
# each core opens for itself (the GB/GBA APUs replace it with their own), at
# the DS rate rounded to a whole Hz. Pacing is the GB APU's in sample frames:
# ahead past 512 queued, the blocking backstop past 4096.

const
  NDS_AUDIO_RATE* = int(SAMPLE_RATE + 0.5)                    # 32728 (32728.498)
  NDS_FRAME_SAMPLES = int(FRAME_CYCLES div SPU_TICK_CYCLES)   # 547 a frame
  NDS_SYNC_AHEAD_BYTES = 512'u32 * 8
  NDS_SYNC_BACKSTOP_BYTES = 4096'u32 * 8

proc open_audio*(g: NdsGame) =
  ## Take the audio queue for the DS's rate (when the game takes over
  ## from the one before: a core built and refused must not have taken it).
  when not defined(test_harness):
    if not audio_open(sfF32, NDS_AUDIO_RATE):
      echo "Warning: DS failed to open audio device"

proc audio_queued_bytes*(g: NdsGame): uint32 =
  when defined(test_harness): 0'u32
  else: audio_queued()

proc audio_ahead*(g: NdsGame): bool =
  ## Synced sound buffered comfortably ahead of playback: the frontend's
  ## signal to hold the next frame (the APUs' audio_ahead).
  g.sync and g.audio_queued_bytes() > NDS_SYNC_AHEAD_BYTES

proc queue_audio*(g: NdsGame; volume: int; mute, pitch_correct: bool) =
  ## This frame's samples to the device, after volume and 2x. Asleep or
  ## switched off the SPU stands still, but time does not: a frame's worth
  ## of silence keeps the device's clock pacing the frames at real speed.
  let spu = g.core.spu
  let made = spu.sample_count
  let n = if g.core.asleep(): max(made, NDS_FRAME_SAMPLES) else: made
  if n == 0: return
  let silent = mute or volume <= 0
  let vf = float32(clamp(volume, 0, 100)) / 100'f32
  g.out_buf.setLen(2 * n)
  for i in 0 ..< 2 * n:
    g.out_buf[i] = if silent or i >= 2 * made: 0'f32
                   elif vf != 1'f32: spu.samples[i] * vf
                   else: spu.samples[i]
  spu.clear_samples()
  var frames = n
  if g.turbo and g.sync:
    if pitch_correct and not silent:
      # WSOLA: every frame in, exactly half as many out over time.
      if not g.stretch_on:
        if g.stretch == nil: g.stretch = new_time_stretch()
        else: g.stretch.reset()
        g.stretch_on = true
        g.stretch_in = 0
        g.stretch_out = 0
      for i in 0 ..< n: g.stretch.push(g.out_buf[2 * i], g.out_buf[2 * i + 1])
      g.stretch_in += n
      frames = g.stretch_in div 2 - g.stretch_out
      for o in 0 ..< frames:
        let (l, r) = g.stretch.pull()
        g.out_buf[2 * o] = l
        g.out_buf[2 * o + 1] = r
      g.stretch_out += frames
    else:
      # Every other frame: the octave-up 2x.
      g.stretch_on = false
      frames = 0
      for i in 0 ..< n:
        g.turbo_parity = not g.turbo_parity
        if g.turbo_parity:
          g.out_buf[2 * frames] = g.out_buf[2 * i]
          g.out_buf[2 * frames + 1] = g.out_buf[2 * i + 1]
          inc frames
  else:
    g.stretch_on = false
  if frames == 0: return
  when not defined(test_harness):
    if not g.sync:
      audio_clear()   # keep only the freshest, as the APUs do unsynced
    else:
      while audio_queued() > NDS_SYNC_BACKSTOP_BYTES: audio_wait(1)
    audio_put(addr g.out_buf[0], frames * 8)

proc run_frame*(g: NdsGame; volume: int; mute, pitch_correct: bool) =
  ## One frame (to the next V-blank), its sound queued, the battery followed.
  g.core.run_frame()
  g.queue_audio(volume, mute, pitch_correct)
  g.after_frame()
