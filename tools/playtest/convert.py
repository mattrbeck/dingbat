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
import os
import re
import statistics
import sys

import emu as emulib
import screen

POLL = 5
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

    def guard(self, since, until):
        """A line readable at `until`, absent at `since`, continuously present
        from its first poll after `since`: (text, first frame) or None."""
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
    rp = Replay(sess, rom, workdir, save, rtc)
    e = rp.e
    # pass 1: replay, sampling the screen and checking the recording's hashes
    # the recorded keypad changes, replayed exactly (actions only shape the text)
    ends = [a['frame'] + a['hold'] if a['kind'] == 'tap'
            else a['last'] + a['hold'] if a['kind'] == 'mash' else a['frame'] for a in acts]
    desync = None
    final = sess['end'] if sess['end'] else sess['events'][-1][0] + 120
    try:
        for frame, mask in sess['events']:
            rp.run_to(frame)
            e.set_keys(mask)
            rp.poll()
        rp.run_to(final)
    except Desync as d:
        # keep only the actions that finished before the replay diverged
        desync = d.args[0]
        keep = [i for i, end in enumerate(ends) if end <= desync]
        acts = [acts[i] for i in keep]
        ends = [ends[i] for i in keep]
        final = desync
    print(file=sys.stderr)

    # pass 2: steps
    lines = [f"# converted from {os.path.basename(log_path)}: {len(sess['events'])} keypad changes, "
             f"{len(acts)} actions, replayed in {rp.name}"
             + (f", {len(sess['hashes'])} sync hashes checked" if sess['hashes'] else ''), f'[{section}]']
    if sess['desync']:
        lines.append(f"# NOTE: truncated at frame {sess['desync'][0]} ({sess['desync'][1]})")
    if desync is not None:
        lines.append(f'# NOTE: the headless replay diverged from the recording at frame {desync}; '
                     f'steps stop there (check BIOS mode / settings of the recording app)')
    if not acts:
        rp.close()
        return '\n'.join(lines) + '\n'
    prev_end = 0
    last_cp = -10 ** 9
    cp_n = 0

    def checkpoint(label, frame):
        nonlocal last_cp, cp_n
        if frame - last_cp >= 300:
            cp_n += 1
            slug = re.sub(r'[^a-z0-9]+', '_', label.lower()).strip('_')[:24] or 'screen'
            lines.append(f'checkpoint {cp_n:02}_{slug}')
            last_cp = frame

    for idx, a in enumerate(acts):
        pending_mash = lines and lines[-1].startswith('@mash ')
        # a mash's goal is text that was not there when the mashing began
        g = rp.guard(acts[idx - 1]['frame'] if pending_mash else prev_end, a['frame'])
        if pending_mash:
            key, every, hold = lines.pop()[6:].split()
            if g:
                text, first = g
                lines.append(f'mash {key} until text {quote(text)} timeout={max(1200, 3 * (a["frame"] - acts[idx - 1]["frame"]))} every={every} hold={hold}')
                if a['frame'] - first > 0:
                    lines.append(f'wait {a["frame"] - first}')
            else:
                lines.append(f'# mash {key} run could not be guarded; replaying taps literally')
                m = acts[idx - 1]
                taps = [ev[0] for ev in sess['events'] if m['frame'] <= ev[0] <= m['last'] and ev[1]]
                for t0, t1 in zip(taps, taps[1:] + [a['frame']]):
                    lines.append(f'press {key} hold={hold}')
                    if t1 - t0 - int(hold) > 0:
                        lines.append(f'wait {t1 - t0 - int(hold)}')
        elif g and a['frame'] - prev_end >= POLL:
            text, first = g
            lines.append(f'until text {quote(text)} timeout={max(600, 3 * (first - prev_end))} every={POLL}')
            checkpoint(text, first)
            if a['frame'] - first > 0:
                lines.append(f'wait {a["frame"] - first}')
        elif a['frame'] > prev_end:
            lines.append(f'wait {a["frame"] - prev_end}')

        if a['kind'] == 'mark':
            cp_n += 1
            lines.append(f'checkpoint {cp_n:02}_mark')
            last_cp = a['frame']
        elif a['kind'] == 'tap':
            lines.append(f"press {a['keys']} hold={a['hold']}")
        elif a['kind'] == 'hold':
            lines.append(f"hold {a['keys']}" if a['keys'] else 'release')
        else:
            lines.append(f"@mash {a['keys']} {a['every']} {a['hold']}")
        prev_end = ends[idx]

    g = rp.guard(acts[-1]['frame'] if lines[-1].startswith('@mash ') else prev_end, final)
    if lines[-1].startswith('@mash '):
        key, every, hold = lines.pop()[6:].split()
        lines.append(f'mash {key} until text {quote(g[0])} every={every} hold={hold}' if g
                     else f'# trailing {key} mash could not be guarded')
    elif g:
        lines.append(f'until text {quote(g[0])} timeout={max(600, 3 * (g[1] - prev_end))} every={POLL}')
    elif final > prev_end:
        lines.append(f'wait {final - prev_end}')
    last_cp = -10 ** 9
    checkpoint('end', final)
    rp.close()
    return '\n'.join(lines) + '\n'


def quote(s):
    return '"' + s.replace('"', "'") + '"'
