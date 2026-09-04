#!/usr/bin/env python3
"""Builds psgbias.gba (+ psgbias-auto.gba) — the GBA PSG-volume /
SOUNDBIAS audio probe (tests/roms/README-probes-gba.md, "PSGBIAS").

Not a page ROM: it plays one tone per STEP and shows the step's settings
in 4x-scaled glyphs, so a photo of the screen and a line-out recording
can be matched.  A = next step, B = previous, START = replay the step
(every step starts with a 15-frame silence gap that delimits it in the
recording).  The -auto variant advances a step every 180 frames for an
audio-dump harness (DINGBAT_GBA_AUDIO_DUMP).

Steps (psgbias.s `step_table`):
   0 PSG V2 R0   ch1 square 440 Hz, envelope 15, SOUNDCNT_H PSG volume 2 (100%)
   1 PSG V3 R0   PSG volume 3 ("prohibited": mute? 100%? something else?)
   2 PSG V1 R0   50%
   3 PSG V0 R0   25%
   4 DS SQ R0    DirectSound A full-scale square (+127/-128, 1134.85 Hz),
                 SOUNDBIAS resolution 0 (9-bit / 32.768 kHz)
   5 DS SQ R1    resolution 1 (8-bit / 65.536 kHz)
   6 DS SQ R2    resolution 2
   7 DS SQ R3    resolution 3 (6-bit / 262.144 kHz)
   8 DS TRI R0   DirectSound A small triangle, +/-16 LSB, 141.9 Hz: the
                 resolution mask turns it into a staircase whose step
                 count IS the mask depth
   9 DS TRI R1
  10 DS TRI R2
  11 DS TRI R3

DirectSound: timer 0 at 924 cycles/sample (18157.6 Hz, exactly 304
samples per frame), FIFO A fed by DMA1 from EWRAM.  The whole 256K of
EWRAM is filled with the waveform (periods 16 and 128 samples divide
2^18) and the DMA source simply walks the EWRAM mirrors
(0x02000000-0x02FFFFFF, 15 minutes) — no per-frame re-arming, so the
stream has no seams.  Variables live in IWRAM.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gbedge import font_1bpp, tile_of        # noqa: E402
import romfix                                # noqa: E402

STRINGS = [
    ("str_step", "STEP"),
    ("str_psg", "PSG V"), ("str_ds_sq", "DS SQ"), ("str_ds_tri", "DS TRI"),
    ("str_bias", "BIAS R"),
    ("str_keys", "A NEXT B PREV START REDO"),
    ("str_cnth", "SOUNDCNT H "), ("str_biasr", " BIAS "),
    ("str_title", "PSGBIAS V1"),
]


def gen_inc():
    lines = [".global font_data", "font_data:"]
    fd = font_1bpp()
    for i in range(0, len(fd), 8):
        lines.append("    .byte " + ",".join(f"0x{b:02X}" for b in fd[i:i+8]))
    for label, text in STRINGS:
        lines.append(f".global {label}")
        lines.append(f"{label}:")
        lines.append("    .byte " + ",".join(str(tile_of(c)) for c in text))
        lines.append(f".equ {label}_len, {len(text)}")
    lines.append(".align 2")
    # waveforms, signed 8-bit, one period each (period divides 2^18)
    square = [127] * 8 + [-128] * 8                      # 16 samples
    tri = []                                             # 128 samples
    for i in range(128):                                 # -16 .. +16 .. -16
        v = i if i < 64 else 128 - i                     # 0..64..0
        tri.append(v // 2 - 16)                          # -16..16
    for name, wave in (("wave_square", square), ("wave_tri", tri)):
        lines.append(f".global {name}")
        lines.append(f"{name}:")
        for i in range(0, len(wave), 16):
            lines.append("    .byte " + ",".join(str(v) for v in wave[i:i+16]))
        lines.append(f".equ {name}_len, {len(wave)}")
    lines.append(".align 2")
    with open(os.path.join(HERE, "psgbias_gen.inc"), "w") as f:
        f.write("\n".join(lines) + "\n")


def build(auto):
    out = "psgbias-auto" if auto else "psgbias"
    defs = ["--defsym", "AUTOSTEP=1"] if auto else []
    o, elf, gba = (os.path.join(HERE, out + ext)
                   for ext in (".o", ".elf", ".gba"))
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", *defs,
                    "-o", o, os.path.join(HERE, "psgbias.s")],
                   check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-ld", "-Ttext=0x08000000",
                    "-o", elf, o], check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", elf, gba],
                   check=True, cwd=HERE)
    rom = bytearray(open(gba, "rb").read())
    rom[0xA0:0xAC] = b"PSGBIAS\0\0\0\0\0"
    rom[0xAC:0xB0] = b"APSB"
    rom[0xB0:0xB2] = b"01"
    rom[0xB2] = 0x96
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF
    open(gba, "wb").write(rom)
    romfix.gba_logo(gba)
    os.unlink(o)
    os.unlink(elf)
    print(f"{gba}: {len(rom)} bytes")


if __name__ == "__main__":
    gen_inc()
    build(False)
    build(True)
