#!/usr/bin/env python3
"""Build the picked-ROM list for the MP2K HLE archive sweep.

GoodGBA-style naming: dedupe to ONE rom per normalized title, preferring
verified [!] dumps, untouched dumps over hacks/trainers/translations, and
U > E > J regions. Bad dumps [b*] and multiboot conversions (MB2GBA) are
skipped outright.

Usage: mp2k_dedupe.py <romdir> <picked.txt> <skipped.tsv>
"""
import os, re, sys

REGION_SCORE = {
    "U": 40, "UE": 38, "JU": 36, "W": 34, "E": 30, "J": 20,
    "F": 12, "G": 12, "I": 12, "S": 12, "A": 12, "K": 12, "C": 12,
}

def parse(name):
    stem = name[:-4]  # .gba
    brackets = re.findall(r"\[([^\]]*)\]", stem)
    parens = re.findall(r"\(([^)]*)\)", stem)
    title = re.sub(r"[\[(].*", "", stem).strip().lower()
    # collapse punctuation/spacing variants
    title = re.sub(r"[^a-z0-9]+", " ", title).strip()
    return title, parens, brackets

def score(name, parens, brackets):
    s = 0
    if "!" in brackets: s += 1000
    if not brackets: s += 500
    for b in brackets:
        c = b[0]
        if c == "T": s -= 300           # translation
        elif c in "hpt": s -= 150       # hack / pirate / trainer
        elif c in "fo": s -= 60         # fixed / overdump
        elif c == "a": s -= 30          # alternate
    for p in parens:
        s += REGION_SCORE.get(p, 0)
        if p.startswith("V"):
            # prefer latest revision: V1.1 over V1.0
            try: s += int(float(p[1:]) * 10)
            except ValueError: pass
        if p in ("Beta", "Proto", "Demo", "Kiosk"): s -= 200
        if p == "Hack": s -= 150
    s -= len(name) * 0.01               # tiebreak: shorter name
    return s

def main():
    romdir, picked_path, skipped_path = sys.argv[1], sys.argv[2], sys.argv[3]
    groups = {}
    skipped = []
    for name in sorted(os.listdir(romdir)):
        if not name.lower().endswith(".gba"):
            continue
        title, parens, brackets = parse(name)
        if any(b.startswith("b") for b in brackets):
            skipped.append((name, "bad-dump"))
            continue
        if "MB2GBA" in parens:
            skipped.append((name, "multiboot-conversion"))
            continue
        groups.setdefault(title, []).append((score(name, parens, brackets), name))
    picks = []
    for title, cands in groups.items():
        cands.sort(reverse=True)
        picks.append(cands[0][1])
        for _, loser in cands[1:]:
            skipped.append((loser, f"dup-of: {cands[0][1]}"))
    picks.sort()
    with open(picked_path, "w") as f:
        f.write("\n".join(picks) + "\n")
    with open(skipped_path, "w") as f:
        for name, why in sorted(skipped):
            f.write(f"{name}\t{why}\n")
    print(f"picked {len(picks)}  skipped {len(skipped)}  "
          f"(bad {sum(1 for _, w in skipped if w == 'bad-dump')}, "
          f"mb2gba {sum(1 for _, w in skipped if w == 'multiboot-conversion')}, "
          f"dups {sum(1 for _, w in skipped if w.startswith('dup'))})")

main()
