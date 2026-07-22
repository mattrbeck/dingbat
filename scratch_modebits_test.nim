import dingbat/gba/gba
# Synthetic unit tests for the MP2K HLE sampler's DirectSound mode bits
# (TONEDATA_TYPE_FIX / _REV / _CMP and combinations), driven WITHOUT a game:
# a fake sample bank is placed in a fabricated cartridge ROM and the samplers
# are configured directly, then render_sample() is pumped one output sample at
# a time. Reference semantics under test (pret pokeemerald src/m4a_1.s):
#   - REV: sample plays back-to-front (last source sample first), one-shot —
#     the reference driver's reversed paths never consult the loop registers.
#   - FIX: playback rate is SoundInfo.pcmFreq; channel.frequency is ignored.
#   - CMP: BDPCM decodes block-at-a-time and mixes at PCM parity, in any
#     combination with REV/FIX, including decimating (step > 1) playback.
#
# Build: nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc \
#          -o:scratch_modebits_test --path:src scratch_modebits_test.nim

var failures = 0

proc check(cond: bool; what: string) =
  if cond:
    echo "PASS  ", what
  else:
    echo "FAIL  ", what
    failures.inc

proc mk_hle(bank: seq[byte]): (Mp2kHle, GBA) =
  ## Fabricate a GBA whose cartridge ROM holds `bank` (padded to a power of
  ## two) and an Mp2kHle around it with neutral settings: no reverb, no
  ## double-buffer delay, hold (nearest) resampling so each output sample is
  ## exactly the latest fetched source sample.
  var rom = bank
  var n = 1
  while n < rom.len: n = n shl 1
  rom.setLen(n)
  let gba = GBA(cartridge: Cartridge(rom: rom, rom_mask: uint32(n - 1)))
  let m = Mp2kHle(gba: gba, engaged: true, resample_mode: 2)
  (m, gba)

proc set_channel(m: Mp2kHle; idx: int; rom_off, count, freq: uint32;
                 compressed = false; reversed = false; fix = false;
                 looping = false; loop_start = 0'u32; pcm_rate = 32768) =
  m.pcm_sample_rate = pcm_rate
  let s = addr m.samplers[idx]
  s[] = Mp2kSampler(
    active: true, in_rom: true, rom_off: rom_off,
    wave_data: 0x08000000'u32 + rom_off,
    sample_count: count, loop_start: loop_start, looping: looping,
    freq: freq, compressed: compressed, reversed: reversed,
    use_pcm_rate: fix, start_off: 0,
    src_index: 0, phase_frac: 0, need_fetch: true,
    blk_index: 0xFFFFFFFF'u32,
    vol_l0: 1, vol_l1: 1, vol_r0: 1, vol_r1: 1)

proc run(m: Mp2kHle; n: int): seq[int16] =
  for _ in 0 ..< n: result.add m.render_sample().l

proc main() =
  # An asymmetric 16-sample s8 pattern (no palindromes, includes extremes).
  let pat = @[3'i8, -7, 20, 127, -128, 55, -1, 0, 9, -90, 42, 17, -33, 66, -5, 88]
  var bank = newSeq[byte](pat.len)
  for i, v in pat: bank[i] = cast[byte](v)

  # ---- REV: forward vs reversed PCM must be exact mirrors -------------------
  block:
    let (m, _) = mk_hle(bank)
    set_channel(m, 0, 0, uint32(pat.len), 32768)          # step = 1.0
    let fwd = m.run(pat.len)
    set_channel(m, 0, 0, uint32(pat.len), 32768, reversed = true)
    let rev = m.run(pat.len)
    var mirrored = true
    for i in 0 ..< pat.len:
      if rev[i] != fwd[pat.len - 1 - i]: mirrored = false
    check(mirrored, "REV: reversed PCM output is the exact mirror of forward")

  # ---- FIX: rate comes from pcmFreq, channel.frequency is ignored -----------
  block:
    let (m, _) = mk_hle(bank)
    # Garbage per-note frequency, FIX set, pcmFreq = output rate: must step
    # exactly one source sample per output sample (documented rate = pcmFreq).
    set_channel(m, 0, 0, uint32(pat.len), freq = 12345, fix = true)
    let fixed = m.run(pat.len)
    set_channel(m, 0, 0, uint32(pat.len), freq = 32768)   # plain, same step
    let plain = m.run(pat.len)
    check(fixed == plain,
      "FIX: plays at SoundInfo.pcmFreq; channel.frequency (12345) ignored")
    # Sanity: without FIX the frequency field DOES scale pitch (half rate ->
    # every source sample held for two output samples in hold mode).
    set_channel(m, 0, 0, uint32(pat.len), freq = 16384)
    let half = m.run(pat.len)
    var doubled = true
    for i in 0 ..< pat.len div 2:
      if half[2*i + 1] != plain[i]: doubled = false
    check(doubled, "no FIX: channel.frequency scales pitch (half-rate holds)")

  # ---- REV + loop: reversed playback is one-shot (loop flags ignored) -------
  block:
    let (m, _) = mk_hle(bank)
    set_channel(m, 0, 0, 8, 32768, looping = true, loop_start = 2)
    let fwd = m.run(20)
    # Forward DOES wrap: after 8 samples it re-enters at loop_start (loop
    # length = 8 - 2 = 6, so the wrap recurs every 6 output samples).
    check(fwd[8] == fwd[2] and fwd[9] == fwd[3] and fwd[14] == fwd[2],
      "loop: forward looping sampler wraps to loop_start")
    set_channel(m, 0, 0, 8, 32768, looping = true, loop_start = 2,
                reversed = true)
    let rev = m.run(20)
    # Reversed must NOT wrap: it plays src[7]..src[0] then holds src[0].
    var held = true
    for i in 8 ..< 20:
      if rev[i] != rev[7]: held = false
    check(held and rev[7] == fwd[0],
      "REV+loop: reversed playback is one-shot; loop registers ignored")

  # ---- CMP: BDPCM at PCM parity, forward/reversed/decimating/fixed ----------
  block:
    # Two BDPCM blocks (66 bytes) with varied base bytes and nibble indices.
    var comp = newSeq[byte](66)
    comp[0] = cast[byte](7'i8)                  # block 0 base
    for i in 1 .. 32: comp[i] = byte((i * 5 + 3) and 0xFF)
    comp[33] = cast[byte](-120'i8)              # block 1 base
    for i in 34 .. 65: comp[i] = byte((i * 11 + 1) and 0xFF)
    const N = 100                               # spans both blocks
    # Reference decode (validated against hand-computed values in
    # scratch_bdpcm_test.nim), turned into an equivalent plain-PCM bank.
    let dec = mp2k_decode_bdpcm(comp, N)
    var pcm = newSeq[byte](N)
    for i, v in dec: pcm[i] = cast[byte](int8(v))
    var full = comp & pcm                       # compressed at 0, PCM at 66
    let (m, _) = mk_hle(full)

    set_channel(m, 0, 0, N, 32768, compressed = true)
    let cfwd = m.run(N)
    set_channel(m, 0, 66, N, 32768)
    let pfwd = m.run(N)
    check(cfwd == pfwd, "CMP: BDPCM decode mixes at exact PCM parity")

    set_channel(m, 0, 0, N, 32768, compressed = true, reversed = true)
    let crev = m.run(N)
    var mirrored = true
    for i in 0 ..< N:
      if crev[i] != cfwd[N - 1 - i]: mirrored = false
    check(mirrored, "CMP+REV: reversed BDPCM is the exact mirror of forward")

    # Decimating step (freq = 2x output rate): every other source sample. The
    # block cache must keep the running DPCM state correct across skips.
    set_channel(m, 0, 0, N, 65536, compressed = true)
    let cskip = m.run(N div 2)
    set_channel(m, 0, 66, N, 65536)
    let pskip = m.run(N div 2)
    check(cskip == pskip, "CMP decimated (step 2): skipped samples decode correctly")

    # FIX+CMP: fixed-rate compressed playback follows pcmFreq, ignores freq.
    set_channel(m, 0, 0, N, freq = 999, compressed = true, fix = true)
    let cfix = m.run(N)
    check(cfix == cfwd, "FIX+CMP: compressed fixed-rate plays at pcmFreq")

    # FIX+REV: fixed-rate reversed playback.
    set_channel(m, 0, 66, N, freq = 999, reversed = true, fix = true)
    let prevfix = m.run(N)
    var mirrored2 = true
    for i in 0 ..< N:
      if prevfix[i] != pfwd[N - 1 - i]: mirrored2 = false
    check(mirrored2, "FIX+REV: fixed-rate reversed PCM mirrors forward")

  if failures == 0:
    echo "MODE BITS: ALL CHECKS PASS"
  else:
    echo "MODE BITS: ", failures, " FAILURE(S)"
    quit(1)

main()
