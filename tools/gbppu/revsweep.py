#!/usr/bin/env python3
"""Which currently-FAILING self-checking rows pass on some other revision?

A row that is red on the machine it is scored on but green on another is a
much smaller problem than one that is red everywhere: the behaviour is
implemented, it is the per-revision gating that is wrong. This sweeps every
failing mooneye / wilbertpol / AGE row (all boolean, all self-checking via the
Fibonacci-register protocol) across every revision dingbat models.
"""
import re, os, subprocess, collections, sys

W = "/Users/matt/code/dingbat/.claude/worktrees/win-hold-zero-fix"
ROMS = "/Users/matt/.claude/jobs/e4d5536b/tmp/romcache/game-boy-test-roms"
PASS = "\N{OK HAND SIGN}"

SUITES = {
    "mooneye/":             (ROMS + "/mooneye-test-suite", ["--mode=mooneye"]),
    "mooneye-wilbertpol/":  (ROMS + "/mooneye-test-suite-wilbertpol",
                             ["--mode=mooneye", "--ed-breakpoint"]),
    "age/":                 (ROMS + "/age-test-roms",
                             ["--mode=mooneye", "--bb-breakpoint"]),
}
DMG_MODELS = ["dmg0", "dmgABC", "mgb", "sgb", "sgb2"]
CGB_MODELS = ["cgb0", "cgbab", "cgbc", "cgbd", "cgbe", "agb"]

failing = []
for line in open(W + "/tests/results.md"):
    m = re.match(r'^\| ([^|]+) \| ([^|]*) \| (.*?)\s*\|\s*$', line)
    if not m:
        continue
    name, dev, res = (g.strip() for g in m.groups())
    if PASS in res or name in ("Test", "Suite"):
        continue
    for pfx in SUITES:
        if name.startswith(pfx):
            failing.append((pfx, name, dev))
            break

print("failing self-checking rows to sweep:", len(failing), flush=True)

def rom_for(pfx, name):
    rel = name[len(pfx):].split("@")[0]
    base, args = SUITES[pfx]
    for ext in (".gb", ".gbc"):
        p = os.path.join(base, rel + ext)
        if os.path.exists(p):
            return p, args
    return None, args

results = {}
for i, (pfx, name, dev) in enumerate(failing):
    rom, extra = rom_for(pfx, name)
    if not rom:
        continue
    row = {}
    for m in DMG_MODELS + CGB_MODELS:
        cmd = [W + "/dingbat_test", rom] + extra + \
              ["--model=" + m, "--timeout=900", "--nosave"]
        if m in CGB_MODELS:
            cmd.append("--cgb")
        try:
            out = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=120).stdout
        except subprocess.TimeoutExpired:
            out = ""
        row[m] = "Mooneye: PASS" in out
    results[name] = row
    if any(row.values()):
        good = [m for m, v in row.items() if v]
        print("  PASSES SOMEWHERE: %-58s -> %s" % (name, ", ".join(good)), flush=True)
    if (i + 1) % 20 == 0:
        print("  ...%d/%d swept" % (i + 1, len(failing)), flush=True)

anywhere = {k: v for k, v in results.items() if any(v.values())}
print("\n==== swept %d rows; %d pass on at least one revision ===="
      % (len(results), len(anywhere)))
for k, v in sorted(anywhere.items()):
    print("  %-58s %s" % (k, ", ".join(m for m, ok in v.items() if ok)))
