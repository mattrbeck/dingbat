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
    d = os.path.join(outroot, 'sessions')
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, name + '.sock')


class Session:
    def __init__(self, name, rom, emus, outroot, save=None, rtc=None):
        self.name = name
        self.dir = os.path.join(outroot, 'sessions', name)
        os.makedirs(self.dir, exist_ok=True)
        self.reader = screen.ScreenReader()
        self.execs = {}
        for n in emus:
            e = emulib.Emulator(n, rom, os.path.join(self.dir, 'env', n), rtc_epoch=rtc, save_in=save)
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
        img.write_png(png, img.composite(frames, labels, scale=2))
        hashes = {v['hash'] for v in info.values()}
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
            self.recorded.append((self.section, script.format_step(step)))
        else:
            # keep a look at the failure, then roll every emulator back
            reply['failed_look'] = self.look()['png']

            def undo(ex):
                ex.emu.state_load(os.path.join(self.dir, f'undo-{ex.emu.name}.state'))
                ex.emu.frame = before[ex.emu.name]
                ex.emu.set_keys(0)
            self.each(undo)
        return reply

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


def serve(name, rom, emus, outroot, save=None, rtc=None):
    path = sock_path(outroot, name)
    if os.path.exists(path):
        os.unlink(path)
    sess = Session(name, rom, emus, outroot, save=save, rtc=rtc)
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
    with Client(sock_path(outroot, name), family='AF_UNIX', authkey=AUTH) as conn:
        conn.send(list(lines))
        return conn.recv()
