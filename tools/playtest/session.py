"""Live exploration session: keeps emulators running between commands so a
route through a game can be discovered one step at a time, and records every
step that succeeded on all of them as a replayable script.

  playtest.py serve NAME --rom ROM [--emus dingbat,mgba,nba] [--save FILE]
  playtest.py do NAME 'press A' 'until text "NEW GAME"' look
  playtest.py do NAME 'mark title'     ... 'rewind title'
  playtest.py do NAME log              print the recorded script
  playtest.py do NAME stop

Besides script steps, `do` understands:
  look            composite PNG of every emulator + OCR text + selection
  mark NAME       save state on every emulator (and the script position)
  rewind NAME     restore that mark; the recorded script is truncated to it
  section NAME    start recording into [new] or [load]
  undo            drop the last recorded step (does not rewind emulators)
"""
import concurrent.futures as cf
import hashlib
import json
import os
import shutil
import threading
import traceback
from multiprocessing.connection import Client, Listener

import emu as emulib
import img
import runner
import screen
import script

AUTH = b'dingbat-playtest'


def sock_path(outroot, name):
    # AF_UNIX paths are limited to ~104 bytes, so the socket lives in /tmp
    # under a short hash of (output root, session name)
    tag = hashlib.sha1(f'{os.path.abspath(outroot)}|{name}'.encode()).hexdigest()[:12]
    return f'/tmp/playtest-{tag}.sock'


def _legacy_sock_path(outroot, name):
    return os.path.join(outroot, 'sessions', name + '.sock')


def _live(path):
    try:
        with Client(path, family='AF_UNIX', authkey=AUTH) as conn:
            conn.send([])
            conn.recv()
        return True
    except (OSError, EOFError):
        return False


AUTHORING = ['dingbat-bios', 'mgba', 'nba']   # the official-BIOS emulators
SLACK = 4      # frames past the slowest emulator before the next input


class Session:
    def __init__(self, name, rom, emus, outroot, save=None, rtc=None, lockstep=True):
        """`save`: one battery file for every emulator, or {emu: file} so
        each [load] boots the save that emulator wrote itself. With
        `lockstep`, every `until` / `mash` ends with all emulators on the same
        frame after the same inputs, and is recorded as a frozen `wait` /
        `tap` (see script.py)."""
        self.name = name
        self.dir = os.path.join(outroot, 'sessions', name)
        os.makedirs(self.dir, exist_ok=True)
        self.reader = screen.ScreenReader()
        self.execs = {}
        self.lockstep = lockstep
        for n in emus:
            seed = save.get(n) if isinstance(save, dict) else save
            e = emulib.Emulator(n, rom, os.path.join(self.dir, 'env', n), rtc_epoch=rtc, save_in=seed)
            self.execs[n] = runner.Executor(e, os.path.join(self.dir, 'shots', n), self.reader)
        self.section = 'load' if save else 'new'
        self.recorded = []            # (section, line)
        self.marks = {}
        self.looks = 0
        self.lock = threading.Lock()

    def each(self, fn):
        with cf.ThreadPoolExecutor(len(self.execs)) as pool:
            futs = {n: pool.submit(fn, ex) for n, ex in self.execs.items()}
            out = {}
            for n, f in futs.items():
                try:
                    out[n] = ('ok', f.result())
                except Exception as e:  # report per emulator
                    out[n] = ('fail', str(e))
            return out

    def look(self):
        self.looks += 1
        tag = f'look{self.looks:03}'
        frames, labels, info = [], [], {}
        for n, ex in self.execs.items():
            p = os.path.join(ex.outdir, tag + '.ppm')
            ex.emu.shot(p)
            h = ex.emu.hash()
            r = self.reader.read(p, key=h)
            frames.append(img.read_ppm(p))
            labels.append(f'{n} f{ex.emu.frame}')
            info[n] = {'frame': ex.emu.frame, 'hash': h, 'selected': r['selected'],
                       'lines': [(l['text'], l['box']) for l in r['lines']]}
        png = os.path.join(self.dir, tag + '.png')
        hashes = {v['hash'] for v in info.values()}
        if len(hashes) == 1:
            # every emulator shows the same frame: one copy is enough
            img.write_png(png, img.composite(frames[:1], ['all identical ' + labels[0].split()[-1]], scale=2))
        else:
            img.write_png(png, img.composite(frames, labels, scale=2))
        return {'png': png, 'identical': len(hashes) == 1, 'emus': info}

    def command(self, line):
        words = line.split()
        op = words[0] if words else ''
        if op == 'look':
            return self.look()
        if op == 'log':
            return {'script': self.render()}
        if op == 'section':
            self.section = words[1]
            return {'section': self.section}
        if op == 'undo':
            return {'dropped': self.recorded.pop() if self.recorded else None}
        if op == 'mark':
            label = words[1]
            res = self.each(lambda ex: ex.emu.state_save(os.path.join(self.dir, f'mark-{label}-{ex.emu.name}.state')))
            self.marks[label] = (len(self.recorded), self.section, {n: ex.emu.frame for n, ex in self.execs.items()})
            return {'mark': label, 'results': res}
        if op == 'rewind':
            label = words[1]
            pos, section, frames = self.marks[label]

            def restore(ex):
                ex.emu.state_load(os.path.join(self.dir, f'mark-{label}-{ex.emu.name}.state'))
                ex.emu.frame = frames[ex.emu.name]
                ex.emu.set_keys(0)
            res = self.each(restore)
            del self.recorded[pos:]
            self.section = section
            return {'rewound': label, 'results': res}
        step = script.parse_step(line)
        # snapshot first so a step that fails anywhere can be undone everywhere:
        # the recorded script then always reproduces the emulators' state
        before = {n: ex.emu.frame for n, ex in self.execs.items()}
        self.each(lambda ex: ex.emu.state_save(os.path.join(self.dir, f'undo-{ex.emu.name}.state')))
        res = self.each(lambda ex: ex.do(step))
        ok = all(r[0] == 'ok' for r in res.values())
        reply = {'step': script.format_step(step), 'recorded': ok,
                 'results': {n: (r[0], r[1] if r[0] == 'fail' else None, self.execs[n].emu.frame)
                             for n, r in res.items()}}
        if ok:
            recorded = script.format_step(step)
            if self.lockstep and step['op'] in ('until', 'mash'):
                recorded, warn = self.freeze(step)
                if warn:
                    reply['warning'] = warn
                reply['results'] = {n: ('ok', None, ex.emu.frame) for n, ex in self.execs.items()}
            reply['frozen'] = recorded
            self.recorded.append((self.section, recorded))
        else:
            # keep a look at the failure, then roll every emulator back
            reply['failed_look'] = self.look()['png']

            def undo(ex):
                ex.emu.state_load(os.path.join(self.dir, f'undo-{ex.emu.name}.state'))
                ex.emu.frame = before[ex.emu.name]
                ex.emu.set_keys(0)
            bad = {n: r[1] for n, r in self.each(undo).items() if r[0] != 'ok'}
            if bad:
                # an emulator that could not roll back is on another timeline now
                reply['rollback_failed'] = bad
        return reply

    def freeze(self, step):
        """Brings every emulator to where the slowest one got, by giving the
        faster ones the same inputs it had (more frames held, more taps), and
        returns the step as a pure input timeline plus the condition as a
        comment with each emulator's own count."""
        execs = self.execs
        cond = script.format_step(step)
        if step['op'] == 'until':
            spent = {n: ex.spent for n, ex in execs.items()}
            target = max(spent.values()) + SLACK
            self.each(lambda ex: ex.emu.run(target - ex.spent))
            note = ' '.join(f'{n}+{f}' for n, f in spent.items())
            return f'# {cond}  [reached {note}]\nwait {target}', None
        taps = {n: ex.taps for n, ex in execs.items()}
        most = max(taps.values())

        def more(ex):
            for _ in range(most - ex.taps):
                ex.tap(step['keys'], step['hold'], step['every'])
        self.each(more)
        note = ' '.join(f'{n}:{t}' for n, t in taps.items())
        line = f'# {cond}  [taps {note}]'
        if most:
            line += f"\ntap {'+'.join(step['keys'])} times={most} every={step['every']} hold={step['hold']}"
        warn = None
        if step['cond']['kind'] != 'stable':
            # the extra taps may have carried a faster emulator past the screen
            lost = [n for n, ex in execs.items() if taps[n] < most and not ex.check(step['cond'], {})]
            if lost:
                warn = (f'after the extra taps (to match the slowest emulator) {", ".join(lost)} no longer '
                        f'satisfies the condition: tap less often (every=), or wait for a screen instead')
        return line, warn

    def render(self):
        out = []
        for sec in script.SECTIONS:
            lines = [l for s, l in self.recorded if s == sec]
            if lines:
                out.append(f'[{sec}]')
                out.extend(lines)
                out.append('')
        return '\n'.join(out)

    def close(self):
        """Quit every emulator the way a user would (flushing its battery
        file); keep a copy of each save and the recorded script."""
        saves = os.path.join(self.dir, 'saves')
        os.makedirs(saves, exist_ok=True)
        for n, ex in self.execs.items():
            path = ex.emu.quit()
            if os.path.exists(path):
                shutil.copyfile(path, os.path.join(saves, n + '.sav'))
        with open(os.path.join(self.dir, 'recorded.play'), 'w') as f:
            f.write(self.render())
        self.reader.close()


def serve(name, rom, emus, outroot, save=None, rtc=None, lockstep=True):
    path = sock_path(outroot, name)
    if os.path.exists(path):
        if _live(path):
            raise SystemExit(f'session {name!r} is already running; pick another name or stop it')
        os.unlink(path)
    sess = Session(name, rom, emus, outroot, save=save, rtc=rtc, lockstep=lockstep)
    print(f'session {name} ready: {path}', flush=True)
    with Listener(path, family='AF_UNIX', authkey=AUTH) as listener:
        while True:
            conn = listener.accept()
            try:
                lines = conn.recv()
                replies = []
                stop = False
                for line in lines:
                    if line.strip() == 'stop':
                        stop = True
                        replies.append({'stopped': True, 'script': sess.render()})
                        break
                    try:
                        r = sess.command(line)
                    except Exception as e:
                        r = {'error': f'{type(e).__name__}: {e}', 'trace': traceback.format_exc()[-800:]}
                    replies.append(r)
                    # stop a batch at the first step that failed anywhere
                    if 'error' in r or r.get('recorded') is False:
                        break
                conn.send(replies)
            finally:
                conn.close()
            if stop:
                break
    sess.close()
    if os.path.exists(path):
        os.unlink(path)


def send(name, lines, outroot):
    path = sock_path(outroot, name)
    if not os.path.exists(path) and os.path.exists(_legacy_sock_path(outroot, name)):
        path = _legacy_sock_path(outroot, name)
    with Client(path, family='AF_UNIX', authkey=AUTH) as conn:
        conn.send(list(lines))
        return conn.recv()
