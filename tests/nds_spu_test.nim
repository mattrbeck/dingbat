## DS ARM7 sound (src/dingbat/nds/io/spu.nim): channels programmed through
## the registers, the mixer ticked directly against a flat test memory, and
## the 10-bit output words checked against GBATEK's integer pipeline.
## A last check runs the whole machine to see evSpuSample fire at the
## nominal rate. `--wav DIR` writes each case's output as a WAV.
##
## Run with: nimble test_ndsspu

import std/[os, math, strutils]
import dingbat/nds/io/spu
import dingbat/nds/nds

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

# ---------------------------------------------------------------------------
# Test bus: 64 KB of memory at address 0

type TestBus = object
  mem: ref seq[uint8]

proc spu_read32(b: TestBus; a: uint32): uint32 =
  let i = int(a and 0xFFFC)
  uint32(b.mem[i]) or (uint32(b.mem[i + 1]) shl 8) or
    (uint32(b.mem[i + 2]) shl 16) or (uint32(b.mem[i + 3]) shl 24)

proc spu_write32(b: TestBus; a: uint32; v: uint32) =
  let i = int(a and 0xFFFC)
  for k in 0..3: b.mem[i + k] = uint8(v shr (8 * k))

proc new_bus(): TestBus =
  result.mem = new seq[uint8]
  result.mem[] = newSeq[uint8](0x10000)

proc put16(b: TestBus; a: int; v: int) =
  b.mem[a] = uint8(v and 0xFF); b.mem[a + 1] = uint8((v shr 8) and 0xFF)

proc get16(b: TestBus; a: int): int =
  int(cast[int16](uint16(b.mem[a]) or (uint16(b.mem[a + 1]) shl 8)))

# ---------------------------------------------------------------------------
# Register helpers

const
  RATE_TICK = 0x10000 - 512    ## TMR for exactly one sample per mixer tick
  PCM8 = 0'u32
  PCM16 = 1'u32
  ADPCM = 2'u32
  PSG = 3'u32
  LOOP = 1'u32
  ONESHOT = 2'u32

proc wr(s: Spu; off: uint32; v: uint32) = s.write_reg(off, v, 0xFFFF_FFFF'u32)

proc master(s: Spu; vol = 127'u32) = s.wr(0x500, 0x8000'u32 or vol)

proc play(s: Spu; ch: int; fmt, repeat: uint32; sad: uint32; tmr = RATE_TICK;
          pnt = 0; len = 0; vol = 127'u32; pan = 64'u32; duty = 0'u32; divi = 0'u32;
          hold = false) =
  let base = 0x400'u32 + uint32(ch) * 16
  s.wr(base + 4, sad)
  s.wr(base + 8, uint32(tmr) or (uint32(pnt) shl 16))
  s.wr(base + 12, uint32(len))
  s.wr(base, vol or (divi shl 8) or (if hold: 0x8000'u32 else: 0) or (pan shl 16) or (duty shl 24) or (repeat shl 27) or
             (fmt shl 29) or 0x8000_0000'u32)

proc run(s: Spu; bus: TestBus; ticks: int): seq[(int, int)] =
  ## One (L, R) 10-bit pair per mixer tick.
  for _ in 0 ..< ticks:
    s.tick(bus)
    result.add((int(s.last_l), int(s.last_r)))

proc expect_out(data, vol, pan, master: int; right: bool; divi = 0): int =
  ## GBATEK "Channel/Mixer Bit-Widths", one channel, plus default bias.
  let v = if vol == 127: 128 else: vol
  let p0 = if pan == 127: 128 else: pan
  let p = if right: p0 else: 128 - p0
  let m = if master == 127: 128 else: master
  let ch = ((((data shl 4) shr [0, 1, 2, 4][divi]) * v * p) shr 10)
  clamp(((ch * m) shr 21) + 0x200, 0, 0x3FF)

var wav_dir = ""

proc write_wav(name: string; s: seq[float32]) =
  if wav_dir.len > 0: writeFile(wav_dir / name & ".wav", wav_bytes(s))

# ---------------------------------------------------------------------------

proc test_pcm8_ramp() =
  echo "PCM8 ramp, one-shot, 3-sample start delay, busy at last sample"
  let bus = new_bus()
  for i in 0 ..< 64: bus.mem[0x100 + i] = uint8(cast[uint8](int8(i * 4 - 128)))
  let s = new_spu()
  s.master()
  s.play(0, PCM8, ONESHOT, 0x100, pnt = 0, len = 16, pan = 0)   # 64 samples
  let o = s.run(bus, 70)
  check o[0][0] == 0x200 and o[1][0] == 0x200, "silent during the start delay",
        $o[0] & " " & $o[1]
  var ok = true
  var bad = ""
  for k in 0 ..< 64:
    let want = expect_out((k * 4 - 128) shl 8, 127, 0, 127, false)
    if o[k + 2][0] != want: (ok = false; bad = "k=" & $k & " got " & $o[k + 2][0] & " want " & $want)
  check ok, "64 ramp samples through the pipeline", bad
  check o[2][1] == 0x200, "pan 0 is silent on the right"
  check o[66][0] == 0x200, "silent after the one-shot ends", $o[66]
  check (s.read_reg(0x400) and 0x8000_0000'u32) == 0, "busy clear after the end"
  # Busy clears at the start of the last sample.
  let s2 = new_spu()
  s2.master()
  s2.play(0, PCM8, ONESHOT, 0x100, len = 16)
  for _ in 0 ..< 65: s2.tick(bus)       # sample 62 playing
  let before = (s2.read_reg(0x400) and 0x8000_0000'u32) != 0
  s2.tick(bus)                           # sample 63, the last
  let at_last = (s2.read_reg(0x400) and 0x8000_0000'u32) != 0
  check before and not at_last, "busy drops when the last sample begins"
  write_wav("pcm8_ramp", s.take_samples())
  # Hold keeps the last sample out after a one-shot, until Hold is cleared.
  let s3 = new_spu()
  s3.master()
  s3.play(0, PCM8, ONESHOT, 0x100, len = 16, pan = 0, hold = true)
  let h = s3.run(bus, 70)
  let last = expect_out((63 * 4 - 128) shl 8, 127, 0, 127, false)
  check h[66][0] == last and h[69][0] == last, "Hold keeps the last sample", $h[66]
  s3.wr(0x400, s3.read_reg(0x400) and not 0x8000'u32)
  check s3.run(bus, 1)[0][0] == 0x200, "clearing Hold silences it"

proc test_pcm16_loop() =
  echo "PCM16 loop, volume divider, panning, half rate"
  let bus = new_bus()
  # 4 words: samples 1000, -1000, 2000, -2000, 3000, -3000, 4000, -4000;
  # loop start at word 2 (sample 4).
  let vals = [1000, -1000, 2000, -2000, 3000, -3000, 4000, -4000]
  for i, v in vals: bus.put16(0x200 + i * 2, v)
  let s = new_spu()
  s.master(100)
  s.play(3, PCM16, LOOP, 0x200, pnt = 2, len = 2, vol = 90, pan = 100, divi = 2)
  let o = s.run(bus, 2 + 8 + 8)
  var seq_ok = true
  let order = [0, 1, 2, 3, 4, 5, 6, 7, 4, 5, 6, 7, 4, 5, 6, 7]
  for k, idx in order:
    let l = expect_out(vals[idx], 90, 100, 100, false, 2)
    let r = expect_out(vals[idx], 90, 100, 100, true, 2)
    if o[k + 2] != (l, r): seq_ok = false
  check seq_ok, "plays 0..7 then loops 4..7 with vol/div/pan/master", $o[2 .. 9]
  # Half rate: TMR = -1024 steps a sample every second tick.
  let s2 = new_spu()
  s2.master()
  s2.play(0, PCM16, LOOP, 0x200, tmr = 0x10000 - 1024, len = 4)
  let h = s2.run(bus, 12)
  check h[5] == h[6] and h[7] == h[8] and h[5] != h[7], "TMR -1024 holds each sample two ticks",
        $h
  write_wav("pcm16_loop", s.take_samples())

proc adpcm_encode(pcm: openArray[int]; start_pcm, start_index: int): seq[uint8] =
  ## Reference IMA-ADPCM encoder (header + nibbles) using the DS's decode
  ## rules, so the decoder's output is predictable exactly.
  const tbl = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]
  const idx = [-1, -1, -1, -1, 2, 4, 6, 8]
  result = @[uint8(start_pcm and 0xFF), uint8((start_pcm shr 8) and 0xFF),
             uint8(start_index), 0'u8]
  var p = start_pcm
  var x = start_index
  var cur = 0'u8
  for i, target in pcm:
    # Pick the nibble whose decoded value lands closest (exhaustive, 16 tries).
    var best = 0
    var best_err = high(int)
    var best_p = 0
    for n in 0 .. 15:
      let t = tbl[x]
      var d = t shr 3
      if (n and 1) != 0: d += t shr 2
      if (n and 2) != 0: d += t shr 1
      if (n and 4) != 0: d += t
      let np = if (n and 8) == 0: min(p + d, 0x7FFF) else: max(p - d, -0x7FFF)
      if abs(np - target) < best_err: (best_err = abs(np - target); best = n; best_p = np)
    p = best_p
    x = clamp(x + idx[best and 7], 0, 88)
    if (i and 1) == 0: cur = uint8(best)
    else: result.add(cur or uint8(best shl 4))

proc adpcm_decode(data: openArray[uint8]; count: int): seq[int] =
  ## Mirror decode for the expected values.
  const tbl = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]
  const idx = [-1, -1, -1, -1, 2, 4, 6, 8]
  var p = int(cast[int16](uint16(data[0]) or (uint16(data[1]) shl 8)))
  var x = int(data[2])
  for i in 0 ..< count:
    let b = data[4 + i div 2]
    let n = int(if (i and 1) == 0: b and 0xF else: b shr 4)
    let t = tbl[x]
    var d = t shr 3
    if (n and 1) != 0: d += t shr 2
    if (n and 2) != 0: d += t shr 1
    if (n and 4) != 0: d += t
    p = if (n and 8) == 0: min(p + d, 0x7FFF) else: max(p - d, -0x7FFF)
    x = clamp(x + idx[n and 7], 0, 88)
    result.add p

proc test_adpcm() =
  echo "IMA-ADPCM: 11-sample delay, decode, loop restores the loop-point state"
  # A 440-ish Hz sine over 8 words of nibbles (64 samples).
  var wave: seq[int]
  for i in 0 ..< 64: wave.add int(round(12000 * sin(2 * PI * float(i) / 16)))
  let enc = adpcm_encode(wave, 0, 56)
  check enc.len == 4 + 32, "encoded block is a header word + 8 data words"
  let bus = new_bus()
  for i, b in enc: bus.mem[0x400 + i] = b
  let dec = adpcm_decode(enc, 64)
  var max_err = 0
  for i in 0 ..< 64: max_err = max(max_err, abs(dec[i] - wave[i]))
  check max_err < 3000, "encoder tracks the sine", "max err " & $max_err
  let s = new_spu()
  s.master()
  # PNT = 5 words (header + 4 words: loop at sample 32), LEN = 4 words.
  s.play(5, ADPCM, LOOP, 0x400, pnt = 5, len = 4, pan = 0)
  let o = s.run(bus, 10 + 64 + 64)
  check o[9][0] == 0x200, "still silent at the 10th tick (11-sample delay)"
  var ok = true
  var bad = ""
  for k in 0 ..< 64:
    let want = expect_out(dec[k], 127, 0, 127, false)
    if o[10 + k][0] != want: (ok = false; bad = "k=" & $k & " got " & $o[10 + k][0] & " want " & $want)
  check ok, "64 decoded samples through the pipeline", bad
  ok = true
  for k in 0 ..< 64:
    let want = expect_out(dec[32 + (k mod 32)], 127, 0, 127, false)
    if o[74 + k][0] != want: (ok = false; bad = "k=" & $k & " got " & $o[74 + k][0] & " want " & $want)
  check ok, "two loops replay samples 32..63 exactly (state restored)", bad
  # Direct: the channel's decoder state after a loop equals the saved state.
  check s.ch[5].loop_pcm == dec[31] and s.ch[5].loop_index >= 0,
        "loop state is the decoder state arriving at the loop start",
        $s.ch[5].loop_pcm & " vs " & $dec[31]
  write_wav("adpcm", s.take_samples())

proc test_psg() =
  echo "PSG square duty (ch 8-13), noise LFSR (ch 14-15)"
  let bus = new_bus()
  for duty in 0'u32 .. 7:
    let s = new_spu()
    s.master()
    s.play(8, PSG, 0, 0, duty = duty, pan = 127)
    let o = s.run(bus, 16)
    let hi = expect_out(0x7FFF, 127, 127, 127, true)
    let lo = expect_out(-0x7FFF, 127, 127, 127, true)
    var pat = ""
    for k in 0 ..< 16: pat.add(if o[k][1] == hi: '-' elif o[k][1] == lo: '_' else: '?')
    let n = int(duty)
    var want = ""
    for k in 0 ..< 16: want.add(if n != 7 and (k and 7) >= 7 - n: '-' else: '_')
    check pat == want, "duty " & $duty & " " & pat, "want " & want
  # PSG on a PCM-only channel is silent.
  let s0 = new_spu()
  s0.master()
  s0.play(2, PSG, 0, 0, duty = 3)
  let z = s0.run(bus, 20)
  check z[19] == (0x200, 0x200), "PSG mode on channel 2 is silent"
  # Square at a musical rate for the WAV: 440 Hz = sample rate 3520 Hz.
  let sw = new_spu()
  sw.master(64)
  sw.play(9, PSG, 0, 0, tmr = 0x10000 - int(round(16_756_991.0 / 3520)), duty = 3)
  discard sw.run(bus, 32768)
  write_wav("psg_square_440", sw.take_samples())
  # Noise: X=7FFFh; X>>=1, carry -> LOW and X^=6000h, else HIGH.
  let s = new_spu()
  s.master()
  s.play(14, PSG, 0, 0, pan = 127)
  let o = s.run(bus, 200)
  var x = 0x7FFF
  var ok = true
  for k in 0 ..< 200:
    let carry = (x and 1) != 0
    x = x shr 1
    var want: int
    if carry:
      x = x xor 0x6000
      want = expect_out(-0x7FFF, 127, 127, 127, true)
    else:
      want = expect_out(0x7FFF, 127, 127, 127, true)
    if o[k][1] != want: ok = false
  check ok, "200 noise samples follow the LFSR"
  let sn = new_spu()
  sn.master(64)
  sn.play(15, PSG, 0, 0, tmr = 0x10000 - 1024)
  discard sn.run(bus, 32768)
  write_wav("noise", sn.take_samples())

proc test_control() =
  echo "SOUNDCNT: master enable, output selectors, ch1/ch3 to mixer; SOUNDBIAS"
  let bus = new_bus()
  for i in 0 ..< 32: bus.put16(0x300 + i * 2, 0x4000)
  let s = new_spu()
  s.play(0, PCM16, LOOP, 0x300, len = 8, pan = 0)
  s.play(1, PCM16, LOOP, 0x300, len = 8, pan = 0, vol = 64)
  var o = s.run(bus, 6)
  check o[5] == (0x200, 0x200), "master disabled: bias only"
  s.wr(0x504, 0x180)
  o = s.run(bus, 1)
  check o[0] == (0x180, 0x180), "SOUNDBIAS applies even when disabled"
  s.wr(0x504, 0x200)
  s.master()
  o = s.run(bus, 5)
  let a = expect_out(0x4000, 127, 0, 127, false) - 0x200
  let b = expect_out(0x4000, 64, 0, 127, false) - 0x200
  check o[4][0] == 0x200 + a + b, "mixer sums ch0 + ch1", $o[4] & " want " & $(0x200 + a + b)
  s.wr(0x500, 0x8000'u32 or 127 or 0x1000)
  o = s.run(bus, 1)
  check o[0][0] == 0x200 + a, "bit 12 takes ch1 out of the mixer", $o[0]
  s.wr(0x500, 0x8000'u32 or 127 or 0x1000 or (1 shl 8))
  o = s.run(bus, 1)
  check o[0][0] == 0x200 + b, "left output from ch1 alone (bit 12 doesn't mute it there)", $o[0]
  s.wr(0x500, 0x8000'u32 or 127 or (3 shl 8))
  o = s.run(bus, 1)
  check o[0][0] == 0x200 + b, "left = ch1 + ch3 (ch3 idle)", $o[0]
  # Full scale clips to 0..3FFh: 16 channels at max on one side.
  let f = new_spu()
  f.master()
  for i in 0 ..< 8: bus.put16(0x380 + i * 2, 0x7FFF)
  for c in 0 ..< 16: f.play(c, PCM16, LOOP, 0x380, len = 4, pan = 0)
  o = f.run(bus, 5)
  check o[4][0] == 0x3FF, "sixteen full-scale channels clip at 3FFh"
  # Register readback masks.
  check f.read_reg(0x404) == 0 and f.read_reg(0x408) == 0, "SAD/TMR read as zero (write-only)"
  f.wr(0x500, 0xFFFF_FFFF'u32)
  check f.read_reg(0x500) == 0xBF7F, "SOUNDCNT unused bits read zero", toHex(f.read_reg(0x500))
  f.wr(0x400, 0x7FFF_FFFF'u32)
  check f.read_reg(0x400) == 0x7F7F_837F'u32, "SOUNDxCNT unused bits read zero",
        toHex(f.read_reg(0x400))

proc test_capture() =
  echo "Capture: mixer to PCM16 / PCM8 memory, one-shot and loop, ch(a) source"
  let bus = new_bus()
  for i in 0 ..< 16: bus.put16(0x500 + i * 2, (i - 8) * 0x800)
  let s = new_spu()
  s.master()
  # Channel 0 plays a 16-sample ramp at one sample per tick, panned hard left.
  s.play(0, PCM16, LOOP, 0x500, len = 8, pan = 0)
  # Capture 0 (left mixer, PCM16, one-shot, 8 words = 16 samples) on ch1's
  # timer, same rate; ch1 itself stays silent.
  s.wr(0x418, uint32(RATE_TICK))
  s.wr(0x510, 0x1000)
  s.wr(0x514, 8)
  discard s.run(bus, 2)                   # ch0 inside its start delay
  s.wr(0x508, 0x80 or 0x04)
  discard s.run(bus, 20)
  var ok = true
  var got: seq[int]
  for k in 0 ..< 16:
    got.add bus.get16(0x1000 + k * 2)
    if got[k] != ((k - 8) * 0x800 * 128 * 128) shr 14: ok = false
  check ok, "PCM16 capture of the left mixer is the ramp", $got
  check (s.read_reg(0x508) and 0x80) == 0, "one-shot capture clears its busy bit"
  check bus.get16(0x1020) == 0, "stops at SNDCAP0LEN"
  # PCM8, looping, from channel 2 (capture 1, bit 1), ch3 timer at half rate.
  let s2 = new_spu()
  s2.master()
  s2.play(2, PCM16, LOOP, 0x500, len = 8, pan = 64, tmr = 0x10000 - 1024)
  s2.wr(0x438, uint32(0x10000 - 1024))
  s2.wr(0x518, 0x2000)
  s2.wr(0x51C, 1)                         # 1 word = 4 PCM8 samples, looped
  discard s2.run(bus, 6)                  # ch2 delay = 6 ticks at half rate
  s2.wr(0x508, (0x80 or 0x08 or 0x02) shl 8)
  discard s2.run(bus, 2 * 8)
  var b8: seq[int]
  for k in 0 ..< 4: b8.add int(cast[int8](bus.mem[0x2000 + k]))
  # The first capture lands on ch2's next sample (1); eight samples into a
  # one-word loop leave the second word, samples 5..8, in place.
  let want8 = @[(5 - 8) * 8, (6 - 8) * 8, (7 - 8) * 8, (8 - 8) * 8]
  check b8 == want8, "PCM8 looped capture of channel 2 wraps at SNDCAP1LEN", $b8 & " want " & $want8
  check bus.mem[0x2004] == 0, "nothing past the loop"

proc test_machine() =
  echo "Machine: evSpuSample runs once per 2048 master cycles"
  let n = new_nds(cast[seq[uint8]](readFile(currentSourcePath.parentDir / "nds/roms/fb_both.nds")),
                  @[], @[], @[])
  n.run_frame()
  n.spu.clear_samples()
  for _ in 0 ..< 30: n.run_frame()
  let frames = n.spu.sample_count
  let want = 30.0 * float(FRAME_CYCLES) / float(SPU_TICK_CYCLES)
  check abs(float(frames) - want) <= 2, "30 frames give 547.06 samples each",
        $frames & " vs " & $want
  check n.spu.samples.len > 0 and n.spu.samples[0] == 0'f32, "idle output is silence"

when isMainModule:
  let args = commandLineParams()
  for i, a in args:
    if a == "--wav" and i + 1 < args.len: wav_dir = args[i + 1]
  test_pcm8_ramp()
  test_pcm16_loop()
  test_adpcm()
  test_psg()
  test_control()
  test_capture()
  test_machine()
  if failures > 0:
    echo failures, " failure(s)"
    quit(1)
  echo "all passed"
