# Per-frame HLE-vs-REAL envelope trace, split by FIFO side (A/B = L/R),
# from the span-matched capture buffers. Prints frames where the two diverge.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_env --path:src scratch_strag_env.nim
#   /tmp/strag_env <rom> <frames> [thresh=1.5]
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 900
  let thresh = if paramCount() >= 3: parseFloat(paramStr(3)) else: 1.5
  var lastN = 0
  for f in 0 ..< frames:
    emu.step_frame()
    let n = min(mp2kWavCapture.len, realDmaCapture.len)
    if n > lastN:
      var ra, rb, hl, hr: float
      var cnt = 0
      var i = lastN
      while i + 1 < n:
        ra += float(realDmaCapture[i])*float(realDmaCapture[i])
        rb += float(realDmaCapture[i+1])*float(realDmaCapture[i+1])
        hl += float(mp2kWavCapture[i])*float(mp2kWavCapture[i])
        hr += float(mp2kWavCapture[i+1])*float(mp2kWavCapture[i+1])
        cnt.inc
        i += 2
      if cnt > 0:
        let fra = sqrt(ra/float(cnt)); let frb = sqrt(rb/float(cnt))
        let fhl = sqrt(hl/float(cnt)); let fhr = sqrt(hr/float(cnt))
        let rtot = sqrt((ra+rb)/float(cnt))
        let htot = sqrt((hl+hr)/float(cnt))
        if rtot > 3.0 and (rtot > htot*thresh or htot > rtot*thresh):
          echo "f=", f, " REAL A=", fra.formatFloat(ffDecimal,1),
            " B=", frb.formatFloat(ffDecimal,1),
            "  HLE L=", fhl.formatFloat(ffDecimal,1),
            " R=", fhr.formatFloat(ffDecimal,1),
            "  tot ", rtot.formatFloat(ffDecimal,1), " vs ", htot.formatFloat(ffDecimal,1)
    lastN = n

main()
