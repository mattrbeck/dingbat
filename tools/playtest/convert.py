"""Turn a human play session into a script section.

Record in the desktop app (the log is appended to; each ROM load starts a
session, quitting writes its end frame):
    DINGBAT_INPUT_LOG=~/rec/emerald-new.log ./dingbat game.gba
Convert:
    playtest.py convert ~/rec/emerald-new.log --rom game.gba --section new

The log holds "<frame> <mask>" keypad changes. The last session is replayed
headless in dingbat with the same BIOS mode while the screen is OCR-sampled
every few frames, then turned into steps:

  - a lone tap becomes `press KEY hold=N`; longer holds `hold` / `release`;
  - a run of taps of one key (dialog mashing) becomes
    `mash KEY until text "<what the mashing led to>" every=<median gap>`;
  - the gap before an action becomes `until text "<line that appeared>"` plus
    the human's reaction time when a readable new line of text appeared
    during it, else `wait N`: so another emulator reaching that screen on a
    different frame still gets its input at the right moment;
  - a checkpoint marks each new screen, at most one per 300 frames, and the end.

A state load or rewind in the session truncates the replay there (the frame
timeline no longer matches). Always verify the result with
`playtest.py run ROM --script FILE --no-cross`, and tidy by hand.
"""
import hashlib
import json
import os
import re
import statistics
import sys

import emu as emulib
import screen

POLL = 5
GUARD_LETTERS = 6  # a guard's text needs at least this many letters
STABLE = 15     # frames a guard's text must read the same before the input
MASH_GAP = 90      # taps of one key closer than this form a mash run
MASH_MIN = 3


def parse_log(path, session=-1):
    sessions = []
    cur = None
    for raw in open(path):
        line = raw.strip()
        if line.startswith('session'):
            cur = {'rom': None, 'bios': {}, 'events': [], 'desync': None, 'end': None,
                   'rtc': None, 'hashes': {}, 'marks': []}
            sessions.append(cur)
        elif cur is None or not line or line.startswith('#'):
            continue
        elif line.startswith('rtc '):
            cur['rtc'] = int(line.split()[1])
        elif line.startswith('hash '):
            _, frame, h = line.split()
            cur['hashes'][int(frame)] = h.upper().rjust(16, '0')
        elif line.startswith('mark '):
            if cur['desync'] is None:
                cur['marks'].append(int(line.split()[1]))
        elif line.startswith('rom '):
            cur['rom'] = line[4:]
        elif line.startswith('bios '):
            cur['bios'] = dict(kv.split('=') for kv in line[5:].split())
        elif line.startswith('desync'):
            _, frame, what = line.split(None, 2)
            if cur['desync'] is None:
                cur['desync'] = (int(frame), what)
        elif line.startswith('end'):
            cur['end'] = int(line.split()[1])
        else:
            frame, mask = line.split()
            if cur['desync'] is None:
                cur['events'].append((int(frame), int(mask)))
    sessions = [s for s in sessions if s['events']]
    if not sessions:
        raise SystemExit(f'{path}: no recorded input')
    s = sessions[session]
    if s['desync']:
        s['end'] = s['desync'][0]
    return s


def keys_of(mask):
    return '+'.join(k for i, k in enumerate(emulib.KEYS) if mask >> i & 1)


def actions_of(events):
    """Keypad changes -> taps (one key down then all up within 60 frames)
    and raw holds."""
    out = []
    k = 0
    prev = 0
    while k < len(events):
        frame, mask = events[k]
        if (prev == 0 and mask and k + 1 < len(events) and events[k + 1][1] == 0
                and events[k + 1][0] - frame <= 60):
            out.append({'kind': 'tap', 'keys': keys_of(mask), 'frame': frame, 'hold': events[k + 1][0] - frame})
            prev = 0
            k += 2
            continue
        out.append({'kind': 'hold', 'keys': keys_of(mask), 'frame': frame})
        prev = mask
        k += 1
    # fold runs of taps of one key into mash actions
    folded = []
    i = 0
    while i < len(out):
        j = i
        while (j + 1 < len(out) and out[i]['kind'] == 'tap' and out[j + 1]['kind'] == 'tap'
               and out[j + 1]['keys'] == out[i]['keys'] and out[j + 1]['frame'] - out[j]['frame'] <= MASH_GAP):
            # a pause well beyond the run's rhythm is the player reading a
            # new screen: end the run there
            if j > i and out[j + 1]['frame'] - out[j]['frame'] > 2 * (out[j]['frame'] - out[j - 1]['frame']) + 10:
                break
            j += 1
        if j - i + 1 >= MASH_MIN:
            gaps = [out[n + 1]['frame'] - out[n]['frame'] for n in range(i, j)]
            folded.append({'kind': 'mash', 'keys': out[i]['keys'], 'frame': out[i]['frame'],
                           'last': out[j]['frame'], 'every': int(statistics.median(gaps)),
                           'hold': out[i]['hold'], 'taps': j - i + 1})
            i = j + 1
        else:
            folded.append(out[i])
            i += 1
    return folded


def readable(lines):
    return {screen.normalize(l['text']): l['text'] for l in lines
            if l.get('conf', 0) >= 0.9 and len(re.sub(r'[^A-Za-z]', '', l['text'])) >= 4}


class Desync(Exception):
    """The headless replay's framebuffer no longer matches the recording."""


class Replay:
    """Runs the recording in dingbat, keeping the readable text of every poll."""

    def __init__(self, sess, rom, workdir, save, rtc):
        bios = sess['bios']
        self.name = 'dingbat' if bios.get('use_hle', 'true') == 'true' else 'dingbat-bios'
        extra = ['--run-bios'] if bios.get('run_bios') == 'true' and self.name == 'dingbat-bios' else []
        os.makedirs(workdir, exist_ok=True)
        self.e = emulib.Emulator(self.name, rom, os.path.join(workdir, 'env'), rtc_epoch=rtc,
                                 save_in=save, extra_args=extra)
        self.reader = screen.ScreenReader()
        self.probe = os.path.join(workdir, 'probe.ppm')
        self.polls = []   # (frame, {norm: text})
        self.hashes = sess['hashes']
        self.total = sess['end'] or sess['events'][-1][0]
        self.poll()

    @classmethod
    def cached(cls, sess, data):
        rp = cls.__new__(cls)
        rp.name = data['name']
        rp.polls = [(f, t) for f, t in data['polls']]
        rp.hashes = sess['hashes']
        return rp

    def poll(self):
        h = self.e.hash()
        self.e.shot(self.probe)
        self.polls.append((self.e.frame, readable(self.reader.ocr(self.probe, key=h))))

    def run_to(self, frame):
        while self.e.frame < frame:
            if self.e.frame // 600 != (self.e.frame + POLL) // 600:
                print(f'\rreplaying frame {self.e.frame} of {self.total}', end='', file=sys.stderr, flush=True)
            step = min(POLL, frame - self.e.frame)
            upcoming = [f for f in self.hashes if self.e.frame < f <= self.e.frame + step]
            if upcoming:
                step = min(upcoming) - self.e.frame
            self.e.run(step)
            self.poll()
            want = self.hashes.get(self.e.frame)
            if want is not None and self.e.hash().upper() != want:
                raise Desync(self.e.frame)

    def text_at(self, frame):
        best = self.polls[0][1]
        for f, t in self.polls:
            if f > frame:
                break
            best = t
        return best

    def guard(self, since, until, after=None):
        """A line readable at `until`, not on screen at `since` (not even as
        an OCR variant), continuously present from its first poll after
        `since` (and after `after`, for a mash's last tap): (text, first
        frame) or None."""
        before = self.text_at(since)
        now = self.text_at(until)
        best = None
        for norm, text in now.items():
            if norm in before:
                continue
            first = until
            for f, t in reversed(self.polls):
                if f > until:
                    continue
                if f <= since or norm not in t:
                    break
                first = f
            if after is not None and first <= after:
                continue
            # text still being typed out or scrolling reads differently on
            # every frame: only a line that has sat still for a while is a guard
            if until - first < STABLE:
                continue
            # a short word misreads easily ("Plain" / "Plamn")
            if len(re.sub(r'[^A-Za-z]', '', text)) < GUARD_LETTERS:
                continue
            # a blinking cursor or scrolling text makes OCR read one line
            # several ways: a "new" line that resembles one seen between
            # `since` and its first appearance is noise, not a new screen
            seen = set(before)
            for f, t in self.polls:
                if since <= f < first:
                    seen.update(t)
            if any(similar(norm, o) for o in seen):
                continue
            cand = (len(text), text, first)
            if best is None or cand > best:
                best = cand
        return (best[1], best[2]) if best else None

    def close(self):
        self.e.kill()
        self.reader.close()


def convert(log_path, rom, section, workdir, save=None, rtc=None):
    sess = parse_log(log_path)
    acts = actions_of(sess['events'])
    # F9 marks become checkpoints, placed after any mash run they fall inside
    for m in sess['marks']:
        k = 0
        while k < len(acts) and acts[k]['frame'] < m:
            k += 1
        prev = acts[k - 1] if k else None
        if prev and prev['kind'] == 'mash' and prev['last'] + prev['hold'] >= m:
            m = prev['last'] + prev['hold']
        acts.insert(k, {'kind': 'mark', 'frame': m})
    if sess['rtc'] is not None:
        rtc = sess['rtc']
    ends = [a['frame'] + a['hold'] if a['kind'] == 'tap'
            else a['last'] + a['hold'] if a['kind'] == 'mash' else a['frame'] for a in acts]
    final = sess['end'] if sess['end'] else sess['events'][-1][0] + 120
    # pass 1 (OCR of every few frames) is slow: cache it beside the recording
    cache = os.path.join(workdir, 'polls.json')
    key = hashlib.sha1(open(log_path, 'rb').read()
                       + repr((POLL, rtc, save and open(save, 'rb').read())).encode()).hexdigest()
    cached = json.load(open(cache)) if os.path.exists(cache) else {}
    if cached.get('key') == key:
        rp = Replay.cached(sess, cached)
        desync = cached['desync']
    else:
        rp = Replay(sess, rom, workdir, save, rtc)
        e = rp.e
        # pass 1: replay the recorded keypad changes exactly, sampling the
        # screen and checking the recording's hashes
        desync = None
        try:
            for frame, mask in sess['events']:
                rp.run_to(frame)
                e.set_keys(mask)
                rp.poll()
            rp.run_to(final)
        except Desync as d:
            desync = d.args[0]
        print(file=sys.stderr)
        rp.close()
        json.dump({'key': key, 'desync': desync, 'name': rp.name,
                   'polls': [[f, t] for f, t in rp.polls]}, open(cache, 'w'))
    if desync is not None:
        # keep only the actions that finished before the replay diverged
        keep = [i for i, end in enumerate(ends) if end <= desync]
        acts = [acts[i] for i in keep]
        ends = [ends[i] for i in keep]
        final = desync

    head = [f"# converted from {os.path.basename(log_path)}: {len(sess['events'])} keypad changes, "
            f"{len(acts)} actions, replayed in {rp.name}"
            + (f", {len(sess['hashes'])} sync hashes checked" if sess['hashes'] else ''), f'[{section}]']
    if sess['desync']:
        head.append(f"# NOTE: truncated at frame {sess['desync'][0]} ({sess['desync'][1]})")
    if desync is not None:
        head.append(f'# NOTE: the headless replay diverged from the recording at frame {desync}; '
                    f'steps stop there (check BIOS mode / settings of the recording app)')
    if not acts:
        return '\n'.join(head) + '\n'

    # pass 2: steps, then replay them in dingbat; a guard that makes an input
    # land away from its recorded frame (or fail) is replaced by a literal wait
    literal = set()
    for attempt in range(1, len(acts) + 3):
        steps = emit(sess, acts, ends, final, rp, literal)
        print(f'verifying generated steps (attempt {attempt}, {len(literal)} literal)', file=sys.stderr)
        # dingbat must replay it on time; mGBA (usually frame-identical, a
        # separate implementation) catches guards that only dingbat's pixels read
        bad = None
        for name in (rp.name, 'mgba'):
            bad = verify(steps, name, rom, os.path.join(workdir, 'verify-' + name), save, rtc)
            if bad is not None:
                print(f'  {name}: guard of action {bad} misplaced an input', file=sys.stderr)
                break
        if bad is None:
            break
        literal.add(bad)
    else:
        head.append('# NOTE: the generated steps never replayed cleanly in dingbat')
    lines = head + [t for t, _ in steps if t]
    if literal:
        lines.insert(len(head), f'# {len(literal)} OCR guard(s) dropped for literal waits after a verification replay')
    return '\n'.join(lines) + '\n'


TOLERANCE = 12   # frames an input may land from its recorded frame (guards poll every 5)


def emit(sess, acts, ends, final, rp, literal):
    """-> [(line, meta)]; meta: 'owner' = the action index whose guard this
    line is (for blame), 'expect' = the recorded frame of this input."""
    out = []
    state = {'last_cp': -10 ** 9, 'cp_n': 0}

    def add(line, **meta):
        out.append((line, meta))

    def checkpoint(label, frame):
        if frame - state['last_cp'] >= 300:
            state['cp_n'] += 1
            slug = re.sub(r'[^a-z0-9]+', '_', label.lower()).strip('_')[:24] or 'screen'
            add(f"checkpoint {state['cp_n']:02}_{slug}")
            state['last_cp'] = frame

    def literal_taps(m, upto):
        taps = [ev[0] for ev in sess['events'] if m['frame'] <= ev[0] <= m['last'] and ev[1]]
        for t0, t1 in zip(taps, taps[1:] + [upto]):
            add(f"press {m['keys']} hold={m['hold']}", expect=t0)
            if t1 - t0 - m['hold'] > 0:
                add(f"wait {t1 - t0 - m['hold']}")

    prev_end = 0
    pending = None   # index of a mash waiting for its goal
    for idx, a in enumerate(acts + [{'kind': 'end', 'frame': final}]):
        if pending is not None:
            m = acts[pending]
            # a mash's goal is text that was not there when the mashing began
            # and first appeared after its last tap
            g = None if pending in literal else rp.guard(m['frame'], a['frame'], after=m['last'])
            if g:
                text, first = g
                add(f"mash {m['keys']} until text {quote(text)} "
                    f"timeout={max(1200, 3 * (a['frame'] - m['frame']))} every={m['every']} hold={m['hold']}",
                    owner=pending, expect=m['frame'])
                if a['frame'] - first > 0:
                    add(f"wait {a['frame'] - first}")
            else:
                literal_taps(m, a['frame'])
            pending = None
        else:
            g = None if idx in literal else rp.guard(prev_end, a['frame'])
            if g and a['frame'] - prev_end >= POLL:
                text, first = g
                add(f"until text {quote(text)} timeout={max(600, 3 * (first - prev_end))} every={POLL}", owner=idx)
                checkpoint(text, first)
                if a['frame'] - first > 0:
                    add(f"wait {a['frame'] - first}")
            elif a['frame'] > prev_end:
                add(f"wait {a['frame'] - prev_end}")

        if a['kind'] == 'mark':
            state['cp_n'] += 1
            add(f"checkpoint {state['cp_n']:02}_mark")
            state['last_cp'] = a['frame']
        elif a['kind'] == 'tap':
            add(f"press {a['keys']} hold={a['hold']}", expect=a['frame'])
        elif a['kind'] == 'hold':
            add(f"hold {a['keys']}" if a['keys'] else 'release', expect=a['frame'])
        elif a['kind'] == 'mash':
            pending = idx
        else:
            add('', expect=final)   # end of the recording
        if a['kind'] != 'end':
            prev_end = ends[idx]
    state['last_cp'] = -10 ** 9
    checkpoint('end', final)
    return out


def verify(steps, name, rom, workdir, save, rtc):
    """Replay the generated steps in dingbat (checkpoints skipped). Returns the
    action index whose guard is to blame for the first input that lands more
    than TOLERANCE frames from its recording, or for a failed step; None when
    every input lands on time."""
    import runner
    import script
    if os.path.isdir(workdir):
        import shutil
        shutil.rmtree(workdir)
    e = emulib.Emulator(name, rom, os.path.join(workdir, 'env'), rtc_epoch=rtc, save_in=save)
    reader = screen.ScreenReader()
    ex = runner.Executor(e, os.path.join(workdir, 'shots'), reader, log=lambda *a, **k: None)
    owner = None
    try:
        for line, meta in steps:
            if 'expect' in meta and meta.get('owner') is None and abs(e.frame - meta['expect']) > TOLERANCE:
                return owner
            if 'owner' in meta:
                owner = meta['owner']
                if abs(e.frame - meta.get('expect', e.frame)) > TOLERANCE:
                    return owner
            if not line or line.startswith('checkpoint') or line.startswith('#'):
                continue
            try:
                ex.do(script.parse_step(line))
            except runner.StepFailed:
                return meta.get('owner', owner)
        return None
    finally:
        e.kill()
        reader.close()


def similar(a, b):
    import difflib
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.75


def quote(s):
    return '"' + s.replace('"', "'") + '"'
