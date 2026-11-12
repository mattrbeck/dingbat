#!/usr/bin/env python3
"""Check that a comment-only edit left the code alone.

usage: commentcheck.py FILE...

Compares each file with its HEAD version after dropping blank lines and
whole-line comments. Trailing comments count as code. Prints words before
and after; exits 1 if any code line differs.
"""
import subprocess
import sys

HASH = (".nim", ".nims", ".py", ".sh", ".cfg", ".yml", ".s", ".inc", ".asm")
SLASH = (".mjs", ".js", ".ts", ".swift", ".c", ".h", ".cpp", ".lean")


def code(text, path):
    out = []
    for line in text.split("\n"):
        s = line.strip()
        if not s:
            continue
        if path.endswith(HASH) and s.startswith("#") and not s.startswith("#!"):
            continue
        if path.endswith(SLASH) and s.startswith(("//", "/*", "*", "--")):
            continue
        out.append(line.rstrip())
    return out


bad = 0
for path in sys.argv[1:]:
    old = subprocess.run(["git", "show", "HEAD:" + path], capture_output=True,
                         text=True, check=True).stdout
    new = open(path).read()
    a, b = code(old, path), code(new, path)
    if a != b:
        bad = 1
        for i, (x, y) in enumerate(zip(a, b)):
            if x != y:
                print(f"CODE CHANGED {path}: {x!r} -> {y!r}")
                break
        else:
            print(f"CODE CHANGED {path}: {len(a)} -> {len(b)} code lines")
    else:
        print(f"ok {path}: {len(old.split())} -> {len(new.split())} words")
sys.exit(bad)
