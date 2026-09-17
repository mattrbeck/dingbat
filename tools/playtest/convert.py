"""Turn a human play session into a script section.

Record in the desktop app (the log is appended to; each ROM load starts a
session, quitting writes its end frame):
    DINGBAT_INPUT_LOG=~/rec/emerald-new.log ./dingbat game.gba
Convert:
    playtest.py convert ~/rec/emerald-new.log --rom game.gba --section new

The log holds "<frame> <mask>" keypad changes, a framebuffer hash every 60
frames, F9 marks and the end frame. The script replays the inputs on exactly
the frames they were pressed: every emulator gets the same input timeline, so
a screen that differs at a checkpoint is a real difference (an emulator that
reaches a screen late is a timing finding, not something to wait out).

  - a lone tap becomes `press KEY hold=N`; anything else `hold` / `release`;
  - the gaps become `wait N`;
  - checkpoints: every F9 mark, one a minute into any unmarked stretch, and
    the end.

Before writing, the last session is replayed headless in dingbat and every
recorded hash is checked, so the script reproduces what the player saw; a
replay that diverges (other BIOS mode or settings in the app, a state load or
rewind) stops the script at the last matching hash with a note.
"""
import os
import sys
import time

import emu as emulib

AUTO_CHECKPOINT = 3600   # frames without a mark before an automatic checkpoint


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


def replay(sess, rom, workdir, save, rtc, end):
    """Replays the inputs headless in dingbat, checking every recorded hash.
    Returns the first frame whose hash differs, or None."""
    bios = sess['bios']
    name = 'dingbat' if bios.get('use_hle', 'true') == 'true' else 'dingbat-bios'
    extra = ['--run-bios'] if bios.get('run_bios') == 'true' and name == 'dingbat-bios' else []
    e = emulib.Emulator(name, rom, os.path.join(workdir, 'env'), rtc_epoch=rtc, save_in=save, extra_args=extra)
    stops = sorted(set([f for f in sess['hashes'] if f <= end] + [f for f, _ in sess['events'] if f <= end] + [end]))
    masks = dict(sess['events'])
    t0 = time.time()
    try:
        for f in stops:
            e.run(f - e.frame)
            if f in sess['hashes'] and e.hash().upper() != sess['hashes'][f]:
                return f
            if f in masks:
                e.set_keys(masks[f])
            if f // 3000 != e.frame // 3000 or f == end:
                print(f'\rchecking replay: frame {f} of {end}', end='', file=sys.stderr, flush=True)
        return None
    finally:
        print(f'\rreplay checked to frame {e.frame} of {end} in {time.time() - t0:.0f}s', file=sys.stderr)
        e.kill()


def convert(log_path, rom, section, workdir, save=None, rtc=None):
    sess = parse_log(log_path)
    if sess['rtc'] is not None:
        rtc = sess['rtc']
    end = sess['end'] or sess['events'][-1][0] + 120
    diverged = replay(sess, rom, workdir, save, rtc, end)

    lines = [f"# converted from {os.path.basename(log_path)}: {len(sess['events'])} keypad changes, "
             f"{len(sess['hashes'])} sync hashes checked in dingbat", f'[{section}]']
    if sess['desync']:
        lines.append(f"# NOTE: truncated at frame {sess['desync'][0]} ({sess['desync'][1]})")
    if diverged is not None:
        # the last hash that matched bounds what the script can trust
        end = max([f for f in sess['hashes'] if f < diverged], default=0)
        lines.append(f'# NOTE: the headless replay diverged from the recording by frame {diverged}; '
                     f'steps stop at frame {end} (check BIOS mode / settings of the recording app)')

    events = [ev for ev in sess['events'] if ev[0] < end]
    # timeline of (frame, step, frame the step finishes)
    items = []
    k = 0
    while k < len(events):
        frame, mask = events[k]
        prev = events[k - 1][1] if k else 0
        if (prev == 0 and mask and k + 1 < len(events) and events[k + 1][1] == 0
                and events[k + 1][0] - frame <= 60):
            items.append((frame, f'press {keys_of(mask)} hold={events[k + 1][0] - frame}', events[k + 1][0]))
            k += 2
            continue
        items.append((frame, f'hold {keys_of(mask)}' if mask else 'release', frame))
        k += 1
    items += [(m, 'mark', m) for m in sess['marks'] if m < end]
    items.sort(key=lambda x: (x[0], x[1] != 'mark'))

    state = {'now': 0, 'last_cp': 0, 'n': 0}

    def wait_to(frame):
        if frame > state['now']:
            lines.append(f"wait {frame - state['now']}")
            state['now'] = frame

    def checkpoint(label):
        state['n'] += 1
        lines.append(f"checkpoint {state['n']:02}_{label}")
        state['last_cp'] = state['now']

    def advance(to):
        while True:
            at = max(state['last_cp'] + AUTO_CHECKPOINT, state['now'])
            if at >= to:
                break
            wait_to(at)
            checkpoint(f'f{at}')
        wait_to(to)

    for frame, step, done in items:
        # a mark during a press is taken when the press ends
        advance(max(frame, state['now']))
        if step == 'mark':
            checkpoint('mark')
        else:
            lines.append(step)
            state['now'] = done
    advance(end)
    checkpoint('end')
    return '\n'.join(lines) + '\n'
