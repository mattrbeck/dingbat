## ARM7 sound: 16 channels at 0x4000400 + 16n (SOUNDxCNT, SAD, TMR, PNT,
## LEN), SOUNDCNT 0x4000500, SOUNDBIAS 0x4000504, capture 0x4000508-0x400051F.
## STUB: registers are storage; no mixing yet. TODO(spu): PCM8/16, IMA-ADPCM,
## PSG square (ch 8-13) and noise (ch 14-15), capture, output through the
## frontend's resampler (common/resampler.nim).

type
  Spu* = ref object
    regs*: array[0x120 div 4, uint32]   ## 0x400..0x51F as words

proc new_spu*(): Spu =
  result = Spu()
  result.regs[(0x504 - 0x400) div 4] = 0x200   # SOUNDBIAS after the BIOS ramp

proc read_reg*(s: Spu; offset: uint32): uint32 =
  let i = int((offset - 0x400) shr 2)
  if i < s.regs.len: s.regs[i] else: 0

proc write_reg*(s: Spu; offset: uint32; v, mask: uint32) =
  let i = int((offset - 0x400) shr 2)
  if i < s.regs.len:
    s.regs[i] = (s.regs[i] and not mask) or (v and mask)
