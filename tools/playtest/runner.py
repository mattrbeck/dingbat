"""Executes play-script steps on one Emulator (see script.py)."""
import os
import time

import img
import screen


class StepFailed(RuntimeError):
    def __init__(self, step, message, frame):
        super().__init__(message)
        self.step = step
        self.frame = frame


class Executor:
    def __init__(self, emu, outdir, reader, log=None):
        self.emu = emu
        self.outdir = outdir
        self.reader = reader
        self.log = log or (lambda msg: None)
        self.checkpoints = {}
        self.steps_done = 0
        os.makedirs(outdir, exist_ok=True)
        self._probe = os.path.join(outdir, '.probe.ppm')

    # -------------------------------------------------------------- screen
    def screen_lines(self):
        h = self.emu.hash()
        self.emu.shot(self._probe)
        return self.reader.ocr(self._probe, key=h)

    def check(self, cond, state):
        kind = cond['kind']
        if kind in ('text', 'notext'):
            found = screen.contains_text(self.screen_lines(), cond['arg'])
            return found if kind == 'text' else not found
        if kind == 'selected':
            h = self.emu.hash()
            self.emu.shot(self._probe)
            sel = self.reader.read(self._probe, key=h)['selected']
            return sel is not None and screen.normalize(cond['arg']) in screen.normalize(sel)
        if kind == 'changed':
            return self.emu.hash() != state.setdefault('start', self.emu.hash())
        if kind in ('blank', 'notblank'):
            self.emu.shot(self._probe)
            b = img.is_blank(img.read_ppm(self._probe))
            return b if kind == 'blank' else not b
        raise ValueError(kind)

    def run_until(self, step, cond, before_poll=None):
        """Poll `cond` every `every` frames; `before_poll` runs the input
        pattern between polls (mash). Returns frames spent."""
        start = self.emu.frame
        state = {}
        if cond['kind'] == 'changed':
            state['start'] = self.emu.hash()
        if cond['kind'] == 'stable' and before_poll:
            # mash until stable: the screen must stop changing for N frames
            # across the input pattern
            need, last, since = cond['arg'], self.emu.hash(), self.emu.frame
            while self.emu.frame - start < step['timeout']:
                before_poll()
                h = self.emu.hash()
                if h != last:
                    last, since = h, self.emu.frame
                elif self.emu.frame - since >= need:
                    return self.emu.frame - start
            raise StepFailed(step, f"screen never stable for {need} frames", self.emu.frame)
        if cond['kind'] == 'stable':
            need, last, streak = cond['arg'], None, 0
            while self.emu.frame - start < step['timeout']:
                for h in self.emu.runhash(min(need, step['timeout'])):
                    streak = streak + 1 if h == last else 1
                    last = h
                    if streak >= need:
                        return self.emu.frame - start
            raise StepFailed(step, f"screen never stable for {need} frames", self.emu.frame)
        if self.check(cond, state):
            return 0
        while self.emu.frame - start < step['timeout']:
            if before_poll:
                before_poll()
            else:
                self.emu.run(step['every'])
            if self.check(cond, state):
                return self.emu.frame - start
        raise StepFailed(step, f"timed out after {step['timeout']} frames waiting for "
                               f"{cond['kind']} {cond.get('arg', '')!r}".rstrip(), self.emu.frame)

    # --------------------------------------------------------------- steps
    def do(self, step):
        e = self.emu
        op = step['op']
        if op == 'wait':
            e.run(step['frames'])
        elif op == 'press':
            base = e.held
            e.set_keys(base | _mask(step['keys']))
            e.run(step['hold'])
            e.set_keys(base)
            e.run(step['after'])
        elif op == 'hold':
            e.set_keys(_mask(step['keys']))
        elif op == 'until':
            self.run_until(step, step['cond'])
        elif op == 'mash':
            def tap():
                base = e.held
                e.set_keys(base | _mask(step['keys']))
                e.run(step['hold'])
                e.set_keys(base)
                e.run(max(0, step['every'] - step['hold']))
            self.run_until(step, step['cond'], before_poll=tap)
        elif op == 'checkpoint':
            self.checkpoint(step['name'], step['window'])
        else:
            raise ValueError(op)
        self.steps_done += 1

    def checkpoint(self, name, window):
        before = self.emu.runhash(window) if window else []
        path = os.path.join(self.outdir, f'{name}.ppm')
        center_hash = self.emu.hash()
        frame = self.emu.frame
        self.emu.shot(path)
        after = self.emu.runhash(window) if window else []
        read = self.reader.read(path, key=center_hash)
        img.write_png(os.path.join(self.outdir, f'{name}.png'), img.read_ppm(path))
        # runhash's last hash is the current frame: hashes[center] is the
        # checkpoint frame, neighbours are one frame apart
        hashes = (before or [center_hash]) + after
        cp = {'name': name, 'frame': frame, 'hash': center_hash, 'ppm': path,
              'hashes': hashes, 'center': len(before or [center_hash]) - 1,
              'text': read['text'], 'selected': read['selected']}
        self.checkpoints[name] = cp
        self.log(f"{self.emu.name}: checkpoint {name} @f{frame} text={read['text'][:80]!r}")
        return cp

    def run_steps(self, steps):
        t0 = time.time()
        for step in steps:
            self.do(step)
        return time.time() - t0


def _mask(keys):
    from emu import key_mask
    return key_mask(keys)
