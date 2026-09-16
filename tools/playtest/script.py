"""Play-script language for the playtest harness.

A script lives at scripts/<rom sha1>.play. Lines starting with `@` are
metadata, `#` starts a comment, `[section]` opens a section. Sections:

  [new]    boot with no battery file and play until the game has saved;
           the harness then quits the emulator, which flushes the save
  [load]   boot with a battery file and play until the loaded game is on
           screen (checkpoints here prove the save was read)

Steps (keys: A B SELECT START RIGHT LEFT UP DOWN R L, combined with +):

  wait N                         run N frames
  press KEYS [hold=6] [after=0]  hold KEYS for `hold` frames, then run `after`
  hold KEYS / release            change held keys without running
  until COND [timeout=600] [every=4]
                                 run `every` frames at a time until COND holds;
                                 failing the timeout fails the run
  mash KEYS until COND [timeout=1200] [every=20] [hold=4]
                                 tap KEYS every `every` frames until COND
  checkpoint NAME [window=30]    screenshot + OCR, plus framebuffer hashes of
                                 `window` frames either side (slip detection)

Conditions:
  text "STR"      OCR finds STR (case/space-insensitive)
  notext "STR"    OCR does not find STR
  selected "STR"  the selected menu entry (screen.py heuristics) contains STR
  stable N        framebuffer unchanged for N consecutive frames
  changed         framebuffer differs from when the step started
  blank / notblank  single-colour screen or not

Everything waits on conditions rather than fixed frame counts where the
game's pacing can drift between emulators (lag frames, load times): a script
recorded on one emulator then replays on all of them.
"""
import re
import shlex

KEY_NAMES = {'A', 'B', 'SELECT', 'START', 'RIGHT', 'LEFT', 'UP', 'DOWN', 'R', 'L'}
SECTIONS = ('new', 'load')


class ScriptError(ValueError):
    pass


def parse_keys(s):
    keys = [k.upper() for k in s.split('+') if k]
    for k in keys:
        if k not in KEY_NAMES:
            raise ScriptError(f'unknown key {k!r}')
    return keys


def _opts(tokens, allowed):
    opts, rest = {}, []
    for t in tokens:
        m = re.fullmatch(r'([a-z]+)=(-?\d+)', t)
        if m and m.group(1) in allowed:
            opts[m.group(1)] = int(m.group(2))
        else:
            rest.append(t)
    return opts, rest


def parse_cond(tokens):
    if not tokens:
        raise ScriptError('missing condition')
    kind = tokens[0]
    if kind in ('text', 'notext', 'selected'):
        if len(tokens) != 2:
            raise ScriptError(f'{kind} takes one quoted string')
        return {'kind': kind, 'arg': tokens[1]}
    if kind == 'stable':
        return {'kind': 'stable', 'arg': int(tokens[1]) if len(tokens) > 1 else 10}
    if kind in ('changed', 'blank', 'notblank'):
        return {'kind': kind}
    raise ScriptError(f'unknown condition {kind!r}')


def parse_step(line):
    tokens = shlex.split(line, comments=False)
    op = tokens[0].lower()
    args = tokens[1:]
    if op == 'wait':
        return {'op': 'wait', 'frames': int(args[0])}
    if op == 'press':
        opts, rest = _opts(args, {'hold', 'after'})
        return {'op': 'press', 'keys': parse_keys(rest[0]), 'hold': opts.get('hold', 6),
                'after': opts.get('after', 0)}
    if op == 'hold':
        return {'op': 'hold', 'keys': parse_keys(args[0])}
    if op == 'release':
        return {'op': 'hold', 'keys': []}
    if op == 'until':
        opts, rest = _opts(args, {'timeout', 'every'})
        return {'op': 'until', 'cond': parse_cond(rest), 'timeout': opts.get('timeout', 600),
                'every': opts.get('every', 4)}
    if op == 'mash':
        opts, rest = _opts(args, {'timeout', 'every', 'hold'})
        if len(rest) < 3 or rest[1] != 'until':
            raise ScriptError('mash KEYS until COND')
        return {'op': 'mash', 'keys': parse_keys(rest[0]), 'cond': parse_cond(rest[2:]),
                'timeout': opts.get('timeout', 1200), 'every': opts.get('every', 20),
                'hold': opts.get('hold', 4)}
    if op == 'checkpoint':
        opts, rest = _opts(args, {'window'})
        return {'op': 'checkpoint', 'name': rest[0], 'window': opts.get('window', 30)}
    raise ScriptError(f'unknown step {op!r}')


def format_step(step):
    op = step['op']
    if op == 'wait':
        return f"wait {step['frames']}"
    if op == 'press':
        s = f"press {'+'.join(step['keys'])}"
        if step['hold'] != 6:
            s += f" hold={step['hold']}"
        if step['after']:
            s += f" after={step['after']}"
        return s
    if op == 'hold':
        return f"hold {'+'.join(step['keys'])}" if step['keys'] else 'release'
    cond = ''
    if 'cond' in step:
        c = step['cond']
        cond = c['kind'] + (f' {shlex.quote(str(c["arg"]))}' if 'arg' in c else '')
    if op == 'until':
        return f"until {cond} timeout={step['timeout']} every={step['every']}"
    if op == 'mash':
        return f"mash {'+'.join(step['keys'])} until {cond} timeout={step['timeout']} every={step['every']}"
    if op == 'checkpoint':
        return f"checkpoint {step['name']} window={step['window']}"
    raise ScriptError(op)


def parse(text):
    """-> {'meta': {...}, 'new': [steps], 'load': [steps]}"""
    out = {'meta': {}, 'new': [], 'load': []}
    section = None
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split('#', 1)[0].strip() if not raw.strip().startswith('@') else raw.strip()
        if not line:
            continue
        try:
            if line.startswith('@'):
                key, _, value = line[1:].partition(' ')
                out['meta'][key] = value.strip()
            elif line.startswith('['):
                section = line.strip('[]').strip()
                if section not in SECTIONS:
                    raise ScriptError(f'unknown section {section!r}')
            else:
                if section is None:
                    raise ScriptError('step outside a section')
                step = parse_step(line)
                step['line'] = n
                out[section].append(step)
        except (ScriptError, IndexError, ValueError) as e:
            raise ScriptError(f'line {n}: {raw.strip()!r}: {e}') from None
    return out
