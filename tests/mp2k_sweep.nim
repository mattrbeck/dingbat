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
#        DINGBAT_SWEEP_WAV=prefix write <prefix>.hle.wav / <prefix>.real.wav
#                                 (32768 Hz s16 stereo, same span) for
#                                 waveform-level A/B of the HLE render vs
#                                 the game's own FIFO stream
#        DINGBAT_PASSDUMP=file    one line per rendered pass: where the HLE
#                                 placed the frame and where its slot's first
#                                 byte left the FIFO (tools/mp2ksweep/README.md
#                                 lists this and the mp2k.nim debug switches)
# Tooling: tools/mp2ksweep (build any commit, sweep, capture, reports).
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
#   hook_fires     mixer passes detected (lock write, then the first ring store)
#   seq_late       channels first seen ON without START
#   retrig         sampler (re)trigger count over the run
#   mono           FIFO topology (0 stereo, 1 mono A, 2 mono B)
#   reverb/pcm_rate  last SoundInfo values seen by the hook
#   hle_rms/real_rms/ratio  span-matched A/B RMS (DC-free per 125 ms block) of
#                  the HLE render vs the game's own FIFO stream (both only
#                  accumulate while engaged)
#   env_corr       Pearson of the two ~100 ms RMS envelopes (shape/tempo)
#   xcorr0         sample-level normalised correlation at lag 0 (waveform)
#   lag            HLE-vs-real lag in APU samples from the RMS envelopes
#                  (64-sample resolution; the waveform aliases on periodic music)
#   start_honoured/_ignored/_unclear  note-ons carrying a non-zero count: did
#                  the engine start the sample there or at 0 (mp2k.nim)
#   wall_s         wall time of the frame loop (perf outlier screen)
when not defined(mp2kwav):
  {.error: "build with -d:mp2kwav (see the header)".}
import std/[os, strutils, math, json, monotimes, times, streams, tables]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

const
  IDENT_IDLE = 0x68736D53'u32
  IDENT_LOCK = 0x68736D54'u32

proc write_wav(path: string; samples: seq[int16]) =
  let f = newFileStream(path, fmWrite)
  let n = samples.len
  f.write("RIFF"); f.write(uint32(36 + n * 2)); f.write("WAVE")
  f.write("fmt "); f.write(uint32(16)); f.write(uint16(1)); f.write(uint16(2))
  f.write(uint32(32768)); f.write(uint32(32768 * 4)); f.write(uint16(4)); f.write(uint16(16))
  f.write("data"); f.write(uint32(n * 2))
  for v in samples: f.write(v)
  f.close()

proc pearson(a, b: seq[float]): float =
  let n = min(a.len, b.len)
  if n < 2: return 0
  var ma, mb = 0.0
  for i in 0 ..< n: ma += a[i]; mb += b[i]
  ma /= float(n); mb /= float(n)
  var sab, saa, sbb = 0.0
  for i in 0 ..< n:
    let da = a[i] - ma
    let db = b[i] - mb
    sab += da * db; saa += da * da; sbb += db * db
  if saa <= 0 or sbb <= 0: return 0
  sab / sqrt(saa * sbb)

proc env_corr(a, b: seq[int16]; blk = 6554): float =
  ## Pearson correlation of the per-~100 ms RMS envelopes (shape/tempo gate).
  let n = min(a.len, b.len)
  var ea, eb: seq[float]
  var i = 0
  while i + blk <= n:
    var sa, sb = 0.0
    for j in i ..< i + blk:
      sa += float(a[j]) * float(a[j]); sb += float(b[j]) * float(b[j])
    ea.add sqrt(sa / float(blk)); eb.add sqrt(sb / float(blk))
    i += blk
  pearson(ea, eb)

proc xcorr0(a, b: seq[int16]): float =
  ## Normalised sample-level correlation at lag 0. The two captures are
  ## span-matched and the HLE carries the hardware's one-frame double-buffer
  ## delay, so lag 0 is the aligned comparison.
  let n = min(a.len, b.len)
  var sab, saa, sbb = 0.0
  for i in 0 ..< n:
    let x = float(a[i])
    let y = float(b[i])
    sab += x * y; saa += x * x; sbb += y * y
  if saa <= 0 or sbb <= 0: return 0
  sab / sqrt(saa * sbb)

proc best_lag(a, b: seq[int16]; blk = 64; span = 40): int =
  ## Lag (APU samples, positive = HLE later) of the HLE capture against the
  ## real stream, from their RMS envelopes in `blk`-sample blocks (mono
  ## mix, mean removed), cross-correlated over +-span blocks. An envelope
  ## cannot alias on periodic music the way the waveform does; resolution
  ## is one block.
  let n = min(a.len, b.len) div 2
  let m = n div blk
  if m < 4 * span: return 0
  var da = newSeq[float](m)
  var db = newSeq[float](m)
  var ma, mb = 0.0
  for i in 0 ..< m:
    var sa, sb = 0.0
    for j in 0 ..< blk:
      let k = (i * blk + j) * 2
      let va = float(a[k]) + float(a[k + 1])
      let vb = float(b[k]) + float(b[k + 1])
      sa += va * va; sb += vb * vb
    da[i] = sqrt(sa / float(blk)); db[i] = sqrt(sb / float(blk))
    ma += da[i]; mb += db[i]
  ma /= float(m); mb /= float(m)
  for i in 0 ..< m:
    da[i] -= ma; db[i] -= mb
  var best = 0
  var bestv = -1e300
  for lag in -span .. span:
    var acc = 0.0
    for i in span ..< m - span:
      acc += da[i + lag] * db[i]
    if acc > bestv:
      bestv = acc; best = lag
  best * blk

proc rms(s: seq[int16]; blk = 8192): float =
  ## RMS with each ~125 ms block's mean removed. The driver's per-channel
  ## floor truncation parks the FIFO stream at about -0.5 per active voice
  ## (-11 on a ten-voice mix): inaudible DC that would otherwise count as
  ## loudness against the HLE, which has none.
  if s.len == 0: return 0
  var a = 0.0
  var i = 0
  while i < s.len:
    let e = min(i + blk, s.len)
    var m = 0.0
    for j in i ..< e: m += float(s[j])
    m /= float(e - i)
    for j in i ..< e:
      let d = float(s[j]) - m
      a += d * d
    i = e
  sqrt(a / float(s.len))

proc main() =
  let rom_path = paramStr(1)
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 900
  let budget = parseFloat(getEnv("DINGBAT_SWEEP_TIMEOUT", "120"))

  let emu = new_gba("", rom_path, run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"
  # post_init emits a sample with the HLE still off, which the real-stream
  # capture keeps: without this the two captures sit one sample apart and a
  # time-aligned HLE reads as lag -1.
  when defined(mp2kwav):
    realDmaCapture.setLen(0)
    mp2kWavCapture.setLen(0)

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
  let wav = getEnv("DINGBAT_SWEEP_WAV")
  if wav.len > 0:
    write_wav(wav & ".hle.wav", mp2kWavCapture)
    write_wav(wav & ".real.wav", realDmaCapture)
  let pd = getEnv("DINGBAT_PASSDUMP")
  if pd.len > 0:
    var f = open(pd, fmWrite)
    for i in 0 ..< dbgPassPlaced.len:
      f.writeLine($i & " " & $dbgPassPlaced[i] & " " & $dbgPassReal[i][0] & " " & $dbgPassReal[i][1] & " " & dbgPassInfo[i])
    f.close()
  var rec = %*{
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
    "hook_fires": emu.mp2k.dbg_hook_fires,
    "replaced": emu.mp2k.dbg_replaced,
    "place_steps": emu.mp2k.dbg_steps,
    "seq_late": emu.mp2k.seq_late,
    "retrig": dbgRetrigCount,
    "mono": emu.mp2k.mono_mode,
    "foreign": emu.mp2k.fifo_foreign,
    "reverb": int(emu.mp2k.dbg_reverb),
    "pcm_rate": emu.mp2k.dbg_pcm_rate,
    "hle_rms": hr,
    "real_rms": rr,
    "ratio": (if rr > 0: hr / rr else: 0.0),
    "env_corr": env_corr(mp2kWavCapture, realDmaCapture),
    "xcorr0": xcorr0(mp2kWavCapture, realDmaCapture),
    "lag": best_lag(mp2kWavCapture, realDmaCapture),
    "predict": emu.mp2k.predict,
    "pred_ok": emu.mp2k.pred_ok,
    "pred_bad": emu.mp2k.pred_bad,
    "lat_avg": int(emu.mp2k.lat_avg),
    "fifo_err": emu.mp2k.fifo_err_avg,
    "fifo_target": emu.mp2k.fifo_target,
    "start_honoured": dbgStartHonoured,
    "start_ignored": dbgStartIgnored,
    "start_unclear": dbgStartUnclear,
    "hle_n": mp2kWavCapture.len,
    "real_n": realDmaCapture.len,
    "overlay_trig": emu.mp2k.dbg_overlay_triggers,
    "overlay_passes": emu.mp2k.dbg_overlay_passes,
    "unlatches": emu.mp2k.dbg_unlatches,
    "wall_s": wall
  }
  when defined(mp2kwcensus):
    wc_close()
    var fields = newJObject()
    for k, v in wcFields: fields[k] = %v
    var envpc = newJObject()
    for k, v in wcEnvPc: envpc[k] = %v
    rec["wc"] = %*{"passes": wcPasses, "ring_passes": wcRingPasses, "no_ring": wcNoRing,
                   "no_ring_late": wcNoRingLate, "env_before": wcEnvBefore,
                   "env_pc": envpc, "ring_outside": wcRingOutside, "other_buf": wcOther,
                   "fields": fields}
  echo $rec

main()
