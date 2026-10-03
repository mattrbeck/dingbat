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

  1. base = origin/main (fetched). Its baseline (every game in all six
     configurations) is cached by commit; the reference emulators' phases are
     replayed from the previous baseline when the scripts and reference
     binaries are unchanged, so a new baseline only plays dingbat.
  2. Candidates that touch nothing the corpus builds from (docs, web, other
     tools) are clean without running. The rest are squash-merged onto base
     in queue order in a temporary worktree; one that conflicts with an
     earlier one rides the next train first, one that does not apply to base
     at all is rejected.
  3. The combined build plays the corpus in the four dingbat configurations,
     the references replayed from the baseline.
  4. Every game is compared with the baseline per configuration: pass/fail
     and every hash (each checkpoint and its frame window, the [new] audio,
     the battery file, every [load] cell the configuration writes or reads).
  5. With more than one candidate and at least one changed game, each
     candidate is built alone on base and replays only the changed games;
     each changed hash is credited to the candidate that reproduces it. A
     change no candidate reproduces alone (or one a candidate makes that the
     combined build does not show) is an interaction, for a human.

The scripts are frozen input timelines and every configuration is
deterministic, so a game identical to the baseline on the combined build is
identical on each candidate -- unless two candidates' changes exactly cancel.

State lives outside every checkout, in $DINGBAT_TRAIN_HOME (default
~/.cache/dingbat-train): queue/, verdicts/, runs/<id>/ (report.md,
report.json, log.txt, the suites' run directories), baselines/, refbin/,
work/ (temporary worktrees, removed after each train). Nothing is pushed and
no existing checkout is touched.
"""
import argparse
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
HOME = os.path.expanduser(os.environ.get('DINGBAT_TRAIN_HOME', '~/.cache/dingbat-train'))
DINGBAT = ['dingbat', 'dingbat-nowl', 'dingbat-bios', 'dingbat-bios-nowl']
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
    for c in sorted(set(before) | set(after), key=lambda k: (k != '*', k)):
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
        loads = sorted(k.split(':', 1)[1] for k in d if k.startswith('load:'))
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
        parts.append(f"{cfg}: {'; '.join(bits)}")
    return ' | '.join(parts)


# ============================================================ suites on disk

def load_suite(suite_dir):
    """{sha1: (row, fingerprint)} for a suite directory."""
    out = {}
    index = os.path.join(suite_dir, 'index.json')
    if not os.path.exists(index):
        return out
    for row in read_json(index, {}).get('games', []):
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
    last_note = 0
    while True:
        v = verdict_of(cid)
        if v:
            print_verdict(v)
            return v.get('exit', 1)
        lk = machine_lock(wait=False)
        if lk:
            try:
                drive(args, lk, until=cid)
            finally:
                lk.release()
            continue
        if time.time() - last_note > 300:
            r = read_json(path('runner.json'), {})
            print(f"waiting: train {r.get('run')} at {r.get('stage')} {r.get('detail', '')}", flush=True)
            last_note = time.time()
        time.sleep(args.poll)


def print_verdict(v):
    print(f"== {v['name']} ({v['sha'][:12]}): {v['status'].upper()}" + (f" -- {v['note']}" if v.get('note') else ''))
    for k in ('fixed', 'regressed', 'mixed', 'neutral'):
        for g in v.get(k, []):
            print(f"   {k:9} {g['title']}: {g['what']}")
    for g in v.get('added', []):
        print(f"   added     {g['title']}: {g['status']}")
    for i in v.get('interactions', []):
        print(f"   INTERACTION {i['title']} with {', '.join(i['involved'])}: "
              f"{'; '.join((i['unexplained'] + i['overlapping'])[:4])}")
    if v.get('report'):
        print(f"   report: {v['report']}")


# ============================================================ worktrees and builds

class Trees:
    """Temporary worktrees of this train under work/<run>/, removed by
    cleanup()."""

    def __init__(self, run_id, log):
        self.root = path('work', run_id, 'x')[:-2]
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
    mgba = os.path.expanduser(os.environ.get('MGBA', '~/code/mgba-ref-src'))
    nba = os.path.expanduser(os.environ.get('NBA', '~/code/NanoBoyAdvance'))
    for lib in (f'{mgba}/build-headless/libmgba.a', f'{nba}/build/src/nba/libnba.a',
                f'{nba}/build/src/platform/core/libplatform-core.a'):
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
    sh(['bash', os.path.join(wt, 'tools/playtest/build.sh'), *REF_BINS], cwd=wt,
       out=os.path.join(trees.root, 'build-refs.log'))
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
    blog = os.path.join(trees.root, f'build-{name}.log')
    t0 = time.time()
    env = dict(os.environ, NIMCACHE=os.path.join(trees.root, f'nimcache-{name}'))
    rc = sh(['bash', os.path.join(wt, 'tools/playtest/build.sh'), 'dingbat_driver'], cwd=wt, env=env,
            check=False, out=blog)
    ok = rc == 0 and os.path.exists(os.path.join(bindir, 'dingbat_driver'))
    log(f"  build {name}: {'ok' if ok else 'FAILED'} in {time.time() - t0:.0f}s" + ('' if ok else f' (log {blog})'))
    return ok


def relevant(files):
    """Whether a change can move a playtest result: the core, the harness
    and its scripts, the build configuration."""
    for f in files:
        if f.endswith('.md'):
            continue
        if f.startswith(('src/', 'tools/playtest/')) and not f.startswith('tools/playtest/tests/'):
            return True
        if '/' not in f and (f.endswith(('.nims', '.cfg', '.nimble'))):
            return True
    return False


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
        p = subprocess.Popen(cmd, cwd=wt, env=env, stdout=fh, stderr=subprocess.STDOUT)
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


# ============================================================ baselines

def baseline_for(base, refkey):
    return path('baselines', f'{base[:12]}-{refkey}', 'x')[:-2]


def ensure_baseline(base, games, refkey, refdir, trees, opts, log, runner):
    """The suite directory holding base's results for `games` (sha1s that
    exist in base), playing whatever is missing."""
    if opts.baseline_suite:
        return os.path.abspath(opts.baseline_suite)
    bdir = baseline_for(base, refkey)
    sdir = os.path.join(bdir, 'out', 'suites', 'baseline')
    have = {r['sha1'] for r in (read_json(os.path.join(sdir, 'index.json'), {}) or {}).get('games', [])}
    missing = [g for g in games if g[0] not in have]
    if not missing:
        log(f'baseline {base[:12]}: cached ({len(have)} games) {sdir}')
        return sdir
    runner.stage('baseline', f'{len(missing)} games')
    # the references are replayed from the newest other baseline with the
    # same reference binaries (per game, when its script is unchanged)
    donors = sorted((d for d in os.listdir(os.path.dirname(bdir))
                     if d.endswith(refkey) and os.path.join(os.path.dirname(bdir), d) != bdir
                     and os.path.exists(os.path.join(os.path.dirname(bdir), d, 'out', 'suites', 'baseline', 'index.json'))),
                    key=lambda d: os.path.getmtime(os.path.join(os.path.dirname(bdir), d)), reverse=True)
    donor = os.path.join(os.path.dirname(bdir), donors[0], 'out', 'suites', 'baseline') if donors else None
    log(f'baseline {base[:12]}: playing {len(missing)} games' + (f', references from {donor}' if donor else ', all six configurations'))
    wt = trees.add('base', base)
    if not build(wt, refdir, trees, 'base', log):
        raise SystemExit(f'base {base[:12]} does not build: see {trees.root}/build-base.log')
    run_suite(wt, os.path.join(bdir, 'out'), 'baseline', missing, donor, opts.jobs, log, runner, 'baseline')
    write_json(os.path.join(bdir, 'baseline.json'), {'base': base, 'refkey': refkey, 'updated': time.time()})
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
        if args.suite:
            # adopt an existing suite of this commit as its baseline
            bdir = baseline_for(base, refkey)
            dst = os.path.join(bdir, 'out', 'suites', 'baseline')
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.lexists(dst):
                os.symlink(os.path.abspath(args.suite), dst)
            log(f'baseline {base[:12]}: adopted {args.suite}')
            return 0
        names = git('ls-tree', '--name-only', f'{base}:tools/playtest/scripts').split()
        wt = trees.add('scan', base)
        games = ready_games(wt, args.only)
        trees.remove(wt)
        games = [g for g in games if f'{g[0]}.play' in names]
        ensure_baseline(base, games, refkey, refdir, trees, args, log, runner)
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
    bsuite = ensure_baseline(base, base_games, refkey, refdir, trees, opts, log, runner)
    run['baseline'] = bsuite

    runner.stage('build', 'combined')
    solo_trees = {}
    if not build(comb, refdir, trees, 'combined', log):
        if len(aboard) == 1:
            verdicts[aboard[0]['id']] = set_verdict(aboard[0], 'build-failed', run_id,
                                                    f'does not build on {base[:12]}', log=f'{trees.root}/build-combined.log')
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
    live = [c['name'] for c in aboard if set(c['files']) & set(REF_INPUTS)]
    if live:
        log(f"  {', '.join(live)} changes what the references play: references run live")
    csuite = run_suite(comb, os.path.join(rd, 'out-combined'), 'combined', games, None if live else bsuite,
                       opts.jobs, log, runner, 'combined')
    B, C = load_suite(bsuite), load_suite(csuite)
    changed, added, removed = diff_suites({s: f for s, (r, f) in B.items()},
                                          {s: f for s, (r, f) in C.items()})
    log(f'  diff vs baseline: {len(changed)} changed, {len(added)} added, {len(removed)} not run')
    run.update(combined=csuite, changed=changed, added=added)

    # ---- attribution
    cand_fps, cand_rows = {}, {}
    if len(aboard) == 1:
        cand_fps[aboard[0]['id']] = {s: C[s][1] for s in changed}
        cand_rows[aboard[0]['id']] = {s: C[s][0] for s in changed}
    elif changed:
        runner.stage('attribute')
        subset = [(s, C[s][0]['title']) for s in changed]
        for i, c in enumerate(aboard):
            wt = solo_trees.get(c['id'])
            if not wt:
                wt = trees.add(f'c{i}', base)
                trees.merge(wt, c)
                if not build(wt, refdir, trees, f'c{i}', log):
                    # built in the batch but not alone: it needs another candidate
                    cand_fps[c['id']] = {}
                    run.setdefault('alone_build_failed', []).append(c['name'])
                    continue
            s = run_suite(wt, os.path.join(rd, f'out-c{i}'), f'c{i}', subset,
                          None if c['name'] in live else bsuite, opts.jobs, log, runner, f"alone: {c['name']}")
            got = load_suite(s)
            cand_fps[c['id']] = {k: f for k, (r, f) in got.items()}
            cand_rows[c['id']] = {k: r for k, (r, f) in got.items()}
            run.setdefault('alone', {})[c['id']] = s
            trees.remove(wt)
    att = attribute({s: B[s][1] for s in changed}, {s: C[s][1] for s in changed}, cand_fps) if changed \
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
                                        aboard=[a['name'] for a in aboard], **groups)
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
                o = g.get('outdirs') or {}
                L.append(f"  - runs: baseline `{o.get('baseline')}`, combined `{o.get('combined')}`"
                         + (f", alone `{o['alone']}`" if o.get('alone') else ''))
        for g in v.get('added', []):
            L.append(f"- **added** {g['title']}: {g['status']} (`{g.get('outdir')}`)")
        for i in v.get('interactions', []):
            L.append(f"- **interaction** {i['title']} with {', '.join(i['involved'])}: "
                     f"{'; '.join((i['unexplained'] + i['overlapping'])[:6])}")
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
    newest three baselines."""
    rd = os.path.dirname(path('runs', 'x'))
    runs = sorted(os.listdir(rd))
    for r in runs[:-keep] if keep else []:
        for d in os.listdir(os.path.join(rd, r)):
            if d.startswith('out-'):
                shutil.rmtree(os.path.join(rd, r, d), ignore_errors=True)
    bd = os.path.dirname(path('baselines', 'x'))
    bs = sorted(os.listdir(bd), key=lambda d: os.path.getmtime(os.path.join(bd, d)))
    for b in bs[:-3]:
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
    return 0


def show(args):
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
    p = sub.add_parser('show', help="a candidate's verdict (id or a part of it) or a run's report")
    p.add_argument('id')
    p = sub.add_parser('baseline', help='build (or adopt) the cached baseline of a commit')
    p.add_argument('--commit', default=None, help='default: origin/main, fetched')
    p.add_argument('--suite', default=None, help='adopt this existing suite directory (run on that commit) as its baseline')
    train_opts(p)

    args = ap.parse_args(argv)
    if hasattr(args, 'base'):
        args.base_given = args.base is not None
        args.base = args.base or 'origin/main'
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
