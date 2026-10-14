#!/usr/bin/env python3
"""Test train for the playtest corpus: batch every pending candidate onto one
build, play the corpus once, and rerun only the games that changed on each
candidate alone to say whose change it was.

  train.py submit REF [--name N] [--wait]   queue a commit (exit 0 clean, 1 changes, 2 conflict/build)
  train.py run [--once]                     drive trains until the queue is empty
  train.py status                           queue, the running train, recent verdicts
  train.py show ID                          a candidate's verdict (or a run's report)
  train.py baseline [--commit REF]          build the cached baseline of a commit now

A train, holding the machine-wide lock (one train or full suite at a time):

  1. base = origin/main (fetched). Its baseline (every game in every
     configuration) is stored by results key: the content of what a result
     depends on (the driver's sources, the harness, the toolchain), each
     game's row valid for the script it played. A main that moved elsewhere
     (docs, web, DS, frontends) reuses the stored results; a combined build
     that later lands as tested is its own next baseline. The reference
     emulators' phases are replayed from another store when the scripts and
     reference binaries are unchanged, so a new baseline only plays dingbat.
  2. Candidates that touch nothing the corpus builds from (docs, web, other
     tools) are clean without running. The rest are squash-merged onto base
     in queue order in a temporary worktree; one that conflicts with an
     earlier one rides the next train first, one that does not apply to base
     at all is rejected.
  3. The combined build plays the corpus in the dingbat configurations, the
     references replayed from the baseline -- only the games its results
     key's store lacks: none when it was played before, only the changed
     scripts when the candidates change nothing else.
  4. Every game is compared with the baseline per configuration: pass/fail
     and every hash (each checkpoint and its frame window, the [new] audio,
     the battery file, every [load] cell the configuration writes or reads).
  5. With more than one candidate and at least one changed game, each
     candidate is built alone on base and replays only the changed games;
     each changed hash is credited to the candidate that reproduces it. A
     change no candidate reproduces alone (or one a candidate makes that the
     combined build does not show) is an interaction, for a human.
  6. Before attribution, the changed games whose changes could be noise
     (could_be_noise: a verdict flip with no hash moved, a reference reading
     a save live) are played once more on base itself (its driver cached
     with the baseline). A cell that differs between the two runs of base is
     noise: it is left out of every verdict, listed in the report's noise
     section and counted in noise.json (the noise ledger). A combined value
     an earlier run of the same base already produced is noise without a
     rerun. A moved dingbat hash is never noise: no rerun.

The scripts are frozen input timelines and every configuration is
deterministic, so a game identical to the baseline on the combined build is
identical on each candidate -- unless two candidates' changes exactly cancel.

State lives outside every checkout, in $DINGBAT_TRAIN_HOME (default
~/.cache/dingbat-train): queue/, verdicts/, runs/<id>/ (report.md,
report.json, log.txt, the suites' run directories), baselines/, refbin/,
noise.json, work/ (temporary worktrees, removed after each train). Nothing is pushed and
no existing checkout is touched.
"""
import argparse
import copy
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import emu as emulib  # noqa: E402
HOME = os.path.expanduser(os.environ.get('DINGBAT_TRAIN_HOME', '~/.cache/dingbat-train'))
DINGBAT = ['dingbat', 'dingbat-nowl', 'dingbat-bios', 'dingbat-bios-nowl', 'dingbat-hleimg']
REF_FILES = ['tools/playtest/drivers/mgba_driver.c', 'tools/playtest/drivers/nba_driver.cpp',
             'tools/playtest/screenread.swift', 'tools/playtest/build.sh']
# what a reference emulator's replayed phase depends on besides its script:
# a candidate touching one of these gets its references played live
REF_INPUTS = REF_FILES + ['tools/playtest/runner.py', 'tools/playtest/emu.py', 'tools/playtest/script.py',
                          'tools/playtest/screen.py', 'tools/playtest/img.py']
REF_BINS = ['mgba_driver', 'nba_driver', 'screenread']
# aspects where a missing value (an older run that did not record it) means
# "unknown", not "different"
LENIENT = ('audio', 'win:')
NICE = 10      # --nice: what a train's suites run at
EXIT = {'clean': 0, 'landed': 0, 'skipped': 0, 'changed': 1, 'conflict': 2, 'build-failed': 2}


# ============================================================ comparison
# Pure functions over suite data: unit-tested in tests/test_train.py.

def _digest(values):
    return hashlib.sha1(' '.join(map(str, values)).encode()).hexdigest()[:16]


def fingerprint(row, results=None, windows=None):
    """Everything that identifies one game's outcome, per dingbat
    configuration: {config: {aspect: value}}, '*' for the game as a whole.

    row: the suite's index.json row; results: the run's results.json;
    windows: {config: {checkpoint: [frame hashes]}} from the phases' whole
    results (None where a run did not keep them)."""
    fp = {'*': {'status': row.get('status')}}
    if not results:
        return fp
    windows = windows or {}
    outdir = row.get('outdir') or '\0'
    for c in results.get('emulators', []):
        if not c.startswith('dingbat'):
            continue
        a = {}
        v = results.get('verdicts', {}).get(c) or {}
        a['pass'] = v.get('pass')
        a['play'] = v.get('play')
        n = results.get('new', {}).get(c) or {}
        err = n.get('error')
        a['new'] = [n.get('ok'), err.replace(outdir, '<run>') if isinstance(err, str) else err, n.get('frame')]
        for cp, d in (n.get('checkpoints') or {}).items():
            a[f'cp:{cp}'] = [d.get('frame'), d.get('hash')]
            w = (windows.get(c) or {}).get(cp)
            a[f'win:{cp}'] = _digest(w) if w else None
        a['audio'] = n.get('audio_sha1')
        s = (results.get('saves') or {}).get(c) or {}
        a['save'] = [s.get('exists'), s.get('size'), s.get('sha1')]
        for key, cell in sorted((results.get('load') or {}).items()):
            w_, r_ = key.split('-in-')
            if c not in (w_, r_):
                continue
            a[f'load:{key}'] = [cell.get('ok'), cell.get('save_unchanged'),
                                sorted([cp, d.get('frame'), d.get('hash')]
                                       for cp, d in (cell.get('checkpoints') or {}).items())]
        fp[c] = a
    return fp


def same(aspect, a, b):
    if a == b:
        return True
    return aspect.startswith(LENIENT) and (a is None or b is None)


def diff_fp(before, after):
    """{config: {aspect: [before, after]}} for every aspect that differs."""
    out = {}
    order = ['*'] + DINGBAT
    for c in sorted(set(before) | set(after), key=lambda k: (order.index(k) if k in order else len(order), k)):
        if c not in before and before.get('*', {}).get('status') not in (None, 'ERROR'):
            # a configuration the baseline did not play at all (added to
            # the harness since): nothing to compare it with yet
            continue
        b, a = before.get(c, {}), after.get(c, {})
        d = {k: [b.get(k), a.get(k)] for k in sorted(set(b) | set(a)) if not same(k, b.get(k), a.get(k))}
        if d:
            out[c] = d
    return out


def diff_suites(base, new):
    """base/new: {sha1: fingerprint}. -> (changed {sha1: diff}, added, removed)."""
    changed = {}
    for s in sorted(set(base) & set(new)):
        d = diff_fp(base[s], new[s])
        if d:
            changed[s] = d
    return changed, sorted(set(new) - set(base)), sorted(set(base) - set(new))


def classify(before, after):
    """How a game moved between two fingerprints: kind (fixed, regressed,
    mixed, neutral or None for no change) and the kind per configuration."""
    d = diff_fp(before, after)
    if not d:
        return {'kind': None, 'configs': {}}
    per = {}
    for c in d:
        if c == '*':
            continue
        bp, ap = before.get(c, {}).get('pass'), after.get(c, {}).get('pass')
        per[c] = 'fixed' if (bp is not True and ap is True) else \
            'regressed' if (bp is True and ap is not True) else 'neutral'
    sb, sa = before['*'].get('status'), after['*'].get('status')
    if sb != sa and not per:
        # a game that stopped (or started) completing at all
        per['*'] = 'regressed' if sa in ('ERROR', None) else 'fixed' if sb in ('ERROR', None) else 'neutral'
    kinds = set(per.values())
    kind = 'mixed' if {'fixed', 'regressed'} <= kinds else 'regressed' if 'regressed' in kinds else \
        'fixed' if 'fixed' in kinds else 'neutral'
    return {'kind': kind, 'configs': per}


def attribute(base, combined, cands):
    """Credit each changed hash to the candidate that reproduces it alone.

    base, combined: {sha1: fingerprint} for the changed games; cands:
    {candidate: {sha1: fingerprint}} for the same games, each candidate
    built alone on base. -> {'effects': {cand: {sha1: classify(...)+aspects}},
    'interactions': [{sha1, unexplained, overlapping, involved}],
    'shared': {sha1: [cands]}}"""
    effects = {c: {} for c in cands}
    interactions, shared = [], {}
    for s in sorted(combined):
        B, C = base[s], combined[s]
        D = diff_fp(B, C)
        E = {c: diff_fp(B, f[s]) for c, f in cands.items() if s in f}
        unexplained, overlapping = [], []
        movers = sorted(c for c, e in E.items() if e)
        several = set()
        for cfg, aspects in D.items():
            for k, (bv, cv) in aspects.items():
                who = [c for c in movers if same(k, cands[c][s].get(cfg, {}).get(k), cv)
                       and k in E[c].get(cfg, {})]
                if not who:
                    unexplained.append(f'{cfg} {k}')
                elif len(who) > 1:
                    several.update(who)
        for c in movers:
            for cfg, aspects in E[c].items():
                for k, (bv, iv) in aspects.items():
                    if not same(k, iv, C.get(cfg, {}).get(k)):
                        overlapping.append(f'{c}: {cfg} {k}')
            effects[c][s] = dict(classify(B, cands[c][s]), aspects=E[c])
        if several:
            shared[s] = sorted(several)
        if unexplained or overlapping:
            interactions.append({'sha1': s, 'unexplained': unexplained, 'overlapping': overlapping,
                                 'involved': movers or sorted(cands)})
    return {'effects': effects, 'interactions': interactions, 'shared': shared}


def describe(aspects):
    """A short human list of what changed in one game: {config: {aspect: [b, a]}}."""
    parts = []
    for cfg, d in aspects.items():
        cps = sorted({k.split(':', 1)[1] for k in d if k.startswith(('cp:', 'win:'))})
        # a cell named from the configuration's side (self) so configurations group
        loads = sorted('-in-'.join('self' if x == cfg else x for x in k.split(':', 1)[1].split('-in-'))
                       for k in d if k.startswith('load:'))
        bits = []
        if 'pass' in d:
            bits.append(f"{'PASS' if d['pass'][0] else 'FAIL'}->{'PASS' if d['pass'][1] else 'FAIL'}")
        if 'status' in d:
            bits.append(f"status {d['status'][0]}->{d['status'][1]}")
        if 'play' in d:
            bits.append(f"play {d['play'][0]}->{d['play'][1]}")
        if 'new' in d:
            bits.append('[new] outcome')
        if cps:
            bits.append('checkpoints ' + ', '.join(cps[:4]) + (f' (+{len(cps) - 4})' if len(cps) > 4 else ''))
        if 'audio' in d:
            bits.append('audio')
        if 'save' in d:
            bits.append('battery file')
        if loads:
            bits.append('load ' + ', '.join(loads[:3]) + (f' (+{len(loads) - 3})' if len(loads) > 3 else ''))
        parts.append((cfg, '; '.join(bits)))
    # configurations that changed the same way share one entry
    grouped = {}
    for cfg, text in parts:
        grouped.setdefault(text, []).append(cfg)
    return ' | '.join(f"{'all ' + str(len(cs)) if len(cs) == len(DINGBAT) and '*' not in cs else ', '.join(cs)}: {text}"
                      for text, cs in grouped.items())


def _usable(fp):
    """A run that produced results (not an ERROR row with nothing in it)."""
    return any(c != '*' for c in fp)


def mask(fp, base_fp, cells):
    """fp with every aspect in cells ({config: [aspects]}) set to base_fp's
    value, so diff_fp no longer sees it."""
    out = copy.deepcopy(fp)
    for cfg, ks in cells.items():
        for k in ks:
            if k in base_fp.get(cfg, {}):
                out.setdefault(cfg, {})[k] = copy.deepcopy(base_fp[cfg][k])
            elif cfg in out:
                out[cfg].pop(k, None)
    return out


def known_values(ledger, base, sha1, cfg, aspect):
    """Values earlier runs of this base produced for one cell (the ledger)."""
    e = (ledger or {}).get('cells', {}).get(f'{sha1} {cfg} {aspect}') or {}
    return e.get('base_values', {}).get(base[:12], [])


REFERENCES = ('mgba', 'nba')


def could_be_noise(d, live=False):
    """Whether one game's changes ({config: {aspect: [before, after]}}) could
    be the base's own nondeterminism rather than the candidates' doing.

    dingbat plays frozen inputs deterministically, so a moved frame, audio,
    battery or [load] hash is a change, never noise (the second run of base
    over 101, 103 and 131 changed games on 2026-10-13 found not one noisy
    cell, at 27-84 minutes each). What can differ between two runs of the
    same build: a verdict whose frame hashes all stayed put (OCR, read under
    load), a game that stopped running at all, and -- only when the
    references play live (`live`) -- a reference reading dingbat's save,
    which may read the host clock."""
    if '*' in d and len(d) == 1:
        return True
    for cfg, aspects in d.items():
        if cfg == '*':
            continue
        if not set(aspects) - {'pass', 'play'}:
            return True
        if live and any(k.startswith('load:') and k.split('-in-')[-1] in REFERENCES for k in aspects):
            return True
    return False


def denoise(B, C, base, ledger, rerun, live=False):
    """Take the base's own nondeterminism out of the combined run.

    B, C: {sha1: fingerprint} of the baseline and the combined run;
    ledger: the noise ledger; rerun(sha1s) -> {sha1: fingerprint} plays
    those games on base again (called only for games whose changes, after
    the ledger's known values, could_be_noise). -> (C masked, changed,
    noise, rerun_sha1s) where noise is {sha1: {config: {aspect: {how,
    baseline, combined[, rerun]}}}}: 'known' a combined value an earlier run
    of this base produced, 'rerun' a cell that differs between the baseline
    and the second run of base. `base` names the base in the ledger (its
    results key)."""
    noise = {}

    def note(s, cfg, k, **kw):
        noise.setdefault(s, {}).setdefault(cfg, {})[k] = kw

    def cells(s):
        return {cfg: list(d) for cfg, d in noise.get(s, {}).items()}

    changed = diff_suites(B, C)[0]
    if not changed:
        return C, {}, {}, []
    for s, d in changed.items():
        for cfg, aspects in d.items():
            for k, (bv, cv) in aspects.items():
                if cv in known_values(ledger, base, s, cfg, k):
                    note(s, cfg, k, how='known', baseline=bv, combined=cv)
    C = dict(C, **{s: mask(C[s], B[s], cells(s)) for s in noise})
    left = diff_suites({s: B[s] for s in changed}, {s: C[s] for s in changed})[0]
    todo = sorted(s for s, d in left.items() if could_be_noise(d, live))
    R = rerun(todo) if todo else {}
    for s in todo:
        if s not in R or not _usable(R[s]) or not _usable(B[s]):
            continue        # the rerun did not play it: nothing to learn
        # A configuration the rerun could not play where the baseline did
        # (its [new] phase ended in an error) says nothing about noise: the
        # second run of base on 2026-10-12 refused every driver, and its
        # failures hid ten games' changes as noise
        broke = {cfg for cfg, a in R[s].items() if cfg != '*' and (a.get('new') or [True])[0] is False
                 and (B[s].get(cfg, {}).get('new') or [False])[0] is True}
        for cfg, aspects in diff_fp(B[s], R[s]).items():
            if cfg != '*' and cfg not in R[s] or cfg in broke or cfg == '*' and broke:
                continue
            for k, (bv, rv) in aspects.items():
                note(s, cfg, k, how='rerun', baseline=bv, rerun=rv, combined=C[s].get(cfg, {}).get(k))
        C[s] = mask(C[s], B[s], cells(s))
    changed = diff_suites({s: B[s] for s in changed}, {s: C[s] for s in changed})[0]
    return C, changed, noise, todo


def ocr_only(noise_cfgs):
    """Configurations whose noise is a pass/fail flip with every frame hash
    identical: OCR read the same frames differently."""
    out = []
    for cfg, ks in noise_cfgs.items():
        if cfg == '*' or not set(ks) & {'pass', 'play'}:
            continue
        if not any(k.startswith(('cp:', 'win:')) for k in ks):
            out.append(cfg)
    return out


def describe_noise(cfgs):
    """describe() of one game's noise cells ({config: {aspect: entry}})."""
    return describe({cfg: {k: [e['baseline'], e.get('rerun', e.get('combined'))] for k, e in d.items()}
                     for cfg, d in cfgs.items()})


def update_ledger(ledger, noise, base, titles, now=None):
    """Count every noise cell in the ledger; a rerun cell also records the
    values base produced (accepted as unchanged on later trains of base)."""
    now = now or datetime.datetime.now().isoformat(timespec='seconds')
    ledger = {} if ledger is None else ledger
    cl = ledger.setdefault('cells', {})
    for s, cfgs in noise.items():
        for cfg, d in cfgs.items():
            for k, e in d.items():
                c = cl.setdefault(f'{s} {cfg} {k}', {'sha1': s, 'config': cfg, 'aspect': k, 'seen': 0,
                                                     'first_seen': now, 'examples': [], 'base_values': {}})
                c.update(title=titles.get(s, s), seen=c['seen'] + 1, last_seen=now)
                if e['how'] != 'rerun':
                    continue
                for v in (e['baseline'], e['rerun']):
                    if v not in c['examples']:
                        c['examples'] = (c['examples'] + [v])[-4:]
                bv = c['base_values'].setdefault(base[:12], [])
                for v in (e['baseline'], e['rerun']):
                    if v not in bv:
                        bv.append(v)
                del bv[:-6]
                for old in list(c['base_values'])[:-3]:
                    del c['base_values'][old]
    return ledger


def chronic(ledger, n=None):
    """Ledger cells, most often seen first."""
    cells = sorted((ledger or {}).get('cells', {}).values(), key=lambda c: (-c['seen'], c.get('title', '')))
    return cells[:n] if n else cells


def known_noisy(ledger, sha1, aspects):
    """'config aspect (seen N)' for the changed cells the ledger has seen
    as noise on any base."""
    cl = (ledger or {}).get('cells', {})
    return [f"{cfg} {k} (noise seen {cl[f'{sha1} {cfg} {k}']['seen']}x)" for cfg, d in aspects.items() for k in d
            if f'{sha1} {cfg} {k}' in cl]


# ============================================================ suites on disk

def load_suite(suite_dir):
    """{sha1: (row, fingerprint)} for a suite directory."""
    return load_rows((read_json(os.path.join(suite_dir, 'index.json'), {}) or {}).get('games', []))


def load_rows(rows):
    """{sha1: (row, fingerprint)} for suite index rows."""
    out = {}
    for row in rows:
        results, windows = None, {}
        od = row.get('outdir')
        if od and os.path.exists(os.path.join(od, 'results.json')):
            results = read_json(os.path.join(od, 'results.json'))
            for c in results.get('emulators', []):
                side = os.path.join(od, 'new', c, 'result.json')
                if c.startswith('dingbat') and os.path.exists(side):
                    cps = (read_json(side) or {}).get('checkpoints') or {}
                    windows[c] = {k: v.get('hashes') for k, v in cps.items()}
        out[row['sha1']] = (row, fingerprint(row, results, windows))
    return out


# ============================================================ plumbing

class Log:
    def __init__(self, path=None):
        self.path = path
        if path:
            os.makedirs(os.path.dirname(path), exist_ok=True)

    def __call__(self, msg):
        line = f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        if self.path:
            with open(self.path, 'a') as f:
                f.write(line + '\n')


def sh(cmd, cwd=None, env=None, check=True, out=None):
    """Run a command; its output to `out` (a path, appended) or returned."""
    if out:
        with open(out, 'a') as fh:
            fh.write(f"\n$ {' '.join(cmd)}\n")
            fh.flush()
            r = subprocess.run(cmd, cwd=cwd, env=env, stdout=fh, stderr=subprocess.STDOUT)
        if check and r.returncode:
            raise subprocess.CalledProcessError(r.returncode, cmd)
        return r.returncode
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode:
        raise subprocess.CalledProcessError(r.returncode, cmd, r.stdout, r.stderr)
    return r.stdout.strip()


def repo_root():
    """The main checkout of this repository (git commands run against its
    object store; its working tree is never touched)."""
    common = sh(['git', '-C', HERE, 'rev-parse', '--path-format=absolute', '--git-common-dir'])
    return os.path.dirname(common)


def git(*args, cwd=None, check=True):
    return sh(['git', '-c', 'core.hooksPath=/dev/null', *args], cwd=cwd or repo_root(), check=check)


def path(*parts):
    p = os.path.join(HOME, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def write_json(p, data):
    tmp = p + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=1, default=str)
    os.replace(tmp, p)


def read_json(p, default=None):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


class MachineLock:
    """fcntl lock on $HOME/lock: one train or whole-corpus suite at a time.
    The kernel drops it when the holder dies, so a lock cannot go stale;
    holder.json only says who has it."""

    def __init__(self, fh):
        self.fh = fh

    def release(self):
        if self.fh:
            try:
                os.remove(path('holder.json'))
            except OSError:
                pass
            fcntl.flock(self.fh, fcntl.LOCK_UN)
            self.fh.close()
            self.fh = None


def machine_lock(wait=True, what='', poll=20):
    fh = open(path('lock'), 'a+')
    told = False
    while True:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            write_json(path('holder.json'), {'pid': os.getpid(), 'what': what,
                                             'since': datetime.datetime.now().isoformat(timespec='seconds')})
            return MachineLock(fh)
        except BlockingIOError:
            if not wait:
                fh.close()
                return None
            if not told:
                h = read_json(path('holder.json'), {})
                print(f"waiting for the playtest machine lock: held by pid {h.get('pid')} ({h.get('what')}) "
                      f"since {h.get('since')}; `tools/playtest/train.py status` shows progress", flush=True)
                told = True
            time.sleep(poll)


def lock_free():
    lk = machine_lock(wait=False)
    if lk:
        lk.release()
        return True
    return False


# ============================================================ queue

def entries():
    qd = path('queue', 'x')
    out = []
    for fn in sorted(os.listdir(os.path.dirname(qd))):
        if fn.endswith('.json'):
            e = read_json(os.path.join(os.path.dirname(qd), fn))
            if e:
                out.append(e)
    return out


def verdict_of(cid):
    return read_json(path('verdicts', f'{cid}.json'))


def pending():
    p = [e for e in entries() if not os.path.exists(path('verdicts', f"{e['id']}.json"))]
    return sorted(p, key=lambda e: (not e.get('deferred'), e['submitted']))


def submit(args):
    try:
        sha = sh(['git', 'rev-parse', '--verify', f'{args.ref}^{{commit}}'])
    except subprocess.CalledProcessError:
        print(f'not a commit here: {args.ref}')
        return 2
    name = args.name or args.ref
    slug = re.sub(r'[^A-Za-z0-9._-]+', '-', name)[:40].strip('-') or sha[:8]
    cid = f"{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}-{sha[:8]}-{slug}"
    entry = {'id': cid, 'name': name, 'ref': args.ref, 'sha': sha, 'cwd': os.getcwd(), 'pid': os.getpid(),
             'submitted': datetime.datetime.now().isoformat(timespec='seconds')}
    write_json(path('queue', f'{cid}.json'), entry)
    print(f'queued {cid} ({sha[:12]})', flush=True)
    if not args.wait:
        return 0
    return wait_for(cid, args)


def wait_for(cid, args):
    """Block until the candidate has a verdict, driving trains ourselves
    whenever nobody else is (the lock decides who)."""
    last_note, drove = 0, False
    while True:
        v = verdict_of(cid)
        if v:
            if not drove:     # a train we drove printed it already
                print_verdict(v)
            return v.get('exit', 1)
        lk = machine_lock(wait=False)
        if lk:
            drove = True
            try:
                drive(args, lk, until=cid)
            finally:
                lk.release()
            continue
        if time.time() - last_note > 300:
            r = read_json(path('runner.json'))
            h = read_json(path('holder.json'), {})
            print(f"waiting: train {r['run']} at {r.get('stage')} {r.get('detail', '')}" if r else
                  f"waiting: the lock is held by pid {h.get('pid')} ({h.get('what')})", flush=True)
            last_note = time.time()
        time.sleep(args.poll)


def print_verdict(v):
    print(f"== {v['name']} ({v['sha'][:12]}): {v['status'].upper()}" + (f" -- {v['note']}" if v.get('note') else ''))
    for k in ('fixed', 'regressed', 'mixed', 'neutral'):
        for g in v.get(k, []):
            print(f"   {k:9} {g['title']}: {g['what']}")
    for g in v.get('added', []):
        print(f"   added     {g['title']}: {g['status']}")
    for g in v.get('noise', []):
        print(f"   noise     {g['title']}: {noise_text(g)}")
    for i in v.get('interactions', []):
        print(f"   INTERACTION {i['title']} with {', '.join(i['involved'])}: "
              f"{'; '.join((i['unexplained'] + i['overlapping'])[:4])}")
    if v.get('report'):
        print(f"   report: {v['report']}")


def noise_text(g):
    why = 'differs between two runs of the base' if 'rerun' in g['how'] else \
        'a value an earlier run of the base produced (noise ledger)'
    ocr = f" (OCR only in {', '.join(g['ocr_only'])}: frame hashes identical)" if g.get('ocr_only') else ''
    return f"{g['what']} -- {why}{ocr}; not attributed"


# ============================================================ worktrees and builds

class Trees:
    """Temporary worktrees of this train under work/<run>/, removed by
    cleanup()."""

    def __init__(self, run_id, log):
        self.root = path('work', run_id, 'x')[:-2]
        self.logdir = path('runs', run_id, 'x')[:-2]   # build logs outlive the trees
        self.log = log
        self.made = []

    def add(self, name, base):
        wt = os.path.join(self.root, name)
        if os.path.exists(wt):
            self.remove(wt)
        git('worktree', 'add', '--detach', wt, base)
        self.made.append(wt)
        return wt

    def merge(self, wt, cand):
        """Squash-merge a candidate onto the worktree. -> 'ok', 'empty'
        (already in) or 'conflict'."""
        try:
            git('merge', '--squash', '--no-commit', cand['sha'], cwd=wt)
        except subprocess.CalledProcessError as e:
            git('reset', '--hard', '-q', 'HEAD', cwd=wt, check=False)
            self.log(f"  {cand['name']}: does not merge ({(e.stderr or e.stdout or '').strip().splitlines()[-1:]})")
            return 'conflict'
        if not git('diff', '--cached', '--name-only', cwd=wt):
            return 'empty'
        git('commit', '-q', '-m', f"train: {cand['name']} ({cand['sha'][:12]})", cwd=wt)
        return 'ok'

    def remove(self, wt):
        git('worktree', 'remove', '--force', wt, check=False)
        shutil.rmtree(wt, ignore_errors=True)

    def cleanup(self):
        for wt in self.made:
            self.remove(wt)
        git('worktree', 'prune', check=False)
        shutil.rmtree(self.root, ignore_errors=True)


def ref_bins(base, trees, opts, log):
    """The reference drivers + OCR tool for this base: (key, dir). Built
    from the base's sources once per source/library state, or copied from
    --ref-bin."""
    if opts.ref_bin:
        h = hashlib.sha1()
        for b in REF_BINS:
            with open(os.path.join(opts.ref_bin, b), 'rb') as f:
                h.update(f.read())
        key = 'bin-' + h.hexdigest()[:12]
        d = path('refbin', key, 'x')[:-2]
        if not all(os.path.exists(os.path.join(d, b)) for b in REF_BINS):
            for b in REF_BINS:
                shutil.copy2(os.path.join(opts.ref_bin, b), os.path.join(d, b))
        return key, d
    h = hashlib.sha1()
    for f in REF_INPUTS:
        h.update(git('show', f'{base}:{f}', check=False).encode())
    # the reference libraries build.sh links (its MGBA= / NBA= defaults)
    text = git('show', f'{base}:tools/playtest/build.sh', check=False)

    def src_dir(var):
        m = re.search(rf'^{var}=\$\{{{var}:-(.*?)\}}', text, re.M)
        return os.path.expanduser(os.environ.get(var) or (m.group(1) if m else ''))
    mgba, second = src_dir('MGBA'), src_dir('NBA')
    for lib in (f'{mgba}/build-headless/libmgba.a', f'{second}/build/src/nba/libnba.a',
                f'{second}/build/src/platform/core/libplatform-core.a'):
        try:
            st = os.stat(lib)
            h.update(f'{lib}|{st.st_size}|{int(st.st_mtime)}'.encode())
        except OSError:
            h.update(f'{lib}|missing'.encode())
    key = 'src-' + h.hexdigest()[:12]
    d = path('refbin', key, 'x')[:-2]
    if all(os.path.exists(os.path.join(d, b)) for b in REF_BINS):
        return key, d
    log(f'building the reference drivers ({key})')
    wt = trees.add('refs', base)
    blog = os.path.join(trees.logdir, 'build-refs.log')
    if sh(['bash', os.path.join(wt, 'tools/playtest/build.sh'), *REF_BINS], cwd=wt, out=blog, check=False):
        raise SystemExit(f'the reference drivers do not build (log {blog}); pass --ref-bin DIR with '
                         f'prebuilt {", ".join(REF_BINS)}')
    for b in REF_BINS:
        shutil.copy2(os.path.join(wt, 'tools/playtest/bin', b), os.path.join(d, b))
    trees.remove(wt)
    return key, d


def build(wt, refdir, trees, name, log):
    """Reference binaries copied in, dingbat_driver built with a private
    nimcache. -> True when it built."""
    bindir = os.path.join(wt, 'tools/playtest/bin')
    os.makedirs(bindir, exist_ok=True)
    for b in REF_BINS:
        shutil.copy2(os.path.join(refdir, b), os.path.join(bindir, b))
    blog = os.path.join(trees.logdir, f'build-{name}.log')
    t0 = time.time()
    env = dict(os.environ, NIMCACHE=os.path.join(trees.root, f'nimcache-{name}'))
    rc = sh(['bash', os.path.join(wt, 'tools/playtest/build.sh'), 'dingbat_driver'], cwd=wt, env=env,
            check=False, out=blog)
    ok = rc == 0 and os.path.exists(os.path.join(bindir, 'dingbat_driver'))
    log(f"  build {name}: {'ok' if ok else 'FAILED'} in {time.time() - t0:.0f}s" + ('' if ok else f' (log {blog})'))
    return ok


def relevant(files):
    """Whether a change can move a playtest result: what the results key is
    made of (the GBA core and the driver, the harness, the build
    configuration) and the scripts."""
    return any(keyed_path(f) or (f.startswith('tools/playtest/scripts/') and f.endswith('.play'))
               for f in files)


class NoBuild(Exception):
    pass


def ready_games(wt, only):
    """(sha1, title) of every ready script in a tree that matches `only`."""
    sys.path.insert(0, HERE)
    import script
    out = []
    sd = os.path.join(wt, 'tools/playtest/scripts')
    for fn in sorted(os.listdir(sd)):
        if not fn.endswith('.play'):
            continue
        sha1 = fn[:-5]
        try:
            meta = script.parse(open(os.path.join(sd, fn)).read())['meta']
        except Exception:
            meta = {}
        title = meta.get('title', sha1)
        if only and not any(sha1.startswith(o) or o.lower() in title.lower() for o in only):
            continue
        if meta.get('status', 'ready') == 'ready':
            out.append((sha1, title))
    return out


class Runner:
    """runner.json: what the train holding the lock is doing."""

    def __init__(self, run_id):
        self.state = {'pid': os.getpid(), 'run': run_id, 'started': datetime.datetime.now().isoformat(timespec='seconds')}

    def stage(self, stage, detail='', **kw):
        if stage != self.state.get('stage'):
            self.state.pop('suite_dir', None)
            self.state.pop('total', None)
        self.state.update(stage=stage, detail=detail, updated=datetime.datetime.now().isoformat(timespec='seconds'), **kw)
        write_json(path('runner.json'), self.state)

    def done(self):
        try:
            os.remove(path('runner.json'))
        except OSError:
            pass


def run_suite(wt, outroot, tag, games, refs_from, jobs, log, runner, label):
    """playtest.py suite in a tree, the references replayed from refs_from.
    -> suite directory."""
    os.makedirs(outroot, exist_ok=True)
    idx = path('rom-index.json')
    link = os.path.join(outroot, 'rom-index.json')
    if not os.path.exists(idx):
        seed = os.path.join(HERE, 'out', 'rom-index.json')
        shutil.copyfile(seed, idx) if os.path.exists(seed) else write_json(idx, {})
    if not os.path.lexists(link):
        os.symlink(idx, link)
    sdir = os.path.join(outroot, 'suites', tag)
    cmd = [sys.executable, os.path.join(wt, 'tools/playtest/playtest.py'), '--out', outroot, 'suite',
           *[s for s, _ in games], '--jobs', str(jobs), '--tag', tag, '--no-lock']
    if refs_from:
        cmd += ['--refs-from', refs_from]
    env = dict(os.environ, DINGBAT_TRAIN_INSIDE='1')
    slog = os.path.join(outroot, f'suite-{tag}.log')
    log(f'  {label}: {len(games)} games, --jobs {jobs}' + (' (references replayed)' if refs_from else '')
        + f' -> {sdir}')
    t0 = time.time()
    runner.stage(runner.state['stage'], label, suite_dir=sdir, total=len(games))
    with open(slog, 'a') as fh:
        # niced: the machine stays usable while a train runs
        p = subprocess.Popen(cmd, cwd=wt, env=env, stdout=fh, stderr=subprocess.STDOUT,
                             preexec_fn=lambda: os.nice(NICE) if NICE else None)
        try:
            while p.poll() is None:
                time.sleep(5)
        except BaseException:
            p.send_signal(signal.SIGTERM)
            p.wait()
            raise
    n = len((read_json(os.path.join(sdir, 'index.json'), {}) or {}).get('games', []))
    log(f'  {label}: done in {(time.time() - t0) / 60:.1f} min ({n} rows, log {slog})')
    return sdir


# ============================================================ results by key
#
# A game's outcome depends on its script, the dingbat driver's sources, the
# harness that plays and judges it, the reference binaries and the
# toolchain -- not on the commit they came from. Results are stored by that
# key (baselines/<key>-<refkey>, one row per game, valid for the script it
# played), so a main that moved only in docs, the web or the DS core reuses
# its predecessor's results, a candidate that lands as it was tested hands
# its combined run to the next train as that train's baseline, and a
# candidate that changes only scripts plays only those games.

# the driver's sources (emu.DRIVER_SOURCES) and the harness around it
KEY_PATHS = tuple(emulib.DRIVER_SOURCES) + ('tools/playtest',)
STORES_KEPT = 4
_toolchain = []


def keyed_path(f):
    """Whether a file is part of the results key (scripts count per game)."""
    if f.endswith('.md') or f.startswith(('tools/playtest/scripts/', 'tools/playtest/tests/')):
        return False
    return any(f == p or f.startswith(p + '/') for p in KEY_PATHS)


def toolchain():
    if not _toolchain:
        for cmd in (['nim', '--version'], ['cc', '--version']):
            try:
                _toolchain.append(sh(cmd, check=False).splitlines()[0])
            except (OSError, IndexError):
                _toolchain.append(f'{cmd[0]}: none')
    return ' / '.join(_toolchain)


def results_key(commit):
    """The key of everything at `commit` a game's result depends on besides
    its own script and the reference binaries."""
    h = hashlib.sha1(toolchain().encode())
    for line in git('ls-tree', '-r', '--full-tree', commit).splitlines():
        meta, f = line.split('\t', 1)
        if keyed_path(f):
            h.update(f'{meta}\t{f}\n'.encode())
    return h.hexdigest()[:12]


def script_blobs(commit):
    """{game sha1: blob id of its script} at `commit`."""
    out = {}
    for line in git('ls-tree', '--full-tree', commit, 'tools/playtest/scripts/').splitlines():
        meta, f = line.split('\t', 1)
        if f.endswith('.play'):
            out[os.path.basename(f)[:-5]] = meta.split()[2]
    return out


def blob_of(p):
    """git's blob id of a file's content (None when it cannot be read)."""
    try:
        with open(p, 'rb') as f:
            data = f.read()
    except OSError:
        return None
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def store_dir(key, refkey):
    return path('baselines', f'{key}-{refkey}', 'x')[:-2]


def store_suite(key, refkey):
    return os.path.join(store_dir(key, refkey), 'out', 'suites', 'baseline')


def fresh_rows(sdir, blobs):
    """{sha1: row} of a suite's rows that played the script `blobs` names."""
    out = {}
    for row in (read_json(os.path.join(sdir, 'index.json'), {}) or {}).get('games', []):
        od = row.get('outdir')
        if od and blobs.get(row['sha1']) and blob_of(os.path.join(od, 'script.play')) == blobs[row['sha1']]:
            out[row['sha1']] = row
    return out


def write_view(sdir, rows, tag):
    """A suite index over rows played elsewhere, for the record."""
    os.makedirs(sdir, exist_ok=True)
    write_json(os.path.join(sdir, 'index.json'), {'tag': tag, 'games': list(rows.values())})
    return sdir


def donor_for(refkey, exclude):
    """The newest other store with these reference binaries: its reference
    phases are replayed (per game, when its script is the same)."""
    root = os.path.dirname(path('baselines', 'x'))
    ds = sorted((d for d in os.listdir(root) if d.endswith(refkey) and os.path.join(root, d) != exclude
                 and os.path.exists(os.path.join(root, d, 'out', 'suites', 'baseline', 'index.json'))),
                key=lambda d: os.path.getmtime(os.path.join(root, d)), reverse=True)
    return os.path.join(root, ds[0], 'out', 'suites', 'baseline') if ds else None


def ensure_results(key, refkey, games, blobs, tree, opts, log, runner, label, refs_from=None):
    """{sha1: row} for every game in `games` with the script `blobs` names,
    from the store of `key`, playing (into the store) only the games it
    lacks. tree() -> a worktree with the driver built, called only when a
    game must play; refs_from: the suite the references replay from
    (default: the newest other store with these reference binaries)."""
    sroot = store_dir(key, refkey)
    sdir = store_suite(key, refkey)
    have = fresh_rows(sdir, blobs)
    missing = [g for g in games if g[0] not in have]
    os.makedirs(sroot, exist_ok=True)
    os.utime(sroot)     # most recently used: pruned last
    if not missing:
        log(f'{label} {key}: stored ({len(games)} games) {sdir}')
        return {g[0]: have[g[0]] for g in games}
    refs_from = refs_from or donor_for(refkey, sroot)
    log(f'{label} {key}: playing {len(missing)} of {len(games)} games'
        + (f', references from {refs_from}' if refs_from else ', every configuration'))
    wt = tree()
    keep_driver(wt, sroot)
    run_suite(wt, os.path.join(sroot, 'out'), 'baseline', missing, refs_from, opts.jobs, log, runner, label)
    write_json(os.path.join(sroot, 'baseline.json'), {'key': key, 'refkey': refkey, 'updated': time.time()})
    # every row just played counts, an ERROR without a run directory too (a
    # game that stopped running is a change); only a later train skips it
    want = {g[0] for g in missing}
    played = {r['sha1']: r for r in (read_json(os.path.join(sdir, 'index.json'), {}) or {}).get('games', [])
              if r['sha1'] in want}
    have.update(played)
    return {g[0]: have[g[0]] for g in games if g[0] in have}


def ensure_baseline(base, bkey, games, refkey, refdir, trees, opts, log, runner):
    """{sha1: row} of base's results for `games` (sha1s that exist in
    base), playing whatever the store of its key lacks."""
    if opts.baseline_suite:
        rows = (read_json(os.path.join(opts.baseline_suite, 'index.json'), {}) or {}).get('games', [])
        return {r['sha1']: r for r in rows}

    def tree():
        wt = trees.add('base', base)
        if not build(wt, refdir, trees, 'base', log):
            raise SystemExit(f'base {base[:12]} does not build: see {trees.logdir}/build-base.log')
        return wt
    runner.stage('baseline')
    return ensure_results(bkey, refkey, games, script_blobs(base), tree, opts, log, runner, 'baseline')


def keep_driver(wt, bdir):
    """Cache a tree's dingbat_driver with its stored results (the noise
    rerun plays base's again)."""
    os.makedirs(os.path.join(bdir, 'bin'), exist_ok=True)
    # the .srcsum stamp with it: emu.py refuses a driver without one
    for f in ('dingbat_driver', 'dingbat_driver.srcsum'):
        if os.path.exists(os.path.join(wt, 'tools/playtest/bin', f)):
            shutil.copy2(os.path.join(wt, 'tools/playtest/bin', f), os.path.join(bdir, 'bin', f))


def rerun_base(base, bdir, refdir, subset, refs_from, trees, opts, log, runner, rd):
    """Play `subset` on base again (the driver cached in its store `bdir`,
    or built now), the references replayed the way the combined run
    replayed them. -> suite directory, or None when base does not build."""
    cached = os.path.join(bdir, 'bin', 'dingbat_driver')
    wt = trees.add('base-again', base)
    # a driver cached before the .srcsum stamps has none: built again
    if os.path.exists(cached) and os.path.exists(cached + '.srcsum'):
        bindir = os.path.join(wt, 'tools/playtest/bin')
        os.makedirs(bindir, exist_ok=True)
        for b in REF_BINS:
            shutil.copy2(os.path.join(refdir, b), os.path.join(bindir, b))
        for f in ('dingbat_driver', 'dingbat_driver.srcsum'):
            shutil.copy2(os.path.join(os.path.dirname(cached), f), os.path.join(bindir, f))
        log(f'  base driver: cached ({cached})')
    elif build(wt, refdir, trees, 'base-again', log):
        keep_driver(wt, bdir)
    else:
        trees.remove(wt)
        return None
    sdir = run_suite(wt, os.path.join(rd, 'out-base'), 'base', subset, refs_from, opts.jobs, log, runner, 'base again')
    trees.remove(wt)
    return sdir


def baseline_cmd(args):
    log = Log()
    lk = machine_lock(wait=True, what='train.py baseline')
    run_id = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-baseline'
    trees, runner = Trees(run_id, log), Runner(run_id)
    try:
        if not args.commit:
            git('fetch', '-q', 'origin', check=False)
        base = git('rev-parse', '--verify', f"{args.commit or args.base}^{{commit}}")
        runner.stage('refs')
        refkey, refdir = ref_bins(base, trees, args, log)
        bkey = results_key(base)
        if args.suite:
            # adopt an existing suite of this commit as its baseline
            dst = store_suite(bkey, refkey)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.lexists(dst):
                os.symlink(os.path.abspath(args.suite), dst)
            log(f'baseline {base[:12]} ({bkey}): adopted {args.suite}')
            return 0
        names = git('ls-tree', '--name-only', f'{base}:tools/playtest/scripts').split()
        wt = trees.add('scan', base)
        games = ready_games(wt, args.only)
        trees.remove(wt)
        games = [g for g in games if f'{g[0]}.play' in names]
        ensure_baseline(base, bkey, games, refkey, refdir, trees, args, log, runner)
        return 0
    finally:
        trees.cleanup()
        runner.done()
        lk.release()


# ============================================================ the train

def drive(args, lk, until=None):
    """Run trains while candidates are pending (or until `until` has a
    verdict). The caller holds the lock."""
    for _ in range(50):
        p = pending()
        if not p or (until and verdict_of(until)):
            return
        car = [p[0]] if p[0].get('solo') else [e for e in p if not e.get('solo')][:args.max_car]
        train_once(car, args)
        if args.once:
            return


def set_verdict(cand, status, run_id, note='', **kw):
    v = {'id': cand['id'], 'name': cand['name'], 'sha': cand['sha'], 'ref': cand['ref'], 'run': run_id,
         'status': status, 'exit': EXIT[status], 'note': note,
         'decided': datetime.datetime.now().isoformat(timespec='seconds')}
    v.update(kw)
    write_json(path('verdicts', f"{cand['id']}.json"), v)
    return v


def defer(cand, run_id, why, solo=False):
    cand = dict(cand, deferred=True, deferred_from=run_id, deferred_why=why, solo=solo or cand.get('solo', False))
    write_json(path('queue', f"{cand['id']}.json"), cand)


def train_once(car, opts):
    run_id = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + f'-{len(car)}c'
    rd = path('runs', run_id, 'x')[:-2]
    log = Log(os.path.join(rd, 'log.txt'))
    runner = Runner(run_id)
    trees = Trees(run_id, log)
    run = {'id': run_id, 'candidates': [c['id'] for c in car], 'opts': {k: v for k, v in vars(opts).items()
                                                                        if k not in ('func',)}}
    try:
        return _train(car, opts, run_id, rd, log, runner, trees, run)
    finally:
        trees.cleanup()
        runner.done()
        prune(opts.keep, log)


def _train(car, opts, run_id, rd, log, runner, trees, run):
    runner.stage('triage')
    if not opts.base_given:
        git('fetch', '-q', 'origin', check=False)
    base = git('rev-parse', '--verify', f'{opts.base}^{{commit}}')
    run['base'] = base
    log(f'== train {run_id}: {len(car)} candidate(s) on {opts.base} {base[:12]}')
    verdicts, riding = {}, []
    for c in car:
        mb = git('merge-base', base, c['sha'], check=False)
        if not mb:
            verdicts[c['id']] = set_verdict(c, 'conflict', run_id, 'no common history with base')
            continue
        if git('rev-list', '--count', f"{base}..{c['sha']}") == '0':
            verdicts[c['id']] = set_verdict(c, 'landed', run_id, 'already in base')
            continue
        files = git('diff', '--name-only', mb, c['sha']).split()
        if not relevant(files):
            verdicts[c['id']] = set_verdict(c, 'skipped', run_id, 'touches nothing the corpus builds from '
                                            f"({', '.join(files[:4])}{'...' if len(files) > 4 else ''})")
            continue
        riding.append(dict(c, files=files))
    for c in car:
        if c['id'] in verdicts:
            log(f"  {c['name']}: {verdicts[c['id']]['status']} ({verdicts[c['id']]['note']})")
    if not riding:
        return finish(run, rd, log, verdicts, car)

    # ---- combine
    runner.stage('combine')
    comb = trees.add('combined', base)
    aboard = []
    for c in riding:
        r = trees.merge(comb, c)
        if r == 'ok':
            aboard.append(c)
        elif r == 'empty':
            verdicts[c['id']] = set_verdict(c, 'landed', run_id, 'its changes are already in base')
        elif not aboard:
            verdicts[c['id']] = set_verdict(c, 'conflict', run_id, f'does not merge onto {base[:12]}: rebase it')
        else:
            defer(c, run_id, f"conflicts with {', '.join(a['name'] for a in aboard)}")
            run.setdefault('ejected', []).append({'id': c['id'], 'name': c['name'],
                                                   'with': [a['name'] for a in aboard]})
            log(f"  {c['name']}: conflicts with an earlier candidate; rides the next train first")
    if not aboard:
        return finish(run, rd, log, verdicts, car)
    log(f"  aboard: {', '.join(c['name'] for c in aboard)}")

    # ---- references, baseline, combined build
    runner.stage('refs')
    refkey, refdir = ref_bins(base, trees, opts, log)
    games = ready_games(comb, opts.only)
    in_base = set(git('ls-tree', '--name-only', f'{base}:tools/playtest/scripts').split())
    base_games = [g for g in games if f'{g[0]}.play' in in_base]
    bkey = results_key(base)
    run['base_key'] = bkey
    brows = ensure_baseline(base, bkey, base_games, refkey, refdir, trees, opts, log, runner)
    bsuite = os.path.abspath(opts.baseline_suite) if opts.baseline_suite else store_suite(bkey, refkey)
    run['baseline'] = bsuite
    # read now: a candidate that changes only scripts shares base's store,
    # and its runs of those scripts replace base's rows there
    B = load_rows(brows.values())

    head = git('rev-parse', 'HEAD', cwd=comb)
    ckey, cblobs = results_key(head), script_blobs(head)
    live = [c['name'] for c in aboard if set(c['files']) & set(REF_INPUTS)]
    # a candidate changing what the references play has them play live,
    # from its own reference inputs: stored under their key, which is the
    # key of main once it lands (--ref-bin keys the binaries alone: not
    # stored then)
    crefkey, crefdir = ref_bins(head, trees, opts, log) if live else (refkey, refdir)
    keep = not live or crefkey != refkey
    stored = fresh_rows(store_suite(ckey, crefkey), cblobs) if keep else {}
    must_play = any(g[0] not in stored for g in games)
    solo_trees = {}
    if must_play:
        runner.stage('build', 'combined')
        if not build(comb, crefdir, trees, 'combined', log):
            if len(aboard) == 1:
                verdicts[aboard[0]['id']] = set_verdict(aboard[0], 'build-failed', run_id,
                                                        f'does not build on {base[:12]}',
                                                        log=f'{trees.logdir}/build-combined.log')
                return finish(run, rd, log, verdicts, car)
            # who breaks it: each alone (kept for attribution)
            ok = []
            for c in aboard:
                wt = trees.add(f"c{len(solo_trees)}", base)
                trees.merge(wt, c)
                if build(wt, refdir, trees, f"c{len(solo_trees)}", log):
                    solo_trees[c['id']] = wt
                    ok.append(c)
                else:
                    verdicts[c['id']] = set_verdict(c, 'build-failed', run_id, f'does not build on {base[:12]}')
            for c in ok:
                # builds alone, not together: each rides a train of its own
                defer(c, run_id, 'the batch did not build together', solo=True)
            run['build_split'] = [c['name'] for c in ok]
            return finish(run, rd, log, verdicts, car)

    # ---- the corpus on the combined build
    runner.stage('combined')
    if live:
        log(f"  {', '.join(live)} changes what the references play: references run live")
    if not keep:
        csuite = run_suite(comb, os.path.join(rd, 'out-combined'), 'combined', games, None,
                           opts.jobs, log, runner, 'combined')
        C = load_suite(csuite)
    else:
        if ckey == bkey and crefkey == refkey:
            log(f'  combined: the same results key as base ({ckey}): only changed scripts play')
        crows = ensure_results(ckey, crefkey, games, cblobs, lambda: comb, opts, log, runner, 'combined',
                               refs_from=None if live else bsuite)
        csuite = write_view(os.path.join(rd, 'out-combined', 'suites', 'combined'), crows, 'combined')
        C = load_rows(crows.values())
    run['combined_key'] = ckey
    Bf, Cf = {s: f for s, (r, f) in B.items()}, {s: f for s, (r, f) in C.items()}
    raw, added, removed = diff_suites(Bf, Cf)
    log(f'  diff vs baseline: {len(raw)} changed, {len(added)} added, {len(removed)} not run')

    # ---- noise: the changed games once more on base itself, where a
    # change could be noise at all (could_be_noise)
    ledger = read_json(path('noise.json'), {}) or {}

    def rerun(subset):
        runner.stage('noise', f'{len(subset)} games on base again')
        sd = rerun_base(base, store_dir(bkey, refkey), refdir, [(s, C[s][0]['title']) for s in subset],
                        None if live else bsuite, trees, opts, log, runner, rd)
        if not sd:
            log('  base does not build again: no noise check')
            return {}
        run['base_again'] = sd
        return {s: f for s, (r, f) in load_suite(sd).items()}
    Cf, changed, noise, reran = denoise(Bf, Cf, bkey, ledger, rerun, live=bool(live))
    if noise:
        ledger = update_ledger(ledger, noise, bkey, {s: (C.get(s) or B.get(s))[0]['title'] for s in noise})
        write_json(path('noise.json'), ledger)
    log(f'  noise: {len(noise)} game(s) with cells that differ between runs of base'
        + (f' ({len(reran)} replayed on base)' if reran else '') + f'; {len(changed)} changed after it')
    run.update(combined=csuite, changed=changed, added=added, noise=noise, reran=reran)

    # ---- attribution
    cand_fps, cand_rows = {}, {}
    if len(aboard) == 1:
        cand_fps[aboard[0]['id']] = {s: Cf[s] for s in changed}
        cand_rows[aboard[0]['id']] = {s: C[s][0] for s in changed}
    elif changed:
        runner.stage('attribute')
        subset = [(s, C[s][0]['title']) for s in changed]
        for i, c in enumerate(aboard):
            wt = solo_trees.get(c['id'])
            if not wt:
                wt = trees.add(f'c{i}', base)
                trees.merge(wt, c)
            built = [bool(solo_trees.get(c['id']))]

            def tree(wt=wt, i=i, built=built):
                if not built[0] and not build(wt, refdir, trees, f'c{i}', log):
                    raise NoBuild()
                built[0] = True
                return wt
            label = f"alone: {c['name']}"
            try:
                if c['name'] in live:
                    tree()
                    s = run_suite(wt, os.path.join(rd, f'out-c{i}'), f'c{i}', subset, None, opts.jobs, log,
                                  runner, label)
                    got = load_suite(s)
                else:
                    ahead = git('rev-parse', 'HEAD', cwd=wt)
                    arows = ensure_results(results_key(ahead), refkey, subset, script_blobs(ahead), tree, opts,
                                           log, runner, label, refs_from=bsuite)
                    s = write_view(os.path.join(rd, f'out-c{i}', 'suites', f'c{i}'), arows, f'c{i}')
                    got = load_rows(arows.values())
            except NoBuild:
                # built in the batch but not alone: it needs another candidate
                cand_fps[c['id']] = {}
                run.setdefault('alone_build_failed', []).append(c['name'])
                trees.remove(wt)
                continue
            cand_fps[c['id']] = {k: mask(f, Bf[k], {cfg: list(d) for cfg, d in noise.get(k, {}).items()})
                                 for k, (r, f) in got.items() if k in Bf}
            cand_rows[c['id']] = {k: r for k, (r, f) in got.items()}
            run.setdefault('alone', {})[c['id']] = s
            trees.remove(wt)
    att = attribute({s: Bf[s] for s in changed}, {s: Cf[s] for s in changed}, cand_fps) if changed \
        else {'effects': {c['id']: {} for c in aboard}, 'interactions': [], 'shared': {}}
    run['attribution'] = att

    def title(s):
        return (C.get(s) or B.get(s))[0]['title']

    def outdirs(s, cid):
        alone = run.get('alone', {}).get(cid)
        a = None
        if alone:
            row = next((r for r in (read_json(os.path.join(alone, 'index.json'), {}) or {}).get('games', [])
                        if r['sha1'] == s), None)
            a = row and row.get('outdir')
        return {'baseline': B[s][0].get('outdir'), 'combined': C[s][0].get('outdir'), 'alone': a}

    noise_list = [{'sha1': s, 'title': title(s), 'what': describe_noise(cfgs),
                   'how': sorted({e['how'] for d in cfgs.values() for e in d.values()}),
                   'ocr_only': ocr_only(cfgs)} for s, cfgs in sorted(noise.items())]
    for c in aboard:
        eff = att['effects'].get(c['id'], {})
        groups = {'fixed': [], 'regressed': [], 'mixed': [], 'neutral': []}
        for s, e in eff.items():
            if not e['kind']:
                continue
            groups[e['kind']].append({'sha1': s, 'title': title(s), 'what': describe(e['aspects']),
                                      'configs': e['configs'], 'aspects': e['aspects'],
                                      'problems_before': _problems(B[s][0]),
                                      'problems_after': _problems(cand_rows.get(c['id'], {}).get(s, {})),
                                      'known_noisy': known_noisy(ledger, s, e['aspects']),
                                      'outdirs': outdirs(s, c['id'])})
        inter = [dict(i, title=title(i['sha1'])) for i in att['interactions'] if c['id'] in i['involved']]
        adds = [{'sha1': s, 'title': C[s][0]['title'], 'status': C[s][0]['status'],
                 'outdir': C[s][0].get('outdir')}
                for s in added if f'tools/playtest/scripts/{s}.play' in c['files']]
        status = 'changed' if any(groups.values()) or inter or adds else 'clean'
        note = ''
        if c['name'] in run.get('alone_build_failed', []):
            note = 'builds only together with the rest of the batch: attribution incomplete'
        verdicts[c['id']] = set_verdict(c, status, run_id, note, base=base, interactions=inter, added=adds,
                                        aboard=[a['name'] for a in aboard], noise=noise_list, **groups)
    return finish(run, rd, log, verdicts, car)


def _problems(row):
    return {c: d.get('problems', []) for c, d in (row.get('detail') or {}).items()} \
        if isinstance(row.get('detail'), dict) else row.get('detail')


def finish(run, rd, log, verdicts, car):
    rep = os.path.join(rd, 'report.md')
    run['verdicts'] = verdicts
    for v in verdicts.values():
        v['report'] = rep
        write_json(path('verdicts', f"{v['id']}.json"), v)
    write_json(os.path.join(rd, 'report.json'), run)
    with open(rep, 'w') as f:
        f.write(render_report(run, car))
    log(f'== train {run["id"]} done: {rep}')
    for c in car:
        if c['id'] in verdicts:
            print_verdict(verdicts[c['id']])
        else:
            print(f"== {c['name']}: deferred to the next train")
    return run


def render_report(run, car):
    L = [f"# Playtest train {run['id']}", '']
    if run.get('base'):
        L.append(f"Base `{run['base'][:12]}`; baseline `{run.get('baseline')}`.")
    if run.get('combined'):
        L.append(f"Combined suite `{run['combined']}`: {len(run.get('changed', {}))} game(s) changed, "
                 f"{len(run.get('added', []))} added.")
    L += ['', '| candidate | commit | verdict | fixed | regressed | mixed | neutral | interactions |',
          '|---|---|---|---|---|---|---|---|']
    vs = run.get('verdicts', {})
    for c in car:
        v = vs.get(c['id'])
        if not v:
            L.append(f"| {c['name']} | `{c['sha'][:10]}` | deferred | | | | | |")
            continue
        L.append(f"| {c['name']} | `{c['sha'][:10]}` | {v['status']} | {len(v.get('fixed', []))} | "
                 f"{len(v.get('regressed', []))} | {len(v.get('mixed', []))} | {len(v.get('neutral', []))} | "
                 f"{len(v.get('interactions', []))} |")
    for c in car:
        v = vs.get(c['id'])
        if not v:
            continue
        L += ['', f"## {c['name']} (`{c['sha'][:12]}`): {v['status']}"]
        if v.get('note'):
            L.append(f"_{v['note']}_")
        for k in ('regressed', 'mixed', 'fixed', 'neutral'):
            for g in v.get(k, []):
                L.append(f"- **{k}** {g['title']} (`{g['sha1'][:10]}`): {g['what']}")
                if k in ('regressed', 'mixed') and g.get('problems_after'):
                    for cfg, ps in g['problems_after'].items():
                        if ps:
                            L.append(f"  - now {cfg}: {'; '.join(ps)[:300]}")
                if k == 'fixed' and isinstance(g.get('problems_before'), dict):
                    for cfg, ps in g['problems_before'].items():
                        if ps and g['configs'].get(cfg) == 'fixed':
                            L.append(f"  - was {cfg}: {'; '.join(ps)[:300]}")
                if g.get('known_noisy'):
                    L.append(f"  - known noisy: {'; '.join(g['known_noisy'])}")
                o = g.get('outdirs') or {}
                L.append(f"  - runs: baseline `{o.get('baseline')}`, combined `{o.get('combined')}`"
                         + (f", alone `{o['alone']}`" if o.get('alone') else ''))
        for g in v.get('added', []):
            L.append(f"- **added** {g['title']}: {g['status']} (`{g.get('outdir')}`)")
        for i in v.get('interactions', []):
            L.append(f"- **interaction** {i['title']} with {', '.join(i['involved'])}: "
                     f"{'; '.join((i['unexplained'] + i['overlapping'])[:6])}")
    nl = next((v['noise'] for v in vs.values() if v.get('noise')), [])
    if nl:
        L += ['', '## Noise (not attributed)', '',
              f"Cells that differ between the baseline and a second run of base `{run['base'][:12]}`, or match "
              'a value an earlier run of it produced; no candidate is credited or blamed for them. '
              f"Counted in `{path('noise.json')}`.", '']
        L += [f"- {g['title']} (`{g['sha1'][:10]}`): {noise_text(g)}" for g in nl]
    if run.get('ejected'):
        L += ['', '## Ejected (ride the next train first)']
        for e in run['ejected']:
            L.append(f"- {e['name']}: conflicts with {', '.join(e['with'])}")
    if run.get('build_split'):
        L += ['', '## Built alone but not together (each rides its own train)']
        L += [f'- {n}' for n in run['build_split']]
    L += ['', '_A game identical to the baseline on the combined build is taken as identical on every '
          'candidate: the scripts are frozen inputs and the emulator is deterministic, so this only misses '
          'two changes that exactly cancel._', '']
    return '\n'.join(L)


def prune(keep, log):
    """Keep the newest `keep` runs' suite outputs (reports always) and the
    STORES_KEPT most recently used result stores."""
    rd = os.path.dirname(path('runs', 'x'))
    runs = sorted(os.listdir(rd))
    for r in runs[:-keep] if keep else []:
        for d in os.listdir(os.path.join(rd, r)):
            if d.startswith('out-'):
                shutil.rmtree(os.path.join(rd, r, d), ignore_errors=True)
    bd = os.path.dirname(path('baselines', 'x'))
    bs = sorted(os.listdir(bd), key=lambda d: os.path.getmtime(os.path.join(bd, d)))
    for b in bs[:-STORES_KEPT]:
        shutil.rmtree(os.path.join(bd, b), ignore_errors=True)
    work = os.path.dirname(path('work', 'x'))
    for w in os.listdir(work):
        # a train that died left its worktrees: nobody else uses work/
        # while we hold the lock
        git('worktree', 'remove', '--force', os.path.join(work, w), check=False)
        shutil.rmtree(os.path.join(work, w), ignore_errors=True)
    git('worktree', 'prune', check=False)


# ============================================================ status / show

def status(args):
    r = read_json(path('runner.json'))
    free = lock_free()
    if r and not free:
        prog = ''
        if r.get('suite_dir'):
            n = len((read_json(os.path.join(r['suite_dir'], 'index.json'), {}) or {}).get('games', []))
            prog = f" {n}/{r.get('total')} games"
        print(f"train {r['run']} (pid {r['pid']}): {r.get('stage')} {r.get('detail', '')}{prog}, "
              f"since {r['started']}; log {os.path.join(HOME, 'runs', r['run'], 'log.txt')}")
    elif not free:
        h = read_json(path('holder.json'), {})
        print(f"lock held by pid {h.get('pid')}: {h.get('what')} since {h.get('since')}")
    else:
        print('no train running' + (f" (stale runner.json from dead pid {r['pid']})" if r and not pid_alive(r['pid']) else ''))
    p = pending()
    print(f'{len(p)} pending:')
    for e in p:
        print(f"  {e['id']}  {e['sha'][:10]}  {e['name']}" + (f"  (deferred: {e.get('deferred_why')})" if e.get('deferred') else ''))
    vd = os.path.dirname(path('verdicts', 'x'))
    recent = sorted(os.listdir(vd), key=lambda f: os.path.getmtime(os.path.join(vd, f)))[-args.recent:]
    if recent:
        print('recent verdicts:')
    for f in recent:
        v = read_json(os.path.join(vd, f), {})
        n = {k: len(v.get(k, [])) for k in ('fixed', 'regressed', 'mixed', 'neutral', 'interactions')}
        print(f"  {v.get('decided')}  {v.get('status', '?'):12} {v.get('name')}  "
              + ' '.join(f'{k}={x}' for k, x in n.items() if x))
    cells = chronic(read_json(path('noise.json'), {}))
    if cells:
        many = [c for c in cells if c['seen'] > 1]
        print(f"noise ledger: {len(cells)} cell(s), {len(many)} seen more than once"
              + ('; most often: ' + '; '.join(f"{c['title']} {c['config']} {c['aspect']} {c['seen']}x"
                                              for c in many[:3]) if many else '')
              + ' (`train.py show noise`)')
    return 0


def show(args):
    if args.id == 'noise':
        cells = chronic(read_json(path('noise.json'), {}))
        print(f'{len(cells)} noise cell(s) in {path("noise.json")}' + (':' if cells else ''))
        for c in cells:
            print(f"  {c['seen']:3}x  {c['title']} (`{c['sha1'][:10]}`) {c['config']} {c['aspect']}  "
                  f"last {c['last_seen']}; e.g. {json.dumps(c['examples'][:2])[:120]}")
        return 0
    vd = os.path.dirname(path('verdicts', 'x'))
    hits = [f for f in os.listdir(vd) if args.id in f]
    if hits:
        for f in sorted(hits):
            print_verdict(read_json(os.path.join(vd, f)))
        return 0
    rep = os.path.join(HOME, 'runs', args.id, 'report.md')
    if os.path.exists(rep):
        with open(rep) as f:
            print(f.read())
        return 0
    print(f'no verdict or run matching {args.id}')
    return 2


# ============================================================ CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    def train_opts(p):
        p.add_argument('--jobs', type=int, default=6, help='games at a time in each suite (default 6)')
        p.add_argument('--nice', type=int, default=NICE,
                       help=f'niceness of the suites a train runs (default {NICE}; 0 for none)')
        p.add_argument('--base', default=None, help='what candidates go on top of (default: origin/main, fetched)')
        p.add_argument('--only', nargs='+', default=None,
                       help='sha1 prefixes or title substrings: a subset of the corpus (testing the train)')
        p.add_argument('--baseline-suite', default=None,
                       help='use this suite directory as the baseline instead of the cached one')
        p.add_argument('--ref-bin', default=None,
                       help='prebuilt mgba_driver, nba_driver and screenread instead of building them')
        p.add_argument('--max-car', type=int, default=8, help='candidates per train (default 8)')
        p.add_argument('--keep', type=int, default=8, help='runs whose suite outputs are kept (default 8)')
        p.add_argument('--once', action='store_true', help='one train, then stop')
        p.add_argument('--poll', type=int, default=20, help=argparse.SUPPRESS)

    p = sub.add_parser('submit', help='queue a candidate commit')
    p.add_argument('ref')
    p.add_argument('--name')
    p.add_argument('--wait', action='store_true',
                   help='block until its verdict; drive the train if nobody is (exit 0 clean, 1 changes, 2 conflict/build)')
    train_opts(p)
    p = sub.add_parser('run', help='drive trains until the queue is empty')
    train_opts(p)
    p = sub.add_parser('status')
    p.add_argument('--recent', type=int, default=8)
    p = sub.add_parser('show', help="a candidate's verdict (id or a part of it), a run's report, or `noise` (the ledger)")
    p.add_argument('id')
    p = sub.add_parser('baseline', help='build (or adopt) the cached baseline of a commit')
    p.add_argument('--commit', default=None, help='default: origin/main, fetched')
    p.add_argument('--suite', default=None, help='adopt this existing suite directory (run on that commit) as its baseline')
    train_opts(p)

    args = ap.parse_args(argv)
    if hasattr(args, 'base'):
        args.base_given = args.base is not None
        args.base = args.base or 'origin/main'
    if hasattr(args, 'nice'):
        global NICE
        NICE = args.nice
    os.makedirs(HOME, exist_ok=True)
    if args.cmd == 'submit':
        return submit(args)
    if args.cmd == 'run':
        lk = machine_lock(wait=True, what='train.py run')
        try:
            drive(args, lk)
        finally:
            lk.release()
        return 0
    if args.cmd == 'status':
        return status(args)
    if args.cmd == 'show':
        return show(args)
    if args.cmd == 'baseline':
        return baseline_cmd(args)


if __name__ == '__main__':
    sys.exit(main())
