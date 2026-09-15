# MP2K probe harness: boot a (usually patched, tools/mp2kprobe) ROM headless
# with the shadow HLE armed and record, per mixer pass, the DRIVER's own
# mixed output straight from its pcmBuffer ring in RAM — ground truth at the
# engine's sample rate, before the FIFO/DAC — next to the HLE render and the
# per-channel SoundChannel state the driver computed that pass.
#
# Build: nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc \
#          -o:mp2k_probe --path:src tests/mp2k_probe.nim
# Usage: mp2k_probe <rom> <out_prefix> [frames=600]
# Env:   DINGBAT_NOHLE=1            HLE disarmed (engine ground truth only)
#        DINGBAT_PROBE_DRIVE=1      mash A/START (menu-gated titles)
#        DINGBAT_MP2K_RESAMPLE=0|1|2  cubic / linear (the driver's) / hold
#        DINGBAT_MP2K_QUALITY=0     quality tier off: the driver's own arithmetic
#        DINGBAT_GBA_AUDIO_DUMP_FINE=1  with DINGBAT_GBA_AUDIO_DUMP: dump the
#                                 emitted value (DAC sum x32 + quality remainder)
#        DINGBAT_PROBE_ZOH=1        hold-mode FIFO playback (real.wav = buffer verbatim)
#        DINGBAT_PROBE_SCRIPT=path  drive the driver directly: a JSON list of
#                                 writes applied at the END of the named frame
#                                 (so the next pass sees them):
#                                   {"f": 100, "ch": 0, "set": {"status": 128,
#                                    "type": 0, "vr": 127, "vl": 127, "atk": 255,
#                                    "dec": 0, "sus": 255, "rel": 0, "echo_vol": 0,
#                                    "echo_len": 0, "wave": 150995456, "freq": 13379,
#                                    "ct": 0}}
#                                   {"f": 120, "ch": 0, "or": {"status": 64}}
#                                   {"f": 100, "si": {"reverb": 64, "master": 15}}
#                                   {"f": 100, "addr": 50331648, "u8": 5}
#                                 Pair it with a host whose songs are all silent
#                                 (tools/mp2kprobe/rig.py) so the sequencer never
#                                 touches the channels.
#
# Outputs (<out_prefix>.*):
#   engA.s8 / engB.s8  the driver's mixed frames, concatenated in mixer order,
#                      s8 at SoundInfo.pcmFreq, one per FIFO half of pcmBuffer
#                      (mono vintages feed one half; the other is zeros)
#   hle.wav / real.wav 32768 Hz s16 stereo; hle = the HLE render as emitted
#                      (from its frame FIFO), real = the FIFO stream as the
#                      APU reconstructs it. Both span-matched (apu.nim).
#   frames.jsonl       one line per emulated frame: pass count, pcmDmaCounter
#                      at the hook, the slot the driver filled, engine rate /
#                      spv / period / reverb / masterVolume, and every
#                      channel with CH_ON: status, type, vol L/R, env vols,
#                      freq, ct, wave pointer and WaveData header fields.
#
# How the filled slot is found: from pcmDmaCounter read AT THE HOOK (the
# HLE's derivation: period - (cnt - 1), or 0 when cnt <= 1), which holds on
# every vintage whether the V-blank handler decrements the counter before
# the mixer (Minish Cap) or after it (Emerald). A frame without a hook (the
# engine skipped a pass) emits no slot. The slot whose bytes changed since
# the previous frame's snapshot is recorded next to it as a cross-check.
when not defined(mp2kwav):
  {.error: "build with -d:mp2kwav (see the header)".}
import std/[os, strutils, json, streams, tables]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

const
  SI_MAGIC       = 0x00'u32
  SI_DMA_COUNTER = 0x04'u32
  SI_REVERB      = 0x05'u32
  SI_MAX_CHANS   = 0x06'u32
  SI_MASTER_VOL  = 0x07'u32
  SI_DMA_PERIOD  = 0x0B'u32
  SI_SPV         = 0x10'u32
  SI_PCM_RATE    = 0x14'u32
  SI_CHANNELS    = 0x50'u32
  SC_SIZE        = 64'u32
  IDENT_IDLE     = 0x68736D53'u32
  IDENT_LOCK     = 0x68736D54'u32

proc write_wav(path: string; samples: seq[int16]) =
  let f = newFileStream(path, fmWrite)
  let n = samples.len
  f.write("RIFF"); f.write(uint32(36 + n * 2)); f.write("WAVE")
  f.write("fmt "); f.write(uint32(16)); f.write(uint16(1)); f.write(uint16(2))
  f.write(uint32(32768)); f.write(uint32(32768 * 4)); f.write(uint16(4)); f.write(uint16(16))
  f.write("data"); f.write(uint32(n * 2))
  for v in samples: f.write(v)
  f.close()

proc main() =
  let rom_path = paramStr(1)
  let prefix = paramStr(2)
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 600
  let emu = new_gba("", rom_path, run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"
  if emu.mp2k != nil:
    let rs = getEnv("DINGBAT_MP2K_RESAMPLE")
    if rs.len > 0: emu.mp2k.resample_mode = parseInt(rs)
    # DINGBAT_MP2K_QUALITY=0: the driver's own arithmetic (parity checks)
    if getEnv("DINGBAT_MP2K_QUALITY") == "0": emu.mp2k.quality = false
  let drive = getEnv("DINGBAT_PROBE_DRIVE") == "1"
  # DINGBAT_PROBE_ZOH=1: zero-order-hold FIFO playback, so real.wav is the
  # engine buffer verbatim (pipeline check) instead of the cubic reconstruction
  if getEnv("DINGBAT_PROBE_ZOH") == "1": emu.apu.set_fifo_interp(false)

  # Script (see the header): writes keyed by frame
  var script: seq[JsonNode]
  let script_path = getEnv("DINGBAT_PROBE_SCRIPT")
  if script_path.len > 0:
    for n in parseJson(readFile(script_path)): script.add n
  const chan_fields = {"status": 0'u32, "type": 1, "vr": 2, "vl": 3, "atk": 4, "dec": 5,
                       "sus": 6, "rel": 7, "ev": 9, "evr": 10, "evl": 11, "echo_vol": 12,
                       "echo_len": 13, "ct": 24, "freq": 32, "wave": 36}.toTable
  const si_fields = {"reverb": 5'u32, "maxchans": 6, "master": 7}.toTable
  proc apply_script(f: int) =
    let sip = emu.bus.read_word_internal(0x03007FF0'u32)
    for n in script:
      if n["f"].getInt != f: continue
      if n.hasKey("addr"):
        emu.bus.write_byte_internal(uint32(n["addr"].getInt), uint8(n["u8"].getInt))
        continue
      if n.hasKey("si"):
        for k, v in n["si"]:
          emu.bus.write_byte_internal(sip + si_fields[k], uint8(v.getInt))
        continue
      let base = sip + SI_CHANNELS + uint32(n["ch"].getInt) * SC_SIZE
      if n.hasKey("set"):
        for k, v in n["set"]:
          let off = chan_fields[k]
          if off >= 24'u32: emu.bus.write_word_internal(base + off, uint32(v.getInt))
          else: emu.bus.write_byte_internal(base + off, uint8(v.getInt))
      if n.hasKey("or"):
        for k, v in n["or"]:
          let off = chan_fields[k]
          let cur = emu.bus.read_byte_internal(base + off)
          emu.bus.write_byte_internal(base + off, cur or uint8(v.getInt))
  let fj = open(prefix & ".frames.jsonl", fmWrite)
  # DINGBAT_PROBE_RING=1: the whole A half of pcmBuffer after every frame
  # (<prefix>.ring.s8, period*spv bytes per frame) for offline slot scans
  var ring_dump: File = nil
  var ring_hook: File = nil
  if getEnv("DINGBAT_PROBE_RING") == "1":
    ring_dump = open(prefix & ".ring.s8", fmWrite)
    ring_hook = open(prefix & ".ringh.s8", fmWrite)
  var engA, engB: seq[int8]
  var prevA, prevB: seq[uint8]
  var passes = 0
  var slot_off = 0
  var slot_cal = false
  var hle_fires_prev = 0
  var cnt_max = 0
  for f in 0 ..< frames:
    if drive:
      let phase = (f div 8) mod 4
      let btn = (if (f div 32) mod 2 == 0: A else: START)
      emu.keypad.handle_input(btn, phase < 2)
    emu.step_frame()
    let sip = emu.bus.read_word_internal(0x03007FF0'u32)
    if (sip shr 24) != 0x02'u32 and (sip shr 24) != 0x03'u32: continue
    if script.len > 0: apply_script(f)
    let ident = emu.bus.read_word_internal(sip + SI_MAGIC)
    if ident != IDENT_IDLE and ident != IDENT_LOCK: continue
    let spv    = int(emu.bus.read_half_internal(sip + SI_SPV))
    let period0 = int(emu.bus.read_byte_internal(sip + SI_DMA_PERIOD))
    let rate   = int(emu.bus.read_word_internal(sip + SI_PCM_RATE))
    let cnt    = int(emu.bus.read_byte_internal(sip + SI_DMA_COUNTER))
    if spv <= 0 or spv > 2048 or period0 <= 0 or period0 > 16: continue
    # The ring's real length is what the counter cycles through (Castlevania:
    # period byte 2, counter 9..1)
    let cnt_hook = (if dbgHookCnt.len > 0: dbgHookCnt[^1] else: cnt)
    if cnt_hook > cnt_max and cnt_hook <= 16: cnt_max = cnt_hook
    let period = max(period0, cnt_max)
    # pcmBuffer halves from the sound DMAs (the driver programs DMA1SAD/DMA2SAD
    # to the two halves; a mono vintage programs one).
    var baseA, baseB = 0'u32
    for c in 1 .. 2:
      if emu.dma.dmacnt_h[c].enable and emu.dma.dmacnt_h[c].start_timing == 3:
        if emu.dma.dmadad[c] == 0x040000A0'u32: baseA = emu.dma.dmasad[c]
        elif emu.dma.dmadad[c] == 0x040000A4'u32: baseB = emu.dma.dmasad[c]
    if baseA == 0 and baseB == 0: continue
    # The half is PCM_DMA_BUF_SIZE bytes (the distance between the two DMA
    # sources when both run), not necessarily period*spv: Castlevania mixes
    # 704-sample slots at 42 kHz into a 1584-byte half.
    var half = spv * period0
    if baseB > baseA and baseB - baseA <= 8192'u32: half = int(baseB - baseA)
    # A mono vintage feeds one FIFO; the other half of pcmBuffer is still
    # read (engB.s8 then shows what the driver leaves there, which its
    # reverb may sum).
    var unfed_b = false
    if baseB == 0 and baseA != 0:
      baseB = baseA + uint32(half)
      unfed_b = true
    var curA = newSeq[uint8](half)
    var curB = newSeq[uint8](half)
    if baseA != 0:
      for i in 0 ..< half: curA[i] = emu.bus.read_byte_internal(baseA + uint32(i))
    if baseB != 0:
      for i in 0 ..< half: curB[i] = emu.bus.read_byte_internal(baseB + uint32(i))
    # The slot this frame's pass filled. pcmDmaCounter is read AFTER the
    # frame: the V-blank handler decrements it after SoundMain ran, so the
    # pass saw cnt+1 and filled slot period - cnt (verified against the
    # changed-slot detector below: 0 mismatches on Emerald). A silent pass
    # leaves the bytes unchanged, so the counter, not the diff, keys the
    # stream — it stays continuous through silence.
    var changed = 0
    var chslot = -1
    if prevA.len == half:
      let sbc = (if spv * period > half: half div period else: spv)
      for s in 0 ..< half div sbc:
        var diff = false
        for i in s * sbc ..< (s + 1) * sbc:
          if curA[i] != prevA[i] or curB[i] != prevB[i]:
            diff = true; break
        if diff:
          inc changed
          if chslot < 0: chslot = s
    prevA = curA
    prevB = curB
    if ring_dump != nil:
      discard ring_dump.writeBuffer(addr curA[0], half)
      # the same half as the hook saw it (zero-filled when no hook fired)
      var hr = newSeq[uint8](half)
      for i in 0 ..< min(half, dbgHookRing.len): hr[i] = dbgHookRing[i]
      discard ring_hook.writeBuffer(addr hr[0], half)
    # The slot the pass filled, from pcmDmaCounter AT THE HOOK (the HLE's
    # own derivation, mp2k.nim apply_pending): slot = period - (cnt - 1)
    # for cnt >= 2, else 0. Read at the hook it holds on every vintage
    # whether the V-blank handler decrements before the mixer (Minish Cap)
    # or after it (Emerald); `chslot` cross-checks it.
    var slot = (if hle_fires_prev == (if emu.mp2k != nil: emu.mp2k.dbg_hook_fires else: 0): -1
                elif cnt_hook <= 1: 0
                else: period - (cnt_hook - 1))
    # ring slot size: spv, or the half split by the period when spv*period
    # does not fit it (Castlevania: 704-sample mixing, 176-byte DMA slots)
    let sb = (if spv * period > half: half div period else: spv)
    if slot >= 0 and (slot + 1) * sb > half: slot = -1
    hle_fires_prev = (if emu.mp2k != nil: emu.mp2k.dbg_hook_fires else: 0)
    discard slot_off; discard slot_cal
    let hle_slot = (if emu.mp2k != nil: emu.mp2k.rev_slot else: -1)
    let hle_fires = (if emu.mp2k != nil: emu.mp2k.dbg_hook_fires else: 0)
    if slot >= 0:
      inc passes
      for i in slot * sb ..< (slot + 1) * sb:
        engA.add cast[int8](curA[i])
        engB.add cast[int8](curB[i])
    var chans = newJArray()
    let maxc = min(int(emu.bus.read_byte_internal(sip + SI_MAX_CHANS)), 12)
    for i in 0 ..< maxc:
      let b = sip + SI_CHANNELS + uint32(i) * SC_SIZE
      let st = emu.bus.read_byte_internal(b)
      # Off channels are listed too when they still carry envelope bytes
      # (what a killed channel's +0x0A/+0x0B hold after the pass)
      if (st and 0xC7'u8) == 0 and emu.bus.read_half_internal(b + 0x0A) == 0: continue
      let wave = emu.bus.read_word_internal(b + 0x24)
      var wj = newJNull()
      if (wave shr 24) >= 0x08'u32 and (wave shr 24) <= 0x0D'u32:
        wj = %*{"type": int(emu.bus.read_half_internal(wave)),
                "flags": int(emu.bus.read_half_internal(wave + 2)),
                "freq": int(emu.bus.read_word_internal(wave + 4)),
                "loop": int(emu.bus.read_word_internal(wave + 8)),
                "size": int(emu.bus.read_word_internal(wave + 12))}
      chans.add(%*{"i": i, "st": int(st), "ty": int(emu.bus.read_byte_internal(b + 1)),
                   "vr": int(emu.bus.read_byte_internal(b + 2)),
                   "vl": int(emu.bus.read_byte_internal(b + 3)),
                   "atk": int(emu.bus.read_byte_internal(b + 4)),
                   "dec": int(emu.bus.read_byte_internal(b + 5)),
                   "sus": int(emu.bus.read_byte_internal(b + 6)),
                   "rel": int(emu.bus.read_byte_internal(b + 7)),
                   "ev": int(emu.bus.read_byte_internal(b + 9)),
                   "evr": int(emu.bus.read_byte_internal(b + 0x0A)),
                   "evl": int(emu.bus.read_byte_internal(b + 0x0B)),
                   "ct": int(emu.bus.read_word_internal(b + 0x18)),
                   "freq": int(emu.bus.read_word_internal(b + 0x20)),
                   "wave": toHex(wave, 8), "wd": wj})
    let hook_at = (if dbgHookCapIdx.len > 0: dbgHookCapIdx[^1] else: -1)
    # DMA1's source cursor at the hook, as a byte offset into the A half:
    # how far the replay is from the slot the pass is about to fill
    let dma_at = (if dbgHookDmaSrc.len > 0 and baseA != 0: int(dbgHookDmaSrc[^1]) - int(baseA) else: -1)
    fj.writeLine($(%*{"f": f, "pass": passes, "cnt": cnt, "slot": slot,
                      "chslot": chslot, "changed": changed,
                      "hle_slot": hle_slot, "hle_fires": hle_fires,
                      "hook_at": hook_at, "dma_at": dma_at, "half": half, "cnt_hook": cnt_hook, "slot_bytes": sb,
                      "src1": (if dbgHookDmaSrc.len > 0: toHex(dbgHookDmaSrc[^1], 8) else: ""),
                      "src2": (if dbgHookDmaSrc2.len > 0: toHex(dbgHookDmaSrc2[^1], 8) else: ""),
                      "sad1": (if dbgHookSad.len > 0: toHex(dbgHookSad[^1], 8) else: ""),
                      "sad2": (if dbgHookSad2.len > 0: toHex(dbgHookSad2[^1], 8) else: ""),
                      "dad1": toHex(emu.dma.dmadad[1], 8), "dad2": toHex(emu.dma.dmadad[2], 8),
                      "en1": emu.dma.dmacnt_h[1].enable, "en2": emu.dma.dmacnt_h[2].enable,
                      "fifo_level": (if emu.mp2k != nil: emu.mp2k.fifo_w - emu.mp2k.fifo_r else: 0),
                      "predict": (emu.mp2k != nil and emu.mp2k.predict),
                      "pred_ok": (if emu.mp2k != nil: emu.mp2k.pred_ok else: 0),
                      "pred_bad": (if emu.mp2k != nil: emu.mp2k.pred_bad else: 0),
                      "seq_late": (if emu.mp2k != nil: emu.mp2k.seq_late else: 0),
                      "fifo_target": (if emu.mp2k != nil: emu.mp2k.fifo_target else: 0),
                      "lat_avg": (if emu.mp2k != nil: int(emu.mp2k.lat_avg) else: 0),
                      "slot_off": (if emu.mp2k != nil: emu.mp2k.slot_off else: 0),
                      "slot_locked": (emu.mp2k != nil and emu.mp2k.slot_locked),
                      "lat_count": (if emu.mp2k != nil: emu.mp2k.lat_count else: 0),
                      "cap_n": mp2kWavCapture.len div 2,
                      "engaged": (emu.mp2k != nil and emu.mp2k.engaged),
                      "rate": rate, "spv": spv, "period": period,
                      "reverb": int(emu.bus.read_byte_internal(sip + SI_REVERB)),
                      "master": int(emu.bus.read_byte_internal(sip + SI_MASTER_VOL)),
                      "baseA": toHex(baseA, 8), "baseB": toHex(baseB, 8), "unfed_b": unfed_b,
                      "sndh": toHex(emu.bus.read_half_internal(0x04000082'u32), 4),
                      "tm0": int(emu.timer.tmd[0]), "tm1": int(emu.timer.tmd[1]),
                      "dma1_cnt": int(emu.dma.dmacnt_l[1]), "dma2_cnt": int(emu.dma.dmacnt_l[2]),
                      "ch": chans}))
  fj.close()
  if ring_dump != nil: ring_dump.close()
  if ring_hook != nil: ring_hook.close()
  block:
    let fa = open(prefix & ".engA.s8", fmWrite)
    if engA.len > 0: discard fa.writeBuffer(addr engA[0], engA.len)
    fa.close()
    let fb = open(prefix & ".engB.s8", fmWrite)
    if engB.len > 0: discard fb.writeBuffer(addr engB[0], engB.len)
    fb.close()
  write_wav(prefix & ".hle.wav", mp2kWavCapture)
  write_wav(prefix & ".real.wav", realDmaCapture)
  echo $(%*{"frames": frames, "passes": passes, "eng_samples": engA.len,
            "hle_n": mp2kWavCapture.len div 2, "real_n": realDmaCapture.len div 2,
            "engaged": (emu.mp2k != nil and emu.mp2k.engaged),
            "seq_late": (if emu.mp2k != nil: emu.mp2k.seq_late else: 0)})

main()
