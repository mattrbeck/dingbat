#!/usr/bin/env python3
"""Per-row diff harness for the mGBA test suite.

Phase-0 safety net for the prefetch-model rewrite (docs/prefetch-model-rewrite.md).
The suite ROM prints one `PASS: <name>` or `FAIL: <name>` line per test row, and a
`<label>: Got <ours> vs <expected>: FAIL` reason line after each failure. This tool
normalizes that raw stdout into a stable, machine-readable per-row table so any change
to the timing model can be judged by `diff` against a golden capture — the only way to
catch a silent regression among the ~3200 Timing+DMA rows (never trust the aggregate
END: pass/total line).

Every row is captured (passing AND failing), for EVERY suite, keyed by
(suite, ordinal-within-suite) so the key is stable even when a model change flips a
row's pass/fail or its numeric value. Passing rows have ours==expected by definition,
so a value change on a passing row necessarily shows up as a PASS->FAIL status flip;
failing rows carry their numeric (ours, expected, delta) so movement toward/away from
correct is visible.

Usage:
  # Capture a golden (runs the harness, parses, writes TSV):
  mgba_rowdiff.py capture --harness ./dingbat_test --rom SUITE.gba \
      [--bios PATH] --out tests/golden/mgba_rows_hle.tsv
  # Parse an already-captured raw stdout dump:
  mgba_rowdiff.py parse RAW.txt --out rows.tsv
  # Diff two captures (exit 1 if any row changed):
  mgba_rowdiff.py diff GOLDEN.tsv NEW.tsv [--only Timing,DMA]
"""

import argparse
import re
import subprocess
import sys

# `<label>: Got <ours> (vs|!=) <expected>: FAIL`
REASON_RE = re.compile(r"Got\s+(\S+)\s+(?:vs|!=)\s+(\S+)\s*:\s*FAIL\s*$")

COLUMNS = ["suite", "ord", "name", "status", "ours", "expected", "delta"]


def _as_int(tok):
    """Parse a suite value token as int (decimal cycle count or bare hex word).

    Returns (value, base) or (None, None). Timing values are decimal; DMA/Memory
    values are bare hex (e.g. A5B6C7D8). Try decimal first so plain digit strings
    stay decimal; fall back to hex for anything with a-f.
    """
    tok = tok.strip()
    try:
        return int(tok, 10), 10
    except ValueError:
        pass
    try:
        return int(tok, 16), 16
    except ValueError:
        return None, None


def parse_raw(text):
    """Parse raw suite stdout into a list of row dicts, in program order.

    Stops at the first repeated suite (the ROM loops after ALL DONE), mirroring the
    runner's `seen_suites` guard so a looping capture doesn't double every row.
    """
    rows = []
    suite = None
    ordinal = 0
    seen = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("BEGIN: "):
            suite = line[len("BEGIN: "):]
            if suite in seen:
                break
            seen.add(suite)
            ordinal = 0
        elif line.startswith("END: "):
            suite = None
        elif line.startswith("PASS: ") and suite is not None:
            rows.append({"suite": suite, "ord": ordinal, "name": line[len("PASS: "):],
                         "status": "PASS", "ours": "", "expected": "", "delta": ""})
            ordinal += 1
        elif line.startswith("FAIL: ") and suite is not None:
            rows.append({"suite": suite, "ord": ordinal, "name": line[len("FAIL: "):],
                         "status": "FAIL", "ours": "?", "expected": "?", "delta": ""})
            ordinal += 1
        elif line.endswith(": FAIL") and suite is not None and rows:
            # Reason line for the most recent FAIL row (does not start with FAIL:).
            m = REASON_RE.search(line)
            if m and rows[-1]["status"] == "FAIL":
                ours_s, exp_s = m.group(1), m.group(2)
                rows[-1]["ours"] = ours_s
                rows[-1]["expected"] = exp_s
                ov, ob = _as_int(ours_s)
                ev, eb = _as_int(exp_s)
                # delta is a cycle-count difference: only meaningful for the decimal
                # Timing rows, not the bare-hex value-mismatch rows (DMA/Memory).
                if ov is not None and ev is not None and ob == 10 and eb == 10:
                    rows[-1]["delta"] = str(ov - ev)
    return rows


def write_tsv(rows, out):
    out.write("\t".join(COLUMNS) + "\n")
    for r in rows:
        out.write("\t".join(str(r[c]) for c in COLUMNS) + "\n")


def read_tsv(path):
    rows = []
    with open(path) as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            vals = line.rstrip("\n").split("\t")
            rows.append(dict(zip(header, vals)))
    return rows


def summarize(rows):
    """Return {suite: (passes, total)} in first-seen order."""
    agg = {}
    for r in rows:
        p, t = agg.get(r["suite"], (0, 0))
        agg[r["suite"]] = (p + (1 if r["status"] == "PASS" else 0), t + 1)
    return agg


def cmd_parse(args):
    text = sys.stdin.read() if args.raw == "-" else open(args.raw).read()
    rows = parse_raw(text)
    out = open(args.out, "w") if args.out else sys.stdout
    write_tsv(rows, out)
    if args.out:
        out.close()
        agg = summarize(rows)
        total_p = sum(p for p, _ in agg.values())
        total_t = sum(t for _, t in agg.values())
        print(f"wrote {len(rows)} rows to {args.out} ({total_p}/{total_t} pass)",
              file=sys.stderr)
    return 0


def cmd_capture(args):
    cmd = [args.harness, args.rom, "--mode=mgba-suite", f"--timeout={args.timeout}"]
    if args.bios:
        cmd.append(f"--bios={args.bios}")
    print("running: " + " ".join(cmd), file=sys.stderr)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    text = proc.stdout + proc.stderr
    if "ALL DONE" not in text:
        print("WARNING: 'ALL DONE' not found — capture may be incomplete/timed out",
              file=sys.stderr)
    if args.raw_out:
        with open(args.raw_out, "w") as f:
            f.write(text)
    rows = parse_raw(text)
    with open(args.out, "w") as f:
        write_tsv(rows, f)
    agg = summarize(rows)
    total_p = sum(p for p, _ in agg.values())
    total_t = sum(t for _, t in agg.values())
    for suite, (p, t) in agg.items():
        print(f"  {suite}: {p}/{t}", file=sys.stderr)
    print(f"wrote {len(rows)} rows to {args.out} ({total_p}/{total_t} pass)",
          file=sys.stderr)
    return 0


def cmd_diff(args):
    only = set(args.only.split(",")) if args.only else None
    golden = read_tsv(args.golden)
    new = read_tsv(args.new)

    def keyed(rows):
        d = {}
        for r in rows:
            if only is not None and r["suite"] not in only:
                continue
            d[(r["suite"], r["ord"])] = r
        return d

    g, n = keyed(golden), keyed(new)
    all_keys = sorted(set(g) | set(n))

    changes = []
    name_mismatches = []
    for k in all_keys:
        gr, nr = g.get(k), n.get(k)
        if gr is None:
            changes.append((k, "ADDED", None, nr))
            continue
        if nr is None:
            changes.append((k, "REMOVED", gr, None))
            continue
        if gr["name"] != nr["name"]:
            name_mismatches.append((k, gr["name"], nr["name"]))
        if gr["status"] != nr["status"]:
            kind = "FIXED" if nr["status"] == "PASS" else "REGRESSED"
            changes.append((k, kind, gr, nr))
        elif gr["status"] == "FAIL" and (gr["ours"], gr["expected"]) != (nr["ours"], nr["expected"]):
            changes.append((k, "VALUE", gr, nr))

    # Aggregate delta per suite.
    ga, na = summarize(golden), summarize(new)
    suites = [s for s in dict.fromkeys([r["suite"] for r in golden] +
                                       [r["suite"] for r in new])
              if only is None or s in only]

    print("=== Suite totals (golden -> new) ===")
    for s in suites:
        gp, gt = ga.get(s, (0, 0))
        np_, nt = na.get(s, (0, 0))
        mark = "" if gp == np_ else f"   <<< {np_ - gp:+d}"
        print(f"  {s:28s} {gp}/{gt} -> {np_}/{nt}{mark}")

    if name_mismatches:
        print("\n!!! NAME MISMATCH at stable key (suite structure changed?) !!!")
        for k, gn, nn in name_mismatches[:20]:
            print(f"  {k}: {gn!r} != {nn!r}")

    regressed = [c for c in changes if c[1] == "REGRESSED"]
    fixed = [c for c in changes if c[1] == "FIXED"]
    value = [c for c in changes if c[1] == "VALUE"]
    struct = [c for c in changes if c[1] in ("ADDED", "REMOVED")]

    def show(title, items):
        if not items:
            return
        print(f"\n=== {title} ({len(items)}) ===")
        for k, kind, gr, nr in items:
            suite, ordn = k
            name = (nr or gr)["name"]
            if kind in ("REGRESSED", "FIXED", "VALUE"):
                gv = f"{gr['ours']} vs {gr['expected']}" if gr['status'] == 'FAIL' else "PASS"
                nv = f"{nr['ours']} vs {nr['expected']}" if nr['status'] == 'FAIL' else "PASS"
                print(f"  [{suite} #{ordn}] {name}")
                print(f"      {gv}  ->  {nv}")

    show("REGRESSED (PASS -> FAIL)", regressed)
    show("FIXED (FAIL -> PASS)", fixed)
    show("VALUE CHANGED (still failing, different numbers)", value)
    if struct:
        print(f"\n=== STRUCTURAL ({len(struct)}) — rows added/removed ===")
        for k, kind, gr, nr in struct:
            print(f"  {kind} {k}: {(nr or gr)['name']}")

    total_changes = len(changes) + len(name_mismatches)
    print(f"\n{total_changes} changed row(s): "
          f"{len(regressed)} regressed, {len(fixed)} fixed, "
          f"{len(value)} value, {len(struct)} structural, "
          f"{len(name_mismatches)} name-mismatch")
    return 1 if total_changes else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("parse", help="parse raw suite stdout into a TSV")
    p.add_argument("raw", help="raw stdout file, or - for stdin")
    p.add_argument("--out", help="output TSV (default: stdout)")
    p.set_defaults(func=cmd_parse)

    c = sub.add_parser("capture", help="run the harness and write a TSV")
    c.add_argument("--harness", required=True)
    c.add_argument("--rom", required=True)
    c.add_argument("--bios", help="genuine BIOS for LLE; omit for HLE")
    c.add_argument("--timeout", type=int, default=36000)
    c.add_argument("--out", required=True)
    c.add_argument("--raw-out", help="also save the raw stdout here")
    c.set_defaults(func=cmd_capture)

    d = sub.add_parser("diff", help="diff two TSV captures")
    d.add_argument("golden")
    d.add_argument("new")
    d.add_argument("--only", help="comma-separated suites to restrict to, e.g. "
                                  "'Timing tests,DMA tests'")
    d.set_defaults(func=cmd_diff)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
