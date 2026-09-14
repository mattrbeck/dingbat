#!/usr/bin/env python3
"""Build the MP2K probe songs (PROBES.md) and inject one into a host ROM.

    python3 probes.py <probe> <host.gba> <out.gba> [--addr 0x09000100]

The host must already have every song-table entry pointed at --addr
(songtable.py --patch ADDR --extend 32). The blob is written at the file
offset ADDR - 0x08000000. Emerald starts its first song about 3.5 s after
boot and its title song about 1.5 s later — both play the injected header —
so every probe opens with a 120-tick rest and the analysis uses the second
start (tests/mp2k_probe.nim records every note-on).

Tempo 150 => TEMPO byte 75 => exactly one tick per V-blank, so tick counts
below are frame counts.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import songgen as sg

RATE = 13379          # Emerald's engine rate: key 60 = one source sample per output sample
LEAD = 120            # opening rest, frames

def dc_wave(v=64):
    # 64-sample loop of a constant: the mixer output is then the per-sample
    # gain alone, whatever the resampler does.
    return sg.Wave(sg.wave_dc(v, 64), sample_rate=RATE, loop_start=0, name="dc%d" % v)

def p1():
    """Volume staircase, flat envelope. Byte value = f(vol, velocity)."""
    s = sg.Song()
    w = dc_wave(64)
    vg = s.voicegroup
    flat = vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0)
    t = s.track()
    t.tempo(150).voice(flat).pan(64).wait(LEAD)
    for vol in (127, 96, 64, 48, 32, 16, 8, 4, 2, 1):
        t.vol(vol).note(60, 127, 20).wait(10)
    t.vol(127)
    for vel in (127, 96, 64, 32, 16, 8, 1):
        t.note(60, vel, 20).wait(10)
    # DC values: does the byte scale linearly in the sample?
    for v in (127, 32, -64, -128):
        vg.direct_sound(dc_wave(v), attack=255, decay=0, sustain=255, release=0)
    for i in range(4):
        t.voice(flat + 1 + i).note(60, 127, 20).wait(10)
    t.fine()
    return s

def p3():
    """Envelope shapes on a DC sample: attack rates, decay, sustain, release,
    and what the mixer does INSIDE the first frame of a note."""
    s = sg.Song()
    w = dc_wave(64)
    vg = s.voicegroup
    voices = []
    for (a, d, su, r) in ((255, 0, 255, 0), (128, 0, 255, 0), (64, 0, 255, 0),
                          (16, 0, 255, 0), (4, 0, 255, 0),
                          (255, 250, 0, 221),      # Emerald's plucked shape
                          (255, 200, 128, 0),      # decay to a sustain level
                          (255, 0, 255, 128),      # release 128
                          (255, 0, 255, 8)):       # slow release
        voices.append(vg.direct_sound(w, attack=a, decay=d, sustain=su, release=r))
    t = s.track()
    t.tempo(150).pan(64).vol(127).wait(LEAD)
    for v in voices:
        t.voice(v).note(60, 127, 40).wait(40)
    t.fine()
    return s

def p2():
    """Single impulse, fixed rate: kernel + note-on timing. One-shot wave of
    1024 samples with one non-zero sample at 200, played at pcmFreq (TYPE_FIXED)
    and at key 60 (step 1.0), key 72 (step 2.0), key 48 (step 0.5)."""
    s = sg.Song()
    vg = s.voicegroup
    w = sg.Wave(sg.wave_impulse(1024, pos=200, amp=127), sample_rate=RATE, name="imp")
    fixed = vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0, type_bits=sg.TYPE_FIXED)
    free = vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0)
    # a 2-sample step: impulse response of the interpolator
    w2 = sg.Wave([0] * 200 + [127] * 400 + [0] * 424, sample_rate=RATE, name="step")
    stepv = vg.direct_sound(w2, attack=255, decay=0, sustain=255, release=0)
    t = s.track()
    t.tempo(150).pan(64).vol(127).wait(LEAD)
    for _ in range(3):
        t.voice(fixed).note(60, 127, 30).wait(30)
    for key in (60, 72, 48, 67, 53):
        t.voice(free).note(key, 127, 30).wait(30)
    for key in (60, 72, 48):
        t.voice(stepv).note(key, 127, 30).wait(30)
    t.fine()
    return s

def p4():
    """Pitch: a 32-sample sine loop at several keys, plus TUNE/BEND."""
    s = sg.Song()
    vg = s.voicegroup
    w = sg.Wave(sg.wave_sine(32, cycles=1, amp=100), sample_rate=RATE, loop_start=0, name="sin32")
    v = vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0)
    t = s.track()
    t.tempo(150).pan(64).vol(127).voice(v).wait(LEAD)
    for key in (60, 61, 62, 64, 67, 72, 79, 84, 48, 36, 24):
        t.note(key, 127, 40).wait(20)
    t.bendr(2)
    for b in (0, 32, 64, 96, 127):
        t.bend(b).note(60, 127, 40).wait(20)
    t.bend(64)
    for tu in (0, 32, 64, 96, 127):
        t.tune(tu).note(60, 127, 40).wait(20)
    t.fine()
    return s

def p5():
    """Pan law: the same note at pan 0..127 (0x40 = centre)."""
    s = sg.Song()
    vg = s.voicegroup
    v = vg.direct_sound(dc_wave(64), attack=255, decay=0, sustain=255, release=0)
    t = s.track()
    t.tempo(150).vol(127).voice(v).wait(LEAD)
    for p in (0, 16, 32, 48, 63, 64, 65, 80, 96, 112, 127):
        t.pan(p).note(60, 127, 20).wait(10)
    t.fine()
    return s

def p6():
    """Reverb: impulse and DC with the song's reverb bit set."""
    s = sg.Song(reverb=64)
    vg = s.voicegroup
    w = sg.Wave(sg.wave_impulse(1024, pos=0, amp=127), sample_rate=RATE, name="imp0")
    imp = vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0, type_bits=sg.TYPE_FIXED)
    dc = vg.direct_sound(dc_wave(64), attack=255, decay=0, sustain=255, release=0)
    t = s.track()
    t.tempo(150).pan(64).vol(127).wait(LEAD)
    for _ in range(3):
        t.voice(imp).note(60, 127, 30).wait(90)
    t.voice(dc).note(60, 127, 60).wait(120)
    t.fine()
    return s

def p7():
    """Loop points: loop start mid-sample, tiny loops, one-shot end."""
    s = sg.Song()
    vg = s.voicegroup
    # ramp 0..127 over 128 samples, loop back to 96: the byte stream shows where
    # the loop lands (size/loopStart off-by-one, AMBIGUITIES A1)
    ramp = sg.Wave([i for i in range(128)], sample_rate=RATE, loop_start=96, name="ramp")
    # 3-sample loop (shorter than the interpolator's history)
    tiny = sg.Wave([100, 0, -100], sample_rate=RATE, loop_start=0, name="tiny")
    # one-shot ramp: what plays after the end?
    once = sg.Wave([i for i in range(-64, 64)], sample_rate=RATE, name="once")
    vs = [vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0) for w in (ramp, tiny, once)]
    t = s.track()
    t.tempo(150).pan(64).vol(127).wait(LEAD)
    for v in vs:
        for key in (60, 72, 48):
            t.voice(v).note(key, 127, 30).wait(30)
    t.fine()
    return s

def p8():
    """BDPCM: a compressed sine vs its PCM twin, looped and one-shot."""
    s = sg.Song()
    vg = s.voicegroup
    samp = sg.wave_sine(64, cycles=4, amp=100)
    pcm = sg.Wave(samp, sample_rate=RATE, loop_start=0, name="pcm")
    cmp_ = sg.Wave(samp, sample_rate=RATE, loop_start=0, compressed=True, name="cmp")
    pcm1 = sg.Wave(samp, sample_rate=RATE, name="pcm1")
    cmp1 = sg.Wave(samp, sample_rate=RATE, compressed=True, name="cmp1")
    vs = [vg.direct_sound(pcm, 255, 0, 255, 0),
          vg.direct_sound(cmp_, 255, 0, 255, 0, type_bits=sg.TYPE_COMPRESSED),
          vg.direct_sound(pcm1, 255, 0, 255, 0),
          vg.direct_sound(cmp1, 255, 0, 255, 0, type_bits=sg.TYPE_COMPRESSED)]
    t = s.track()
    t.tempo(150).pan(64).vol(127).wait(LEAD)
    for v in vs:
        for key in (60, 67, 53):
            t.voice(v).note(key, 127, 30).wait(30)
    t.fine()
    return s

def p9():
    """Reversed and fixed-rate type bits on an asymmetric ramp."""
    s = sg.Song()
    vg = s.voicegroup
    ramp = sg.Wave([i for i in range(-64, 64)] * 4, sample_rate=RATE, name="ramp4")
    vs = [vg.direct_sound(ramp, 255, 0, 255, 0),
          vg.direct_sound(ramp, 255, 0, 255, 0, type_bits=sg.TYPE_REVERSED),
          vg.direct_sound(ramp, 255, 0, 255, 0, type_bits=sg.TYPE_FIXED),
          vg.direct_sound(ramp, 255, 0, 255, 0, type_bits=sg.TYPE_FIXED | sg.TYPE_REVERSED)]
    t = s.track()
    t.tempo(150).pan(64).vol(127).wait(LEAD)
    for v in vs:
        for key in (60, 72, 48):
            t.voice(v).note(key, 127, 30).wait(30)
    t.fine()
    return s

def p10():
    """Channel cap: 12 tracks each holding a note; then 14 to exceed maxChans."""
    s = sg.Song()
    vg = s.voicegroup
    v = vg.direct_sound(dc_wave(127), attack=255, decay=0, sustain=255, release=0)
    for i in range(14):
        t = s.track()
        t.tempo(150).pan(64).vol(127).voice(v).wait(LEAD + i * 4)
        t.note(60 + i, 127, 90 - i * 4).wait(20)
        t.fine()
    return s

def p11():
    """Loop wraps at fractional steps: a seeded-noise wave with a mid-sample
    loop, held for many wraps at keys whose step is not a whole number."""
    s = sg.Song()
    vg = s.voicegroup
    w = sg.Wave(sg.wave_noise(300, seed=7, amp=100), sample_rate=RATE, loop_start=200, name="nz300")
    v = vg.direct_sound(w, attack=255, decay=0, sustain=255, release=0)
    t = s.track()
    t.tempo(150).pan(64).vol(127).voice(v).wait(LEAD)
    for key in (60, 61, 63, 66, 55, 72):
        t.note(key, 127, 40).wait(50)
    t.fine()
    return s

PROBES = {"p11": p11, "p1": p1, "p2": p2, "p3": p3, "p4": p4, "p5": p5, "p6": p6,
          "p7": p7, "p8": p8, "p9": p9, "p10": p10}

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    addr = 0x09000100
    if "--addr" in sys.argv:
        addr = int(sys.argv[sys.argv.index("--addr") + 1], 16)
    name, host, out = args
    song = PROBES[name]()
    blob, hdr = sg.build(song, addr)
    rom = bytearray(open(host, "rb").read())
    off = addr - 0x08000000
    if off + len(blob) > len(rom):
        raise SystemExit("host ROM too small for the blob at %#x" % addr)
    rom[off:off + len(blob)] = blob
    open(out, "wb").write(rom)
    print("%s: %d bytes at %#x -> %s" % (name, len(blob), hdr, out))

if __name__ == "__main__":
    main()
