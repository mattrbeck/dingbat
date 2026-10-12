"""The SingleStepTests ARM7TDMI probe: where dingbat and the vectors disagree,
asked of the console (docs/hwprobe-sst.md has the questions and answers).

    python3 sst.py emulators        # dingbat (HLE and real BIOS) -> sst-dingbat.json
    python3 sst.py console          # the AGB SP over the link   -> sst-agb.json
    python3 sst.py console --safe   # everything but sstrisk.s (= --groups=AB)
    python3 sst.py console --groups=C --keep --skip=x.mrs_r15
                                    # after a power cycle: the risky cells again,
                                    # kept with the answers already in the file
    python3 sst.py show             # the cells side by side, decoded
    python3 sst.py rom DIR          # cartridge ROMs of both payloads (results
                                    # at 0x02000000, one word a cell, in order)

Two payloads, uploaded separately: tests/roms/payloads/sst.s (CELLS: every
cell that comes back by itself or through the watchdog) and sstrisk.s
(RISK_CELLS: an undefined-instruction trap or a jump into the BIOS is a
possible answer). `console` runs sst.s first -- group A (the cells that
re-confirm known answers and time the stores), then group B (UNPREDICTABLE
encodings) -- three passes each, then the risky cells one at a time in
RISK_CELLS order, least risky first. A cell whose call never returns stops
the run there: the console needs a power cycle and nothing else will
answer. The JSON is written after every cell, so what was answered is kept.

Each payload is uploaded once and read back; each cell's argument is
written and read back, the cell called through a trampoline, and its answer
read until two reads agree (as monitor.run_payload does, without uploading
the code again for every cell). The code is read back after every pass.
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp   # noqa: E402

SAFE_SRC = os.path.join(payloadcmp.ROMS, 'payloads', 'sst.s')
RISK_SRC = os.path.join(payloadcmp.ROMS, 'payloads', 'sstrisk.s')
DINGBAT_FILE = os.path.join(HERE, 'sst-dingbat.json')
CONSOLE_FILE = os.path.join(HERE, 'sst-agb.json')
EMULATORS = ('dingbat', 'dingbat-bios')

# sst.s's dispatch table, in order. Group A is 0..69, group B 70..
TIMING = (['t.ctrl']
          + [f't.{n}.{d}' for d in ('iw', 'ew')
             for n in ('str_r0', 'str_pc', 'strb_r0', 'strb_pc', 'strh_r0', 'strh_pc',
                       'stm_r0-r3', 'stm_r0-r2_pc', 'stmdb_r0_r4_r11_r12_lr', 'stmdb_r4_r11_r12_lr_pc')]
          + ['t.thumb_ctrl']
          + [f't.{n}.{d}' for d in ('iw', 'ew')
             for n in ('push_r0', 'push_lr', 'push_r3-r7', 'push_r4-r7_lr')])
CELLS = TIMING + [
    'v.str_pc', 'v.strb_pc', 'v.strh_pc', 'v.stm_pc', 'v.stmdb_pc',
    'v.push_order.thumb_push', 'v.push_order.arm_stmia', 'v.push_order.arm_str_desc',
    'c.thumb_lsl_0x101', 'c.thumb_lsr_0x101', 'c.thumb_asr_0x101', 'c.mov_pc_lsl_reg',
    'c.fiq.svc_view', 'c.fiq.fiq_view', 'c.fiq.sys_view',
    'c.user_msr_c_1F', 'c.user_msr_fc_F000001F', 'c.user_msr_c_13', 'c.sys_msr_c_D3',
    'r.sysmovs.movs', 'r.sysmovs.subs', 'r.sysmovs.ldm^',
    'r.sysmovs.movs.thumbspsr', 'r.sysmovs.subs.thumbspsr', 'r.sysmovs.ldm^.thumbspsr',
    'r.usermovs.movs', 'r.usermovs.subs', 'r.usermovs.ldm^',
    'r.ldmia_pc!', 'r.str_pc_post', 'r.ldr_pc_post', 'r.ldr_pc_pre!', 'r.str_pc_pre!', 'r.stmia_pc!',
    'r.cpsr_0FFFFFDF', 'r.spsr_0FFFFF00', 'r.spsr_FFFFFFEF', 'r.spsr_00000000',
    'r.thumb_cmp_pc.irq', 'r.thumb_cmp_pc.sys',
] + [f'u.{op}p.{mode}' for mode in ('svc', 'irq', 'sys') for op in ('tst', 'teq', 'cmp', 'cmn')] + [
    'u.rs15_lsr', 'u.rn15_regshift', 'u.rm15_regshift',
    'u.mul_rd15', 'u.mla_rd15', 'u.umull_rdlo15', 'u.umull_rdhi15',
    'u.mul_rm15', 'u.mul_rs15', 'u.mla_rn15', 'u.umull_rm15',
    'u.swp_rm15', 'u.swp_rd15', 'u.swp_rn15',
]
GROUP_B = CELLS.index('u.tstp.svc')
# sstrisk.s's table, least risky first: GBATEK says CP14 does not trap
RISK_CELLS = ['x.mrc14_c0', 'x.mrc14_c1', 'x.mrc14_c2', 'x.mcr14_c1', 'x.mrc14_r15',
              'x.thumb_dexx', 'x.mrs_r15']


def frames_for(count):
    return 60 + 8 * count


# ---- emulators

def _in_emulators(src, args):
    """{emulator: [answer text]}; 'hung' for the cells a run never got past
    (payloadrun.s stores each answer, then 0x600D0000 at 0x02000FFC)."""
    rom = payloadcmp.build_wrapper(src, args)
    got = payloadcmp.in_emulators(rom, 0x400, names=EMULATORS, frames=frames_for(len(args)),
                                  block=(payloadcmp.RESULTS, 0x400))
    out = {}
    for n in EMULATORS:
        done = got[n][0x3FF] == 0x600D0000
        out[n] = [f'{w:08X}' for w in got[n][:len(args)]]
        if not done:
            # the first cell whose slot is still zero is where it stopped
            k = next((i for i, w in enumerate(got[n][:len(args)]) if w == 0), len(args) - 1)
            out[n][k:] = ['hung'] + ['-'] * (len(args) - k - 1)
    return out


def run_emulators():
    out = {}
    got = _in_emulators(SAFE_SRC, list(range(len(CELLS))))
    for i, name in enumerate(CELLS):
        out[name] = {n: got[n][i] for n in EMULATORS}
    # one ROM a risky cell: a core that hangs on one keeps the others
    for i, name in enumerate(RISK_CELLS):
        got = _in_emulators(RISK_SRC, [i])
        out[name] = {n: got[n][0] for n in EMULATORS}
    json.dump(out, open(DINGBAT_FILE, 'w'), indent=1)
    print(f'{len(out)} cells -> {os.path.relpath(DINGBAT_FILE)}')


def build_roms(dest):
    import shutil
    os.makedirs(dest, exist_ok=True)
    for src, cells, stem in ((SAFE_SRC, CELLS, 'sst'), (RISK_SRC, RISK_CELLS, 'sstrisk')):
        rom = payloadcmp.build_wrapper(src, list(range(len(cells))))
        shutil.copyfile(rom, os.path.join(dest, stem + '.gba'))
        print(f'{dest}/{stem}.gba: {len(cells)} cells, answers at 0x02000000 in order')


# ---- console

class Wedged(RuntimeError):
    pass


class Session:
    """One payload resident in IWRAM, called once per cell."""

    def __init__(self, m, code):
        from monitor import PAYLOAD_ADDRESS
        self.m = m
        data = bytearray(code)
        while len(data) % 4:
            data.append(0)
        words = [int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4)]
        self.ncode = len(words)
        tramp = PAYLOAD_ADDRESS + 4 * len(words)
        branch = ((PAYLOAD_ADDRESS - (tramp + 12 + 8)) >> 2) & 0xFFFFFF
        words += [0xE92D4010,              # stmfd sp!, {r4, lr}
                  0xE28F4010,              # adr r4, slots
                  0xE5940000,              # ldr r0, [r4]
                  0xEB000000 | branch,     # bl payload
                  0xE5840004,              # str r0, [r4, #4]
                  0xE8BD4010,              # ldmfd sp!, {r4, lr}
                  0xE12FFF1E,              # bx lr
                  0, 0x5A5A5A5A]
        self.words = words
        self.base = PAYLOAD_ADDRESS
        self.tramp = tramp
        self.arg_at = tramp + 28
        self.result_at = tramp + 32
        self.upload()

    def upload(self, tries=3):
        for _ in range(tries):
            self.m.write_mem(self.base, self.words)
            if self.m.read_mem(self.base, len(self.words)) == self.words:
                return
            self.m.resync()
        raise RuntimeError('the payload would not upload intact')

    def intact(self):
        return self.m.read_mem(self.base, self.ncode) == self.words[:self.ncode]

    def ask(self, arg, tries=3):
        from monitor import MonitorError
        for _ in range(tries):
            self.m.write_mem(self.arg_at, [arg, 0x5A5A5A5A])
            if self.m.read_mem(self.arg_at, 2) != [arg, 0x5A5A5A5A]:
                self.m.resync()
                continue
            try:
                self.m.call(self.tramp, 0, timeout=10.0)
            except MonitorError as e:
                raise Wedged(str(e))
            for _ in range(4):
                first = self.m.read_mem(self.result_at, 1)[0]
                if first == self.m.read_mem(self.result_at, 1)[0]:
                    return first
                self.m.resync()
        raise RuntimeError(f'cell {arg} would not run intact')


def load(path):
    return json.load(open(path)) if os.path.exists(path) else {}


def record(table, name, word):
    cell = table.setdefault(name, {})
    text = f'{word:08X}'
    cell[text] = cell.get(text, 0) + 1


def run_console(runs, groups, keep, skip):
    from monitor import Monitor, assemble
    scratch = payloadcmp.SCRATCH
    os.makedirs(scratch, exist_ok=True)
    state = load(CONSOLE_FILE) if keep else {}
    tallies = state.setdefault('cells', {})
    state.update({'runs': runs, 'started': time.strftime('%Y-%m-%d %H:%M:%S'), 'stopped_at': None})

    def save():
        json.dump(state, open(CONSOLE_FILE, 'w'), indent=1)

    plan = [('sst', SAFE_SRC, CELLS, range(0, GROUP_B), 'A', runs),
            ('sst', SAFE_SRC, CELLS, range(GROUP_B, len(CELLS)), 'B', runs),
            ('sstrisk', RISK_SRC, RISK_CELLS, range(len(RISK_CELLS)), 'C', None)]
    plan = [p for p in plan if p[4] in groups]
    for stem, src, names, idx, group, passes in plan:
        idx = [i for i in idx if names[i] not in skip]
        if not idx:
            continue
        code = assemble(src, out_dir=scratch)
        with Monitor() as m:
            m.ping()
            s = Session(m, code)
            print(f'group {group}: {stem}.s, {len(s.words)} words, {len(idx)} cells', flush=True)
            for i in idx:
                tallies.pop(names[i], None)       # this run's answers replace a kept file's
            try:
                if passes:
                    for p in range(passes):
                        for i in idx:
                            record(tallies, names[i], s.ask(i))
                            save()
                        if not s.intact():
                            print(f'  pass {p}: the code changed; uploading it again', flush=True)
                            state.setdefault('notes', []).append(f'group {group} pass {p}: code re-uploaded')
                            s.upload()
                else:
                    # one cell at a time, three runs each, so a wedge names its cell
                    for i in idx:
                        for _ in range(runs):
                            record(tallies, names[i], s.ask(i))
                            save()
                        print(f'  {names[i]:<20} {" | ".join(tallies[names[i]])}', flush=True)
                        if not s.intact():
                            s.upload()
            except Wedged as e:
                state['stopped_at'] = names[i]
                save()
                print(f'STOPPED: cell {names[i]} ({stem}.s #{i}) never came back ({e}).\n'
                      'The console needs a power cycle (and `monitor.py install`) before anything '
                      'else runs. Every answer before it is in ' + os.path.relpath(CONSOLE_FILE))
                return 2
    state['finished'] = time.strftime('%Y-%m-%d %H:%M:%S')
    save()
    two = [n for n, c in tallies.items() if len(c) > 1]
    print(f'{len(tallies)} cells -> {os.path.relpath(CONSOLE_FILE)}'
          + (f'; answered more than one way: {", ".join(two)}' if two else ''))
    return 0


# ---- show

def decode(name, word, ctrl=None, tctrl=None):
    """A short reading of one answer, for the table."""
    try:
        w = int(word, 16)
    except (TypeError, ValueError):
        return ''
    if name.startswith('t.') and 'ctrl' not in name:
        base = tctrl if name.startswith('t.push') else ctrl
        return f'{(w - base) / 4:g}/insn' if base is not None else ''
    if name.startswith('v.push_order'):
        return f'TM0-TM1 = {(w >> 16) - (w & 0xFFFF):+d}'
    if name.startswith('v.'):
        return ''
    return ''


def show():
    emu = load(DINGBAT_FILE)
    con = load(CONSOLE_FILE).get('cells', {})
    names = CELLS + RISK_CELLS

    def first(n, src):
        if src == 'agb':
            c = con.get(n)
            return ' | '.join(sorted(c)) if c else None
        return emu.get(n, {}).get(src)

    def ctrl(src, n):
        v = first(n, src)
        return int(v, 16) if v and '|' not in v else None
    print(f'{"cell":<34}{"dingbat":<12}{"dingbat-bios":<14}{"AGB SP":<20}notes')
    for n in names:
        row = [first(n, 'dingbat'), first(n, 'dingbat-bios'), first(n, 'agb')]
        note = decode(n, row[1], ctrl('dingbat-bios', 't.ctrl'), ctrl('dingbat-bios', 't.thumb_ctrl')) \
            if row[1] else ''
        if row[2] and '|' not in row[2] and n.startswith('t.'):
            note += f'  (console {decode(n, row[2], ctrl("agb", "t.ctrl"), ctrl("agb", "t.thumb_ctrl"))})'
        mark = '' if row[2] is None or row[2] == row[1] else '  <<<'
        print(f'{n:<34}{row[0] or "-":<12}{row[1] or "-":<14}{row[2] or "-":<20}{note}{mark}')


def main(argv):
    what = argv[1] if len(argv) > 1 else 'show'
    if what == 'emulators':
        run_emulators()
    elif what == 'console':
        opt = lambda k, d: next((a.split('=', 1)[1] for a in argv if a.startswith(f'--{k}=')), d)  # noqa: E731
        groups = 'AB' if '--safe' in argv else opt('groups', 'ABC')
        skip = set(filter(None, opt('skip', '').split(',')))
        return run_console(int(opt('runs', '3')), groups, '--keep' in argv, skip)
    elif what == 'show':
        show()
    elif what == 'rom':
        build_roms(argv[2] if len(argv) > 2 else payloadcmp.SCRATCH)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
