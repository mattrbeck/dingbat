"""`playtest.py freeze`: turn a condition script (until / mash, reading the
screen) into a frozen one (fixed input frames, see script.py) by playing it
in a lockstep session on the authoring emulators. [new] runs first; each
emulator's own save then seeds its [load].

The frozen script keeps the metadata, the checkpoints and, as comments, each
condition with the frames every emulator took to meet it.
"""
import os
import re
import shutil

import script
import session as sessionlib


class FreezeFailed(RuntimeError):
    pass


def _section_lines(text, section):
    """The raw step lines of one section, comments stripped."""
    out, cur = [], None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith('['):
            cur = line.strip('[]').strip()
            continue
        if cur != section or not line or line.startswith('#') or line.startswith('@'):
            continue
        out.append(_strip_comment(raw))
    return [l for l in out if l]


def _strip_comment(raw):
    """Drops a trailing comment, keeping '#' inside quotes."""
    q = False
    for i, ch in enumerate(raw):
        if ch == '"':
            q = not q
        elif ch == '#' and not q:
            return raw[:i].strip()
    return raw.strip()


def run_section(name, rom, lines, outroot, rtc, emus, save=None, log=print):
    sess = sessionlib.Session(name, rom, emus, outroot, save=save, rtc=rtc)
    try:
        for line in lines:
            r = sess.command(line)
            if not r.get('recorded', True):
                fails = {n: v[1] for n, v in r['results'].items() if v[0] != 'ok'}
                raise FreezeFailed(f'{line!r} failed on {fails} (screen: {r.get("failed_look")})')
            if r.get('warning'):
                log(f'   warning at {line!r}: {r["warning"]}')
        frames = {n: ex.emu.frame for n, ex in sess.execs.items()}
        log(f'   [{sess.section}] frozen: {len(lines)} steps, frame {frames}')
        return sess
    except Exception:
        sess.close()
        raise


def freeze(script_path, rom, outroot, rtc, emus=None, log=print):
    emus = emus or sessionlib.AUTHORING
    text = open(script_path).read()
    play = script.parse(text)
    tag = os.path.basename(script_path)[:12]
    out = [f'@{k} {v}' for k, v in play['meta'].items()]
    out.append(f'@frozen {",".join(emus)}')
    out.append('')
    # free-text comment lines before the first section are kept
    for raw in text.splitlines():
        if raw.strip().startswith('['):
            break
        if raw.strip().startswith('#'):
            out.append(raw)
    saves = {}
    for section in script.SECTIONS:
        lines = _section_lines(text, section)
        if not lines:
            continue
        seed = (saves or None) if section == 'load' else None
        if section == 'load' and not saves and play['meta'].get('save', '').strip() != 'none':
            raise FreezeFailed('no emulator wrote a save in [new]')
        sess = run_section(f'freeze-{tag}-{section}', rom, lines, outroot, rtc, emus, save=seed, log=log)
        out.append(f'[{section}]')
        out.extend(l for s, l in sess.recorded if s == section)
        out.append('')
        sess.close()
        if section == 'new':
            savedir = os.path.join(sess.dir, 'saves')
            for n in emus:
                p = os.path.join(savedir, n + '.sav')
                if os.path.exists(p) and os.path.getsize(p):
                    keep = os.path.join(outroot, 'sessions', f'freeze-{tag}-saves', n + '.sav')
                    os.makedirs(os.path.dirname(keep), exist_ok=True)
                    shutil.copyfile(p, keep)
                    saves[n] = keep
    return '\n'.join(out)


def is_frozen(text):
    return bool(re.search(r'^@frozen ', text, re.M))
