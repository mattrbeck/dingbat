#!/usr/bin/env python3
"""Cartridge RTC battery-file interchange between dingbat and mGBA.

The GBA battery-save RTC trailer (16 bytes after the chip data; FlashGBX's
format, also written by mGBA 0.10+; see src/dingbat/gba/rtc_calendar.nim)
carries a cart's clock between tools. This drives both emulators' headless
drivers on an RTC cart (Pokemon Emerald by default) and reads the clock the
way the game does, over the GPIO port (`rtc_get` / `rtc_set` in the driver
protocol), to show a clock survives each hand-off:

  1. dingbat sets the cart clock; its save carries it to mGBA, which reads the
     saved time plus the source-clock time elapsed since.
  2. mGBA rewrites the save (a flash write dirties it); dingbat reads the clock
     back from mGBA's trailer, still offset from the source clock.
  3. Both on the host wall clock, in a non-UTC zone: they read the same time.
  4. A FlashGBX-style trailer (hour byte with the PM flag, status filler 0x01).

    tools/playtest/rtc_crosscheck.py [rom] [--bios gba_bios.bin]

Exit status 0 when every check passes.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import calendar

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, 'bin')
E1 = 1136073600  # 2006-01-01 00:00:00 UTC

failures = 0


def check(ok, msg, detail=''):
    global failures
    print(f"  [{'PASS' if ok else 'FAIL'}] {msg}" + (f'  ({detail})' if detail and not ok else ''))
    if not ok:
        failures += 1


class Driver:
    def __init__(self, name, rom, envdir, bios, save_in=None, rtc=None, tz='UTC'):
        os.makedirs(envdir, exist_ok=True)
        self.rom = os.path.join(envdir, 'game.gba')
        if not os.path.exists(self.rom):
            os.symlink(os.path.abspath(rom), self.rom)
        self.save = os.path.join(envdir, 'game.sav')
        if os.path.exists(self.save):
            os.remove(self.save)
        if save_in:
            shutil.copyfile(save_in, self.save)
        binary = 'dingbat_driver' if name == 'dingbat' else 'mgba_driver'
        cmd = [os.path.join(BIN, binary), self.rom, 'hle' if name == 'dingbat' else bios]
        if rtc is not None:
            cmd += ['--rtc', str(rtc)]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                  env=dict(os.environ, TZ=tz), cwd=envdir)
        self._read()

    def _read(self):
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError('driver exited')
            line = line.rstrip('\n')
            if line == 'ok' or line.startswith(('ok ', 'err', 'ready')):
                return line

    def cmd(self, line):
        self.p.stdin.write(line + '\n')
        self.p.stdin.flush()
        out = self._read()
        if out.startswith('err'):
            raise RuntimeError(f'{line} -> {out}')
        return out[3:]

    def clock(self):
        dt, status = self.cmd('rtc_get').split()
        return bytes.fromhex(dt), int(status, 16)

    def quit(self):
        self.cmd('quit')
        self.p.wait()


def unbcd(b):
    return (b >> 4) * 10 + (b & 15)


def decode(reg):
    """DATE_TIME register bytes -> (unix-style calendar seconds, weekday)."""
    hour = unbcd(reg[4] & 0x3F)
    s = calendar.timegm((2000 + unbcd(reg[0]), unbcd(reg[1]), unbcd(reg[2]),
                         hour, unbcd(reg[5]), unbcd(reg[6]), 0, 0, 0))
    return s, reg[3]


def fmt(s):
    return time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(s))


def trailer(path, chip=0x20000):
    data = open(path, 'rb').read()
    if len(data) != chip + 16:
        return None
    t = data[chip:]
    return decode(t[:7]) + (t[7], struct.unpack('<Q', t[8:])[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom', nargs='?', default=os.path.expanduser('~/Documents/emu/gba/PokemonEmerald.gba'))
    ap.add_argument('--bios', default=os.path.expanduser(os.environ.get(
        'PLAYTEST_BIOS', '~/code/dingbat/tests/roms/gba_bios.bin')))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix='rtc_crosscheck_')
    SET = calendar.timegm((2031, 7, 14, 21, 5, 9, 0, 0, 0))
    SET_REG = '31071401210509'  # weekday counter 1

    print('1. dingbat sets the clock -> mGBA reads it')
    d = Driver('dingbat', args.rom, os.path.join(work, 'd1'), args.bios, rtc=E1)
    d.cmd('run 600')
    reg, st = d.clock()
    check(decode(reg)[0] == E1 and st == 0x40, 'dingbat boots at the frozen epoch, 24-hour status',
          f'{reg.hex()} {st:02X}')
    d.cmd(f'rtc_set {SET_REG}')
    reg, st = d.clock()
    check(decode(reg) == (SET, 1) and reg[4] == 0xA1,
          f'dingbat reads back {fmt(SET)}', reg.hex())
    d.cmd('run 60')
    d.quit()
    t = trailer(d.save)
    check(t == (SET, 1, 0x40, E1), 'dingbat save: 131072 chip bytes + trailer for that clock latched at the epoch',
          repr(t))

    m = Driver('mgba', args.rom, os.path.join(work, 'm2'), args.bios, save_in=d.save, rtc=E1 + 3661)
    m.cmd('run 60')
    reg, st = m.clock()
    check(decode(reg) == (SET + 3661, 1),
          f'mGBA, one hour later, reads {fmt(SET + 3661)}', f'{reg.hex()} = {fmt(decode(reg)[0])}')
    check(st == 0x40, 'mGBA adopts the trailer status', f'{st:02X}')

    print('2. mGBA rewrites the save -> dingbat reads the clock back')
    for a, v in (('0E005555', 'AA'), ('0E002AAA', '55'), ('0E005555', 'A0'), ('0E00FFF0', 'FF')):
        m.cmd(f'poke8 {a} {v}')
    m.cmd('run 240')
    m.quit()
    t = trailer(m.save)
    check(t is not None and t[0] == SET + 3661 and t[3] == E1 + 3661,
          'mGBA save: trailer holds the clock it last read, latched at its source time', repr(t))
    d = Driver('dingbat', args.rom, os.path.join(work, 'd3'), args.bios, save_in=m.save, rtc=E1 + 7200)
    d.cmd('run 60')
    reg, st = d.clock()
    check(decode(reg) == (SET + 7200, 1),
          f'dingbat, two hours after the set, reads {fmt(SET + 7200)}', f'{reg.hex()} = {fmt(decode(reg)[0])}')
    d.quit()

    print('3. host wall clock, TZ=America/New_York: both read the same resumed clock')
    first = os.path.join(work, 'd1', 'game.sav')
    d = Driver('dingbat', args.rom, os.path.join(work, 'd4'), args.bios, save_in=first, tz='America/New_York')
    m = Driver('mgba', args.rom, os.path.join(work, 'm4'), args.bios, save_in=first, tz='America/New_York')
    d.cmd('run 30')
    m.cmd('run 30')
    rd, _ = d.clock()
    rm, _ = m.clock()
    want = SET + (int(time.time()) - E1)
    check(abs(decode(rd)[0] - want) <= 2, f'dingbat reads saved + wall time since latch ~ {fmt(want)}',
          fmt(decode(rd)[0]))
    check(abs(decode(rm)[0] - decode(rd)[0]) <= 2, 'mGBA reads the same time',
          f'{fmt(decode(rm)[0])} vs {fmt(decode(rd)[0])}')
    d.quit()
    m.quit()

    print('4. FlashGBX-style trailer: hour with the PM flag, status filler 0x01')
    fg = os.path.join(work, 'flashgbx.sav')
    with open(fg, 'wb') as f:
        f.write(b'\xff' * 0x20000)
        f.write(bytes.fromhex('04053101971415 01') + struct.pack('<Q', 1643287972))
    d = Driver('dingbat', args.rom, os.path.join(work, 'd5'), args.bios, save_in=fg, rtc=1643287972 + 45)
    d.cmd('run 30')
    reg, st = d.clock()
    want = calendar.timegm((2004, 5, 31, 17, 15, 0, 0, 0, 0))
    check(decode(reg) == (want, 1) and reg[4] == 0x97 and st == 0x40,
          'dingbat resumes 2004-05-31 17:14:15 + 45 s, 24-hour status kept', f'{reg.hex()} {st:02X}')
    d.quit()
    m = Driver('mgba', args.rom, os.path.join(work, 'm5'), args.bios, save_in=fg, rtc=1643287972 + 45)
    m.cmd('run 30')
    reg, _ = m.clock()
    print(f'  [info] mGBA on the same file reads {reg.hex()} = {fmt(decode(reg)[0])} '
          '(it decodes the flagged hour 0x97 as 97; why dingbat writes the hour unflagged)')
    m.quit()

    shutil.rmtree(work)
    print('all passed' if failures == 0 else f'{failures} failure(s)')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
