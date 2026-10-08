## ARM7 sound (GBATEK "DS Sound"): 16 channels at 0x4000400 + 16n
## (SOUNDxCNT, SAD, TMR, PNT, LEN), SOUNDCNT 0x4000500, SOUNDBIAS 0x4000504,
## two capture units 0x4000508-0x400051F.
##
## Timing. Channel timers count at half the bus clock (16.756991 MHz): a
## channel steps one sample each time its 16-bit timer overflows and reloads
## from SOUNDxTMR. The mixer is evaluated once per 1024 bus cycles (2048
## master cycles, the `evSpuSample` event): every channel and capture timer
## is advanced by 512 counts, then the current sample of each channel goes
## through GBATEK's integer pipeline ("Channel/Mixer Bit-Widths") to a
## 10-bit value per side, the PWM output word.
##
## Output. `samples` holds interleaved stereo float32 (L, R, L, R, ...) at
## SAMPLE_RATE = 33513982 / 1024 = 32728.5 Hz (the "32.768 kHz" of GBATEK,
## nominally). Each value is the 10-bit output minus 0x200, over 512, so the
## default bias is silence at 0.0. Frontends drain it every frame with
## `take_samples` (or read `samples` and `clear_samples`) and resample; if
## nobody drains it the buffer is dropped at MAX_FRAMES.
##
## Memory. Channels fetch sample words and the capture units store words
## through the ARM7 bus: `tick` is generic over the bus and binds
## spu_read32 / spu_write32 at instantiation (bus7.nim defines them for
## Arm7Bus; tests bring their own).
##
## FIFOs (GBATEK's block diagram). A channel reads its sample words ahead of
## playback: the first FIFO_WORDS words during the start delay, then one
## more each time playback moves on a word, following the loop. So a write
## to sample memory is heard only once the read-ahead reaches it, and a
## channel replaying the buffer a capture unit is filling (capture-based
## reverb) hears what was captured one loop earlier instead of feeding
## straight back. The depth (8 words) is Assumed; the loop-late delay was
## compared by running snd_suite in a reference emulator (docs/oracles.md, NDS
## core). Capture stores each word when it is complete (its FIFO not
## modelled).
##
## Repeat modes: 1 loops, 2 is one-shot, 3 ("Prohibited") loops like 1, and
## 0 ("Manual") keeps playing past PNT+LEN through the following memory,
## busy until stopped -- GBATEK names 0 and 3 only; both are Assumed
## (docs/oracles.md, NDS core: the reference emulators disagree).
##
## Not modelled: the 1.05 MHz internal mixer rate (the PWM word is the
## mixer's value at each 1024-cycle tick, so a channel faster than the
## output rate aliases at full level: Assumed), sub-tick start timing (a
## start bit takes effect at the next mixer tick).

import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

const
  FIFO_WORDS* = 8           ## channel read-ahead, words (Assumed)

type
  SpuChannel* = object
    cnt*: uint32            ## SOUNDxCNT (bit 31 = busy, as read back)
    sad*: uint32            ## SOUNDxSAD
    tmr*: uint16            ## SOUNDxTMR
    pnt*: uint16            ## SOUNDxPNT, words
    len*: uint32            ## SOUNDxLEN, words
    active*: bool           ## the timer runs and samples are being played
    ctr*: uint32            ## timer count; a sample step at 0x10000
    pos*: int32             ## current sample; negative = start delay
    output*: int32          ## current sample as PCM16
    adpcm_pcm*, adpcm_index*: int32
    loop_pcm*, loop_index*: int32  ## ADPCM state saved at the loop start
    lfsr*: uint16           ## noise channels 14-15
    fifo*: array[FIFO_WORDS, uint32]  ## sample words read ahead of playback
    sw*: int32              ## stream index of the word being played
    fetched*: int32         ## stream index of the next word to read
    cur_word*: int32        ## word offset from SAD of the word being played

  SpuCapture* = object
    cnt*: uint8             ## SNDCAPxCNT
    dad*: uint32            ## SNDCAPxDAD
    len*: uint16            ## SNDCAPxLEN, words
    ctr*: uint32            ## timer count (runs off SOUND1TMR / SOUND3TMR)
    addr_cur*: uint32
    words_left*: uint32
    acc*: uint32            ## bytes gathered for the next word
    acc_bytes*: int

  Spu* = ref object
    ch*: array[16, SpuChannel]
    soundcnt*: uint16
    bias*: uint16
    cap*: array[2, SpuCapture]
    next_tick*: int64       ## master cycle of the next mixer tick
    samples*: seq[float32]  ## interleaved stereo output, see above
    last_l*, last_r*: uint16  ## most recent 10-bit output words

const
  SPU_TICK_CYCLES* = 2048   ## master cycles per mixer tick (1024 bus cycles)
  SAMPLE_RATE* = 33_513_982.0 / 1024.0
  TIMER_STEP = 512'u32      ## channel timer counts per mixer tick
  MAX_FRAMES = 32768        ## undrained output is dropped beyond this

  FMT_PCM8 = 0'u32
  FMT_PCM16 = 1'u32
  FMT_ADPCM = 2'u32
  FMT_PSG = 3'u32

  ADPCM_TABLE: array[89, int32] = [
    0x0007'i32, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x0010,
    0x0011, 0x0013, 0x0015, 0x0017, 0x0019, 0x001C, 0x001F, 0x0022, 0x0025,
    0x0029, 0x002D, 0x0032, 0x0037, 0x003C, 0x0042, 0x0049, 0x0050, 0x0058,
    0x0061, 0x006B, 0x0076, 0x0082, 0x008F, 0x009D, 0x00AD, 0x00BE, 0x00D1,
    0x00E6, 0x00FD, 0x0117, 0x0133, 0x0151, 0x0173, 0x0198, 0x01C1, 0x01EE,
    0x0220, 0x0256, 0x0292, 0x02D4, 0x031C, 0x036C, 0x03C3, 0x0424, 0x048E,
    0x0502, 0x0583, 0x0610, 0x06AB, 0x0756, 0x0812, 0x08E0, 0x09C3, 0x0ABD,
    0x0BD0, 0x0CFF, 0x0E4C, 0x0FBA, 0x114C, 0x1307, 0x14EE, 0x1706, 0x1954,
    0x1BDC, 0x1EA5, 0x21B6, 0x2515, 0x28CA, 0x2CDF, 0x315B, 0x364B, 0x3BB9,
    0x41B2, 0x4844, 0x4F7E, 0x5771, 0x602F, 0x69CE, 0x7462, 0x7FFF]
  ADPCM_INDEX: array[8, int32] = [-1'i32, -1, -1, -1, 2, 4, 6, 8]

  CNT_MASK = 0xFF7F_837F'u32   ## SOUNDxCNT's writable bits
  DIV_SHIFT = [0, 1, 2, 4]

proc new_spu*(): Spu =
  result = Spu(bias: 0x200)   # SOUNDBIAS after the BIOS ramp
  result.next_tick = SPU_TICK_CYCLES

# ---------------------------------------------------------------------------
# Output buffer

proc sample_count*(s: Spu): int = s.samples.len div 2
  ## Stereo frames waiting in `samples`.

proc clear_samples*(s: Spu) = s.samples.setLen(0)

proc take_samples*(s: Spu): seq[float32] =
  ## Everything produced since the last take, interleaved L/R.
  result = move(s.samples)
  s.samples = newSeqOfCap[float32](2048)

proc wav_bytes*(samples: openArray[float32]): string =
  ## `samples` (interleaved stereo, as produced here) as a 16-bit PCM WAV
  ## file at 32728 Hz, for dumps (tools/ndsrun.nim --wav, tests).
  proc le(d: var string; x: uint32; n: int) =
    for k in 0 ..< n: d.add char((x shr (8 * k)) and 0xFF)
  let rate = uint32(SAMPLE_RATE)
  result = "RIFF"
  result.le(uint32(36 + samples.len * 2), 4)
  result.add "WAVEfmt "
  result.le(16, 4); result.le(1, 2); result.le(2, 2)
  result.le(rate, 4); result.le(rate * 4, 4); result.le(4, 2); result.le(16, 2)
  result.add "data"
  result.le(uint32(samples.len * 2), 4)
  for f in samples:
    result.le(uint32(cast[uint16](int16(clamp(f, -1'f32, 1'f32) * 32767))), 2)

# ---------------------------------------------------------------------------
# Helpers

proc fmt(c: SpuChannel): uint32 {.inline.} = (c.cnt shr 29) and 3
proc repeat_mode(c: SpuChannel): uint32 {.inline.} = (c.cnt shr 27) and 3
proc hold(c: SpuChannel): bool {.inline.} = (c.cnt and 0x8000) != 0

proc vol7(v: uint32): int32 {.inline.} =
  ## 7-bit volume/pan register value N: 0..126 as is, 127 counts as 128.
  if v == 127: 128 else: int32(v)

proc total_samples(c: SpuChannel): int32 {.inline.} =
  ## One-shot length, PNT + LEN, in samples.
  let words = int32(c.pnt) + int32(c.len)
  case c.fmt
  of FMT_PCM8: words * 4
  of FMT_PCM16: words * 2
  else: (words - 1) * 8

proc loop_start(c: SpuChannel): int32 {.inline.} =
  case c.fmt
  of FMT_PCM8: int32(c.pnt) * 4
  of FMT_PCM16: int32(c.pnt) * 2
  else: max(int32(c.pnt) - 1, 0) * 8

proc adpcm_step(c: var SpuChannel; nibble: uint32) {.inline.} =
  ## GBATEK's decode, with the hardware's rounding and clipping.
  let t = ADPCM_TABLE[c.adpcm_index]
  var diff = t shr 3
  if (nibble and 1) != 0: diff += t shr 2
  if (nibble and 2) != 0: diff += t shr 1
  if (nibble and 4) != 0: diff += t
  if (nibble and 8) == 0: c.adpcm_pcm = min(c.adpcm_pcm + diff, 0x7FFF)
  else: c.adpcm_pcm = max(c.adpcm_pcm - diff, -0x7FFF)
  c.adpcm_index = clamp(c.adpcm_index + ADPCM_INDEX[nibble and 7], 0, 88)

proc stream_addr(c: SpuChannel; n: int32): uint32 {.inline.} =
  ## Address of the n-th word the channel reads after a start: the words
  ## from SAD up to PNT+LEN, then (looping) the loop part over and over.
  let total = int32(c.pnt) + int32(c.len)
  var w = n
  if n >= total and c.repeat_mode != 0:
    let lw = if c.fmt == FMT_ADPCM: max(int32(c.pnt), 1) else: int32(c.pnt)
    w = lw + (n - total) mod max(total - lw, 1)
  (c.sad + uint32(w) * 4) and 0x07FF_FFFC'u32

proc fill[B](c: var SpuChannel; bus: B) =
  ## Keep the FIFO FIFO_WORDS words ahead of the word being played.
  mixin spu_read32
  while c.fetched < c.sw + FIFO_WORDS:
    c.fifo[c.fetched and (FIFO_WORDS - 1)] = spu_read32(bus, c.stream_addr(c.fetched))
    inc c.fetched

proc fetch_word[B](c: var SpuChannel; bus: B; wi: int32; looped: bool): uint32 {.inline.} =
  ## The word at offset `wi` (words from SAD) for the sample being played,
  ## from the FIFO. Every change of word -- including a loop back to the
  ## same word -- moves on one stream word and reads one more ahead.
  if wi != c.cur_word or looped:
    inc c.sw
    c.cur_word = wi
    c.fill(bus)
  c.fifo[c.sw and (FIFO_WORDS - 1)]

# ---------------------------------------------------------------------------
# Channels

proc start(s: Spu; i: int) =
  template c: untyped = s.ch[i]
  c.active = true
  c.ctr = c.tmr
  c.sw = 0
  c.fetched = 0
  c.cur_word = 0
  c.lfsr = 0x7FFF
  c.pos = case c.fmt
          of FMT_PSG: -1
          of FMT_ADPCM: -11
          else: -3
  # Hold (GBATEK "Hold Flag"): a held level survives the first delay sample.
  if not c.hold: c.output = 0

proc stop(c: var SpuChannel) =
  ## Start bit written 0.
  c.active = false
  c.output = 0

proc finish(c: var SpuChannel) =
  ## End of a one-shot sound: the last sample stays out while Hold is set.
  c.active = false
  c.cnt = c.cnt and not 0x8000_0000'u32
  if not c.hold: c.output = 0

proc step[B](c: var SpuChannel; i: int; bus: B) =
  ## Advance one sample period.
  inc c.pos
  if c.pos < 0:
    # Start delay: a held level lasts only the first delay sample. The
    # FIFO fills during it (PSG/noise have none).
    c.output = 0
    if c.fetched == 0 and c.fmt != FMT_PSG: c.fill(bus)
    return
  let f = c.fmt
  if f == FMT_PSG:
    if i >= 8 and i <= 13:
      let duty = int32((c.cnt shr 24) and 7)
      let phase = c.pos and 7
      c.output = if duty != 7 and phase >= 7 - duty: 0x7FFF'i32 else: -0x7FFF'i32
    elif i >= 14:
      let carry = (c.lfsr and 1) != 0
      c.lfsr = c.lfsr shr 1
      if carry:
        c.lfsr = c.lfsr xor 0x6000
        c.output = -0x7FFF
      else:
        c.output = 0x7FFF
    else:
      c.output = 0
    if c.pos >= 0x4000_0000: c.pos = c.pos and 7   # PSG runs forever
    return
  let total = c.total_samples
  if int32(c.pnt) + int32(c.len) < 4:
    # GBATEK: PNT+LEN under 4 words hangs the channel -- busy, silent.
    c.output = 0
    c.pos = 0
    return
  var looped = false
  # Mode 0 ("Manual") reads on past the end (Assumed, see the header).
  if c.pos >= total and c.repeat_mode != 0:
    if c.repeat_mode == 2:
      c.finish()
      return
    # Loop: mode 1, and mode 3 ("Prohibited") the same (Assumed).
    c.pos = c.loop_start
    looped = true
    if f == FMT_ADPCM:
      c.adpcm_pcm = c.loop_pcm
      c.adpcm_index = c.loop_index
  case f
  of FMT_PCM8:
    let wd = c.fetch_word(bus, c.pos shr 2, looped)
    let b = (wd shr (uint32(c.pos and 3) * 8)) and 0xFF
    c.output = int32(cast[int8](uint8(b))) shl 8
  of FMT_PCM16:
    let wd = c.fetch_word(bus, c.pos shr 1, looped)
    let h = (wd shr (uint32(c.pos and 1) * 16)) and 0xFFFF
    c.output = int32(cast[int16](uint16(h)))
  else:  # ADPCM
    if c.pos == 0 and not looped:
      let hdr = c.fifo[0]           # stream word 0, read during the delay
      c.adpcm_pcm = int32(cast[int16](uint16(hdr and 0xFFFF)))
      c.adpcm_index = min(int32((hdr shr 16) and 0x7F), 88)
    if c.pos == c.loop_start and not looped:
      # The state a loop restores: what the decoder held arriving here.
      c.loop_pcm = c.adpcm_pcm
      c.loop_index = c.adpcm_index
    let wd = c.fetch_word(bus, 1 + (c.pos shr 3), looped)
    let byte = (wd shr (uint32((c.pos shr 1) and 3) * 8)) and 0xFF
    let nib = if (c.pos and 1) == 0: byte and 0xF else: byte shr 4
    c.adpcm_step(nib)
    c.output = c.adpcm_pcm
  # One-shot: busy clears at the start of the last sample.
  if c.repeat_mode == 2 and c.pos == total - 1:
    c.cnt = c.cnt and not 0x8000_0000'u32

proc advance[B](c: var SpuChannel; i: int; bus: B) =
  c.ctr += TIMER_STEP
  while c.ctr >= 0x10000'u32 and c.active:
    c.ctr = c.ctr - 0x10000'u32 + uint32(c.tmr)
    c.step(i, bus)

# ---------------------------------------------------------------------------
# Capture

proc capture_store[B](s: Spu; x: int; value: int32; bus: B) =
  ## Append one sample (`value` is 16.8 fixed point) to capture unit x.
  mixin spu_write32
  var k = addr s.cap[x]
  let pcm8 = (k.cnt and 8) != 0
  let frac_bits = if pcm8: 16 else: 8
  # GBATEK "Capture Clipping/Rounding": the fraction is dropped, rounding
  # negative values towards zero when its MSB is set.
  var v = value shr frac_bits
  if value < 0 and (value and (1'i32 shl (frac_bits - 1))) != 0: inc v
  if pcm8:
    k.acc = k.acc or ((uint32(v) and 0xFF) shl (k.acc_bytes * 8))
    inc k.acc_bytes
  else:
    k.acc = k.acc or ((uint32(v) and 0xFFFF) shl (k.acc_bytes * 8))
    k.acc_bytes += 2
  if k.acc_bytes < 4: return
  spu_write32(bus, k.addr_cur, k.acc)
  k.acc = 0
  k.acc_bytes = 0
  k.addr_cur += 4
  dec k.words_left
  if k.words_left == 0:
    if (k.cnt and 4) != 0:
      k.cnt = k.cnt and not 0x80'u8          # one-shot: done
    else:
      k.addr_cur = k.dad
      k.words_left = max(uint32(k.len), 1)

proc start_capture(s: Spu; x: int) =
  var k = addr s.cap[x]
  k.addr_cur = k.dad
  k.words_left = max(uint32(k.len), 1)
  k.acc = 0
  k.acc_bytes = 0
  k.ctr = s.ch[1 + 2 * x].tmr

# ---------------------------------------------------------------------------
# Mixer tick

proc pick(sel: uint16; mix, c1, c3: int64): int64 {.inline.} =
  ## SOUNDCNT's left/right output source.
  case sel
  of 0: mix
  of 1: c1
  of 2: c3
  else: c1 + c3

proc clip16_8(v: int64): int32 {.inline.} = int32(clamp(v, -0x80_0000'i64, 0x7F_FFFF'i64))

proc tick*[B](s: Spu; bus: B) =
  ## One mixer tick (1024 bus cycles): advance channels and captures, then
  ## append one stereo output frame.
  let enabled = (s.soundcnt and 0x8000) != 0
  var vol_out: array[16, int64]   ## after volume, 16.11
  if enabled:
    for i in 0 ..< 16:
      if s.ch[i].active: s.ch[i].advance(i, bus)
    for i in 0 ..< 16:
      template c: untyped = s.ch[i]
      if not c.active and not c.hold: c.output = 0   # Hold cleared after the end
      let d = (int64(c.output) shl 4) shr DIV_SHIFT[(c.cnt shr 8) and 3]  # 16.4
      vol_out[i] = d * vol7(c.cnt and 0x7F)                             # 16.11
  let ch1_mix = (s.soundcnt and 0x1000) == 0
  let ch3_mix = (s.soundcnt and 0x2000) == 0
  # Capture's ch(a)+ch(b) addition: ch1 into ch0, ch3 into ch2.
  var add: array[2, bool]
  var cap_chan: array[2, int64]   ## capture input from ch(a), 16.11
  for x in 0..1:
    let a = 2 * x
    let b = a + 1
    add[x] = (s.cap[x].cnt and 0x81) == 0x81
    if add[x]:
      # Capture side: always added (an idle ch(a) contributes 0), wrapping
      # at 16 bits instead of clipping (GBATEK "Overflow Bug").
      let w = (vol_out[a] + vol_out[b]) and 0x7FF_FFFF'i64
      cap_chan[x] = if w >= 0x400_0000'i64: w - 0x800_0000'i64 else: w
    else:
      # "Both Negative Bug": -8000h when ch(a) and ch(b) are both negative.
      cap_chan[x] = if vol_out[a] < 0 and vol_out[b] < 0: -0x8000'i64 shl 11
                    else: vol_out[a]
  # Pan and mix. Each channel's panned output is 16.8 after the strip.
  var mix_l, mix_r: int64
  var c1_l, c1_r, c3_l, c3_r: int64
  for i in 0 ..< 16:
    var v = vol_out[i]
    if (i == 1 and add[0]) or (i == 3 and add[1]):
      continue                                   # heard through ch0 / ch2
    if (i == 0 and add[0]) or (i == 2 and add[1]):
      let b = i + 1
      let b_mix = if b == 1: ch1_mix else: ch3_mix
      v = if s.ch[i].active: v + (if b_mix: vol_out[b] else: 0'i64) else: 0'i64
    let pan = vol7((s.ch[i].cnt shr 16) and 0x7F)
    let l = (v * (128 - pan)) shr 10
    let r = (v * pan) shr 10
    if i == 1: (c1_l = l; c1_r = r)
    if i == 3: (c3_l = l; c3_r = r)
    if (i == 1 and not ch1_mix) or (i == 3 and not ch3_mix): continue
    mix_l += l
    mix_r += r
  # Captures run off ch1 / ch3's timer.
  if enabled:
    for x in 0..1:
      if (s.cap[x].cnt and 0x80) == 0: continue
      let src = if (s.cap[x].cnt and 2) != 0: int32(cap_chan[x] shr 3)
                elif x == 0: clip16_8(mix_l)
                else: clip16_8(mix_r)
      s.cap[x].ctr += TIMER_STEP
      while s.cap[x].ctr >= 0x10000'u32 and (s.cap[x].cnt and 0x80) != 0:
        s.cap[x].ctr = s.cap[x].ctr - 0x10000'u32 + uint32(s.ch[1 + 2 * x].tmr)
        s.capture_store(x, src, bus)
  # Output selectors, master volume, bias, 10-bit clip.
  let master = int64(vol7(s.soundcnt and 0x7F))
  var out_l, out_r: int64
  if enabled:
    out_l = (pick((s.soundcnt shr 8) and 3, mix_l, c1_l, c3_l) * master) shr 21
    out_r = (pick((s.soundcnt shr 10) and 3, mix_r, c1_r, c3_r) * master) shr 21
  s.last_l = uint16(clamp(out_l + int64(s.bias), 0, 0x3FF))
  s.last_r = uint16(clamp(out_r + int64(s.bias), 0, 0x3FF))
  if s.samples.len >= MAX_FRAMES * 2: s.samples.setLen(0)
  s.samples.add (float32(s.last_l) - 512'f32) / 512'f32
  s.samples.add (float32(s.last_r) - 512'f32) / 512'f32

# ---------------------------------------------------------------------------
# Registers (word offsets 0x400..0x51C, byte mask)

proc read_reg*(s: Spu; offset: uint32): uint32 =
  case offset
  of 0x400 .. 0x4FC:
    let c = s.ch[(offset - 0x400) shr 4]
    # SAD, TMR/PNT and LEN are write-only (GBATEK); CNT reads back.
    if (offset and 0xF) == 0: c.cnt else: 0'u32
  of 0x500: uint32(s.soundcnt)
  of 0x504: uint32(s.bias)
  of 0x508: uint32(s.cap[0].cnt) or (uint32(s.cap[1].cnt) shl 8)
  of 0x510: s.cap[0].dad
  of 0x518: s.cap[1].dad
  else: 0'u32   # SNDCAPxLEN write-only

proc write_reg*(s: Spu; offset: uint32; v, mask: uint32) =
  template merge(old: uint32): uint32 = (old and not mask) or (v and mask)
  case offset
  of 0x400 .. 0x4FC:
    let i = int((offset - 0x400) shr 4)
    var c = addr s.ch[i]
    case offset and 0xF
    of 0x0:
      let was = (c.cnt and 0x8000_0000'u32) != 0
      c.cnt = merge(c.cnt) and CNT_MASK
      let now = (c.cnt and 0x8000_0000'u32) != 0
      if now and not was: s.start(i)
      elif was and not now: c[].stop()
    of 0x4: c.sad = merge(c.sad) and 0x07FF_FFFC'u32
    of 0x8:
      let w = merge(uint32(c.tmr) or (uint32(c.pnt) shl 16))
      c.tmr = uint16(w and 0xFFFF)
      c.pnt = uint16(w shr 16)
    else: c.len = merge(c.len) and 0x3F_FFFF'u32
  of 0x500: s.soundcnt = uint16(merge(uint32(s.soundcnt)) and 0xBF7F)
  of 0x504: s.bias = uint16(merge(uint32(s.bias)) and 0x3FF)
  of 0x508:
    let w = merge(uint32(s.cap[0].cnt) or (uint32(s.cap[1].cnt) shl 8))
    for x in 0..1:
      let was = (s.cap[x].cnt and 0x80) != 0
      s.cap[x].cnt = uint8((w shr (8 * x)) and 0x8F)
      if (s.cap[x].cnt and 0x80) != 0 and not was: s.start_capture(x)
  of 0x510: s.cap[0].dad = merge(s.cap[0].dad) and 0x07FF_FFFC'u32
  of 0x514: s.cap[0].len = uint16(merge(uint32(s.cap[0].len)) and 0xFFFF)
  of 0x518: s.cap[1].dad = merge(s.cap[1].dad) and 0x07FF_FFFC'u32
  of 0x51C: s.cap[1].len = uint16(merge(uint32(s.cap[1].len)) and 0xFFFF)
  else: discard

{.pop.}
