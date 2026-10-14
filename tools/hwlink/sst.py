"""The SingleStepTests ARM7TDMI probe: where dingbat and the vectors disagree,
asked of the console (docs/hwprobe-sst.md has the questions and answers).

    python3 sst.py emulators        # dingbat (HLE and real BIOS) -> sst-dingbat.json
    python3 sst.py console          # the AGB SP over the link   -> sst-agb.json
    python3 sst.py console --safe   # everything but sstrisk.s (= --groups=AB)
    python3 sst.py console --groups=C --keep --skip=x.mrs_r15
                                    # after a power cycle: the risky cells again,
                                    # kept with the answers already in the file
    python3 sst.py monitor-sim [--mode=0x1F]
                                    # the console run's exact traffic through the
                                    # monitor's own code in dingbat (monsim.py),
                                    # checked against sst-dingbat.json
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
the code again for every cell). Because the code is not uploaded again,
the run guards against a payload that changes its own image:
  - first a smoke test, a two-instruction payload called twice through one
    upload, before anything of the probe's is sent;
  - after a group's first cell, the whole image read back;
  - before every call, the trampoline read back (a call through a damaged
    one never returns, which is how the first console run ended: the
    payload's variables overran the end of the image, see sst.inc);
  - after every pass, the whole image again.
A damaged image stops the run with the console still answering.
`monitor-sim` plays the same traffic into the monitor's own code in dingbat;
run it after any change to the payloads or to this file.
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
GAP_SRC = os.path.join(payloadcmp.ROMS, 'payloads', 'sstgap.s')
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
              'x.thumb_dexx', 'x.mrs_r15',
              # the forms the first run left out (2026-10-14)
              'x.mrc14_c3', 'x.mrc14_c5', 'x.mrc14_c8', 'x.mrc14_c15', 'x.mcr14_c0', 'x.mcr14_c2',
              'x.mrsu_18', 'x.mrsu_19', 'x.mrsu_1A', 'x.mrsu_1B', 'x.mrsu_cpsr_und']
# sstgap.s's table (group D): the forms of each known divergence the first
# run's cells left out (docs/hwprobe-sst.md, section 7)
GAP_CELLS = ([f'ut.{op}p.usr' for op in ('tst', 'teq', 'cmp', 'cmn')]
             + [f'sa.{op}s_pc.sys' for op in ('add', 'and', 'orr', 'eor', 'bic', 'mvn', 'rsb')]
             + ['wb.ldrb_pc_post', 'wb.strb_pc_post', 'wb.ldrt_pc_post', 'wb.strt_pc_post',
                'wb.ldrbt_pc_post', 'wb.strbt_pc_post', 'wb.ldr_pc_post_reg', 'wb.ldr_pc_pre!_reg',
                'wb.ldrb_pc_pre!', 'wb.strb_pc_pre!',
                'wb.ldr_pc_[pc]_post', 'wb.ldr_pc_[pc]_pre!', 'wb.str_pc_[pc]_post',
                'wb.ldmib_pc!', 'wb.ldmda_pc!', 'wb.ldmdb_pc!', 'wb.stmdb_pc!',
                'wb.ldmia_pc!^', 'wb.stmia_pc!^', 'wb.ldmia_pc!_r1pc', 'wb.stmia_pc!_r1pc',
                'um.smull_rdlo15', 'um.umlal_rdlo15',
                'ur.umull_rs15', 'ur.smull_rm15', 'ur.smlal_rm15', 'ur.umlal_rs15',
                'u.swpb_rn15']
             + [f'tc.thumb_cmp_pc.{m}' for m in ('svc', 'fiq', 'abt', 'und')]
             + ['tc.thumb_cmp_pc_pc.irq', 'tc.thumb_cmp_pc.usr'])


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
    got = _in_emulators(GAP_SRC, list(range(len(GAP_CELLS))))
    for i, name in enumerate(GAP_CELLS):
        out[name] = {n: got[n][i] for n in EMULATORS}
    # one ROM a risky cell: a core that hangs on one keeps the others
    for i, name in enumerate(RISK_CELLS):
        got = _in_emulators(RISK_SRC, [i])
        out[name] = {n: got[n][0] for n in EMULATORS}
    json.dump(out, open(DINGBAT_FILE, 'w'), indent=1)
    print(f'{len(out)} cells -> {os.path.relpath(DINGBAT_FILE)}')


def sim_session(src, names, idx, mode=0x1F, emulators=EMULATORS):
    """The console runner's exact traffic for these cells, played into the
    monitor's own code in the emulators (monsim.py): {emulator: {cell:
    answer}}, 'hung' for a call that never came back and '-' after it."""
    import monsim
    from monitor import ANS_PONG, ANS_DONE, assemble
    h = monsim.Host()
    h.connect()
    pong = h.ping()
    sessions = []                      # (label, words, upload readback, [(cell, ...)], readback after the first)

    def session(code, cells):
        words, tramp, arg_at, result_at = Session.layout(code)
        h.write_mem(Session.BASE, words)
        back = h.read_mem(Session.BASE, len(words))
        plan, after_first = [], None
        for k, (name, arg) in enumerate(cells):
            trampback = h.read_mem(tramp, 7)            # Session.tramp_intact
            h.write_mem(arg_at, [arg, 0x5A5A5A5A])
            argback = h.read_mem(arg_at, 2)
            done, _ = h.call(tramp, 0)
            res = h.read_mem(result_at, 1)[0]
            h.read_mem(result_at, 1)
            plan.append((name, arg, trampback, argback, done, res))
            if k == 0:                                  # Session.intact after the first call
                after_first = h.read_mem(Session.BASE, len(words) - 9)
        sessions.append((words, back, plan, after_first))

    # what run_console sends: the smoke test, then the probe
    session(SMOKE_CODE, [('smoke 0x1234', 0x1234), ('smoke 0x5678', 0x5678)])
    session(assemble(src, out_dir=payloadcmp.SCRATCH), [(names[i], i) for i in idx])
    got = monsim.run(h, mode=mode, names=emulators, frames=60 + 4 * len(idx))
    out = {}
    for e in emulators:
        log = got[e]
        cells = out[e] = {}
        if log[pong] != ANS_PONG:
            cells['(ping)'] = 'failed'
            continue
        for words, back, plan, after_first in sessions:
            if [log[k] for k in back] != words:
                cells['(upload)'] = 'failed'
                break
            stop = False
            for k, (name, arg, trampback, argback, done, res) in enumerate(plan):
                if [log[t] for t in trampback] != words[-9:-2]:
                    cells[name] = 'corrupt'                # run_console stops here
                    stop = True
                    break
                if log[done] is None:
                    cells[name] = 'hung'
                    stop = True
                    break
                if [log[t] for t in argback] != [arg, 0x5A5A5A5A] or log[done] != ANS_DONE:
                    cells[name] = 'link'
                    continue
                cells[name] = f'{log[res]:08X}'
                if k == 0 and [log[t] for t in after_first] != words[:-9]:
                    cells[name] += ' corrupt'              # the image changed: run_console stops
                    stop = True
                    break
            if stop:
                break
    return out


def run_sim(mode):
    emu = load(DINGBAT_FILE)
    bad = 0
    for src, names in ((SAFE_SRC, CELLS), (GAP_SRC, GAP_CELLS), (RISK_SRC, RISK_CELLS)):
        got = sim_session(src, names, range(len(names)), mode=mode)
        for e, cells in got.items():
            smoke = [cells.get('smoke 0x1234'), cells.get('smoke 0x5678')]
            if smoke != ['00001235', '00005679']:
                bad += 1
                print(f'  {e:<13}smoke test answered {smoke}')
            for n in names:
                a = cells.get(n, '-')
                if a != emu.get(n, {}).get(e):
                    bad += 1
                    print(f'  {e:<13}{n:<30}{a}  (wrapper {emu.get(n, {}).get(e)})')
            print(f'{e:<13} {os.path.basename(src)}: {sum(1 for n in names if cells.get(n) == emu.get(n, {}).get(e))}'
                  f'/{len(names)} cells as the wrapper ROM answers them (mode {mode:#x})')
    return 1 if bad else 0


def build_roms(dest):
    import shutil
    os.makedirs(dest, exist_ok=True)
    for src, cells, stem in ((SAFE_SRC, CELLS, 'sst'), (GAP_SRC, GAP_CELLS, 'sstgap'),
                             (RISK_SRC, RISK_CELLS, 'sstrisk')):
        rom = payloadcmp.build_wrapper(src, list(range(len(cells))))
        shutil.copyfile(rom, os.path.join(dest, stem + '.gba'))
        print(f'{dest}/{stem}.gba: {len(cells)} cells, answers at 0x02000000 in order')


# ---- console

class Wedged(RuntimeError):
    pass


class Corrupt(RuntimeError):
    """The payload's image changed under it: stop before calling it again."""


# `add r0, r0, #1; bx lr`: the smoke test's whole payload
SMOKE_CODE = bytes.fromhex('010080E2') + bytes.fromhex('1EFF2FE1')


class Session:
    """One payload resident in IWRAM, called once per cell."""

    BASE = 0x03000000                      # monitor.PAYLOAD_ADDRESS

    @staticmethod
    def layout(code):
        """(the words uploaded, the trampoline, its argument and result
        slots): monitor.run_payload's layout, code then trampoline."""
        data = bytearray(code)
        while len(data) % 4:
            data.append(0)
        words = [int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4)]
        tramp = Session.BASE + 4 * len(words)
        branch = ((Session.BASE - (tramp + 12 + 8)) >> 2) & 0xFFFFFF
        words += [0xE92D4010,              # stmfd sp!, {r4, lr}
                  0xE28F4010,              # adr r4, slots
                  0xE5940000,              # ldr r0, [r4]
                  0xEB000000 | branch,     # bl payload
                  0xE5840004,              # str r0, [r4, #4]
                  0xE8BD4010,              # ldmfd sp!, {r4, lr}
                  0xE12FFF1E,              # bx lr
                  0, 0x5A5A5A5A]
        return words, tramp, tramp + 28, tramp + 32

    def __init__(self, m, code):
        from monitor import PAYLOAD_ADDRESS
        assert PAYLOAD_ADDRESS == Session.BASE
        self.m = m
        self.words, self.tramp, self.arg_at, self.result_at = Session.layout(code)
        self.ncode = len(self.words) - 9
        self.base = Session.BASE
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

    def tramp_intact(self):
        n = (self.arg_at - self.tramp) // 4
        want = self.words[self.ncode:self.ncode + n]
        for _ in range(2):
            if self.m.read_mem(self.tramp, n) == want:
                return True
            self.m.resync()
        return False

    def ask(self, arg, tries=3):
        from monitor import MonitorError
        # A payload that writes past its own end lands on the trampoline,
        # and a call through a broken trampoline never comes back: check it
        # before every call rather than find out by wedging the console.
        if not self.tramp_intact():
            raise Corrupt('the trampoline after the payload has changed: the payload wrote '
                          'past its own end on an earlier call')
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
            ('sstgap', GAP_SRC, GAP_CELLS, range(len(GAP_CELLS)), 'D', runs),
            ('sstrisk', RISK_SRC, RISK_CELLS, range(len(RISK_CELLS)), 'C', None)]
    plan = [p for p in plan if p[4] in groups]

    # Smoke test: a two-instruction payload, called twice through the same
    # upload, before anything of the probe's goes near the console
    with Monitor() as m:
        m.ping()
        try:
            s = Session(m, SMOKE_CODE)
            got = [s.ask(0x1234), s.ask(0x5678)]
            ok = got == [0x1235, 0x5679] and s.intact()
        except (Wedged, Corrupt, RuntimeError) as e:
            got, ok = str(e), False
        if not ok:
            state['stopped_at'] = 'smoke test'
            save()
            print(f'STOPPED: the smoke test (r0 + 1, called twice) answered {got}, not '
                  '[0x1235, 0x5679]. Nothing of the probe was sent. Check the link and the '
                  'monitor (`monitor.py ping`); after a wedge, power-cycle and `monitor.py install`.')
            return 2
        print('smoke test: a payload called twice through one upload came back both times', flush=True)

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
            i = idx[0]
            try:
                # the first cell once, then the whole image read back: a
                # payload that damages itself stops here, before a second call
                record(tallies, names[i], s.ask(i))
                save()
                if not s.intact():
                    raise Corrupt(f'the payload image changed after its first call ({names[i]})')
                first = idx[0]                    # its first run is the one above
                if passes:
                    for p in range(passes):
                        for i in idx:
                            if p == 0 and i == first:
                                continue
                            record(tallies, names[i], s.ask(i))
                            save()
                        if not s.intact():
                            print(f'  pass {p}: the code changed; uploading it again', flush=True)
                            state.setdefault('notes', []).append(f'group {group} pass {p}: code re-uploaded')
                            s.upload()
                else:
                    # one cell at a time, three runs each, so a wedge names its cell
                    for i in idx:
                        for _ in range(runs - (i == first)):
                            record(tallies, names[i], s.ask(i))
                            save()
                        print(f'  {names[i]:<20} {" | ".join(tallies[names[i]])}', flush=True)
                        if not s.intact():
                            s.upload()
            except Corrupt as e:
                state['stopped_at'] = names[i]
                save()
                print(f'STOPPED at {names[i]} ({stem}.s #{i}), before calling anything more: {e}. '
                      'The console is still answering; this is a payload bug, not a console answer.')
                return 3
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
    names = CELLS + GAP_CELLS + RISK_CELLS

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
        groups = 'ABD' if '--safe' in argv else opt('groups', 'ABDC')
        skip = set(filter(None, opt('skip', '').split(',')))
        return run_console(int(opt('runs', '3')), groups, '--keep' in argv, skip)
    elif what == 'monitor-sim':
        mode = next((int(a.split('=')[1], 0) for a in argv if a.startswith('--mode=')), 0x1F)
        return run_sim(mode)
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
