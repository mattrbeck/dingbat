## Regression tests for the GBA PPU compositor.
##
## Why this exists: the compositor was rewritten into window spans with three
## specialized inner loops (opaque / alpha / brighten-darken), the opaque and
## shade loops instantiated per layer-walk length. That is a lot of open-coded
## duplication — the layer walk now appears four times — and until this file
## there was NO in-tree test of it at all. The rewrite was verified once, by
## throwaway scratch code diffing against the previous revision, which is not
## something the next edit can lean on.
##
## Deliberately NOT a golden-hash test. A checked-in framebuffer hash would be
## the broadest possible net, but it would also have to be identical on every
## architecture CI runs on, and it would have to be regenerated for any
## intentional behaviour fix — turning a real accuracy improvement into a
## mysterious test failure. Everything below is instead *self-checking*: each
## test renders two configurations that must agree for a stated reason and
## compares them to each other. That is portable, needs no maintenance, and
## when it fails it says which invariant broke.
##
## Run with: nimble test_ppucomposite

import std/[os, strutils]
import dingbat/gba/gba

var failures = 0

proc check(cond: bool; name: string; detail = "") =
  if cond:
    echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name, (if detail.len > 0: "  " & detail else: "")
    inc failures

# --- deterministic RNG, independent of emulator state ------------------------
var rng: uint64 = 0x243F6A8885A308D3'u64
proc nxt(): uint32 =
  rng = rng xor (rng shl 13)
  rng = rng xor (rng shr 7)
  rng = rng xor (rng shl 17)
  uint32(rng shr 32)

proc reseed(s: uint64) = rng = s

# ---------------------------------------------------------------------------
# 1. The saturation-removal proof.
#
# brighten/darken call bgr16_pack, which masks each lane to 5 bits instead of
# saturating. That is only legal if no lane can ever exceed 0x1F, which holds
# because every evy_coefficient read is clamped to 16. Prove it over the whole
# reachable domain rather than asserting it at runtime (a doAssert in the pixel
# loop measured 1.0-7.3% on -d:release, so it is not affordable there).
#
# This is what catches a future edit that reads evy_coefficient unclamped: at
# EVY = 17 the identity below genuinely breaks, so the property is not vacuous.
# ---------------------------------------------------------------------------
proc test_pack_domain() =
  echo "bgr16_pack vs bgr16_pack_sat over the reachable domain"
  var mismatches = 0
  var max_lane = 0'u64
  var min_lane = 0xFFFF'u64
  for c in 0'u32 .. 0xFFFF'u32:
    let s = bgr16_spread(uint16(c))
    for evy in 0'u64 .. 16'u64:
      # brighten: s + ((0x7FFF - s) * evy) / 16
      let d = (((bgr16_spread(0x7FFF'u16) - s) * evy) shr 4) and BGR_LANE_MASK
      let up = s + d
      # darken: s - (s * evy) / 16
      let dn = s - (((s * evy) shr 4) and BGR_LANE_MASK)
      for v in [up, dn]:
        for lane in 0 .. 2:
          let x = (v shr (16 * lane)) and 0xFFFF'u64
          if x > max_lane: max_lane = x
          if x < min_lane: min_lane = x
          if x > 0x1F'u64: inc mismatches
        if bgr16_pack(v) != bgr16_pack_sat(v): inc mismatches
  check(mismatches == 0, "no lane leaves [0, 0x1F] and pack == pack_sat",
        "mismatches=" & $mismatches)
  # The bound must be TIGHT, or the test is not actually pinning anything down:
  # brighten must be able to reach exactly 31 and darken exactly 0.
  check(max_lane == 0x1F and min_lane == 0,
        "the bound is tight (max lane 31, min lane 0)",
        "max=" & $max_lane & " min=" & $min_lane)
  # And EVY = 17 must break it, otherwise the clamp is not load-bearing and
  # this whole test proves nothing about the clamp.
  var overflow_at_17 = false
  for c in 0'u32 .. 0xFFFF'u32:
    let s = bgr16_spread(uint16(c))
    let d = (((bgr16_spread(0x7FFF'u16) - s) * 17'u64) shr 4) and BGR_LANE_MASK
    let v = s + d
    for lane in 0 .. 2:
      if ((v shr (16 * lane)) and 0xFFFF'u64) > 0x1F'u64: overflow_at_17 = true
  check(overflow_at_17, "EVY = 17 really does overflow (so the clamp matters)")

# --- a GBA instance with a synthetic cartridge -------------------------------
# The compositor reads only VRAM/PRAM/OAM and the register block, all of which
# the tests overwrite, so the ROM's contents are irrelevant — it exists purely
# so new_cartridge has a file to open. Written to a temp path, never the repo.
proc make_emu(): GBA =
  let rom_path = getTempDir() / "dingbat_ppucomposite_synthetic.gba"
  if not fileExists(rom_path):
    var rom = newString(0x8000)
    for i in 0 ..< rom.len: rom[i] = char((i * 7 + 13) and 0xFF)
    writeFile(rom_path, rom)
  # Built WITHOUT -d:test_harness, so there is no test_output field to set —
  # nothing here runs the CPU, so nothing needs one.
  result = new_gba("", rom_path, run_bios = false, use_hle = true)
  result.post_init()

proc seed_memory(ppu: PPU; transparent_bias: bool) =
  for i in 0 ..< ppu.vram.len: ppu.vram[i] = uint8(nxt())
  for i in 0 ..< ppu.pram.len: ppu.pram[i] = uint8(nxt())
  for i in 0 ..< ppu.oam.len:  ppu.oam[i]  = uint8(nxt())
  if transparent_bias:
    # Push a lot of tile data to palette index 0 so the layer walk falls
    # through to lower layers, the backdrop, and the blend-bottom search.
    for i in 0 ..< ppu.vram.len:
      if (nxt() and 3) != 0: ppu.vram[i] = 0

proc render(ppu: PPU; mask: uint16 = 0xFFFF): uint64 =
  ## 160 visible scanlines, hashed. vcount is driven directly so no CPU runs.
  ##
  ## `mask` exists for one reason. BGR555 occupies bits 0..14 and bit 15 is
  ## unused, but the two write paths treat it differently: a pixel that takes no
  ## colour effect is copied straight out of PRAM with bit 15 intact, while one
  ## that goes through blend/brighten/darken is rebuilt by bgr16_spread (which
  ## masks the three 5-bit channels) and comes back with bit 15 cleared. So the
  ## same visual colour can land in the framebuffer as two different words.
  ##
  ## That is pre-existing — the old compositor's bgr16_pack_sat masked exactly
  ## the same way — and harmless as long as consumers ignore bit 15, which is
  ## what hardware does. But it means any test comparing an effect path against
  ## a non-effect path has to compare the 15 bits that are actually colour.
  result = 0xCBF29CE484222325'u64
  for row in 0'u16 .. 159'u16:
    ppu.vcount = row
    ppu.render_dirty = true
    ppu.skip_render = false
    ppu.scanline()
  for v in ppu.framebuffer:
    result = (result xor uint64(v and mask)) * 0x100000001B3'u64

# ---------------------------------------------------------------------------
# 2. Coefficient clamping, through the real compositor.
#
# EVA/EVB/EVY are 5-bit fields, so software can write 17..31, and hardware
# treats everything above 16 as 16. If a future edit drops a clamp, these stop
# matching — which is the behavioural guard that replaces the rejected runtime
# assert in bgr16_pack.
# ---------------------------------------------------------------------------
proc test_coefficient_clamping(emu: GBA) =
  echo "EVA/EVB/EVY clamp at 16"
  let ppu = emu.ppu
  proc hash_with(mode: uint8; coeff_reg: uint32; value: uint8): uint64 =
    reseed(0x9E3779B97F4A7C15'u64)
    seed_memory(ppu, transparent_bias = true)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = 0
    ppu[0x000] = 0                        # mode 0, no forced blank
    ppu[0x001] = 0x1F                     # all BGs + OBJ enabled
    ppu.debug_layer_mask = 0x1F
    ppu[0x050] = 0x0F or (mode shl 6)     # BG0-3 as 1st target, blend mode
    ppu[0x051] = 0x3F                     # everything a 2nd target
    ppu[coeff_reg] = value
    if coeff_reg == 0x052: ppu[0x053] = 8 # a fixed EVB so EVA is the variable
    ppu.render()

  for (name, mode, reg) in [("EVY brighten", 2'u8, 0x054'u32),
                            ("EVY darken",   3'u8, 0x054'u32),
                            ("EVA alpha",    1'u8, 0x052'u32),
                            ("EVB alpha",    1'u8, 0x053'u32)]:
    let at16 = hash_with(mode, reg, 16)
    let at17 = hash_with(mode, reg, 17)
    let at31 = hash_with(mode, reg, 31)
    check(at16 == at17 and at16 == at31, name & " = 16, 17 and 31 agree",
          toHex(at16) & " / " & toHex(at17) & " / " & toHex(at31))

# ---------------------------------------------------------------------------
# 3. Fast path vs slow path.
#
# composite() takes a cheap path when no window is active and no colour math
# can apply, and a per-span path otherwise. A window covering the whole screen,
# with WININ/WINOUT enabling every layer and the colour-effect bit clear, is
# visually a no-op — so the two paths must produce identical output. This is
# the closest thing to an in-tree differential oracle: it compares two
# independent implementations of the same pixel decision against each other.
# ---------------------------------------------------------------------------
proc test_fast_slow_agree(emu: GBA) =
  echo "the windowed slow path agrees with the unwindowed fast path"
  let ppu = emu.ppu
  proc setup(bg_mode: uint8) =
    reseed(0xBB67AE8584CAA73B'u64)
    seed_memory(ppu, transparent_bias = true)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = 0
    ppu[0x000] = bg_mode
    ppu[0x001] = 0x1F
    ppu.debug_layer_mask = 0x1F
    # blend mode 0 and no semi-transparent sprites, so no colour math anywhere
    ppu[0x050] = 0
    ppu[0x051] = 0
    let spr = ppu.sprites_ptr()
    for i in 0 ..< 128:
      spr[i].attr0 = spr[i].attr0 and not (0b11'u16 shl 10)   # OBJ mode 0

  for bg_mode in [0'u8, 1'u8, 2'u8, 3'u8, 4'u8, 5'u8]:
    setup(bg_mode)
    let fast = ppu.render()
    setup(bg_mode)
    # WIN0 over the entire screen; every layer enabled inside and out, colour
    # special effect (bit 5) clear in both.
    ppu[0x040] = 240; ppu[0x041] = 0      # WIN0H: x2 = 240, x1 = 0
    ppu[0x044] = 160; ppu[0x045] = 0      # WIN0V: y2 = 160, y1 = 0
    ppu[0x048] = 0x1F                     # WININ  win0: BG0-3 + OBJ, no effect
    ppu[0x04A] = 0x1F                     # WINOUT outside: same
    ppu[0x001] = ppu[0x001] or 0x20       # enable WIN0
    let slow = ppu.render()
    check(fast == slow, "mode " & $bg_mode & ": fast path == full-screen window",
          toHex(fast) & " vs " & toHex(slow))

# ---------------------------------------------------------------------------
# 4. Disabled BGs' line buffers are never read.
#
# This is the invariant behind skipping their per-scanline clear. Poison the
# line buffers of every DISPCNT-disabled BG each scanline: if anything reads
# them, the output changes.
#
# On its own that would be a test that can pass for the wrong reason — if the
# poison were simply overwritten before compositing, "output unchanged" would
# prove nothing. (An earlier version of this test poisoned ENABLED BGs as a
# control and saw no change either, precisely because scanline() clears those
# buffers on entry.) So the second check confirms the poison was still in place
# when compositing ran, by finding it intact afterwards: a disabled BG's buffer
# is neither cleared (that is the optimization) nor written (every renderer
# returns on the same enable bit), so 0xA5 must survive the scanline.
# ---------------------------------------------------------------------------
proc test_disabled_bg_buffers_unread(emu: GBA) =
  echo "disabled BGs' line buffers are never read"
  let ppu = emu.ppu
  var poison_survived = false
  proc run(poison_disabled, poison_enabled: bool): uint64 =
    reseed(0x3C6EF372FE94F82B'u64)
    seed_memory(ppu, transparent_bias = true)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = uint8(nxt())
    ppu[0x000] = ppu[0x000] and 0xF8'u8
    ppu.debug_layer_mask = 0x1F
    result = 0xCBF29CE484222325'u64
    for row in 0'u16 .. 159'u16:
      ppu.vcount = row
      ppu.render_dirty = true
      ppu.skip_render = false
      # Churn the enable bits AND the bg mode per line. The mode matters: a
      # regular BG's renderer writes all 240 columns, so for those the clear is
      # redundant anyway and poisoning proves nothing — it is the affine and
      # bitmap modes, whose sampling can leave columns untouched, where a
      # missing clear actually shows through.
      ppu[0x001] = uint8(nxt())
      ppu[0x000] = (ppu[0x000] and 0xF8'u8) or uint8(nxt() mod 6)
      var poisoned_bgs: set[0..3] = {}
      for bg in 0 .. 3:
        let enabled = ((uint16(ppu.dispcnt) shr uint16(8 + bg)) and 1) != 0
        if (enabled and poison_enabled) or ((not enabled) and poison_disabled):
          for c in 0 .. 239: ppu.layer_palettes[bg][c] = 0xA5
          if not enabled: poisoned_bgs.incl(bg)
      ppu.scanline()
      # Still disabled and still 0xA5 => it was live throughout compositing.
      for bg in poisoned_bgs:
        if ((uint16(ppu.dispcnt) shr uint16(8 + bg)) and 1) == 0 and
           ppu.layer_palettes[bg][0] == 0xA5 and ppu.layer_palettes[bg][239] == 0xA5:
          poison_survived = true
    for v in ppu.framebuffer:
      result = (result xor uint64(v)) * 0x100000001B3'u64

  let clean = run(false, false)
  let poisoned_off = run(true, false)
  let poisoned_on  = run(false, true)
  check(clean == poisoned_off,
        "poisoning disabled BGs' buffers changes nothing",
        toHex(clean) & " vs " & toHex(poisoned_off))
  check(poison_survived,
        "the poison was still intact when compositing ran (so the above is meaningful)",
        "no disabled BG kept its 0xA5 - the poison never reached the compositor")
  # And ENABLED BGs must be unaffected too — not because they are unread, but
  # because scanline() clears them on entry. This is the check that fails if the
  # clear is ever skipped for a BG that IS in the walk, which the poison test
  # above cannot see (it only touches buffers nothing reads).
  check(clean == poisoned_on,
        "poisoning ENABLED BGs' buffers changes nothing (they are cleared)",
        toHex(clean) & " vs " & toHex(poisoned_on))

# ---------------------------------------------------------------------------
# 5. Determinism. Cheap, and it protects every test above: if rendering were
# state-dependent across runs, all the comparisons would be meaningless.
# ---------------------------------------------------------------------------
proc test_determinism(emu: GBA) =
  echo "rendering the same configuration twice gives the same output"
  let ppu = emu.ppu
  proc once(): uint64 =
    reseed(0xA54FF53A5F1D36F1'u64)
    seed_memory(ppu, transparent_bias = false)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = uint8(nxt())
    ppu[0x000] = ppu[0x000] and 0x7F'u8
    ppu.debug_layer_mask = 0x1F
    ppu.render()
  let a = once()
  let b = once()
  check(a == b, "two identical renders agree", toHex(a) & " vs " & toHex(b))

# ---------------------------------------------------------------------------
# 6. The three inner loops agree where the colour math is an identity.
#
# This is the test with real teeth, and the reason it exists is instructive:
# test 3 above compares the windowed and unwindowed paths, but BOTH of them
# funnel into the same composite_span, so it only validates the window plumbing
# — not the loops. Verified by mutation: flipping the OBJ-vs-BG priority
# comparison (`sprio <= w.prio[i]` -> `<`) inside composite_span_opaque passes
# every other test in this file.
#
# The fix is to route one visual result through different loops and require
# agreement, using configurations where the colour math is provably an
# identity:
#   * brighten/darken with EVY = 0   -> shade loop, s + 0 = s
#   * alpha with EVA = 16, EVB = 0   -> alpha loop, (top*16 + bot*0)/16 = top
# Both must equal blend mode 0, which takes the opaque loop. So a bug in any
# one of the three loops breaks the agreement, and a bug in the layer walk
# common to all three still shows up as long as it is not replicated
# identically in every copy — which, since the walk is now open-coded four
# times, is exactly the failure mode worth guarding.
# ---------------------------------------------------------------------------
proc test_loops_agree_on_identities(emu: GBA) =
  echo "the opaque, shade and alpha loops agree where colour math is identity"
  let ppu = emu.ppu
  proc hash_blend(bldcnt_lo, bldcnt_hi, eva, evb, evy: uint8;
                  bg_mode: uint8): uint64 =
    reseed(0x510E527FADE682D1'u64)
    seed_memory(ppu, transparent_bias = true)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = 0
    ppu[0x000] = bg_mode
    ppu[0x001] = 0x1F
    ppu.debug_layer_mask = 0x1F
    # OBJ mode 0 everywhere: a semi-transparent sprite would force alpha and
    # break the "mode 0 takes the opaque loop" premise.
    let spr = ppu.sprites_ptr()
    for i in 0 ..< 128:
      spr[i].attr0 = spr[i].attr0 and not (0b11'u16 shl 10)
    ppu[0x050] = bldcnt_lo
    ppu[0x051] = bldcnt_hi
    ppu[0x052] = eva
    ppu[0x053] = evb
    ppu[0x054] = evy
    # Compare the 15 colour bits only — see `render`'s note on bit 15.
    ppu.render(mask = 0x7FFF)

  for bg_mode in [0'u8, 1'u8, 3'u8, 4'u8]:
    # every layer a 1st and 2nd target, so the effect applies as widely as
    # possible and any per-layer bookkeeping error has room to show
    let plain    = hash_blend(0x00, 0x00, 0, 0, 0, bg_mode)        # opaque loop
    let brighten = hash_blend(0x9F, 0x3F, 0, 0, 0, bg_mode)        # shade, EVY=0
    let darken   = hash_blend(0xDF, 0x3F, 0, 0, 0, bg_mode)        # shade, EVY=0
    let alpha    = hash_blend(0x5F, 0x3F, 16, 0, 0, bg_mode)       # alpha, 16/0
    check(plain == brighten, "mode " & $bg_mode & ": brighten EVY=0 == no effect",
          toHex(plain) & " vs " & toHex(brighten))
    check(plain == darken, "mode " & $bg_mode & ": darken EVY=0 == no effect",
          toHex(plain) & " vs " & toHex(darken))
    check(plain == alpha, "mode " & $bg_mode & ": alpha EVA=16 EVB=0 == no effect",
          toHex(plain) & " vs " & toHex(alpha))

# ---------------------------------------------------------------------------
# 7. The blend BOTTOM search actually selects the right layer.
#
# Test 6 leaves this unguarded: it pins the alpha loop with EVB = 0, which makes
# the bottom contribute nothing, so the bottom search's result cannot affect the
# output. Confirmed by mutation — flipping `bsprio <= w.prio[bidx]` to `<` in
# the bottom walk survives every other test here.
#
# The construction below makes the choice observable. BG0 (priority 0) is the
# top and the only 1st target. OBJ and BG1 both sit at priority 2, and only OBJ
# is a 2nd target. With EVA = 0 / EVB = 16 the blended result is purely the
# bottom, so:
#   * correct — OBJ ties with BG1 and, per GBATEK, an OBJ sits in front of a BG
#     of equal priority, so OBJ is the bottom, is a valid 2nd target, and the
#     pixel blends. Output differs from the unblended top.
#   * broken — BG1 is taken as the bottom instead; BG1 is not a 2nd target, so
#     no blend occurs and the output collapses back to the plain top.
# So "did anything blend at all" is a sufficient oracle, and no reference
# implementation of the blend is needed.
# ---------------------------------------------------------------------------
proc test_blend_bottom_selection(emu: GBA) =
  echo "the blend-bottom search picks OBJ over an equal-priority BG"
  let ppu = emu.ppu
  proc setup(second_target_obj: bool): uint64 =
    reseed(0x1F83D9ABFB41BD6B'u64)
    seed_memory(ppu, transparent_bias = false)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = 0
    ppu[0x000] = 0                          # mode 0
    ppu[0x001] = 0x13                       # BG0 + BG1 + OBJ
    ppu.debug_layer_mask = 0x1F
    ppu[0x008] = 0x00                       # BG0CNT priority 0
    ppu[0x00A] = 0x02                       # BG1CNT priority 2
    # BG0 is the 1st target; the 2nd-target set is the variable under test.
    ppu[0x050] = 0x01 or (1'u8 shl 6)       # BG0 1st target, alpha
    ppu[0x051] = if second_target_obj: 0x10 else: 0x00   # OBJ only, or nothing
    ppu[0x052] = 0                          # EVA = 0
    ppu[0x053] = 16                         # EVB = 16 -> result is the bottom
    # Big opaque sprites at priority 2, tiled across the screen so plenty of
    # columns have an OBJ pixel competing with BG1.
    let spr = ppu.sprites_ptr()
    for i in 0 ..< 128:
      if i < 16:
        spr[i].attr0 = uint16((i div 4) * 40) or (0b00'u16 shl 10) or
                       (0b00'u16 shl 14)    # y, OBJ mode 0 (opaque), square
        spr[i].attr1 = uint16((i mod 4) * 64) or (0b11'u16 shl 14)  # x, 64x64
        spr[i].attr2 = 1'u16 or (2'u16 shl 10)   # tile 1, priority 2
      else:
        spr[i].attr0 = 0; spr[i].attr1 = 0; spr[i].attr2 = 0
    ppu.render(mask = 0x7FFF)

  let blended = setup(true)     # OBJ is a valid 2nd target -> blending happens
  let no_blend = setup(false)   # nothing is a 2nd target  -> top passes through
  check(blended != no_blend,
        "OBJ is selected as the blend bottom (blending is observable)",
        "both " & toHex(blended) & " - the bottom search never reached OBJ")

# ---------------------------------------------------------------------------
# 8. The line really is split into spans on the colour-effect flag.
#
# Every other window test here uses a window state that is uniform across the
# line, so the span splitter is never asked to produce more than one span and a
# splitter that ignores `line_effects` entirely passes them all (verified by
# mutation: dropping `ppu.line_effects[e] == eff` from the run-length loop
# survives tests 1-7).
#
# So: put WIN0 over the left half with the colour-special-effect bit SET inside
# and CLEAR outside, and brighten at full strength. The left half must then match
# a whole-screen brightened render and the right half a whole-screen unbrightened
# one — compared per pixel against those two references rather than by hash, so
# the two halves can be checked independently.
# ---------------------------------------------------------------------------
proc test_effect_spans(emu: GBA) =
  echo "spans split on the per-column colour-effect flag"
  let ppu = emu.ppu
  const SPLIT = 120
  proc setup(effects_on: bool) =
    reseed(0x9B05688C2B3E6C1F'u64)
    seed_memory(ppu, transparent_bias = false)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = 0
    ppu[0x000] = 0                                  # mode 0
    ppu[0x001] = 0x1F
    ppu.debug_layer_mask = 0x1F
    let spr = ppu.sprites_ptr()
    for i in 0 ..< 128:
      spr[i].attr0 = spr[i].attr0 and not (0b11'u16 shl 10)   # OBJ mode 0
    # brighten at full strength when enabled, so the two references differ
    # everywhere a pixel is a 1st target
    ppu[0x050] = (if effects_on: 0x1F'u8 or (2'u8 shl 6) else: 0'u8)
    ppu[0x051] = 0x3F
    ppu[0x054] = 16                                 # EVY = 16

  setup(true)
  discard ppu.render()
  let bright = ppu.framebuffer
  setup(false)
  discard ppu.render()
  let plain = ppu.framebuffer

  # Now the split line: effects inside WIN0 (left half), none outside.
  setup(true)
  ppu[0x040] = uint8(SPLIT); ppu[0x041] = 0         # WIN0H: x2 = 120, x1 = 0
  ppu[0x044] = 160;          ppu[0x045] = 0         # WIN0V: whole screen
  ppu[0x048] = 0x1F or 0x20                         # WININ:  layers + effects
  ppu[0x04A] = 0x1F                                 # WINOUT: layers, NO effects
  ppu[0x001] = ppu[0x001] or 0x20                   # enable WIN0
  discard ppu.render()

  var left_ok = true
  var right_ok = true
  var halves_differ = false
  for row in 0 ..< 160:
    for col in 0 ..< 240:
      let i = row * 240 + col
      if col < SPLIT:
        if ppu.framebuffer[i] != bright[i]: left_ok = false
      else:
        if ppu.framebuffer[i] != plain[i]: right_ok = false
      if bright[i] != plain[i]: halves_differ = true
  check(halves_differ,
        "the two references actually differ (so the comparison has content)")
  check(left_ok, "inside WIN0 (effects on) matches the brightened reference")
  check(right_ok, "outside WIN0 (effects off) matches the plain reference")

# ---------------------------------------------------------------------------
# 9. The uniform-window fast path.
#
# composite() may skip compute_line_enables entirely and composite the whole
# line as one span when it can prove from the registers alone that all 240
# columns would receive the same (enable mask, colour-effect flag) pair. That
# proof lives in window_cover / uniform_window_state, and it is the only place
# in the renderer where a *predicate* decides whether a whole scanline's window
# resolution happens. If the predicate is ever wrong in the permissive
# direction, a line is composited with the wrong layer set — so the tests below
# are all soundness tests: whenever the fast path claims uniformity, the
# general path must agree, byte for byte.
#
# ppu.disable_uniform_window forces the general path, which is what makes the
# frame-level halves of this a true A/B of two implementations rather than a
# self-comparison.
# ---------------------------------------------------------------------------

# Registers are built as raw halfwords and cast, the same way savestate.nim
# reads them back, so the tests can reach values software can write but the
# emulator's own code never constructs (x1 > 240, y2 = 255, ...).
proc winh(x1, x2: int): WINH = cast[WINH](uint16((x1 and 0xFF) shl 8) or uint16(x2 and 0xFF))
proc winv(y1, y2: int): WINV = cast[WINV](uint16((y1 and 0xFF) shl 8) or uint16(y2 and 0xFF))
proc winin_of(b0: int; e0: bool; b1: int; e1: bool): WININ =
  cast[WININ](uint16(b0 and 0x1F) or (if e0: 0x20'u16 else: 0'u16) or
              (uint16(b1 and 0x1F) shl 8) or (if e1: 0x2000'u16 else: 0'u16))
proc winout_of(bo: int; eo: bool; bw: int; ew: bool): WINOUT =
  cast[WINOUT](uint16(bo and 0x1F) or (if eo: 0x20'u16 else: 0'u16) or
               (uint16(bw and 0x1F) shl 8) or (if ew: 0x2000'u16 else: 0'u16))

proc set_dispcnt_windows(ppu: PPU; w0, w1, ow: bool) =
  var d = uint16(ppu.dispcnt)
  d = d and 0x1FFF'u16
  if w0: d = d or 0x2000'u16
  if w1: d = d or 0x4000'u16
  if ow: d = d or 0x8000'u16
  ppu.dispcnt = cast[DISPCNT](d)

# ---------------------------------------------------------------------------
# 9a. window_cover, proved exhaustively over its ENTIRE domain.
#
# window_cover(x1, x2) -> {empty, partial, full} is the subtle part: WIN0H's
# two halves are independent 8-bit values, so x1 > x2 (hardware wraps around
# the right edge), x2 > 240 and x1 > 240 (both clamped) are all reachable, and
# combinations of them are what a naive `x1 <= col < x2` gets wrong.
#
# There are only 65536 of them, so don't sample: check every one against what
# fill_window_cols actually writes, via compute_line_enables with a window
# whose bits differ from the outside bits.
# ---------------------------------------------------------------------------
proc test_window_cover_exhaustive(emu: GBA) =
  echo "window_cover agrees with fill_window_cols over all 65536 (x1, x2)"
  let ppu = emu.ppu
  ppu.debug_layer_mask = 0x1F
  ppu.vcount = 80
  ppu.set_dispcnt_windows(w0 = true, w1 = false, ow = false)
  ppu.win0v  = winv(0, 160)
  ppu.winin  = winin_of(0x1F, true, 0, false)     # inside: all layers, effects
  ppu.winout = winout_of(0x00, false, 0, false)   # outside: nothing, no effects
  for c in 0 ..< 240: ppu.sprite_pixels[c].window = false
  var bad = 0
  var n_full = 0
  var n_empty = 0
  var n_partial = 0
  var first_bad = ""
  for x1 in 0 .. 255:
    for x2 in 0 .. 255:
      ppu.win0h = winh(x1, x2)
      ppu.compute_line_enables()
      var covered = 0
      for c in 0 ..< 240:
        # inside == 0x1F/true, outside == 0x00/false, so either field identifies
        # the column, and checking both also pins the effect flag to the column.
        if ppu.line_enables[c] == 0x1F and ppu.line_effects[c]: inc covered
        elif ppu.line_enables[c] != 0 or ppu.line_effects[c]:
          inc bad
          if first_bad.len == 0: first_bad = "mixed state at x1=" & $x1 & " x2=" & $x2
      let cov = window_cover(ppu.win0h)
      let want = (if covered == 0: wcEmpty elif covered == 240: wcFull else: wcPartial)
      case want
      of wcEmpty: inc n_empty
      of wcFull: inc n_full
      of wcPartial: inc n_partial
      if cov != want:
        inc bad
        if first_bad.len == 0:
          first_bad = "x1=" & $x1 & " x2=" & $x2 & ": window_cover=" & $cov &
                      " but " & $covered & " columns written"
  check(bad == 0, "all 65536 (x1, x2) classified correctly", first_bad)
  # The classification must be non-degenerate: if window_cover returned wcPartial
  # for everything the fast path would simply never fire and this test would pass.
  check(n_full > 0 and n_empty > 0 and n_partial > 0,
        "all three classes are actually reachable",
        "full=" & $n_full & " empty=" & $n_empty & " partial=" & $n_partial)

# ---------------------------------------------------------------------------
# 9b. Vertical ranges: every (y1, y2) against every scanline.
#
# WIN0V/WIN1V wrap the same way WIN0H does, and y2 > 160 is clamped by nothing
# at all — the comparator just never matches above 159. 256 x 256 x 160 is
# 10.5M combinations, which is affordable because the check is O(1): the
# vertical decision must not depend on anything the horizontal one does.
# ---------------------------------------------------------------------------
proc test_vertical_ranges(emu: GBA) =
  echo "WIN0V/WIN1V vertical ranges, every (y1, y2) x every scanline"
  let ppu = emu.ppu
  ppu.set_dispcnt_windows(w0 = true, w1 = true, ow = false)
  var bad = 0
  var n_in = 0
  var first_bad = ""
  for y1 in 0 .. 255:
    for y2 in 0 .. 255:
      ppu.win0v = winv(y1, y2)
      ppu.win1v = winv(y2, y1)      # the mirror image, so both orders are hit
      for row in 0 .. 159:
        ppu.vcount = uint16(row)
        let f = ppu.line_window_flags()
        # The reference: a plain comparator, written out independently.
        let want0 = (if y1 <= y2: row >= y1 and row < y2 else: row >= y1 or row < y2)
        let want1 = (if y2 <= y1: row >= y2 and row < y1 else: row >= y2 or row < y1)
        if f.win0 != want0 or f.win1 != want1:
          inc bad
          if first_bad.len == 0:
            first_bad = "y1=" & $y1 & " y2=" & $y2 & " row=" & $row
        if f.win0: inc n_in
  check(bad == 0, "10.5M (y1, y2, line) vertical decisions match a comparator",
        first_bad)
  check(n_in > 0, "the window is inside on at least some lines")
  # Degenerate ranges called out by name, so a regression names itself.
  for (y1, y2, row, want, name) in [
      (0, 160, 80, true,  "y1=0 y2=160 covers line 80"),
      (0, 0,   80, false, "zero-height y1=y2=0 covers nothing"),
      (80, 80, 80, false, "zero-height y1=y2=80 covers nothing"),
      (0, 255, 159, true, "y2=255 (past the screen) still covers line 159"),
      (200, 255, 80, false, "a range entirely below the screen covers nothing"),
      (200, 100, 80, true,  "a wrapped range y1>y2 covers the middle"),
      (200, 100, 150, false, "...but not line 150"),
      # A wrapped range's upper half extends past the last visible line, so the
      # comparator says "inside" for rows the screen does not have. That is the
      # comparator being a comparator; nothing ever asks it about row 210.
      (200, 100, 210, true, "...and is still inside at the nonexistent row 210")]:
    ppu.win0v = winv(y1, y2)
    ppu.vcount = uint16(row)
    check(ppu.line_window_flags().win0 == want, name)

# ---------------------------------------------------------------------------
# 9c. The differential fuzz: randomize the whole window register space and
# assert the fast path's verdict against the general path's 240 entries.
#
# Every class the fast path has to reason about is deliberately weighted into
# the generator: boundary x/y values, wrapped ranges, both windows on at once,
# every DISPCNT window-enable combination, WININ/WINOUT masks that sometimes
# agree and sometimes do not, the colour-effect bits varied independently of
# the layer masks, a debug layer mask that can zero bits after the AND, and an
# OBJ window covering none / some / all columns.
#
# Two properties are checked. SOUNDNESS (a hard failure): if the fast path says
# uniform, all 240 general-path entries must equal the value it returned.
# COMPLETENESS (reported, not enforced): how often a line really was uniform
# and the fast path failed to notice. Being conservative is safe; the number is
# there so "the fast path never fires" cannot pass silently.
# ---------------------------------------------------------------------------
proc test_uniform_window_fuzz(emu: GBA) =
  echo "uniform-window fast path vs compute_line_enables (differential fuzz)"
  let ppu = emu.ppu
  reseed(0xA54FF53A5F1D36F1'u64)
  # A pool of coordinates that clusters on every boundary the code branches on.
  const EDGES = [0, 1, 2, 119, 120, 121, 159, 160, 161, 238, 239, 240, 241, 254, 255]
  proc coord(): int =
    if (nxt() and 1) == 0: EDGES[int(nxt()) mod EDGES.len]
    else: int(nxt() and 0xFF)

  var unsound = 0
  var missed = 0
  var missed_objwin = 0
  var fired = 0
  var truly_uniform = 0
  var total = 0
  var first_bad = ""
  # Coverage counters, so the run can prove it exercised what it claims to.
  var seen_objwin_partial = 0
  var seen_both_windows = 0
  var seen_wrapped_h = 0
  var seen_nonuniform = 0

  const ITERS = 200_000
  for iter in 0 ..< ITERS:
    let w0 = (nxt() and 1) == 0
    let w1 = (nxt() and 1) == 0
    let ow = (nxt() and 1) == 0
    ppu.set_dispcnt_windows(w0, w1, ow)
    ppu.win0h = winh(coord(), coord())
    ppu.win1h = winh(coord(), coord())
    ppu.win0v = winv(coord(), coord())
    ppu.win1v = winv(coord(), coord())
    ppu.vcount = uint16(int(nxt()) mod 160)
    # Masks: half the time drawn from a tiny set so different sources collide
    # (which is what makes the "partial overlay paints what is already there"
    # branch reachable), half the time fully random.
    proc mask(): int =
      if (nxt() and 1) == 0: [0, 0x1F, 0x07][int(nxt()) mod 3] else: int(nxt() and 0x1F)
    proc flag(): bool = (nxt() and 1) == 0
    ppu.winin  = winin_of(mask(), flag(), mask(), flag())
    ppu.winout = winout_of(mask(), flag(), mask(), flag())
    ppu.debug_layer_mask = (if (nxt() and 7) == 0: uint16(nxt() and 0x1F) else: 0x1F'u16)
    # OBJ window: none, all, a contiguous block, or a scatter.
    let objkind = int(nxt() and 3)
    var any_obj = false
    var all_obj = true
    case objkind
    of 0:
      for c in 0 ..< 240: ppu.sprite_pixels[c].window = false
      all_obj = false
    of 1:
      for c in 0 ..< 240: ppu.sprite_pixels[c].window = true
      any_obj = true
    of 2:
      let lo = int(nxt()) mod 241
      let hi = int(nxt()) mod 241
      for c in 0 ..< 240:
        let v = c >= min(lo, hi) and c < max(lo, hi)
        ppu.sprite_pixels[c].window = v
        if v: any_obj = true else: all_obj = false
    else:
      for c in 0 ..< 240:
        let v = (nxt() and 1) == 0
        ppu.sprite_pixels[c].window = v
        if v: any_obj = true else: all_obj = false
    ppu.line_obj_window = any_obj
    if any_obj and not all_obj and ow: inc seen_objwin_partial

    let f = ppu.line_window_flags()
    if not (f.win0 or f.win1 or f.objwin): continue   # the pre-existing path
    inc total
    if f.win0 and f.win1: inc seen_both_windows
    if (f.win0 and int(ppu.win0h.x1) > int(ppu.win0h.x2)) or
       (f.win1 and int(ppu.win1h.x1) > int(ppu.win1h.x2)): inc seen_wrapped_h

    var ubits: uint16
    var ueff: bool
    let fast = ppu.uniform_window_state(f.win0, f.win1, f.objwin, ubits, ueff)

    ppu.compute_line_enables()
    var uniform = true
    for c in 1 ..< 240:
      if ppu.line_enables[c] != ppu.line_enables[0] or
         ppu.line_effects[c] != ppu.line_effects[0]:
        uniform = false
        break
    if uniform: inc truly_uniform else: inc seen_nonuniform

    if fast:
      inc fired
      var ok = true
      for c in 0 ..< 240:
        if ppu.line_enables[c] != ubits or ppu.line_effects[c] != ueff:
          ok = false
          break
      if not ok:
        inc unsound
        if first_bad.len == 0:
          first_bad = "iter " & $iter & ": fast said (" & toHex(ubits) & ", " &
                      $ueff & ") but general path has (" &
                      toHex(ppu.line_enables[0]) & ", " & $ppu.line_effects[0] &
                      ") .. uniform=" & $uniform
    elif uniform:
      inc missed
      if f.objwin: inc missed_objwin

  check(unsound == 0,
        "no windowed line was composited as uniform when it is not (" &
        $total & " windowed cases, " & $fired & " took the fast path)", first_bad)
  # A generator that only ever produced uniform or only ever produced
  # non-uniform lines would make the above vacuous in one direction or the
  # other, so both have to be present in quantity.
  check(fired > total div 20 and seen_nonuniform > total div 20,
        "the fuzz produced both kinds of line in quantity",
        "fast=" & $fired & " truly_uniform=" & $truly_uniform &
        " nonuniform=" & $seen_nonuniform & " of " & $total)
  check(seen_both_windows > 100 and seen_wrapped_h > 100 and
        seen_objwin_partial > 100,
        "the fuzz reached both-windows, wrapped-x and partial-OBJ-window cases",
        "both=" & $seen_both_windows & " wrapped=" & $seen_wrapped_h &
        " objwin=" & $seen_objwin_partial)
  # Conservatism is safe but not free, so the split is printed rather than
  # asserted. The dominant miss class is a live OBJ window: proving that one is
  # uniform would need a per-column scan, which is the work being avoided, so
  # the fast path declines it unless the OBJ-window state equals the outside
  # state. Real games use the OBJ window for a shaped mask, not a full-screen
  # one, so this costs essentially nothing outside the fuzz.
  echo "    conservative misses (uniform but not detected): ", missed,
       " of ", truly_uniform, " uniform lines (", missed_objwin,
       " of them with a live OBJ window)"

# ---------------------------------------------------------------------------
# 9d. Frame-level A/B: identical framebuffers with the fast path on and off.
#
# 9c proves the predicate agrees with the table. This proves the two code paths
# through composite() agree on pixels, over real renders with real sprites
# (including OBJ-window sprites, which the table-level fuzz can only simulate),
# real blending, and every BG mode.
#
# The second half rewrites the window registers at scanline granularity, which
# is the only way to check that the uniformity decision is made per line with
# live values rather than latched once per frame.
# ---------------------------------------------------------------------------
proc test_uniform_window_frames(emu: GBA) =
  echo "framebuffers are byte-identical with the fast path on and off"
  let ppu = emu.ppu

  proc setup(seed: uint64; bg_mode: uint8; objwin: bool) =
    reseed(seed)
    seed_memory(ppu, transparent_bias = true)
    for a in 0x000'u32 .. 0x055'u32: ppu[a] = 0
    ppu[0x000] = bg_mode
    ppu[0x001] = 0x1F
    ppu.debug_layer_mask = 0x1F
    ppu[0x050] = uint8(nxt() and 0xFF)      # BLDCNT: random targets and mode
    ppu[0x051] = uint8(nxt() and 0x3F)
    ppu[0x052] = uint8(nxt() and 0x1F)      # EVA
    ppu[0x053] = uint8(nxt() and 0x1F)      # EVB
    ppu[0x054] = uint8(nxt() and 0x1F)      # EVY
    let spr = ppu.sprites_ptr()
    for i in 0 ..< 128:
      # Keep the sprites on-screen so they actually contribute, and give a
      # slice of them OBJ-window mode so line_obj_window is genuinely driven.
      spr[i].attr0 = (spr[i].attr0 and not 0x0300'u16) and 0xFCFF'u16
      spr[i].attr0 = spr[i].attr0 or uint16((nxt() mod 160) and 0xFF)
      if objwin and (i and 3) == 0:
        spr[i].attr0 = spr[i].attr0 or (0b10'u16 shl 10)
    ppu.win0h = winh(int(nxt() and 0xFF), int(nxt() and 0xFF))
    ppu.win1h = winh(int(nxt() and 0xFF), int(nxt() and 0xFF))
    ppu.win0v = winv(int(nxt() and 0xFF), int(nxt() and 0xFF))
    ppu.win1v = winv(int(nxt() and 0xFF), int(nxt() and 0xFF))
    ppu.winin  = cast[WININ](uint16(nxt() and 0xFFFF))
    ppu.winout = cast[WINOUT](uint16(nxt() and 0xFFFF))
    ppu.set_dispcnt_windows((nxt() and 1) == 0, (nxt() and 1) == 0, objwin)

  proc run(seed: uint64; bg_mode: uint8; objwin, midframe, disable: bool): uint64 =
    setup(seed, bg_mode, objwin)
    ppu.disable_uniform_window = disable
    # The register rewrites must be identical in both runs, so they are driven
    # off a private counter rather than the shared RNG (whose call sequence the
    # two runs would otherwise share anyway, but this makes it impossible to
    # get wrong).
    var lfsr = seed or 1'u64
    result = 0xCBF29CE484222325'u64
    for row in 0'u16 .. 159'u16:
      if midframe:
        lfsr = lfsr * 6364136223846793005'u64 + 1442695040888963407'u64
        let r = uint32(lfsr shr 33)
        case r and 7
        of 0: ppu.win0h = winh(int((r shr 3) and 0xFF), int((r shr 11) and 0xFF))
        of 1: ppu.win1h = winh(int((r shr 3) and 0xFF), int((r shr 11) and 0xFF))
        of 2: ppu.win0v = winv(int((r shr 3) and 0xFF), int((r shr 11) and 0xFF))
        of 3: ppu.win1v = winv(int((r shr 3) and 0xFF), int((r shr 11) and 0xFF))
        of 4: ppu.winin  = cast[WININ](uint16((r shr 3) and 0xFFFF))
        of 5: ppu.winout = cast[WINOUT](uint16((r shr 3) and 0xFFFF))
        of 6: ppu.set_dispcnt_windows((r and 8) != 0, (r and 16) != 0,
                                      objwin and (r and 32) != 0)
        else: discard
      ppu.vcount = row
      ppu.render_dirty = true
      ppu.skip_render = false
      ppu.scanline()
    for v in ppu.framebuffer:
      result = (result xor uint64(v)) * 0x100000001B3'u64
    ppu.disable_uniform_window = false

  var mismatches = 0
  var first_bad = ""
  var cases = 0
  for bg_mode in [0'u8, 1'u8, 2'u8, 3'u8, 4'u8, 5'u8]:
    for objwin in [false, true]:
      for midframe in [false, true]:
        for trial in 0 ..< 6:
          let seed = 0x9E3779B97F4A7C15'u64 * uint64(trial + 1) +
                     uint64(bg_mode) * 0x1000003 + (if objwin: 7 else: 0) +
                     (if midframe: 13 else: 0)
          inc cases
          let a = run(seed, bg_mode, objwin, midframe, disable = false)
          let b = run(seed, bg_mode, objwin, midframe, disable = true)
          if a != b:
            inc mismatches
            if first_bad.len == 0:
              first_bad = "mode " & $bg_mode & " objwin=" & $objwin &
                          " midframe=" & $midframe & " trial=" & $trial &
                          ": " & toHex(a) & " vs " & toHex(b)
  check(mismatches == 0,
        $cases & " randomized frames identical with and without the fast path",
        first_bad)

  # A control: the toggle must actually change which code runs, or the whole
  # comparison above is one path compared against itself. Count the lines that
  # take the fast path in a configuration where it certainly should (full-width
  # WIN0 over the whole screen, no OBJ window) and in one where it certainly
  # should not (WIN0 over the left half only, with different bits inside).
  proc count_fast(x1, x2, in_bits, out_bits: int): int =
    ppu.set_dispcnt_windows(w0 = true, w1 = false, ow = false)
    ppu.win0h = winh(x1, x2)
    ppu.win0v = winv(0, 160)
    ppu.winin  = winin_of(in_bits, false, 0, false)
    ppu.winout = winout_of(out_bits, false, 0, false)
    ppu.debug_layer_mask = 0x1F
    ppu.line_obj_window = false
    for c in 0 ..< 240: ppu.sprite_pixels[c].window = false
    for row in 0 .. 159:
      ppu.vcount = uint16(row)
      let f = ppu.line_window_flags()
      var ub: uint16
      var ue: bool
      if ppu.uniform_window_state(f.win0, f.win1, f.objwin, ub, ue): inc result
  check(count_fast(0, 240, 0x1F, 0x00) == 160,
        "full-width WIN0 takes the fast path on all 160 lines")
  check(count_fast(0, 120, 0x1F, 0x00) == 0,
        "half-width WIN0 with differing bits takes it on none")

when isMainModule:
  test_pack_domain()
  let emu = make_emu()
  test_coefficient_clamping(emu)
  test_fast_slow_agree(emu)
  test_loops_agree_on_identities(emu)
  test_blend_bottom_selection(emu)
  test_effect_spans(emu)
  test_disabled_bg_buffers_unread(emu)
  test_determinism(emu)
  test_window_cover_exhaustive(emu)
  test_vertical_ranges(emu)
  test_uniform_window_fuzz(emu)
  test_uniform_window_frames(emu)
  echo ""
  if failures == 0:
    echo "ppucomposite: all checks passed"
  else:
    echo "ppucomposite: ", failures, " check(s) FAILED"
    quit(1)
