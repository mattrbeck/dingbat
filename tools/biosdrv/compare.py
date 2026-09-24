#!/usr/bin/env python3
"""Run a biosdrv probe ROM on the HLE BIOS and on the real BIOS image inside
dingbat (tests/biosdrv_probe.nim) and diff what the sound driver did.

  compare.py <rom.gba> [frames] [--show] [--fifo] [--io] [--polls] [--area]
             [--first]

Reports, marker by marker: the cycle cost of every bracketed call (0xF0 ->
0xF1), then every snapshot byte that differs (SoundArea offsets are printed
relative to its base), and optionally the FIFO byte streams and the I/O
write logs. Outputs are left in /tmp/bd/<rom>.{hle,real}.*.

The real BIOS image is read from BIOS (default: the repo's untracked
tests/roms/gba_bios.bin in the main checkout); it is never copied.
"""
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PROBE = os.environ.get("PROBE", os.path.join(ROOT, "biosdrv_probe"))
BIOS = os.environ.get("BIOS", "/Users/matt/code/dingbat/tests/roms/gba_bios.bin")
OUT = "/tmp/bd"


def regions_of(rom):
    snap = os.path.splitext(rom)[0] + ".snap"
    regs = []
    for part in open(snap).read().strip().split(","):
        a, n = part.split(":")
        regs.append((int(a, 16), int(n, 16)))
    return regs


def run(rom, frames, bios, tag, env_extra=None):
    os.makedirs(OUT, exist_ok=True)
    prefix = os.path.join(OUT, os.path.splitext(os.path.basename(rom))[0] + "." + tag)
    env = dict(os.environ)
    env["BD_SNAP"] = open(os.path.splitext(rom)[0] + ".snap").read().strip()
    if env_extra:
        env.update(env_extra)
    subprocess.run([PROBE, rom, prefix, str(frames), bios], check=True, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return prefix


def load_marks(prefix, regs):
    data = open(prefix + ".marks.bin", "rb").read()
    size = sum(n for _, n in regs)
    rec = 16 + size
    out = []
    for off in range(0, len(data) - rec + 1, rec):
        m, f, c = struct.unpack_from("<IIq", data, off)
        body = data[off + 16: off + rec]
        snaps = []
        p = 0
        for a, n in regs:
            snaps.append(body[p:p + n])
            p += n
        out.append((m, f, c, snaps))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    rom = os.path.abspath(args[0])
    frames = int(args[1]) if len(args) > 1 else 60
    regs = regions_of(rom)
    extra = {"BD_IOREAD": "1"} if "--polls" in flags else None
    ph = run(rom, frames, "hle", "hle", extra)
    pr = run(rom, frames, BIOS, "real", extra)
    mh = load_marks(ph, regs)
    mr = load_marks(pr, regs)
    print(f"marks: hle {len(mh)} real {len(mr)}")
    ndiff = 0
    for i in range(min(len(mh), len(mr))):
        (a, fa, ca, sa), (b, fb, cb, sb) = mh[i], mr[i]
        line = f"#{i:3d} mark {a:02X}/{b:02X}"
        if a == 0xF1 and i > 0:
            dh = ca - mh[i - 1][2]
            dr = cb - mr[i - 1][2]
            line += f"  call cycles hle {dh} real {dr} ({dh - dr:+d})"
        else:
            line += f"  t hle {ca} real {cb} ({ca - cb:+d})"
        diffs = []
        # --area: the SoundArea snapshot only (no RESULT / register block)
        rsel = regs[:1] if "--area" in flags else regs
        for (base, n), x, y in zip(rsel, sa, sb):
            for j in range(n):
                if x[j] != y[j]:
                    diffs.append(f"{base + j:08X}(+{j:03X}) {x[j]:02X}/{y[j]:02X}")
        if diffs:
            ndiff += 1
            line += f"  {len(diffs)} bytes differ"
        if diffs and "--first" in flags:
            print(line)
            for d in diffs[:int(os.environ.get("MAXD", "24"))]:
                print("      " + d)
            break
        if diffs or "--show" in flags or a == 0xF1:
            print(line)
            for d in diffs[:int(os.environ.get("MAXD", "24"))]:
                print("      " + d)
    print(f"marks with differences: {ndiff}")
    if "--fifo" in flags:
        for ch in "AB":
            x = open(ph + f".fifo{ch}.bin", "rb").read()
            y = open(pr + f".fifo{ch}.bin", "rb").read()
            n = min(len(x), len(y))
            first = next((k for k in range(n) if x[k] != y[k]), None)
            print(f"FIFO {ch}: hle {len(x)} real {len(y)} bytes, first diff at {first}")
    if "--polls" in flags:
        # Every call that polls VCOUNT: first/last poll and timer start
        def polls(prefix, marks):
            reads = [int(l.split()[1]) for l in open(prefix + ".ioread.txt") if "04000006" in l]
            io = [(int(l.split()[1]), l) for l in open(prefix + ".io.txt")]
            out = []
            for i in range(1, len(marks)):
                if marks[i][0] == 0xF1 and marks[i - 1][0] == 0xF0:
                    t0, t1 = marks[i - 1][2], marks[i][2]
                    rr = [c for c in reads if t0 <= c <= t1]
                    if not rr:
                        continue
                    ts = [c for c, l in io if t0 <= c <= t1 and "102=80" in l]
                    out.append((i, rr[0] - t0, rr[-1] - t0, ts[0] - t0 if ts else None, t1 - t0))
            return out
        for a, b in zip(polls(ph, mh), polls(pr, mr)):
            print(f"polls #{a[0]}: first {a[1]}/{b[1]} ({a[1]-b[1]:+d}) last {a[2]}/{b[2]} "
                  f"timer {a[3]}/{b[3]} total {a[4]}/{b[4]} ({a[4]-b[4]:+d})")
    if "--io" in flags:
        os.system(f"diff <(cut -d' ' -f3- {ph}.io.txt) <(cut -d' ' -f3- {pr}.io.txt) | head -60")


if __name__ == "__main__":
    main()
