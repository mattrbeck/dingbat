#!/usr/bin/env python3
"""Drive a game's MP2K mixer directly: build a host whose songs are all
silent (songtable.py --patch + probes.py p0), place WaveData blobs of our own
in the ROM copy, and emit a per-frame script of SoundChannel writes for
tests/mp2k_probe.nim (DINGBAT_PROBE_SCRIPT). The game boots and initialises
its driver as usual; its sequencer never allocates a channel, so the channel
table is ours and the mixer plays exactly what the script says.

    python3 rig.py <scenario> <silent-host.gba> <out.gba> <out.json>

Waves go at WAVE_BASE (0x09010000 in the padded copy), the script's frames
count from boot; START_FRAME leaves the game time to bring the driver up.
Scenarios: dc (gain), imp (kernel/timing), env (attack/decay/release), iec
(pseudo-echo floor), types (loop/reversed/fixed/compressed), side (direct
per-side bytes), stereo (pan bytes), cap (all channels).
"""
import sys, os, json, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import songgen as sg

WAVE_BASE = 0x09010000
START_FRAME = 420          # after the driver is up on every host tried
RATE = 13379

class Rig:
    def __init__(self):
        self.blobs = []      # (addr, bytes)
        self.next = WAVE_BASE
        self.script = []
    def wave(self, w, **kw):
        blob = w.encode(**kw)
        addr = self.next
        self.blobs.append((addr, blob))
        self.next = (addr + len(blob) + 15) & ~15
        return addr
    def note(self, f, ch, wave, freq=RATE, vr=127, vl=127, atk=255, dec=0, sus=255, rel=0,
             type_=0, echo_vol=0, echo_len=0, ct=0, status=0x80):
        self.script.append({"f": f, "ch": ch, "set": {"status": status, "type": type_, "vr": vr, "vl": vl,
                            "atk": atk, "dec": dec, "sus": sus, "rel": rel, "echo_vol": echo_vol,
                            "echo_len": echo_len, "wave": wave, "freq": freq, "ct": ct}})
    def stop(self, f, ch):
        self.script.append({"f": f, "ch": ch, "or": {"status": 0x40}})
    def set(self, f, ch, **fields):
        self.script.append({"f": f, "ch": ch, "set": fields})
    def si(self, f, **fields):
        self.script.append({"f": f, "si": fields})

def dc(v=64, n=64, loop=True):
    return sg.Wave(sg.wave_dc(v, n), sample_rate=RATE, loop_start=0 if loop else None)

def scenario(name):
    r = Rig(); F = START_FRAME
    if name == "dc":
        w = r.wave(dc(64))
        for i, (vr, vl) in enumerate([(127, 127), (96, 64), (64, 96), (32, 0), (0, 32), (1, 1)]):
            r.note(F + i * 30, 0, w, vr=vr, vl=vl); r.stop(F + i * 30 + 20, 0)
        for i, m in enumerate([15, 12, 8, 4, 0]):
            r.si(F + 200 + i * 30, master=m); r.note(F + 200 + i * 30, 0, w); r.stop(F + 200 + i * 30 + 20, 0)
        r.si(F + 360, master=15)
    elif name == "imp":
        w = r.wave(sg.Wave(sg.wave_impulse(1024, pos=200, amp=127), sample_rate=RATE))
        for i, freq in enumerate([RATE, 2 * RATE, RATE // 2, 20045, 3 * RATE, 4 * RATE, RATE // 4]):
            r.note(F + i * 40, 0, w, freq=freq); r.stop(F + i * 40 + 30, 0)
        r.note(F + 300, 0, w, type_=0x08); r.stop(F + 330, 0)
    elif name == "env":
        w = r.wave(dc(64))
        for i, (a, d, su, re) in enumerate([(4, 0, 255, 0), (32, 0, 255, 0), (255, 250, 0, 0), (255, 240, 96, 0),
                                            (255, 0, 255, 128), (255, 0, 255, 200), (255, 0, 255, 1), (255, 0, 255, 255)]):
            f = F + i * 60
            r.note(f, 0, w, atk=a, dec=d, sus=su, rel=re); r.stop(f + 30, 0)
    elif name == "iec":
        w = r.wave(dc(64))
        for i, (re, ev, ln) in enumerate([(200, 40, 8), (128, 40, 8), (0, 40, 8), (200, 40, 1), (200, 40, 0),
                                          (200, 0, 8), (255, 40, 4), (200, 200, 3)]):
            f = F + i * 60
            r.note(f, 0, w, rel=re, echo_vol=ev, echo_len=ln); r.stop(f + 20, 0)
    elif name == "types":
        ramp = sg.Wave([i for i in range(-64, 64)] * 2, sample_rate=RATE, loop_start=128)
        cmp_ = sg.Wave(sg.wave_sine(64, cycles=4, amp=100), sample_rate=RATE, loop_start=0, compressed=True)
        once = sg.Wave([i for i in range(-64, 64)], sample_rate=RATE)
        wr, wc, wo = r.wave(ramp), r.wave(cmp_), r.wave(once)
        i = 0
        for wave, t in [(wr, 0), (wr, 0x10), (wr, 0x08), (wr, 0x18), (wc, 0x20), (wc, 0x30), (wo, 0), (wo, 0x10)]:
            for freq in (RATE, 20045, RATE // 2):
                r.note(F + i * 30, 0, wave, freq=freq, type_=t); r.stop(F + i * 30 + 20, 0); i += 1
        # start offsets: does the mixer honour ct at START?
        for ct in (0, 100, 200):
            r.note(F + i * 30, 0, wo, ct=ct); r.stop(F + i * 30 + 20, 0); i += 1
    elif name == "offs":
        # start offsets on a looping wave and a one-shot: honoured or stale?
        ramp = sg.Wave([i for i in range(-64, 64)] * 4, sample_rate=RATE, loop_start=256)
        once = sg.Wave([i for i in range(-64, 64)] * 4, sample_rate=RATE)
        wr, wo = r.wave(ramp), r.wave(once)
        i = 0
        for wave in (wr, wo):
            for ct in (0, 100, 300, 500):
                r.note(F + i * 30, 0, wave, ct=ct); r.stop(F + i * 30 + 20, 0); i += 1
    elif name == "side":
        # write the per-side bytes ourselves with the envelope parked (attack 0
        # keeps ev at 0): is +0x0A/+0x0B what the mixer multiplies by?
        w = r.wave(dc(64))
        r.note(F, 0, w, atk=0, sus=255, rel=0)
        for i, (a, b) in enumerate([(200, 100), (100, 200), (255, 0), (0, 255), (128, 128)]):
            r.set(F + 2 + i * 10, 0, evr=a, evl=b)
        r.stop(F + 70, 0)
    elif name == "cap":
        w = r.wave(dc(32))
        for c in range(12):
            r.note(F + c * 4, c, w, freq=RATE + c * 97); r.stop(F + 120 - c * 2, c)
    else:
        raise SystemExit("unknown scenario " + name)
    return r

def main():
    name, host, out, outjs = sys.argv[1:5]
    r = scenario(name)
    rom = bytearray(open(host, "rb").read())
    for addr, blob in r.blobs:
        off = addr - 0x08000000
        rom[off:off + len(blob)] = blob
    open(out, "wb").write(rom)
    json.dump(sorted(r.script, key=lambda n: n["f"]), open(outjs, "w"))
    print("%s: %d waves, %d writes, frames %d..%d -> %s" % (name, len(r.blobs), len(r.script),
          r.script[0]["f"], r.script[-1]["f"], out))

if __name__ == "__main__":
    main()
