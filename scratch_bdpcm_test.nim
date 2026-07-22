import dingbat/gba/gba
# Validate the BDPCM block format (33 bytes / 64 samples: 1 s8 base + 32 nibble
# bytes) and the differential LUT against hand-computed expected values.
# LUT = [0,1,4,9,16,25,36,49,-64,-49,-36,-25,-16,-9,-4,-1]
proc main() =
  # Build one block. base byte = 10. Then nibble bytes drive the running sum.
  var b = newSeq[byte](33)
  b[0] = byte(10)                 # base s8 = 10
  # byte[1] high nibble = index 1 (LUT +1), low nibble = index 2 (LUT +4)
  b[1] = byte((1 shl 4) or 2)
  # byte[2] high nibble = index 8 (LUT -64), low nibble = index 15 (LUT -1)
  b[2] = byte((8 shl 4) or 15)
  # rest zero (index 0 -> +0), so running holds
  let dec = mp2k_decode_bdpcm(b, 6)
  # Expected running accumulator:
  # pos0 (off0): reset to base(10) + LUT[byte1>>4 =1] = 10 + 1 = 11
  # pos1 (off1): 11 + LUT[byte1 &15 =2] = 11 + 4 = 15
  # pos2 (off2): 15 + LUT[byte2>>4 =8] = 15 + (-64) = -49
  # pos3 (off3): -49 + LUT[byte2 &15 =15] = -49 + (-1) = -50
  # pos4 (off4): -50 + LUT[byte3>>4 =0] = -50
  # pos5 (off5): -50 + LUT[byte3 &15 =0] = -50
  let expected = @[11.0'f32, 15, -49, -50, -50, -50]
  var ok = true
  for i in 0 ..< expected.len:
    if abs(dec[i] - expected[i]) > 0.001'f32:
      echo "MISMATCH pos", i, " got=", dec[i], " expected=", expected[i]
      ok = false
  # Block boundary resync: sample 64 must reset to base of block 1.
  var b2 = newSeq[byte](66)
  b2[0] = byte(0)
  b2[33] = byte(50)               # block 1 base = 50
  b2[34] = byte((3 shl 4))        # pos64 high nibble = index 3 (LUT +9)
  let dec2 = mp2k_decode_bdpcm(b2, 65)
  # pos64 (block1, off0): reset to base(50) + LUT[3]=9 = 59 (ignores block0 drift)
  if abs(dec2[64] - 59.0'f32) > 0.001'f32:
    echo "MISMATCH block-resync pos64 got=", dec2[64], " expected=59"; ok = false
  echo (if ok: "BDPCM decode: ALL CHECKS PASS" else: "BDPCM decode: FAILED")
main()
