#!/usr/bin/env python3
"""Run the Test Suite workflow's test steps locally, as CI runs them.

Reads .github/workflows/test.yml, so the list of steps never drifts from CI:
builds every test binary with .github/scripts/build-tests.sh, then runs each
step's `run:` from "Run tests" on, in order, and prints a pass/fail table.
Steps that download packages (npm ci, Playwright) are skipped unless --web.

    python3 tools/ci_local.py              # every native and Node step
    python3 tools/ci_local.py --web        # plus the npm/Playwright steps
    python3 tools/ci_local.py --only ppu   # steps whose name contains "ppu"
    python3 tools/ci_local.py --no-build   # reuse binaries already built

The test runner rewrites tests/results*.md; a timestamp-only change there is
not a result (revert it), a real one rides the commit it belongs to.
"""
import argparse, os, re, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
WORKFLOW = os.path.join(ROOT, '.github', 'workflows', 'test.yml')
NEEDS_NET = ('npm ci', 'playwright install')


def steps(path):
    """The `test` job's steps as dicts (name, run, if, working-directory):
    enough YAML for this file's shape, which keeps every step at one indent."""
    out, cur, block, block_indent = [], None, None, 0
    for line in open(path):
        raw = line.rstrip('\n')
        if block is not None:
            if raw.strip() == '' or len(raw) - len(raw.lstrip()) >= block_indent:
                cur['run'] += raw[block_indent:] + '\n'
                continue
            block = None
        m = re.match(r'^(\s*)- name:\s*(.*)$', raw)
        if m:
            cur = {'name': m.group(2).strip(), 'indent': len(m.group(1)) + 2}
            out.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r'^(\s*)([A-Za-z-]+):\s*(.*)$', raw)
        if m and len(m.group(1)) == cur['indent']:
            key, val = m.group(2), m.group(3)
            if key == 'run' and val in ('|', '>'):
                cur['run'], block = '', True
                block_indent = cur['indent'] + 2
            else:
                cur[key] = val
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--web', action='store_true', help='also the steps that npm ci / install Playwright')
    ap.add_argument('--only', help='run only steps whose name contains this (case-insensitive)')
    ap.add_argument('--no-build', action='store_true', help="don't rebuild the test binaries")
    args = ap.parse_args()
    os.chdir(ROOT)
    all_steps = steps(WORKFLOW)
    names = [s['name'] for s in all_steps]
    # the `test` job: from the runner to its artifact upload (the WASM and
    # WebKit jobs after it are other machines)
    start = names.index('Run tests')
    end = names.index('Upload test results', start)
    todo = [s for s in all_steps[start:end] if 'run' in s]
    if args.only:
        todo = [s for s in todo if args.only.lower() in s['name'].lower()]
    if not args.no_build:
        print('== building the test binaries (.github/scripts/build-tests.sh)', flush=True)
        if subprocess.run(['bash', '.github/scripts/build-tests.sh']).returncode != 0:
            print('build failed: see .build-logs/'); return 2
    results = []
    for s in todo:
        if not args.web and any(n in s['run'] for n in NEEDS_NET):
            results.append((s['name'], 'skip', 0.0, 'needs --web'))
            continue
        cwd = os.path.join(ROOT, s.get('working-directory', '.'))
        print('== ' + s['name'], flush=True)
        t = time.time()
        rc = subprocess.run(['bash', '-c', s['run']], cwd=cwd).returncode
        results.append((s['name'], 'PASS' if rc == 0 else 'FAIL', time.time() - t,
                        '' if rc == 0 else 'exit %d' % rc))
    print()
    width = max(len(r[0]) for r in results) if results else 0
    for name, st, secs, note in results:
        print('%-4s  %-*s  %6.1fs  %s' % (st, width, name, secs, note))
    failed = [r for r in results if r[1] == 'FAIL']
    print('\n%d passed, %d failed, %d skipped' % (
        sum(r[1] == 'PASS' for r in results), len(failed), sum(r[1] == 'skip' for r in results)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
