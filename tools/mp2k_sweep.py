#!/usr/bin/env python3
"""Parallel driver for the MP2K HLE archive sweep (tests/mp2k_sweep.nim).

For each ROM in the picked list: copy it into a per-worker scratch subdir
(the emulator writes .sav next to the ROM — never boot from the archive),
run the probe binary for N frames, append its JSON result line to a JSONL
checkpoint, and delete the copy + any save files. Resumable: ROMs already
present in the output JSONL are skipped.

Usage: mp2k_sweep.py <picked.txt> <romdir> <scratchdir> <out.jsonl>
           [--bin PATH] [--frames 900] [--workers 8] [--limit N] [--nohle]
"""
import argparse, json, os, shutil, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

def run_one(bin_path, rom_src, workdir, frames, timeout, nohle):
    os.makedirs(workdir, exist_ok=True)
    # clear leftovers from a previous (possibly killed) task
    for f in os.listdir(workdir):
        try: os.remove(os.path.join(workdir, f))
        except OSError: pass
    dst = os.path.join(workdir, "rom.gba")
    shutil.copyfile(rom_src, dst)
    env = dict(os.environ)
    env["DINGBAT_SWEEP_TIMEOUT"] = str(timeout)
    if nohle:
        env["DINGBAT_NOHLE"] = "1"
    rec = {"rom": os.path.basename(rom_src)}
    t0 = time.time()
    try:
        p = subprocess.run([bin_path, dst, str(frames)], env=env,
                           capture_output=True, text=True,
                           timeout=timeout + 60)
        # harness prints exactly one JSON line (last line starting with '{')
        payload = None
        for line in reversed(p.stdout.splitlines()):
            if line.startswith("{"):
                payload = json.loads(line)
                break
        if payload is not None:
            payload["rom"] = rec["rom"]        # replace copy name w/ real name
            rec = payload
            rec["status"] = "crash" if "crash" in payload else \
                            ("timeout" if payload.get("timeout") else "ok")
        else:
            rec["status"] = "crash"
        if p.returncode != 0:
            rec["status"] = "crash"
            rec["exit"] = p.returncode
            if p.stderr:
                rec["stderr"] = p.stderr.strip()[-400:]
    except subprocess.TimeoutExpired:
        rec["status"] = "hard-timeout"
    rec.setdefault("wall_s", round(time.time() - t0, 2))
    for f in os.listdir(workdir):
        try: os.remove(os.path.join(workdir, f))
        except OSError: pass
    return rec

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("picked"); ap.add_argument("romdir")
    ap.add_argument("scratch"); ap.add_argument("out")
    ap.add_argument("--bin", default="./mp2k_sweep")
    ap.add_argument("--frames", type=int, default=900)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--nohle", action="store_true")
    args = ap.parse_args()

    done = set()
    if os.path.exists(args.out):
        with open(args.out) as f:
            for line in f:
                try: done.add(json.loads(line)["rom"])
                except Exception: pass
    roms = [r.strip() for r in open(args.picked) if r.strip()]
    todo = [r for r in roms if r not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f"{len(roms)} picked, {len(done)} done, {len(todo)} to run",
          flush=True)

    lock = threading.Lock()
    out = open(args.out, "a")
    slot_ids = list(range(args.workers))
    t0 = time.time()
    n_done = [0]

    def task(rom):
        with lock:
            slot = slot_ids.pop()
        try:
            rec = run_one(args.bin, os.path.join(args.romdir, rom),
                          os.path.join(args.scratch, f"w{slot}"),
                          args.frames, args.timeout, args.nohle)
        except Exception as e:
            rec = {"rom": rom, "status": "driver-error", "err": str(e)}
        finally:
            with lock:
                slot_ids.append(slot)
        with lock:
            out.write(json.dumps(rec) + "\n")
            out.flush()
            n_done[0] += 1
            if n_done[0] % 25 == 0:
                el = time.time() - t0
                print(f"{n_done[0]}/{len(todo)} in {el:.0f}s "
                      f"({el/n_done[0]:.2f} s/rom)", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(ex.map(task, todo))
    out.close()
    print("done", flush=True)

main()
