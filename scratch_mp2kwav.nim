import std/[os, strutils, math, algorithm]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  emu.mp2k.env_mode = parseInt(getEnv("MP2K_ENV", "0"))
  emu.mp2k.resample_mode = parseInt(getEnv("MP2K_RS", "0"))
  emu.mp2k.makeup = parseFloat(getEnv("MP2K_MAKEUP", "0"))
  emu.mp2k.master_apply = parseInt(getEnv("MP2K_MASTER", "0"))
  let frames = parseInt(paramStr(2))
  # Optional: mash START+A to advance past title screens into gameplay music,
  # which is where BDPCM (compressed) instruments tend to show up. Enabled when
  # a 3rd arg "drive" is passed. Also let capture start after a warmup so intro
  # jingles don't dominate the A/B RMS.
  let drive = paramCount() >= 3 and paramStr(3) == "drive"
  for f in 0 ..< frames:
    if drive:
      # press for a few frames, release, cycling A then START
      let phase = (f div 8) mod 4
      let btn = (if (f div 32) mod 2 == 0: A else: START)
      let down = phase < 2
      emu.keypad.handle_input(btn, down)
    emu.step_frame()
  mp2k_write_wav("/tmp/mp2k_hle.wav")
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var acc = 0.0
    for v in s: acc += float(v) * float(v)
    sqrt(acc / float(s.len))
  proc peak(s: seq[int16]): int =
    for v in s: result = max(result, abs(int(v)))
  proc zcr(s: seq[int16]): float =
    # zero crossings per second over the L channel (interleaved stereo)
    if s.len < 4: return 0
    var cross = 0
    var i = 2
    while i < s.len:
      if (s[i-2] >= 0) != (s[i] >= 0): cross.inc
      i += 2
    float(cross) / (float(s.len div 2) / 32768.0)
  proc top1(s: seq[int16]): float =
    # mean magnitude of the loudest 1% of samples (transient energy proxy)
    if s.len == 0: return 0
    var mags = newSeq[int](s.len)
    for i in 0 ..< s.len: mags[i] = abs(int(s[i]))
    mags.sort(Descending)
    let k = max(1, s.len div 100)
    var acc = 0.0
    for i in 0 ..< k: acc += float(mags[i])
    acc / float(k)
  proc frameEnergy(s: seq[int16]): seq[float] =
    # RMS envelope per ~1 audio frame (546 stereo samples), L channel
    let win = 546
    var i = 0
    while i + win*2 <= s.len:
      var acc = 0.0
      for j in 0 ..< win: acc += float(s[i+j*2])*float(s[i+j*2])
      result.add sqrt(acc/float(win))
      i += win*2
  proc bestLag(a, b: seq[float]): tuple[lag: int, corr: float] =
    # normalized cross-correlation of two envelopes over lags -6..6 frames
    let n = min(a.len, b.len)
    var ma=0.0; var mb=0.0
    for i in 0..<n: ma+=a[i]; mb+=b[i]
    ma/=float(n); mb/=float(n)
    result.corr = -2
    for lag in -6..6:
      var num=0.0; var da=0.0; var db=0.0
      for i in 0..<n:
        let j=i+lag
        if j<0 or j>=n: continue
        num += (a[i]-ma)*(b[j]-mb); da += (a[i]-ma)*(a[i]-ma); db += (b[j]-mb)*(b[j]-mb)
      let c = (if da>0 and db>0: num/sqrt(da*db) else: 0.0)
      if c > result.corr: result.corr=c; result.lag=lag
  let feH = frameEnergy(mp2kWavCapture)
  var feR = frameEnergy(realDmaCapture)
  # REAL captures a few frames before HLE engages; drop that leading offset so
  # the envelopes are aligned at index 0 before measuring residual lag.
  if feR.len > feH.len: feR = feR[(feR.len - feH.len) ..< feR.len]
  let (lg, cr) = bestLag(feR, feH)   # positive lag => HLE frame trails REAL
  echo "engaged=", emu.mp2k.engaged
  echo "compressed_skipped=", emu.mp2k.compressed_skipped, " compressed_used=", emu.mp2k.dbg_compressed_used
  echo "reverb=", int(emu.mp2k.dbg_reverb), " pcm_rate=", emu.mp2k.dbg_pcm_rate
  echo "masterVol=", dbgMaster
  echo "HLE  : rms=", rms(mp2kWavCapture), " peak=", peak(mp2kWavCapture), " n=", mp2kWavCapture.len, " zcr=", zcr(mp2kWavCapture)
  echo "REAL : rms=", rms(realDmaCapture), " peak=", peak(realDmaCapture), " n=", realDmaCapture.len, " zcr=", zcr(realDmaCapture)
  echo "gain-to-match(rms) = ", (if rms(mp2kWavCapture) > 0: rms(realDmaCapture)/rms(mp2kWavCapture) else: 0.0)
  block:
    proc chrms(s: seq[int16]; off: int): float =
      var acc = 0.0; var n = 0
      var i = off
      while i < s.len: acc += float(s[i])*float(s[i]); n.inc; i += 2
      (if n>0: sqrt(acc/float(n)) else: 0.0)
    echo "REAL A-rms=", chrms(realDmaCapture,0).formatFloat(ffDecimal,2), " B-rms=", chrms(realDmaCapture,1).formatFloat(ffDecimal,2), "  HLE L-rms=", chrms(mp2kWavCapture,0).formatFloat(ffDecimal,2), " R-rms=", chrms(mp2kWavCapture,1).formatFloat(ffDecimal,2)
  echo "HLE  top1%=", top1(mp2kWavCapture).formatFloat(ffDecimal,2), " crest=", (peak(mp2kWavCapture).float/max(1.0,rms(mp2kWavCapture))).formatFloat(ffDecimal,2)
  echo "REAL top1%=", top1(realDmaCapture).formatFloat(ffDecimal,2), " crest=", (peak(realDmaCapture).float/max(1.0,rms(realDmaCapture))).formatFloat(ffDecimal,2)
  echo "frame-env bestLag(REAL->HLE)=", lg, " corr=", cr.formatFloat(ffDecimal,3), " (env_mode=", emu.mp2k.env_mode, ")"
  echo "steps=", dbgStepN, " decimated(>1x)=", dbgStepDecimN, " maxStep=", dbgStepMax
  mp2k_dump_attack()
  mp2k_dump_voices()

main()
