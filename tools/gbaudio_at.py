#!/usr/bin/env python3
"""Dump GB/GBC audio PCM from a dingbat build at an ARBITRARY historical commit.

WHY THIS EXISTS
---------------
`DINGBAT_GB_AUDIO_DUMP` (src/dingbat/gb/apu.nim) only exists from commit
c7fb1a7 (2026-07-26) onwards, so you cannot simply build an old ref and ask it
for audio.  To bisect an audio regression you need the dump at refs that predate
the hook.  This script materialises any ref into a scratch tree, injects an
equivalent hook when the ref lacks one, builds a headless runner and produces a
`.pcm` you can feed to tools/pcmdiff.py and tools/popscan.py.

It NEVER touches the working tree, the index, the stash or HEAD:  the tree comes
from `git archive <ref> | tar -x`, so it is safe to run while other sessions are
using the same repo/worktree.

USAGE
-----
    tools/gbaudio_at.py <ref> [<ref> ...] --rom <path> [options]

    --rom PATH        ROM to run.  Repeatable; every ref runs every ROM.
                      A sibling "<stem>.sav" is copied in automatically when it
                      exists (use --no-sav to suppress, --sav to override).
    --frames N        frames to emulate (default 600).  Frame numbering matches
                      tools/gbfuzz/dingbat_gb_nav: frames 0..N-1 are stepped.
    --script S        input script, comma-separated FRAME:KEY[:HOLD] ("" = none)
    --bios            play the boot ROM (default: GBFUZZ_SKIP_BIOS=1, i.e.
                      dingbat's shipping calibrated post-boot state)
    --bootdir DIR     boot ROM dir for --bios (default /Users/matt/Documents/emu/gb)
    --scratch DIR     scratch root (default $GBAUDIO_SCRATCH or
                      /Users/matt/.claude/jobs/679eeb5e/tmp/hist)
    --rebuild         force re-extract + rebuild even if cached
    --stats           also run tools/popscan.py on each dump
    --repo DIR        repo to read refs from (default: this script's repo)

OUTPUT
------
    <scratch>/pcm/<shortref>__<romstem>.pcm      the dump
    <scratch>/trees/<shortref>/                  extracted + patched source
    <scratch>/runs/<shortref>__<romstem>/        isolated rom + .sav + .ppm
A one-line summary per (ref, rom) goes to stdout;  a ref that fails to build is
reported as SKIP together with the compiler's own error text (the last lines of
the build log, which is kept at <scratch>/trees/<shortref>/build.log).

HOW THE HOOK IS INJECTED
------------------------
See inject_dump_hook().  It is a structural patcher, not a fixed .patch file,
because the code around the mix point drifts a lot across the range of interest.
It is idempotent and it is a no-op on refs that already ship the hook (those use
the real thing, so HEAD is a genuine end-to-end control).

VALIDATION (2026-07-31, re-runnable)
------------------------------------
Three byte-equality checks establish that a dump from this script is the same
artefact as a dump from a normal build:
  * bc43cf7 built directly in the worktree  ==  bc43cf7 via this script.
  * c7fb1a7 (real hook)  ==  625cff6 (injected hook) -- parent/child, and the
    child is the commit that ADDED the hook, so this is the injected hook
    agreeing with the shipping one across the commit that introduced it.
  * bc43cf7 with its shipping hook disabled and the injected hook used instead
    == bc43cf7 with the shipping hook.  Same binary, same ref, both hooks:
    byte-identical.  This is the direct A/B of the two implementations.

RUNNER SELECTION
----------------
If the ref has tools/gbfuzz/dingbat_gb_nav.nim, that is used, so the numbers are
directly comparable with the rest of the gbfuzz tooling.  Older refs get
STANDALONE_RUNNER below, which uses only new_gb/post_init/handle_input/
step_frame -- the four API points that are stable across the whole history
examined (new_gb has kept the same first five parameters since 7f01880).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

DEFAULT_SCRATCH = "/Users/matt/.claude/jobs/679eeb5e/tmp/hist"
DEFAULT_BOOTDIR = "/Users/matt/Documents/emu/gb"

# ---------------------------------------------------------------------------
# The injected hook.  It must produce the SAME BYTES as the real hook that
# landed in c7fb1a7: s16le stereo, interleaved L,R, one frame per mixed sample,
# tapped in get_sample on the mixed sample BEFORE the output/test_harness
# switch (the test_harness branch throws the sample away, so a tap after it
# would dump nothing in a headless build).
#
# Differences from the shipping hook, both deliberate and both byte-neutral for
# a single-GB headless run:
#   * the file is claimed on the first *sample* rather than in new_apu, so the
#     patcher does not have to locate a constructor whose shape drifts;
#   * clamping is spelled out instead of calling system.clamp, so it does not
#     depend on which clamp overload is in scope at a given ref.  int16(float32)
#     truncates toward zero in both spellings.
# ---------------------------------------------------------------------------
HOOK_MODULE = '''
# --- injected by tools/gbaudio_at.py: DINGBAT_GB_AUDIO_DUMP ----------------
# Writes every mixed sample as raw s16le stereo at GB_SAMPLE_RATE (32768 Hz).
# Deliberately OUTSIDE any test_harness gate so the headless build dumps.
var gbad_file: File = nil
var gbad_on = false
var gbad_claimed = false
var gbad_pending = 0

proc gbad_claim() =
  if gbad_claimed: return
  gbad_claimed = true
  let gbad_path = getEnv("DINGBAT_GB_AUDIO_DUMP")
  if gbad_path.len > 0:
    gbad_file = open(gbad_path, fmWrite)
    gbad_on = true

proc gbad_clamp16(v: float32): int16 =
  var x = v * 32767.0'f32
  if x < -32768.0'f32: x = -32768.0'f32
  if x > 32767.0'f32: x = 32767.0'f32
  int16(x)

proc gbad_write(left, right: float32) =
  var gbad_frame: array[2, int16]
  gbad_frame[0] = gbad_clamp16(left)
  gbad_frame[1] = gbad_clamp16(right)
  discard gbad_file.writeBuffer(addr gbad_frame[0], sizeof(gbad_frame))
  inc gbad_pending
  if gbad_pending >= 32768:
    gbad_pending = 0
    gbad_file.flushFile()
# --- end injected ----------------------------------------------------------

'''

HOOK_CALL = '''  # injected by tools/gbaudio_at.py
  if not gbad_claimed: gbad_claim()
  if gbad_on: gbad_write(sample_left, sample_right)
'''

MARKER = "injected by tools/gbaudio_at.py"

# ---------------------------------------------------------------------------
# Standalone runner for refs that predate tools/gbfuzz/dingbat_gb_nav.nim.
# Same argv contract as dingbat_gb_nav so the driver does not branch:
#   <rom> <bootromdir|none> <outprefix> <script> <shots>
# It does not write .ppm/.mem/.state -- only audio matters here.
# ---------------------------------------------------------------------------
STANDALONE_RUNNER = r'''## Minimal headless GB audio dumper -- injected by tools/gbaudio_at.py.
## Same CLI as tools/gbfuzz/dingbat_gb_nav, minus the screenshot outputs.
##   dingbat_gb_audio <rom> <bootromdir|none> <outprefix> <script> <shots>
## Uses only new_gb / post_init / handle_input / step_frame.
import std/[os, strutils]
import dingbat/gb/gb
import dingbat/common/input

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

proc main() =
  let args = commandLineParams()
  if args.len < 5:
    echo "Usage: dingbat_gb_audio <rom> <bootromdir|none> <outprefix> <script> <shots>"
    quit(2)
  let rom_path = args[0]
  let bootdir  = args[1]
  let script   = parse_script(args[3])
  var shots: seq[int]
  for tok in args[4].split(','):
    if tok.len > 0: shots.add(parseInt(tok))

  # Same boot policy as dingbat_gb_nav: play the boot ROM unless
  # GBFUZZ_SKIP_BIOS is set or no boot dir was given.
  let run_bios = getEnv("GBFUZZ_SKIP_BIOS") == "" and bootdir != "none"
  var bootrom = ""
  if run_bios:
    var hdr = newSeq[uint8](0x150)
    let fh = open(rom_path, fmRead)
    discard fh.readBuffer(addr hdr[0], hdr.len)
    fh.close()
    bootrom = bootdir / (if (hdr[0x143] and 0x80) != 0: "cgb_boot.bin" else: "dmg_boot.bin")

  let emu = new_gb(bootrom, rom_path, fifo = true, headless = true,
                   run_bios = run_bios)
  emu.post_init()

  var max_frame = 0
  for s in shots: max_frame = max(max_frame, s)
  for f in 0 .. max_frame:
    for ev in script:
      if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
    emu.step_frame()

main()
'''


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def short(repo: Path, ref: str) -> str:
    r = run(["git", "-C", str(repo), "rev-parse", "--short", ref])
    if r.returncode != 0:
        sys.exit(f"gbaudio_at: cannot resolve ref {ref!r}: {r.stderr.strip()}")
    return r.stdout.strip()


def extract(repo: Path, ref: str, dest: Path, rebuild: bool):
    """Materialise <ref> at <dest> with git archive.  Never touches the worktree."""
    if dest.exists() and not rebuild:
        return
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    tar = dest.parent / (dest.name + ".tar")
    with open(tar, "wb") as fh:
        p = subprocess.run(["git", "-C", str(repo), "archive", ref],
                           stdout=fh, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.exit(f"gbaudio_at: git archive {ref} failed: {p.stderr.decode()}")
    with tarfile.open(tar) as tf:
        tf.extractall(dest)
    tar.unlink()


def inject_dump_hook(apu: Path) -> str:
    """Add a DINGBAT_GB_AUDIO_DUMP tap to a historical src/dingbat/gb/apu.nim.

    Returns "native" (ref already has the hook), "injected" or "already".

    Structure relied on -- verified present at every ref from 7f01880 (the
    oldest commit in the repo) to HEAD:

        proc get_sample*(apu: GbApu; gb: GB) =
          ...
          let sample_right =
            <continuation lines, indent > 2>
          <first line back at indent 2>     <-- tap goes here

    The tap therefore lands after the mix and before whatever the ref does with
    the sample (`when defined(test_harness)` in newer refs, `when
    defined(emscripten)` in the oldest), which is exactly where the shipping
    hook sits.
    """
    text = apu.read_text()
    if "DINGBAT_GB_AUDIO_DUMP" in text and MARKER not in text:
        return "native"
    if MARKER in text:
        return "already"

    lines = text.splitlines(keepends=True)

    gi = next((i for i, l in enumerate(lines)
               if re.match(r"proc get_sample\*\(", l)), None)
    if gi is None:
        raise RuntimeError("gbaudio_at: no `proc get_sample*(` in apu.nim")

    ri = next((i for i in range(gi, len(lines))
               if lines[i].startswith("  let sample_right")), None)
    if ri is None:
        raise RuntimeError("gbaudio_at: no `let sample_right` in get_sample")

    # walk past the continuation of the sample_right expression
    ci = ri + 1
    while ci < len(lines):
        l = lines[ci]
        if l.strip() and not l.startswith("   "):   # back to indent <= 2
            break
        ci += 1
    else:
        raise RuntimeError("gbaudio_at: get_sample ended inside sample_right")

    lines.insert(ci, HOOK_CALL)
    lines.insert(gi, HOOK_MODULE)
    apu.write_text("".join(lines))
    return "injected"


def build(tree: Path, rebuild: bool):
    """Compile the headless runner in <tree>.  Returns (binary_path, err_or_None)."""
    binary = tree / "gbaudio_runner"
    log = tree / "build.log"
    if binary.exists() and not rebuild:
        return binary, None

    nav = tree / "tools/gbfuzz/dingbat_gb_nav.nim"
    if nav.exists():
        src, which = nav, "dingbat_gb_nav"
    else:
        src = tree / "tools/gbaudio_dump.nim"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_text(STANDALONE_RUNNER)
        which = "standalone"

    base = ["nim", "c", "-d:release", "-d:test_harness", "--path:src",
            "--hints:off", "--warnings:off", f"-o:{binary}", str(src)]

    attempts = [base]
    # Refs older than the test_harness gate in apu.nim reference SDL2 symbols
    # unconditionally, and nim.cfg only supplies the SDL link line when
    # test_harness is NOT defined.  Retry once with SDL2 linked in.
    attempts.append(base + ["--passL:-L/opt/homebrew/lib", "--passL:-lSDL2"])

    err = None
    for i, cmd in enumerate(attempts):
        r = run(cmd, cwd=str(tree))
        log.write_text(f"$ {' '.join(cmd)}\n\n{r.stdout}\n{r.stderr}")
        if r.returncode == 0 and binary.exists():
            return binary, None
        err = (r.stdout + r.stderr).strip()
    return None, f"[runner={which}] {err}"


def tail_error(err: str, n: int = 12) -> str:
    lines = [l for l in err.splitlines() if l.strip()]
    return "\n".join(lines[-n:])


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("refs", nargs="+")
    ap.add_argument("--rom", action="append", required=True)
    ap.add_argument("--sav", action="append", default=[])
    ap.add_argument("--no-sav", action="store_true")
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--script", default="")
    ap.add_argument("--bios", action="store_true")
    ap.add_argument("--bootdir", default=DEFAULT_BOOTDIR)
    ap.add_argument("--scratch", default=os.environ.get("GBAUDIO_SCRATCH", DEFAULT_SCRATCH))
    ap.add_argument("--tag", default="",
                    help="suffix for the output names, so two different "
                         "frame/script configs for the same ROM do not "
                         "overwrite each other")
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    a = ap.parse_args()

    repo = Path(a.repo).resolve()
    scratch = Path(a.scratch).resolve()
    (scratch / "pcm").mkdir(parents=True, exist_ok=True)
    (scratch / "trees").mkdir(parents=True, exist_ok=True)
    (scratch / "runs").mkdir(parents=True, exist_ok=True)

    rc = 0
    for ref in a.refs:
        sha = short(repo, ref)
        tree = scratch / "trees" / sha
        extract(repo, ref, tree, a.rebuild)

        apu = tree / "src/dingbat/gb/apu.nim"
        if not apu.exists():
            print(f"SKIP  {sha}  no src/dingbat/gb/apu.nim at this ref")
            rc = 1
            continue
        try:
            hook = inject_dump_hook(apu)
        except RuntimeError as e:
            print(f"SKIP  {sha}  patcher: {e}")
            rc = 1
            continue

        binary, err = build(tree, a.rebuild)
        if binary is None:
            print(f"SKIP  {sha}  BUILD FAILED (hook={hook}); log {tree}/build.log")
            print(tail_error(err))
            rc = 1
            continue

        for i, rom in enumerate(a.rom):
            rom = Path(rom).resolve()
            stem = rom.stem
            suffix = ("__" + re.sub(r"[^A-Za-z0-9]+", "_", a.tag)) if a.tag else ""
            tag = f"{sha}__{re.sub(r'[^A-Za-z0-9]+', '_', stem)}{suffix}"
            rundir = scratch / "runs" / tag
            if rundir.exists():
                shutil.rmtree(rundir)
            rundir.mkdir(parents=True)

            # Copy the ROM (and its battery save) into an isolated directory:
            # dingbat writes <rom-basename>.sav back next to the ROM, and a
            # mutated save would poison every later A/B run.
            local_rom = rundir / rom.name
            shutil.copy2(rom, local_rom)
            if not a.no_sav:
                sav = Path(a.sav[i]) if i < len(a.sav) else rom.with_suffix(".sav")
                if sav.exists():
                    shutil.copy2(sav, rundir / (rom.stem + ".sav"))

            pcm = scratch / "pcm" / f"{tag}.pcm"
            if pcm.exists():
                pcm.unlink()

            env = dict(os.environ)
            env["DINGBAT_GB_AUDIO_DUMP"] = str(pcm)
            if not a.bios:
                env["GBFUZZ_SKIP_BIOS"] = "1"
            else:
                env.pop("GBFUZZ_SKIP_BIOS", None)

            bootdir = a.bootdir if a.bios else "none"
            last = a.frames - 1
            r = run([str(binary), str(local_rom), bootdir,
                     str(rundir / "shot"), a.script, str(last)], env=env)

            size = pcm.stat().st_size if pcm.exists() else 0
            frames = size // 4
            status = "OK  " if size > 0 else "FAIL"
            if size == 0:
                rc = 1
            extra = ""
            if a.stats and size > 0:
                s = run([sys.executable, str(repo / "tools/popscan.py"), str(pcm)])
                # popscan reports per channel ("L: dc_steps=18"); take both
                ms = re.findall(r"dc_steps=(\d+)", s.stdout)
                extra = ("  dc_steps L/R=" + "/".join(ms[:2])) if ms else "  dc_steps=?"
            print(f"{status}  {sha}  {stem:<28} hook={hook:<8} "
                  f"{frames} samples ({size} B){extra}  -> {pcm}")
            if r.returncode != 0:
                print(f"      runner exit {r.returncode}: {tail_error(r.stderr, 4)}")

    return rc


if __name__ == "__main__":
    sys.exit(main())
