#!/usr/bin/env python3
"""Mixer probe scenarios: generate mix_script.h for mix.c and build
mix_<name>.gba (ROM + .snap) next to this file.

  mixgen.py <name> [...]     build the named scenarios (default: all)

A scenario is a SoundDriverMode value, a frame count, a list of waves and a
list of pokes {frame, SoundArea offset, width, value}; wave pointers are
written as WAVE(n). The waves are this project's own test signals (ramps,
square, noise from a fixed LCG), in the WaveData layout loveemu's MP2K
summary documents.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build as B  # noqa: E402

CH = 0x50          # SoundArea offset of channel 0
CHS = 0x40         # SoundChannel size
# SoundChannel fields
ST, TY, VR, VL, AT, DE, SU, RE, KEY, EV, ER, EL, EVOL, ELEN = range(14)
COUNT, FW, FREQ, WAV, CUR = 0x18, 0x1C, 0x20, 0x24, 0x28


def WAVE(n):
    return 0xEE000000 | n


def ramp(n=64, loop=True, lstart=0, freq=0x4000_0000 >> 0):
    data = [((i * 256 // n) - 128) & 0xFF for i in range(n)]
    return dict(flags=0x4000 if loop else 0, freq=freq, loop=lstart, data=data)


def square(n=32, amp=100, loop=True):
    data = [(amp if i < n // 2 else -amp) & 0xFF for i in range(n)]
    return dict(flags=0x4000 if loop else 0, freq=0, loop=0, data=data)


def noise(n=256, seed=1, loop=True, lstart=0):
    x = seed
    data = []
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        data.append((x >> 16) & 0xFF)
    return dict(flags=0x4000 if loop else 0, freq=0, loop=lstart, data=data)


def chan(frame, c, **fields):
    """Pokes for channel c; status (if given) goes last."""
    names = dict(status=(ST, 1), type=(TY, 1), vr=(VR, 1), vl=(VL, 1), atk=(AT, 1),
                 dec=(DE, 1), sus=(SU, 1), rel=(RE, 1), key=(KEY, 1), ev=(EV, 1),
                 er=(ER, 1), el=(EL, 1), evol=(EVOL, 1), elen=(ELEN, 1),
                 count=(COUNT, 4), fw=(FW, 4), freq=(FREQ, 4), wav=(WAV, 4), cur=(CUR, 4))
    ops = []
    for k, v in fields.items():
        if k == "status":
            continue
        off, w = names[k]
        ops.append((frame, CH + c * CHS + off, w, v))
    if "status" in fields:
        ops.append((frame, CH + c * CHS + ST, 1, fields["status"]))
    return ops


def stop(frame, c):
    """Note-off the way a sequencer does it: OR STOP into the status."""
    return [(frame, CH + c * CHS + ST, 0x81, 0x40)]


def info(frame, off, width, value):
    return [(frame, off, width, value)]


NOTE = dict(type=0x08, vr=127, vl=127, atk=255, dec=0, sus=255, rel=0, status=0x80)

SCENARIOS = {
    # One fixed-rate channel, full volume, instant attack, looping ramp
    "fix1": dict(mode=0x0094F800, frames=12, waves=[ramp()],
                 ops=chan(2, 0, wav=WAVE(0), **NOTE)),
    # Resampled channels at a few frequencies (freq field; key irrelevant)
    "freq": dict(mode=0x0094F800, frames=24, waves=[noise(512)],
                 ops=chan(2, 0, wav=WAVE(0), freq=13379, **dict(NOTE, type=0))
                 + chan(8, 1, wav=WAVE(0), freq=6000, **dict(NOTE, type=0))
                 + chan(14, 2, wav=WAVE(0), freq=40000, **dict(NOTE, type=0))
                 + chan(18, 3, wav=WAVE(0), freq=13379 * 3 // 2, **dict(NOTE, type=0))),
    # Envelopes: attack/decay/sustain/release rates, a note-off, asymmetric
    # volumes; a constant (DC) wave so every byte is the gain
    "env": dict(mode=0x0094F800, frames=40, waves=[dict(flags=0x4000, freq=0, loop=0, data=[100] * 32)],
                ops=chan(2, 0, wav=WAVE(0), **dict(NOTE, atk=40, dec=200, sus=100, rel=180, vr=127, vl=60))
                + chan(2, 1, wav=WAVE(0), **dict(NOTE, atk=255, dec=240, sus=0, rel=0, vr=30, vl=127))
                + chan(2, 2, wav=WAVE(0), **dict(NOTE, atk=7, dec=255, sus=255, rel=250, vr=90, vl=90))
                + chan(2, 3, wav=WAVE(0), **dict(NOTE, atk=255, dec=128, sus=128, rel=128, vr=127, vl=127))
                + chan(20, 0, status=0x40) + chan(22, 2, status=0x40) + chan(24, 3, status=0x40)
                + info(28, 7, 1, 7) + info(32, 7, 1, 1)),
    # Release, pseudo-echo, one-shot ends and loop starts
    "rel": dict(mode=0x0094F800, frames=48,
                waves=[dict(flags=0x4000, freq=0, loop=0, data=[100] * 32),
                       dict(flags=0, freq=0, loop=0, data=[80] * 300),
                       dict(flags=0x4000, freq=0, loop=100, data=[(i * 3) & 0xFF for i in range(160)])],
                ops=chan(2, 0, wav=WAVE(0), **dict(NOTE, rel=200)) + stop(5, 0)
                + chan(2, 1, wav=WAVE(0), **dict(NOTE, rel=0)) + stop(6, 1)
                + chan(2, 2, wav=WAVE(0), **dict(NOTE, atk=20, rel=128, evol=40, elen=5)) + stop(4, 2)
                + chan(2, 3, wav=WAVE(1), **dict(NOTE, type=0x08))
                + chan(3, 4, wav=WAVE(2), **dict(NOTE, type=0x08))
                + chan(10, 5, wav=WAVE(0), **dict(NOTE, status=0xC0))
                + chan(12, 6, wav=WAVE(0), **dict(NOTE, dec=100, sus=20, rel=230)) + stop(13, 6)
                + chan(12, 7, wav=WAVE(1), freq=40000, **dict(NOTE, type=0))
                + chan(20, 0, wav=WAVE(0), **dict(NOTE, rel=250, evol=100, elen=3)) + stop(22, 0)
                + chan(20, 1, wav=WAVE(0), **dict(NOTE, rel=255)) + stop(22, 1)),
    # One resampled channel on an impulse train: the interpolation kernel
    "interp": dict(mode=0x0094F800, frames=10,
                   waves=[dict(flags=0x4000, freq=0, loop=0, data=([120] + [0] * 7) * 8)],
                   ops=chan(2, 0, wav=WAVE(0), freq=6000, **dict(NOTE, type=0, vr=255, vl=127))),
    # The interpolation's fixed point: full-swing noise at two engine rates
    # and odd frequencies, one channel each, full right gain
    "interp2": dict(mode=0x0091F800, frames=12, waves=[noise(256, seed=7)],
                    ops=chan(2, 0, wav=WAVE(0), freq=3333, **dict(NOTE, type=0, vr=255, vl=100))
                    + chan(6, 0, wav=WAVE(0), freq=5000, **dict(NOTE, type=0, vr=255, vl=100))
                    + chan(9, 0, wav=WAVE(0), freq=9001, **dict(NOTE, type=0, vr=255, vl=100))),
    "interp3": dict(mode=0x009BF800, frames=12, waves=[noise(256, seed=9)],
                    ops=chan(2, 0, wav=WAVE(0), freq=12345, **dict(NOTE, type=0, vr=255, vl=100))
                    + chan(6, 0, wav=WAVE(0), freq=30011, **dict(NOTE, type=0, vr=255, vl=100))
                    + chan(9, 0, wav=WAVE(0), freq=77777, **dict(NOTE, type=0, vr=255, vl=100))),
    # More of the same across rates 2, 5, 12 and many frequencies
    "interp4": dict(mode=0x0092F800, frames=40, waves=[noise(1024, seed=11)],
                    ops=sum((chan(2 + 3 * k, 0, wav=WAVE(0), freq=1000 + 2717 * k,
                                  **dict(NOTE, type=0, vr=255, vl=190)) for k in range(12)), [])),
    "interp5": dict(mode=0x0095F800, frames=40, waves=[noise(1024, seed=13)],
                    ops=sum((chan(2 + 3 * k, 0, wav=WAVE(0), freq=777 + 3911 * k,
                                  **dict(NOTE, type=0, vr=255, vl=190)) for k in range(12)), [])),
    "interp6": dict(mode=0x009CF800, frames=40, waves=[noise(1024, seed=17)],
                    ops=sum((chan(2 + 3 * k, 0, wav=WAVE(0), freq=5555 + 6173 * k,
                                  **dict(NOTE, type=0, vr=255, vl=190)) for k in range(12)), [])),
    # Reverb (every slot, so the next-slot tap wraps), rate 2 (spv 132, not a
    # multiple of 16)
    "rev": dict(mode=0x009250FF, frames=40, waves=[noise(300, seed=3)],
                ops=chan(2, 0, wav=WAVE(0), freq=7000, **dict(NOTE, type=0, vr=200, vl=90))
                + chan(4, 1, wav=WAVE(0), **dict(NOTE, type=0x08, vr=60, vl=250))
                + chan(20, 0, status=0x40) + info(24, 5, 1, 0x7F) + info(30, 5, 1, 0x01)),
    # Rate 5 (spv 264) without reverb; PSG-typed channels; 12 channels with
    # maxChans 15; master volume 0; attack landing on 255 exactly; decay
    # landing on sustain exactly
    "misc": dict(mode=0x0095FC00, frames=24, waves=[noise(300, seed=5), dict(flags=0x4000, freq=0, loop=0, data=[90] * 16)],
                 ops=sum((chan(2, c, wav=WAVE(0), freq=5000 + 999 * c, **dict(NOTE, type=0, vr=20 + c, vl=40)) for c in range(12)), [])
                 + chan(3, 1, **dict(NOTE, type=0x01)) + chan(3, 2, **dict(NOTE, type=0x0A))
                 + chan(5, 3, wav=WAVE(1), **dict(NOTE, atk=85, dec=128, sus=127, vr=127, vl=127))
                 + info(12, 7, 1, 0) + info(14, 6, 1, 0) + info(16, 6, 1, 12) + info(16, 7, 1, 15)),
    # Reverb alone: loud noise for a few passes, then silence while the tail
    # decays (the pass writes only the reverb term)
    "revfit": dict(mode=0x009470FF, frames=40, waves=[noise(512, seed=21)],
                   ops=chan(2, 0, wav=WAVE(0), freq=9000, **dict(NOTE, type=0, vr=255, vl=150))
                   + chan(2, 1, wav=WAVE(0), **dict(NOTE, type=0x08, vr=100, vl=255))
                   + chan(12, 0, status=0) + chan(12, 1, status=0) + info(26, 5, 1, 0xC3)),
    "revfit2": dict(mode=0x009470FF, frames=60, waves=[noise(512, seed=23)],
                    ops=chan(2, 0, wav=WAVE(0), freq=9000, **dict(NOTE, type=0, vr=255, vl=255))
                    + chan(2, 1, wav=WAVE(0), **dict(NOTE, type=0x08, vr=255, vl=255))
                    + chan(9, 0, status=0) + chan(9, 1, status=0) + info(9, 5, 1, 0xFF)
                    + chan(20, 0, wav=WAVE(0), freq=9000, **dict(NOTE, type=0, vr=255, vl=255))
                    + chan(20, 1, wav=WAVE(0), **dict(NOTE, type=0x08, vr=255, vl=255))
                    + chan(27, 0, status=0) + chan(27, 1, status=0) + info(27, 5, 1, 0xA0)
                    + chan(40, 0, wav=WAVE(0), freq=9000, **dict(NOTE, type=0, vr=255, vl=255))
                    + chan(47, 0, status=0) + info(47, 5, 1, 0x81)),
}

# Timing scenarios, each under three source-memory settings: the cartridge at
# WAITCNT reset (N 5 / S 3 per halfword), the cartridge at 0x4317 (4 / 2 +
# prefetch), and EWRAM (3 / 3)
MEMS = {"w0": dict(waitcnt=0x0000), "w4317": dict(waitcnt=0x4317), "ram": dict(wave_ram=True),
        "ea": dict(waitcnt=0x0000, area=0x02020000), "q": dict(waitcnt=0x0000, quiet=True)}
TIMING = {
    # one fixed-rate channel on a 64-byte loop (3.5 wraps a pass)
    "tfix": dict(mode=0x0094F800, frames=10, waves=[ramp()],
                 ops=chan(2, 0, wav=WAVE(0), **NOTE)),
    # resampled at ratios below 1, 1-2, 2-3 and above 3, one after another
    "tres": dict(mode=0x0094F800, frames=26, waves=[noise(2048, seed=31)],
                 ops=chan(2, 0, wav=WAVE(0), freq=7000, **dict(NOTE, type=0))
                 + chan(8, 0, wav=WAVE(0), freq=19000, **dict(NOTE, type=0))
                 + chan(14, 0, wav=WAVE(0), freq=33000, **dict(NOTE, type=0))
                 + chan(20, 0, wav=WAVE(0), freq=47000, **dict(NOTE, type=0))),
    # high ratios: 4-16 source samples per output
    "tfast": dict(mode=0x0094F800, frames=26, waves=[noise(4096, seed=37)],
                  ops=chan(2, 0, wav=WAVE(0), freq=60000, **dict(NOTE, type=0))
                  + chan(8, 0, wav=WAVE(0), freq=90000, **dict(NOTE, type=0))
                  + chan(14, 0, wav=WAVE(0), freq=140000, **dict(NOTE, type=0))
                  + chan(20, 0, wav=WAVE(0), freq=200000, **dict(NOTE, type=0))),
    "tfast2": dict(mode=0x0094F800, frames=32, waves=[noise(8192, seed=41)],
                   ops=chan(2, 0, wav=WAVE(0), freq=113700, **dict(NOTE, type=0))
                   + chan(8, 0, wav=WAVE(0), freq=167000, **dict(NOTE, type=0))
                   + chan(14, 0, wav=WAVE(0), freq=280000, **dict(NOTE, type=0))
                   + chan(20, 0, wav=WAVE(0), freq=400000, **dict(NOTE, type=0))
                   + chan(26, 0, wav=WAVE(0), freq=16000, **dict(NOTE, type=0))),
    # short loops (7 samples after a 3-sample head): wraps inside every
    # advance pattern
    "twrap": dict(mode=0x0094F800, frames=40,
                  waves=[dict(flags=0x4000, freq=0, loop=3, data=[(i * 37) & 0xFF for i in range(10)])],
                  ops=chan(2, 0, wav=WAVE(0), freq=9000, **dict(NOTE, type=0))
                  + chan(8, 0, wav=WAVE(0), freq=20000, **dict(NOTE, type=0))
                  + chan(14, 0, wav=WAVE(0), freq=33000, **dict(NOTE, type=0))
                  + chan(20, 0, wav=WAVE(0), freq=47000, **dict(NOTE, type=0))
                  + chan(26, 0, wav=WAVE(0), freq=87000, **dict(NOTE, type=0))
                  + chan(32, 0, wav=WAVE(0), **NOTE)),
    # wraps at every position of 8-16 advances (a 53-sample loop)
    "twrap2": dict(mode=0x0094F800, frames=40,
                   waves=[dict(flags=0x4000, freq=0, loop=7, data=[(i * 29) & 0xFF for i in range(60)])],
                   ops=chan(2, 0, wav=WAVE(0), freq=115000, **dict(NOTE, type=0))
                   + chan(12, 0, wav=WAVE(0), freq=160000, **dict(NOTE, type=0))
                   + chan(22, 0, wav=WAVE(0), freq=205000, **dict(NOTE, type=0))
                   + chan(32, 0, wav=WAVE(0), freq=120000, **dict(NOTE, type=0))),
    # one-shot ends mid-pass, fixed and resampled, and a loop wrap resampled
    "tend": dict(mode=0x0094F800, frames=12,
                 waves=[dict(flags=0, freq=0, loop=0, data=[40] * 100),
                        dict(flags=0x4000, freq=0, loop=10, data=[50] * 40)],
                 ops=chan(2, 0, wav=WAVE(0), **NOTE)
                 + chan(4, 0, wav=WAVE(0), freq=5000, **dict(NOTE, type=0))
                 + chan(6, 0, wav=WAVE(1), freq=21000, **dict(NOTE, type=0))
                 + chan(8, 0, wav=WAVE(1), **NOTE)),
}
for _n, _s in TIMING.items():
    for _m, _extra in MEMS.items():
        SCENARIOS[f"{_n}_{_m}"] = dict(_s, **_extra)


def gen_header(s, path):
    lines = ["// generated by mixgen.py", f"#define MIX_MODE 0x{s['mode']:08X}u",
             f"#define MIX_FRAMES {s['frames']}u", "static const Op script[] = {"]
    for f, off, w, v in sorted(s["ops"], key=lambda o: o[0]):
        lines.append(f"  {{{f}, 0x{off:X}, {w}, 0, 0, 0x{v:08X}u}},")
    lines.append("};")
    for i, w in enumerate(s["waves"]):
        hdr = f"WAVE_HDR(0x{w['flags']:X}, 0x{w['freq']:X}u, {w['loop']}u, {len(w['data'])}u)"
        body = ", ".join(str(b) for b in w["data"])
        lines.append(f"static const u8 wave{i}[] __attribute__((aligned(4))) = {{{hdr}, {body}}};")
    lines.append("const u8 *const waves[] = {" + ", ".join(f"wave{i}" for i in range(len(s["waves"]))) + "};")
    lines.append("const u32 wave_sizes[] = {" + ", ".join(str(16 + len(w["data"])) for w in s["waves"]) + "};")
    lines.append(f"#define MIX_NWAVES {len(s['waves'])}")
    if "waitcnt" in s:
        lines.insert(1, f"#define MIX_WAITCNT 0x{s['waitcnt']:04X}")
    if s.get("wave_ram"):
        lines.insert(1, "#define MIX_WAVE_RAM 1")
    if s.get("quiet"):
        lines.insert(1, "#define MIX_QUIET 1")
    open(path, "w").write("\n".join(lines) + "\n")


def build(name):
    s = SCENARIOS[name]
    gdir = os.path.join("/tmp/bd/mixgen", name)
    os.makedirs(gdir, exist_ok=True)
    gen_header(s, os.path.join(gdir, "mix_script.h"))
    out = "mix_" + name
    elf = os.path.join(gdir, out + ".elf")
    gba = os.path.join(HERE, out + ".gba")
    area = s.get("area", 0x03004000)
    subprocess.run([f"{B.DKA}/arm-none-eabi-gcc", "-mthumb", "-mcpu=arm7tdmi", "-O2",
                    "-specs=gba.specs", f"-DAREA_ADDR=0x{area:08X}", "-I", gdir, "-I", HERE, "-o", elf,
                    os.path.join(HERE, "mix.c"), os.path.join(HERE, "rt.s")], check=True)
    subprocess.run([f"{B.DKA}/arm-none-eabi-objcopy", "-O", "binary", elf, gba], check=True)
    subprocess.run([B.GBAFIX, gba, "-tMIX" + name.upper()[:9], "-cBDRV", "-r0"],
                   check=True, capture_output=True)
    regs = B.sym(elf, "bd_regs")
    snap = f"{area:08X}:FB0,03007FF0:10,02030000:100,{regs:08X}:20"
    open(os.path.join(HERE, out + ".snap"), "w").write(snap + "\n")
    print(f"{gba}: {os.path.getsize(gba)} bytes")


if __name__ == "__main__":
    for n in sys.argv[1:] or sorted(SCENARIOS):
        build(n)
