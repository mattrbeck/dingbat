# =============================================================================
# Camelot "Bon" sound-driver HLE for Golden Sun  (included by gba.nim)
# =============================================================================
# Shadow-mode HLE of the custom high-quality PCM mixer Camelot ships in Golden
# Sun (and siblings). Off by default (the "Improve audio quality" setting; the
# shared gba.mp2k_hle flag). The game uses the STOCK m4a/MP2K sequencer and
# SoundInfo/SoundChannel work area (ident "Smsh" at the usual SOUND_INFO_PTR
# slot 0x03007FF0) but replaces SoundMain/SoundMainRAM with its own mixer, so:
#   * the m4a lock (ident+1) is NEVER taken -> the MP2K HLE's lock-based hook
#     learning never engages on these games (verified; mutual exclusion is
#     structural, not coordinated), and
#   * the envelope/volume outputs the MP2K HLE consumes (SoundChannel
#     envelopeVolumeRight/Left at +0x0A/+0x0B) are never written -> this HLE
#     computes per-side gains from the raw fields instead (see gs_on_frame).
#
# Provenance / license (clean-room; this emulator is MIT):
#   * pret decompilations include/gba/m4a_internal.h — SoundInfo / SoundChannel
#     / WaveData struct layouts (Golden Sun uses the stock layouts; verified at
#     runtime with this project's own probes).
#   * ipatix/gba-hq-mixer (MIT) — documentation of this mixer family's
#     techniques (it is an RE-derived reimplementation of the Camelot mixer);
#     consulted for facts, no code copied.
#   * This project's OWN runtime probing + disassembly of the game's IWRAM
#     mixer copy (scratch_gs_probe/scratch_gs_trace): frame flow, the
#     per-channel envelope algorithm, the vol*env>>9 per-side gain, the mixer
#     entry offset, and the stable-region fingerprint below all come from that
#     first-party RE.
#   * GBATEK — DirectSound FIFO/DMA hardware facts.
# No GPL/LGPL emulator or player source was used for code.
#
# Driver facts established by our probes (GS1 USA):
#   * SOUND_INFO_PTR 0x03007FF0 -> SoundInfo at 0x02003050 (EWRAM), ident
#     0x68736D53 "Smsh" — never locked/incremented.
#   * maxChans=8, masterVolume=15, reverb=50, freq idx 7 -> pcmFreq 21024 Hz,
#     pcmSamplesPerVBlank=352, pcmDmaPeriod=4.
#   * DMA1 -> FIFO A from SoundInfo+0x350; DMA2 -> FIFO B from
#     SoundInfo+0x350+0x630 (s8 stereo double buffers, 4-frame ring).
#   * The mixer is ARM/Thumb code copied at boot from ROM (GS1: file 0x770,
#     0xC88 bytes) to IWRAM 0x03000000. Bytes 0x380..0x828 of that block are
#     never modified at runtime (the self-modifying inner loops start at
#     exactly +0x828) — that range is the detection fingerprint. The
#     per-channel processing (envelope + setup, Thumb) starts at +0x658 and is
#     entered exactly once per frame from the game's VBlank handler with
#     r0=chan count, r1=DMA quarter index, r2=quarter byte offset; channel
#     START bits are still intact there and envelopes are PRE-update, so the
#     hook replicates the driver's per-frame ADSR step in shadow (see
#     gs_env_step) instead of consuming driver-computed values.
#   * Per-channel envelope (from our disassembly of the +0x658 code): stock
#     m4a statusFlags semantics (START 0x80 / STOP 0x40 / LOOP 0x10 / IEC 0x04
#     / phase 0..3), attack additive, decay/release multiplicative (x/256),
#     pseudo-echo hold at pseudoEchoVolume for pseudoEchoLength frames; note-on
#     sets ct=WaveData.size, currentPointer=data, env=0 and applies the attack
#     step the same frame. Per-side gain = sideVolume * env >> 9 (0..63).
#   * Channel frequency (+0x20) is the playback rate in integer Hz; the
#     mixer's resample step is freq * SoundInfo.divFreq (+0x18) in 9.23 fixed
#     point per source sample (divFreq 399 for 21024 Hz — ~143 ppm sharp of
#     nominal; the HLE replicates the integer product to stay phase-locked).
#   * SYNTH instruments: WaveData with size==0 && loopStart==0. The sample
#     data area then describes an oscillator: data[1] selects 0=duty-modulated
#     square, 1=sawtooth, else triangle; the oscillator period corresponds to
#     64 source samples at the channel frequency. The exact generators (from
#     our disassembly of the IWRAM block at +0xC8C..+0xDF4; the mixer stores
#     the modulation/shaper state in the channel's ct field (+0x18) and the
#     32-bit phase in +0x1C):
#       - square: output = +-(sideVol << 6) in mix-buffer units (i.e. a
#         SYMMETRIC square at s8 amplitude +-64, full per-side volume, no
#         duty-dependent level). High-for-phase < threshold, where the 32-bit
#         threshold is recomputed once per frame:
#           acc  += data[3]                          (u8 step, wraps)
#           u     = acc + data[5]                    (u8 phase offset)
#           fold  = u >= 128 ? (255-u)<<16 | 0xFFFF : u<<16   ("mvnmi" fold)
#           thresh = fold * data[4] + data[2]<<24    (u32, WRAPS mod 2^32)
#         so duty = base/256 + tri(acc)*depth/256 with tri in [0, 0.5), a
#         triangle of period 256/step frames (data[3]=0xF0 == -16 -> the
#         16-frame modulation heard in GS1's square0).
#       - saw: r9 = (p>>24) - 112 - ((p>>26)&31)  (a 4x-rate mini-saw rides
#         the main ramp), shaped through r2 = r9 + (r2 asr 1) at the SOURCE
#         rate (one update per driver output sample), contribution =
#         (sideVol>>1) * r2 -> s8 amplitude r2/2 (about +-125).
#       - triangle: p < 2^31 ? (p>>23) - 128 : 384 - (p>>23), contribution =
#         sideVol * value -> s8 amplitude +-128 at full per-side volume.
#   * Camelot 4-bit ADPCM (negative WaveData.size; Mario Tennis) is NOT
#     handled yet (Mario Tennis only).
#   * Reverb (from our disassembly of the IWRAM block's output loop at
#     +0xB60..+0xC78): after clamping, the mixer packs each frame's 16-bit
#     mix buffer (one word per stereo frame, low half = left) into s8 bytes
#     (value >> 7) for the two FIFO DMA ring buffers, READING the old bytes
#     it overwrites (output of pcmDmaPeriod frames ago) first — and then
#     stores back into the mix buffer the seed the NEXT frame's channels
#     will accumulate onto:
#       seedL[i] = mixL[i] >> A  +  oldR[i]_as_s15 >> B   (+bias if negative)
#       seedR[i] = mixR[i] >> A  +  oldL[i]_as_s15 >> B
#     i.e. a two-tap feedback: a same-side tap one frame back (gain 2^-(A-16))
#     and a CROSS-CHANNEL tap pcmDmaPeriod+1 frames back (gain 2^-(B-17)),
#     the latter quantized through the s8 FIFO byte. The shift amounts are
#     RUNTIME-PATCHED CODE, not data — GS1 rewrites the eight asr-pair slots
#     per context (observed live: title A=19,B=18 -> 1/8 + 1/2; in-game
#     Vale A=18,B=19 -> 1/4 + 1/4; ROM copy default 1/4 + 1/4). The HLE
#     therefore parses the gains from the live instructions every frame
#     (gs_parse_reverb) instead of hardcoding a mapping; unrecognized
#     opcodes there disable reverb (safe non-engagement). SoundInfo.reverb
#     (50) is NOT consulted by this code path at mix time.
#     [Corroboration: ipatix/gba-hq-mixer (MIT) documents this driver
#     family's buffer-feedback reverb design; agbplay documents distinct
#     'gs1'/'gs2' reverb models for these games — facts only, no code.]

const
  GS_SOUNDINFO_PTR_ADDR = 0x03007FF0'u32
  GS_IDENT              = 0x68736D53'u32   # "Smsh" (stock m4a ident, never locked here)
  GS_MAX_CHANNELS       = 12               # sampler slots (>= any build's maxChans)
  GS_REV_SLOT_LEN       = 1024             # real-reverb ring slot capacity (stereo samples)

type GsBonBuild = object
  ## Per-build (per-ROM) constants for one known Bon-driver build: the
  ## code fingerprint of its IWRAM mixer copy, the locations the HLE
  ## hooks/parses inside that copy, and the build's envelope/mixer
  ## semantics. One row per build; ROMs whose block matches no row are left
  ## alone (safe non-engagement) — do NOT guess values for builds that were
  ## not probed on real dumps.
  ##
  ## POSITION-INDEPENDENT: detection SCANS IWRAM for the fingerprint region
  ## (word-aligned prefilter compare, CRC on hits) instead of checking a
  ## fixed address, and every code location is an OFFSET from the match
  ## base (g.fp_addr). Regional builds of the same driver link the
  ## byte-identical mixer block at different IWRAM addresses (their IWRAM
  ## data layouts differ); a rigid relocation moves every internal offset
  ## together, so a CRC match at any base inherits the build's verified
  ## semantics wholesale.
  name:     string
  fp_len:   int      # length of the never-runtime-modified code range
                     # (the CRC window)
  fp_first: uint32   # first word of the range (the scan's cheap prefilter)
  fp_crc:   uint32   # CRC-32 (IEEE reflected) of the range
  entry_off: uint32  # per-channel processing entry PC as an offset from the
                     # fingerprint base (Thumb bit set to match cpu.tick's
                     # PC-with-thumb-bit compare)
  max_chans: int     # the build's PCM channel count (<= GS_MAX_CHANNELS)
  # Reverb model (see the header): grmParsedShift live-parses the runtime-
  # patched asr instructions at rev_insn (GS1).
  # Builds that were not probed on real dumps never reach this path
  # (fingerprint non-match = non-engagement); do NOT guess addresses.
  rev_model: GsRevModel
  rev_insn_off: uint32 # grmParsedShift: first reverb-coefficient instruction
                       # pair ("asrs rX, rY, #A / adds rX, rX, rZ, asr #B"),
                       # offset from the fingerprint base (0 = none)
  # Output calibration (A/B vs the real FIFO on the build's title music):
  db_delay_frames: float32  # double-buffer latency, video frames
  makeup: float32           # grmParsedShift output makeup gain on the
                            # *128 FIFO-latch mapping

const GS_BUILDS = [
  # Golden Sun (USA) — all values from our own runtime probes/disassembly of
  # the live IWRAM block (block copied from ROM file offset 0x770, 0xC88
  # bytes; USA links it at 0x03000000 with the fingerprint region at block
  # +0x380; self-modifying inner loops start at +0x828).
  #
  # Regional coverage (2026-07 archive survey, whole-block byte compare of
  # the ROM's boot-copy source + boot A/B verification of title music):
  #   * (UE)/[!], (F), (G), (I), (S): whole 0xC88 block BYTE-IDENTICAL to
  #     USA (same file offset 0x770); title A/B numbers identical to USA.
  #   * Ougon no Taiyou - Hirakareshi Fuuin (J): block identical except ONE
  #     instruction at block+0x214 — `add ip, r0, #0x1C` -> `#0x18`, the
  #     entry-count bound of a bitmask-driven byte-store utility at
  #     +0x214..+0x24C (14 -> 12 table entries). That utility is sequencer-
  #     side (upstream of the channel RAM both the real mixer and this
  #     shadow consume) and outside every code path the HLE reads/parses;
  #     title A/B verified equal to the USA baseline (ratio 0.97/1.00,
  #     corr 0.69/0.71 — USA's own title numbers).
  #   * Translation patches of these bases (Polish UE, Chinese J) leave the
  #     mixer block untouched and verify identically.
  GsBonBuild(name: "GS1",
             fp_len: 0x4A8,
             fp_first: 0xE020C001'u32, fp_crc: 0x7CB231AD'u32,
             entry_off: 0x2D9'u32,            # block +0x658 | Thumb
             max_chans: 8,
             rev_model: grmParsedShift,
             rev_insn_off: 0x858'u32,         # block +0xBD8: real reverb,
                                              # live-parsed coefficients
             db_delay_frames: 1.0'f32,
             makeup: 1.0'f32),                # the *128 mapping is exact for GS1
  # Mario Golf: Advance Tour / Mario Tennis: Power Tour ship a RELATED but
  # different build of this driver family. They are deliberately UNSUPPORTED:
  # the CRC rejects them and fp_give_up stops the scan (verified safely
  # non-engaging on U/J dumps of both, real audio unaffected).
]

const
  # SoundChannel field offsets (stock m4a layout, pret m4a_internal.h;
  # runtime-verified for GS1):
  GSC_STATUS   = 0x00
  GSC_TYPE     = 0x01
  GSC_VOL_A    = 0x02   # FIFO-A-lane volume (pret m4a names +2 'rightVolume',
  GSC_VOL_B    = 0x03   # but this driver's packer feeds +2 to the buffer-A/low
                        # halfword lane — established empirically on BOTH builds:
                        # per-side RMS only matches the real FIFO A/B streams
                        # this way round)
  GSC_ATTACK   = 0x04
  GSC_DECAY    = 0x05
  GSC_SUSTAIN  = 0x06
  GSC_RELEASE  = 0x07
  GSC_ENV_VOL  = 0x09
  GSC_ECHO_VOL = 0x0C
  GSC_ECHO_LEN = 0x0D
  GSC_CT       = 0x18   # source samples remaining until sample end
  GSC_FREQ     = 0x20   # playback rate, integer Hz
  GSC_WAVE     = 0x24   # -> WaveData
  GSC_CUR      = 0x28   # current sample data pointer
  GSC_SIZE     = 64

  # SoundInfo offsets (stock m4a):
  GSI_REVERB     = 0x05
  GSI_MAX_CHANS  = 0x06
  GSI_MASTER_VOL = 0x07
  GSI_DMA_PERIOD = 0x0B
  GSI_SPV        = 0x10   # pcmSamplesPerVBlank (u16)
  GSI_PCM_RATE   = 0x14
  GSI_DIV_FREQ   = 0x18   # per-Hz step multiplier: step = freq*divFreq (9.23)

  GS_START = 0x80'u8
  GS_STOP  = 0x40'u8
  GS_LOOP  = 0x10'u8
  GS_IEC   = 0x04'u8
  GS_ON    = 0xC7'u8

proc new_gs_bon*(gba: GBA): GsBonHle =
  GsBonHle(gba: gba, hook_addr: 0xFFFFFFFF'u32)

proc grd8(g: GsBonHle; a: uint32): uint8  {.inline.} = g.gba.bus.read_byte_internal(a)
proc grd16(g: GsBonHle; a: uint32): uint16 {.inline.} = g.gba.bus.read_half_internal(a)
proc grd32(g: GsBonHle; a: uint32): uint32 {.inline.} = g.gba.bus.read_word_internal(a)

proc gs_state_loaded*(g: GsBonHle) =
  ## Save-state / rollback load: shadow state is not serialized; drop it and
  ## re-latch from the restored RAM at the next mixer-entry hook (mid-note
  ## channels resume at the engine's own position via ct — see gs_on_frame).
  for i in 0 ..< GS_MAX_CHANNELS:
    g.samplers[i] = GsBonSampler()
  for v in g.out_delay.mitems: v = 0
  g.out_delay_w = 0
  for v in g.rev_ring.mitems: v = 0
  g.rev_slot = 0
  g.rev_pos = 0
  g.frame_pos = 0
  g.resync_pending = true

# -----------------------------------------------------------------------------
# Detection: SoundInfo ident magic + code fingerprint of the IWRAM mixer copy,
# located by SCANNING IWRAM (position-independent: regional builds link the
# byte-identical block at different addresses; see GsBonBuild).
# Structurally exclusive with the MP2K HLE: stock m4a games never carry the
# Bon code bytes in IWRAM (CRC cannot match), and Bon games never take the m4a
# lock (the MP2K HLE's probe never learns). We additionally skip fingerprinting
# whenever the MP2K HLE has learned its hook, so an m4a game costs this poll
# almost nothing.
# -----------------------------------------------------------------------------

proc gs_crc32(g: GsBonHle; base: uint32; len: int): uint32 =
  ## Bitwise CRC-32 (IEEE 802.3 reflected polynomial), table-free.
  var crc = 0xFFFFFFFF'u32
  for i in 0 ..< len:
    crc = crc xor uint32(g.grd8(base + uint32(i)))
    for _ in 0 ..< 8:
      if (crc and 1'u32) != 0:
        crc = (crc shr 1) xor 0xEDB88320'u32
      else:
        crc = crc shr 1
  not crc

proc gs_frame_poll*(g: GsBonHle) =
  ## Once-per-frame detection / liveness check (called from step_frame while
  ## the "Improve audio quality" flag is on).
  let sip = g.grd32(GS_SOUNDINFO_PTR_ADDR)
  let plausible = (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32
  var ident = 0'u32
  if plausible: ident = g.grd32(sip)
  if g.engaged:
    if ident != GS_IDENT:
      # Engine torn down (or a state from another game was loaded).
      g.engaged = false
      for i in 0 ..< GS_MAX_CHANNELS: g.samplers[i].active = false
    else:
      g.sound_info = sip
    return
  if ident != GS_IDENT: return
  # m4a game already claimed by the MP2K HLE's runtime learning? Skip the CRC.
  if g.gba.mp2k != nil and g.gba.mp2k.hook_addr != 0xFFFFFFFF'u32: return
  if g.fp_give_up: return
  # Scan IWRAM for each known build's fingerprint region (word-aligned).
  # The mixer block's link address is a per-build artifact — regional builds
  # relocate the byte-identical block — so detection must not assume a fixed
  # base. Cheap prefilter per word (the region's first word), full CRC only
  # on prefilter hits; a match at any base engages with every hook/parse
  # location derived as base + per-build offset. Cost: 8K word reads per
  # frame while an unclaimed "Smsh" work area exists (a few microseconds;
  # stock-m4a games stop paying it once the MP2K HLE learns its hook or
  # fp_give_up trips).
  var any_prefilter = false
  var off = 0'u32
  while off < 0x8000'u32:
    let w = g.grd32(0x03000000'u32 + off)
    for bi in 0 ..< GS_BUILDS.len:
      let b = GS_BUILDS[bi]
      if w != b.fp_first or int(off) + b.fp_len > 0x8000: continue
      any_prefilter = true
      let base = 0x03000000'u32 + off
      if g.gs_crc32(base, b.fp_len) == b.fp_crc:
        g.sound_info = sip
        g.build = bi
        g.fp_addr = base
        g.hook_addr = base + b.entry_off
        g.rev_insn_addr = (if b.rev_insn_off != 0: base + b.rev_insn_off else: 0'u32)
        g.rev_model = b.rev_model
        g.engaged = true
        g.resync_pending = true
        g.frame_pos = 0
        # Per-build double-buffer latency (measured by A/B cross-correlation).
        let want = int(b.db_delay_frames * float32(g.frame_len))
        if not g.db_delay_ovr and want != g.db_delay:
          g.db_delay = want
          g.out_delay = newSeq[int16](max(2, want * 2))
          g.out_delay_w = 0
        return
    off += 4
  if any_prefilter:
    inc g.fp_fails
    if g.fp_fails > 32: g.fp_give_up = true   # magic present but not a known Bon build

# -----------------------------------------------------------------------------
# Per-frame channel refresh at the mixer-entry hook.
# -----------------------------------------------------------------------------

proc gs_env_step(g: GsBonHle; base: uint32; status: uint8): tuple[env: uint8, alive: bool, started: bool] =
  ## Shadow replica of the driver's per-frame envelope update (our disassembly
  ## of the IWRAM code at GS1 block+0x658; stock m4a ADSR
  ## semantics). The hook runs BEFORE the driver processes the channel this
  ## frame, so the RAM env value is last frame's — this predicts the value the
  ## driver is about to compute and use for this frame's chunk. Nothing is
  ## written back (shadow mode).
  var env = g.grd8(base + GSC_ENV_VOL)
  let started = (status and GS_START) != 0
  if started:
    if (status and GS_STOP) != 0: return (0'u8, false, false)  # keyed and killed
    # note-on: env restarts at 0, phase=attack, attack applied this same frame
    var e = int(g.grd8(base + GSC_ATTACK))
    if e > 255: e = 255
    return (uint8(e), true, true)
  if (status and GS_IEC) != 0:
    # pseudo-echo tail: driver decrements echoLength and kills the channel
    # when it reaches zero; env holds at pseudoEchoVolume
    let el = g.grd8(base + GSC_ECHO_LEN)
    if el <= 1'u8: return (0'u8, false, false)
    return (env, true, false)
  if (status and GS_STOP) != 0:
    let rel = uint32(g.grd8(base + GSC_RELEASE))
    let echo = g.grd8(base + GSC_ECHO_VOL)
    # GS1 build: multiplicative release, env = env*release >> 8.
    let e = (uint32(env) * rel) shr 8
    if e > uint32(echo): return (uint8(e), true, false)
    if echo == 0: return (0'u8, false, false)
    return (echo, true, false)
  case status and 3'u8
  of 2'u8:   # decay
    let dec = uint32(g.grd8(base + GSC_DECAY))
    var e = (uint32(env) * dec) shr 8
    let sus = g.grd8(base + GSC_SUSTAIN)
    if e > uint32(sus): return (uint8(e), true, false)
    if sus == 0'u8:
      let echo = g.grd8(base + GSC_ECHO_VOL)
      if echo == 0: return (0'u8, false, false)
      return (echo, true, false)
    return (sus, true, false)
  of 3'u8:   # attack (still ramping)
    var e = int(env) + int(g.grd8(base + GSC_ATTACK))
    if e > 255: e = 255
    return (uint8(e), true, false)
  else:      # sustain / release-idle: hold
    return (env, true, false)

proc gs_parse_reverb(g: GsBonHle) =
  ## The reverb tap gains live IN THE CODE (see header): the game runtime-
  ## patches the shift amounts of the mix-buffer seed instructions. Parse the
  ## first patched pair each frame; anything unexpected there turns reverb
  ## off (safe non-engagement). Encodings (ARM data-processing, shift
  ## immediate at bits 11..7):
  ##   asrs r6, rX, #A  -> 0xE1B06_44 | A<<7   (mix-halfword tap, gain 2^-(A-16))
  ##   adds r6, r6, fp, asr #B -> 0xE096604B | B<<7 (old-byte tap, gain 2^-(B-17))
  ## Only reached on builds with rev_insn != 0 (GS1); echo-model builds keep
  ## their coefficients at 0 and never consult this parser.
  g.rev_coef_new = 0
  g.rev_coef_old = 0
  if g.rev_insn_addr == 0: return
  let i0 = g.grd32(g.rev_insn_addr)
  let i1 = g.grd32(g.rev_insn_addr + 4)
  if (i0 and 0xFFFFF07F'u32) == 0xE1B06044'u32 and
     (i1 and 0xFFFFF07F'u32) == 0xE096604B'u32:
    let a = int((i0 shr 7) and 31)
    let b = int((i1 shr 7) and 31)
    if a in 17 .. 30 and b in 17 .. 30:
      g.rev_coef_new = 1.0'f32 / float32(1 shl (a - 16))
      g.rev_coef_old = 1.0'f32 / float32(1 shl (b - 17))

proc gs_on_frame(g: GsBonHle) =
  ## Refresh every sampler from SoundInfo once per video frame, at the mixer
  ## entry (channel state untouched by the driver for this frame yet).
  let sound_info = g.sound_info
  var maxc = int(g.grd8(sound_info + GSI_MAX_CHANS))
  if maxc > GS_BUILDS[g.build].max_chans: maxc = GS_BUILDS[g.build].max_chans
  g.reverb_strength = g.grd8(sound_info + GSI_REVERB)
  g.rev_period = int(g.grd8(sound_info + GSI_DMA_PERIOD))
  if g.rev_period < 1: g.rev_period = 1
  elif g.rev_period > 16: g.rev_period = 16
  g.src_rate = int(g.grd32(sound_info + GSI_PCM_RATE))
  if g.src_rate < 1024 or g.src_rate > 65536: g.src_rate = 21024
  # The driver's resampler step is freq * divFreq in 9.23 fixed point per
  # SOURCE sample (mul r4, ip, lr in the block; divFreq = SoundInfo+0x18,
  # 0x18F = 399 for 21024 Hz). 399 vs the exact 2^23/21024 = 398.94 means
  # every voice plays ~143 ppm sharp on hardware; replicate the integer
  # product so long sustained notes stay phase-locked to the real mixer
  # (the measured effect on 30 s A/B windows is small but strictly >= 0).
  g.div_freq = g.grd32(sound_info + GSI_DIV_FREQ)
  if g.div_freq == 0 or g.div_freq > 0xFFFF'u32:
    g.div_freq = uint32(8388608 div g.src_rate)
  case g.rev_model
  of grmParsedShift:
    # REAL reverb model (GS1): live-parse the runtime-patched coefficients
    # and maintain the wet-history ring: rev_period+1 one-frame slots — the
    # cross tap reads the slot written pcmDmaPeriod+1 passes ago, which with
    # P+1 slots is exactly the slot we are about to overwrite (read-before-
    # write, like the real loop's ldr-before-str on the FIFO ring).
    # Maintained whenever engaged so a reverb-config change mid-song echoes
    # real history, not silence.
    g.gs_parse_reverb()
    let want = (g.rev_period + 1) * GS_REV_SLOT_LEN * 2
    if g.rev_ring.len != want:
      g.rev_ring = newSeq[float32](want)
      g.rev_slot = 0
    g.rev_slot = (if g.rev_slot + 1 >= g.rev_period + 1: 0 else: g.rev_slot + 1)
    g.rev_pos = 0
  g.frame_pos = 0
  for i in 0 ..< GS_MAX_CHANNELS:
    let s = addr g.samplers[i]
    if i >= maxc:
      s.active = false
      continue
    let base   = sound_info + uint32(0x50 + i * GSC_SIZE)
    let status = g.grd8(base + GSC_STATUS)
    if (status and GS_ON) == 0:
      s.active = false
      continue
    let ctype = g.grd8(base + GSC_TYPE)
    if (ctype and 0x07'u8) != 0:
      s.active = false          # CGB-routed note: never a PCM channel
      continue
    let wave = g.grd32(base + GSC_WAVE)
    if wave == 0 or (wave shr 24) == 0:
      s.active = false
      continue
    let (env, alive, started) = g.gs_env_step(base, status)
    if not alive:
      s.active = false
      continue
    let size       = g.grd32(wave + 12)
    let loop_start = g.grd32(wave + 8)
    if (size and 0x80000000'u32) != 0:
      # Camelot 4-bit ADPCM (negative size, Mario Tennis) — not handled yet.
      s.active = false
      continue
    let synth = size == 0 and loop_start == 0
    if synth: g.dbg_synth_chframes.inc
    when defined(mp2kwav):
      block:
        var seen = false
        for w in g.dbg_waves:
          if w == wave: seen = true; break
        if not seen and g.dbg_waves.len < 512: g.dbg_waves.add wave
    let data  = wave + 16
    let looping = (g.grd8(wave + 3) shr 6) != 0   # loop flags, high byte of u16 at +2
    let retrig = started or not s.active or s.wave_data != data or s.synth != synth
    if retrig:
      if g.resync_pending and not started and not synth:
        # Post-load resync: resume mid-note at the engine's own position.
        # ct = source samples remaining (driver sets ct=size at note-on and
        # decrements per source sample consumed).
        let remaining = g.grd32(base + GSC_CT)
        s.src_index =
          if remaining >= 1'u32 and remaining <= size: size - remaining
          else: 0'u32
        s.age = 1
      else:
        s.src_index = 0
        s.age = 0
      s.phase_frac = 0
      s.need_fetch = true
      s.tap0 = 0; s.tap1 = 0; s.tap2 = 0; s.tap3 = 0
      s.phase_u = 0
      s.saw_iir = 0
      s.src_carry = 0
      s.active = true
      if synth:
        # Oscillator descriptor in the sample-data area (see header comment).
        s.synth_kind   = g.grd8(data + 1)
        s.duty_base    = g.grd8(data + 2)
        s.duty_step    = g.grd8(data + 3)
        s.duty_depth   = g.grd8(data + 4)
        s.duty_phase0  = g.grd8(data + 5)
        s.duty_acc     = 0     # the driver keeps this in ct, zeroed at note-on
    else:
      s.age.inc
    s.wave_data    = data
    s.synth        = synth
    s.freq         = g.grd32(base + GSC_FREQ)
    s.loop_start   = loop_start
    s.sample_count = size
    s.looping      = looping and not synth
    # Resample step per 32768 Hz output sample, using the driver's OWN
    # integer step arithmetic (freq * divFreq, 9.23 per source sample — see
    # the div_freq note above): the effective playback rate is
    # freq * divFreq/2^23 * srcRate, slightly sharp of nominal on hardware.
    let eff_hz = float64(s.freq) * float64(g.div_freq) *
                 float64(g.src_rate) / 8388608.0
    s.freq_step = float32(eff_hz / float64(APU_SAMPLE_RATE))
    if synth:
      # Oscillator phase accumulators (2^32 = one period of 64 source
      # samples, exactly the driver's wrapping 32-bit phase register):
      # synth_step advances at our render rate, saw_step at the driver's
      # native rate (the saw shaper below is a source-rate IIR).
      s.synth_step = uint32(eff_hz * 4294967296.0 /
                            (64.0 * float64(APU_SAMPLE_RATE)))
      s.saw_step   = uint32(eff_hz * 4294967296.0 /
                            (64.0 * float64(g.src_rate)))
      # Per-frame duty-modulation step + threshold (see header: the exact
      # once-per-frame computation from the block's +0xC94 square path,
      # including the mvnmi fold and the WRAPPING u32 mla).
      s.duty_acc = s.duty_acc + s.duty_step
      let u = s.duty_acc + s.duty_phase0
      let f24 = (if u >= 128'u8: (uint32(255'u8 - u) shl 16) or 0xFFFF'u32
                 else: uint32(u) shl 16)
      s.duty_thresh = f24 * uint32(s.duty_depth) + (uint32(s.duty_base) shl 24)
    let wave_region = data shr 24
    s.in_rom = wave_region >= 0x08'u32 and wave_region <= 0x0D'u32
    if s.in_rom:
      s.rom_off = data and 0x01FFFFFF'u32
    # Per-side gains, exactly the driver's formula: sideVol * env >> 9, in
    # 0..63 — normalized to 0..1 against 64. +2 feeds the FIFO-A (our l) lane,
    # +3 the FIFO-B (our r) lane — see the GSC_VOL_A note. Ramp last frame's
    # endpoint to this frame's across the frame, like the MP2K HLE.
    let enveff = uint32(env)
    let gl = float32((uint32(g.grd8(base + GSC_VOL_A)) * enveff) shr 9) / 64.0'f32
    let gr = float32((uint32(g.grd8(base + GSC_VOL_B)) * enveff) shr 9) / 64.0'f32
    if retrig and not g.resync_pending:
      s.vol_l0 = gl; s.vol_r0 = gr        # fresh note: no ramp from stale values
    else:
      s.vol_l0 = s.vol_l1; s.vol_r0 = s.vol_r1
    s.vol_l1 = gl
    s.vol_r1 = gr
  g.engaged_frames.inc
  g.resync_pending = false

proc gs_mixer_hook*(g: GsBonHle) =
  ## PC hook at the per-channel processing entry (fires once per frame from
  ## the game's VBlank handler). Validate the work area, then refresh.
  let sip = g.grd32(GS_SOUNDINFO_PTR_ADDR)
  if ((sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32) and
     g.grd32(sip) == GS_IDENT:
    g.sound_info = sip
    g.dbg_hook_fires.inc
    g.gs_on_frame()
  # else: stale hook (should not happen while the fingerprint region is
  # intact); the frame poll's liveness check will disengage.

# -----------------------------------------------------------------------------
# Rendering: one stereo sample per APU tick at 32768 Hz (same machinery family
# as the MP2K HLE: forward-stepping resampler with a 4-tap history + Catmull-
# Rom cubic interpolation, per Paul Bourke "Cubic Interpolation").
# -----------------------------------------------------------------------------

proc gs_wave_s8(g: GsBonHle; s: ptr GsBonSampler; rom: ptr seq[byte];
                rmask: uint32; idx: uint32): float32 {.inline.} =
  if s.in_rom:
    float32(cast[int8](rom[][(s.rom_off + idx) and rmask]))
  else:
    float32(cast[int8](g.grd8(s.wave_data + idx)))

proc gs_synth_sample(s: ptr GsBonSampler; src_ratio: float32): float32 {.inline.} =
  ## Oscillator output in s8 units — the EXACT generators from our
  ## disassembly of the IWRAM block's synth paths (+0xC8C square, +0xD18
  ## saw, +0xD9C triangle; amplitude scale derivation in the header).
  ## Advances the oscillator state (one output sample at 32768 Hz).
  case s.synth_kind
  of 0'u8:
    # Duty-modulated square: symmetric +-(vol<<6) — s8 amplitude +-64 —
    # high while the wrapping 32-bit phase is below the per-frame threshold
    # (unsigned compare, then step: the driver's cmp/addcc/subcs order).
    result = (if s.phase_u < s.duty_thresh: 64.0'f32 else: -64.0'f32)
    s.phase_u += s.synth_step
  of 1'u8:
    # Saw: r9 = (p>>24) - 112 - ((p>>26)&31), shaped by the source-rate IIR
    # r2 = r9 + (r2 asr 1); volume is halved for this shape (lsr #1 on the
    # packed volume word), so s8 value = r2/2. The IIR pole is tied to the
    # driver's native rate: run it on a source-sample clock and hold the
    # last value between ticks (the real FIFO stream is exactly that hold).
    s.src_carry += src_ratio
    while s.src_carry >= 1.0'f32:
      s.src_carry -= 1.0'f32
      s.phase_u += s.saw_step
      let p = s.phase_u
      let r9 = int32(p shr 24) - 112'i32 - int32((p shr 26) and 31)
      s.saw_iir = r9 + ashr(s.saw_iir, 1)
    result = float32(s.saw_iir) * 0.5'f32
  else:
    # Triangle: exact two-slope ramp, s8 amplitude +-128 at full volume.
    s.phase_u += s.synth_step
    let p = s.phase_u
    result = (if p < 0x80000000'u32: float32(int32(p shr 23)) - 128.0'f32
              else: 384.0'f32 - float32(int32(p shr 23)))

proc gs_render_sample*(g: GsBonHle): tuple[l: int16, r: int16] =
  ## Substitute for the DirectSound FIFO A/B latches (A=left, B=right — the
  ## driver's DMA1 buffer is the left channel; verified by A/B correlation).
  if not g.engaged: return (0'i16, 0'i16)
  var outl = 0'i16
  var outr = 0'i16
  block:
    var accl = 0.0'f32
    var accr = 0.0'f32
    let t = (if g.frame_len > 0: float32(g.frame_pos) / float32(g.frame_len) else: 0.0'f32)
    let src_ratio = (if g.src_rate > 0: float32(g.src_rate) / float32(APU_SAMPLE_RATE)
                     else: 21024.0'f32 / float32(APU_SAMPLE_RATE))
    let rom = addr g.gba.cartridge.rom
    let rmask = g.gba.cartridge.rom_mask
    for i in 0 ..< GS_MAX_CHANNELS:
      let s = addr g.samplers[i]
      if not s.active: continue
      var sample: float32
      if s.synth:
        # Oscillator: 64 source samples = one period at the channel frequency.
        sample = gs_synth_sample(s, src_ratio)
      else:
        if s.need_fetch and s.src_index < s.sample_count:
          let ns = g.gs_wave_s8(s, rom, rmask, s.src_index)
          s.tap3 = s.tap2; s.tap2 = s.tap1; s.tap1 = s.tap0; s.tap0 = ns
          s.need_fetch = false
        let mu = s.phase_frac
        when defined(gslinear):
          # DIAG build: the real mixer's linear interpolation, for A/B isolation
          # of the interpolation response (see the title-strings analysis).
          sample = s.tap2 + (s.tap1 - s.tap2) * mu
        else:
          # Catmull-Rom cubic (Paul Bourke), tap0 newest .. tap3 oldest.
          let mu2 = mu * mu
          let a0 = s.tap0 - s.tap1 - s.tap3 + s.tap2
          let a1 = s.tap3 - s.tap2 - a0
          let a2 = s.tap1 - s.tap3
          let a3 = s.tap2
          sample = a0 * mu * mu2 + a1 * mu2 + a2 * mu + a3
        s.phase_frac += s.freq_step
        if s.phase_frac >= 1.0'f32:
          let n = uint32(s.phase_frac)
          s.phase_frac -= float32(n)
          s.src_index += n
          s.need_fetch = true
          if s.src_index >= s.sample_count:
            if s.looping and s.loop_start < s.sample_count:
              s.src_index = s.loop_start +
                ((s.src_index - s.sample_count) mod (s.sample_count - s.loop_start))
            else:
              s.src_index = s.sample_count
              s.need_fetch = false
      sample = sample / 128.0'f32
      when defined(gsstepvol):
        let vl = s.vol_l1   # DIAG: per-frame stepped volumes, like the real mixer
        let vr = s.vol_r1
      else:
        let vl = s.vol_l0 * (1.0'f32 - t) + s.vol_l1 * t
        let vr = s.vol_r0 * (1.0'f32 - t) + s.vol_r1 * t
      accl += sample * vl
      accr += sample * vr
    g.frame_pos.inc
    if g.frame_len > 0 and g.frame_pos >= g.frame_len: g.frame_pos = g.frame_len
    # --- Reverb, REAL model (GS1; see header for the derivation). Same-side
    # tap: previous pass's wet mix at this intra-frame index (gain
    # rev_coef_new). Cross-side tap: the wet output pcmDmaPeriod+1 passes
    # ago, quantized through the s8 FIFO byte (gain rev_coef_old) — with P+1
    # slots that is the slot we are about to overwrite, so read-before-write
    # mirrors the real loop's ldr-before-str. Floats are in the same norm
    # units as the dry mix (real FIFO byte == norm * 64), so the byte
    # quantization maps to floor(x*64)/64 and the mix-buffer halfword
    # saturation to +-2.0.
    var outl_f = accl
    var outr_f = accr
    if g.rev_ring.len > 0:
      let cap  = GS_REV_SLOT_LEN
      let i    = (if g.rev_pos < cap: g.rev_pos else: cap - 1)
      let nslots = g.rev_ring.len div (cap * 2)
      let cur  = (g.rev_slot * cap + i) * 2
      let prevs = (if g.rev_slot == 0: nslots - 1 else: g.rev_slot - 1)
      let prev = (prevs * cap + i) * 2
      if g.rev_coef_new > 0'f32 or g.rev_coef_old > 0'f32:
        let oldl = float32(clamp(int(floor(g.rev_ring[cur] * 64.0'f32)),
                                 -128, 127)) / 64.0'f32
        let oldr = float32(clamp(int(floor(g.rev_ring[cur + 1] * 64.0'f32)),
                                 -128, 127)) / 64.0'f32
        outl_f = accl + g.rev_coef_new * g.rev_ring[prev]     + g.rev_coef_old * oldr
        outr_f = accr + g.rev_coef_new * g.rev_ring[prev + 1] + g.rev_coef_old * oldl
      outl_f = clamp(outl_f, -2.0'f32, 2.0'f32)   # the mixer's halfword saturation
      outr_f = clamp(outr_f, -2.0'f32, 2.0'f32)
      g.rev_ring[cur]     = outl_f
      g.rev_ring[cur + 1] = outr_f
      g.rev_pos.inc
    # Scale into the FIFO latch range: the real FIFO byte is norm*64 and the
    # APU latches bytes <<1, so the exact mapping is *128 (makeup is the
    # per-build A/B calibration, 1.0 for GS1). Clamp = the byte range
    # [-128,127] <<1.
    let mk = (if g.makeup > 0'f32: g.makeup else: GS_BUILDS[g.build].makeup)
    let li = int32(outl_f * 128.0'f32 * mk)
    let ri = int32(outr_f * 128.0'f32 * mk)
    outl = int16(clamp(li, -256, 254))
    outr = int16(clamp(ri, -256, 254))
  # Double-buffer latency: the chunk the driver mixes at VBlank N is drained
  # by the FIFO DMA later; delay our stream to line up (calibrated by
  # cross-correlation against the real FIFO, like the MP2K HLE's).
  var eoutl = outl
  var eoutr = outr
  if g.db_delay > 0 and g.out_delay.len >= 2:
    let slots = g.out_delay.len shr 1
    if g.out_delay_w >= slots: g.out_delay_w = 0
    let wi = g.out_delay_w shl 1
    eoutl = g.out_delay[wi]
    eoutr = g.out_delay[wi + 1]
    g.out_delay[wi]     = outl
    g.out_delay[wi + 1] = outr
    g.out_delay_w = g.out_delay_w + 1
  when defined(mp2kwav):
    mp2kWavCapture.add eoutl
    mp2kWavCapture.add eoutr
  (eoutl, eoutr)

proc init_gs_bon*(g: GsBonHle) =
  g.frame_len = APU_SAMPLE_RATE div 60
  g.db_delay = g.frame_len          # 1 frame default; per-build override at engage
  g.out_delay = newSeq[int16](g.db_delay * 2)
  g.out_delay_w = 0
