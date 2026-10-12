"""The resident monitor's own code, run in an emulator with a scripted host.

    from monsim import Host, run
    h = Host()
    h.connect(); h.ping()
    h.write_mem(0x03000000, words)
    ...
    answers = run(h, mode=0x1F)        # {emulator: [the console's word per transfer]}

tests/roms/gbamon.s is assembled with its `sio_xfer` swapped for one that
takes each word the host would have clocked in from a list in ROM and logs
the word the console clocked out, then linked at 0x02000000 like the
multiboot image and entered at 0x020000C0 by a cartridge stub, in the CPU
mode given. So a payload goes through exactly what the link would put it
through -- do_write's upload, the trampoline, do_call's `mov lr, pc; bx r7`
and the command loop that runs again after it returns -- with nothing but
the wire replaced. What it cannot show: anything the cable does (a dropped
word, a transfer that races the console re-arming), and the state a real
multiboot boot leaves (the mode is a parameter for that reason).

Host keeps the transfer index of every word whose answer matters, so the
caller reads them off the log: `h.mark(name)` before a transfer, then
`answers[emulator][h.marks[name]]`.
"""
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import payloadcmp   # noqa: E402
from monitor import (CMD_PING, CMD_WRITE, CMD_READ, CMD_CALL, CMD_GETR,   # noqa: E402
                     CMD_ABRT, MAX_WORDS)

GBAMON = os.path.join(payloadcmp.ROMS, 'gbamon.s')
SIMVARS = 0x0201FFF0          # index, count, stream base
LOG = 0x02020000              # the console's word per transfer (64 KB)
DONE_MARK = 0x600D0000        # stored after the last logged word

FAKE_SIO = """sio_xfer:
    ldr r1, =0x0201FFF0            @ sim: index, count, stream base
    ldr r2, [r1]
    ldr r3, [r1, #4]
    ldr r12, =0x02020000           @ the log
    cmp r2, r3
    bhs sim_end
    str r0, [r12, r2, lsl #2]      @ what the console sent on this transfer
    ldr r12, [r1, #8]
    ldr r0, [r12, r2, lsl #2]      @ what the host sent
    add r2, r2, #1
    str r2, [r1]
    bx  lr
sim_end:
    ldr r0, =0x600D0000
    str r0, [r12, r2, lsl #2]
    b   .
    .ltorg

"""

STUB = """    .arm
    .text
    .global _start
_start:
    b   main
    .space 0x9C
    .space 0x20
main:
    ldr r0, =mon
    ldr r1, =0x02000000
    ldr r2, =mon_end
    ldr r3, =mon
    sub r2, r2, r3
1:  ldr r4, [r0], #4
    str r4, [r1], #4
    subs r2, r2, #4
    bgt 1b
    ldr r1, =0x0201FFF0
    mov r0, #0
    str r0, [r1]
    ldr r0, =stream_end
    ldr r2, =stream
    sub r0, r0, r2
    mov r0, r0, lsr #2
    str r0, [r1, #4]
    str r2, [r1, #8]
    ldr r0, =MODE
    msr cpsr_c, r0
    ldr sp, =0x03007F00
    ldr r0, =0x020000C0
    bx  r0
    .ltorg
    .align 2
mon:
    .incbin "monsim_mon.bin"
    .align 2
mon_end:
stream:
    .incbin "monsim_stream.bin"
stream_end:
"""


class Host:
    """The words monitor.Monitor would send, without a console to answer."""

    def __init__(self):
        self.words = []
        self.marks = {}

    def x(self, w=0):
        self.words.append(w & 0xFFFFFFFF)
        return len(self.words) - 1

    def mark(self, name):
        self.marks[name] = len(self.words)

    def connect(self):                 # Monitor.__init__: four discards, a resync
        for _ in range(4):
            self.x(0)
        self.x(CMD_ABRT)
        self.x(CMD_ABRT)

    def ping(self):
        self.x(CMD_PING)
        return self.x()

    def write_mem(self, address, words):
        for i in range(0, len(words), MAX_WORDS):
            chunk = words[i:i + MAX_WORDS]
            self.x(CMD_WRITE)
            self.x(address + 4 * i)
            self.x(len(chunk))
            for w in chunk:
                self.x(w)

    def read_mem(self, address, count):
        """The transfer indices whose answers are the words read."""
        out = []
        for i in range(0, count, MAX_WORDS):
            n = min(MAX_WORDS, count - i)
            self.x(CMD_READ)
            self.x(address + 4 * i)
            self.x(n)
            out += [self.x() for _ in range(n)]
        return out

    def call(self, address, arg=0):
        """The index of the poll that should read DONE, and of GETR's answer."""
        self.x(CMD_CALL)
        self.x(address)
        self.x(arg)
        done = self.x()                # the payload has run by the next transfer
        self.x(CMD_GETR)
        return done, self.x()


def _build(host, mode, scratch):
    os.makedirs(scratch, exist_ok=True)
    src = open(GBAMON).read()
    start = src.index('sio_xfer:\n')
    end = src.index('    .align 2\nstate:')
    src = src[:start] + FAKE_SIO + src[end:]
    open(os.path.join(scratch, 'monsim_mon.s'), 'w').write(src)

    def run(*cmd):
        subprocess.run(cmd, check=True, cwd=scratch)
    run('arm-none-eabi-as', '-mcpu=arm7tdmi', '-o', 'monsim_mon.o', 'monsim_mon.s')
    run('arm-none-eabi-ld', '-Ttext=0x02000000', '-o', 'monsim_mon.elf', 'monsim_mon.o')
    run('arm-none-eabi-objcopy', '-O', 'binary', 'monsim_mon.elf', 'monsim_mon.bin')
    open(os.path.join(scratch, 'monsim_stream.bin'), 'wb').write(
        struct.pack(f'<{len(host.words)}I', *host.words))
    open(os.path.join(scratch, 'monsim.s'), 'w').write(f'.equ MODE, {mode:#x}\n' + STUB)
    run('arm-none-eabi-as', '-mcpu=arm7tdmi', '-o', 'monsim.o', 'monsim.s')
    run('arm-none-eabi-ld', '-Ttext=0x08000000', '-o', 'monsim.elf', 'monsim.o')
    run('arm-none-eabi-objcopy', '-O', 'binary', 'monsim.elf', 'monsim.gba')
    rom = os.path.join(scratch, 'monsim.gba')
    data = bytearray(open(rom, 'rb').read())
    while len(data) % 16:
        data.append(0)
    open(rom, 'wb').write(bytes(data))
    sys.path.insert(0, payloadcmp.ROMS)
    import romfix
    romfix.gba_logo(rom)
    return rom


def run(host, mode=0x1F, names=('dingbat', 'dingbat-bios'), frames=120):
    """{emulator: the console's word on every transfer, or None where the
    run never got that far}. The log ends where the monitor stopped
    answering: a payload that never came back leaves the rest None."""
    if len(host.words) + 1 > 0x4000:
        raise ValueError('more transfers than the log holds')
    rom = _build(host, mode, os.path.join(payloadcmp.SCRATCH, 'monsim'))
    n = len(host.words)
    head = (LOG - SIMVARS) // 4
    got = payloadcmp.in_emulators(rom, head + n + 1, names=names, frames=frames,
                                  block=(SIMVARS, head + n + 1))
    out = {}
    for name in names:
        reached = got[name][0]                 # transfers the console made
        words = got[name][head:]
        k = min(reached, n)
        out[name] = words[:k] + [None] * (n - k)
    return out
