import dingbat/gba/gba
# Validate the BDPCM block format (33 bytes / 64 samples: 1 s8 base + 32 nibble
# bytes) and the differential LUT against hand-computed expected values, per the
# shipped decoder (SoundMainRAM_Unk2 in pret pokeemerald src/m4a_1.s):
#   - sample 0 of a block is the RAW s8 base byte
#   - sample 1 uses the LOW nibble of the first delta byte (high nibble unused)
#   - each subsequent byte supplies its high nibble, then its low nibble
#   - the accumulator wraps at 8 bits (strb/ldrsb in the driver)
# LUT = [0,1,4,9,16,25,36,49,-64,-49,-36,-25,-16,-9,-4,-1]
proc main() =
  # Build one block. base byte = 10. Then nibble bytes drive the running sum.
  var b = newSeq[byte](33)
  b[0] = byte(10)                 # base s8 = 10
  # byte[1] high nibble = index 1 (UNUSED), low nibble = index 2 (LUT +4)
  b[1] = byte((1 shl 4) or 2)
  # byte[2] high nibble = index 8 (LUT -64), low nibble = index 15 (LUT -1)
  b[2] = byte((8 shl 4) or 15)
  # rest zero (index 0 -> +0), so running holds
  let dec = mp2k_decode_bdpcm(b, 6)
  # Expected running accumulator:
  # pos0 (off0): raw base = 10  (byte1's high nibble is never read)
  # pos1 (off1): 10 + LUT[byte1 &15 =2] = 10 + 4 = 14
  # pos2 (off2): 14 + LUT[byte2>>4 =8] = 14 + (-64) = -50
  # pos3 (off3): -50 + LUT[byte2 &15 =15] = -50 + (-1) = -51
  # pos4 (off4): -51 + LUT[byte3>>4 =0] = -51
  # pos5 (off5): -51 + LUT[byte3 &15 =0] = -51
  let expected = @[10.0'f32, 14, -50, -51, -51, -51]
  var ok = true
  for i in 0 ..< expected.len:
    if abs(dec[i] - expected[i]) > 0.001'f32:
      echo "MISMATCH pos", i, " got=", dec[i], " expected=", expected[i]
      ok = false
  # Block boundary resync: sample 64 must reset to the raw base of block 1
  # (the high nibble of block 1's first delta byte is unused).
  var b2 = newSeq[byte](66)
  b2[0] = byte(0)
  b2[33] = byte(50)               # block 1 base = 50
  b2[34] = byte((3 shl 4))        # high nibble (index 3) is UNUSED at off0/off1
  let dec2 = mp2k_decode_bdpcm(b2, 65)
  if abs(dec2[64] - 50.0'f32) > 0.001'f32:
    echo "MISMATCH block-resync pos64 got=", dec2[64], " expected=50"; ok = false
  # 8-bit wraparound: base 120 + LUT[7]=+49 = 169 -> wraps to -87 as s8.
  var b3 = newSeq[byte](33)
  b3[0] = byte(120)
  b3[1] = byte(7)                 # low nibble index 7 (LUT +49)
  let dec3 = mp2k_decode_bdpcm(b3, 2)
  if abs(dec3[1] - (-87.0'f32)) > 0.001'f32:
    echo "MISMATCH wrap pos1 got=", dec3[1], " expected=-87"; ok = false
  echo (if ok: "BDPCM decode: ALL CHECKS PASS" else: "BDPCM decode: FAILED")
  if not ok: quit(1)
main()
