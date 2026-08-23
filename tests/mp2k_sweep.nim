# MP2K HLE archive-sweep probe: boot one ROM headless for N frames with the
# shadow HLE armed and emit ONE machine-readable JSON line describing how the
# detection + shadow mixer behaved. Designed to be driven in bulk by
# tools/mp2k_sweep.py over a ROM archive.
#
# Build: nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc \
#          -o:mp2k_sweep --path:src tests/mp2k_sweep.nim
# Usage: mp2k_sweep <rom> [frames=900]
# Env:   DINGBAT_NOHLE=1          boot with the HLE disarmed (isolation runs)
#        DINGBAT_SWEEP_TIMEOUT=s  wall-clock budget before bailing (default 120)
#        DINGBAT_SWEEP_DRIVE=1    mash A/START (menu-gated titles: health
#                                 screens, title menus — e.g. Mother 3's
#                                 press-any-button intro gate)
#
# Reported fields (all from THIS run):
#   rom            basename
#   frames_run     frames actually stepped (== frames unless timeout)
#   timeout        wall budget exhausted
#   rom_magic      m4a ID_NUMBER literal present in the ROM image (ground truth:
#                  every m4a build embeds 0x68736D53 in a literal pool)
#   m4a_seen/_frame  SOUND_INFO_PTR pointed at a live ident (ID_NUMBER or +1)
#   ident_last     last ident value seen through a valid SOUND_INFO_PTR (hex)
#   engaged/_frame/_ever  shadow mixer state (final / first frame / ever)
#   hook           learned SoundMainRAM entry PC (hex)
#   hook_fires     mixer-pass hook fires
#   probe_fails    mislearn (unlearn) count — nonzero means detection churn
#   retrig         sampler (re)trigger count over the run
#   mono           FIFO topology (0 stereo, 1 mono A, 2 mono B)
#   reverb/pcm_rate  last SoundInfo values seen by the hook
#   hle_rms/real_rms/ratio  span-matched A/B RMS of the HLE render vs the
#                  game's own FIFO stream (both only accumulate while engaged)
#   wall_s         wall time of the frame loop (perf outlier screen)
import std/[os, strutils, math, json, monotimes, times]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

const
  IDENT_IDLE = 0x68736D53'u32
  IDENT_LOCK = 0x68736D54'u32

proc rms(s: seq[int16]): float =
  if s.len == 0: return 0
  var a = 0.0
  for v in s: a += float(v) * float(v)
  sqrt(a / float(s.len))

proc main() =
  let rom_path = paramStr(1)
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 900
  let budget = parseFloat(getEnv("DINGBAT_SWEEP_TIMEOUT", "120"))

  let emu = new_gba("", rom_path, run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"

  # Every m4a/MP2K build embeds ID_NUMBER 0x68736D53 in a literal pool, so
  # scan the ROM bytes for its little-endian form. The pow2 padding is the
  # open-bus pattern, which can never spell the constant.
  var rom_magic = false
  block:
    let rom = addr emu.cartridge.rom
    let n = rom[].len
    var i = 0
    while i + 4 <= n:
      if rom[][i] == 0x53'u8 and rom[][i+1] == 0x6D'u8 and
         rom[][i+2] == 0x73'u8 and rom[][i+3] == 0x68'u8:
        rom_magic = true
        break
      inc i

  var
    engage_frame = -1
    engaged_ever = false
    m4a_frame = -1
    ident_last = 0'u32
    frames_run = 0
    timed_out = false
  let drive = getEnv("DINGBAT_SWEEP_DRIVE") == "1"
  let t0 = getMonoTime()
  try:
    for f in 0 ..< frames:
      if drive:
        let phase = (f div 8) mod 4
        let btn = (if (f div 32) mod 2 == 0: A else: START)
        emu.keypad.handle_input(btn, phase < 2)
      emu.step_frame()
      inc frames_run
      if emu.mp2k.engaged:
        engaged_ever = true
        if engage_frame < 0: engage_frame = f
      # m4a runtime ground truth, independent of the HLE's own state machine.
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
        let ident = emu.bus.read_word_internal(sip)
        if ident != 0'u32: ident_last = ident
        if ident == IDENT_IDLE or ident == IDENT_LOCK:
          if m4a_frame < 0: m4a_frame = f
      if (f and 31) == 31:
        if (getMonoTime() - t0).inMilliseconds.float / 1000.0 > budget:
          timed_out = true
          break
  except CatchableError as e:
    let wall = (getMonoTime() - t0).inMilliseconds.float / 1000.0
    echo $(%*{"rom": rom_path.extractFilename, "crash": e.msg,
              "crash_kind": $e.name, "frames_run": frames_run,
              "wall_s": wall})
    quit(3)
  let wall = (getMonoTime() - t0).inMilliseconds.float / 1000.0

  let hr = rms(mp2kWavCapture)
  let rr = rms(realDmaCapture)
  echo $(%*{
    "rom": rom_path.extractFilename,
    "frames_run": frames_run,
    "timeout": timed_out,
    "rom_magic": rom_magic,
    "m4a_seen": m4a_frame >= 0,
    "m4a_frame": m4a_frame,
    "ident_last": toHex(ident_last, 8),
    "engaged": emu.mp2k.engaged,
    "engaged_ever": engaged_ever,
    "engage_frame": engage_frame,
    "hook": toHex(emu.mp2k.hook_addr, 8),
    "hook_fires": emu.mp2k.dbg_hook_fires,
    "probe_hits": emu.mp2k.dbg_probe_hits,
    "probe_ident": toHex(emu.mp2k.dbg_probe_ident, 8),
    "probe_fails": emu.mp2k.probe_fails,
    "retrig": dbgRetrigCount,
    "mono": emu.mp2k.mono_mode,
    "foreign": emu.mp2k.fifo_foreign,
    "reverb": int(emu.mp2k.dbg_reverb),
    "pcm_rate": emu.mp2k.dbg_pcm_rate,
    "hle_rms": hr,
    "real_rms": rr,
    "ratio": (if rr > 0: hr / rr else: 0.0),
    "hle_n": mp2kWavCapture.len,
    "real_n": realDmaCapture.len,
    "overlay_trig": emu.mp2k.dbg_overlay_triggers,
    "overlay_passes": emu.mp2k.dbg_overlay_passes,
    "unlatches": emu.mp2k.dbg_unlatches,
    "wall_s": wall
  })

main()
