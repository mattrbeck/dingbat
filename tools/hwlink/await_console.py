"""Wait for the console to be switched on, then run payloads unattended.

The rig can only talk to a GBA that is powered on: either sitting in its
multiboot wait loop, which is where a BIOS boot with no cartridge leaves it,
or already running a resident monitor from an earlier session. Switching it
on is the one part of a hardware session a person still has to do. This
waits for it instead of failing:

    python3 await_console.py out.txt payloads/psgwhy.s:8 payloads/waitprobe.s@0,4,8

It polls the link every 20 seconds, doing nothing while the console is dark,
and the moment it answers, installs the monitor and runs each payload in
turn, appending its answers to the output file. A payload that answers in a block
of memory says how many words as `source.s:8`; one that wants arguments, and
answers in r0 to each, lists them as `source.s@0,4,8`. So the
answer is waiting whenever the console is next switched on, rather than
needing someone at the keyboard at that moment.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gblink
import monitor

RESULTS = 0x02008000
WORDS = 8
POLL_SECONDS = 20
GIVE_UP_HOURS = 12


def as_words(values):
    """monitor.read_mem hands back ints; be forgiving of hex strings too."""
    return [v if isinstance(v, int) else int(v, 16) for v in values]


def console_state():
    """'multiboot', 'monitor', or None if the console is not answering.

    Waiting only for the multiboot handshake was wrong: a console that is
    already running a resident monitor never sends it, so this sat polling a
    console that was answering perfectly well. A monitor echoes any word it
    does not recognise, and 0x6202 is not one of its commands, so the same
    probe separates the two states -- 0x7202 back means the BIOS wait loop,
    the word itself means a monitor.
    """
    try:
        with gblink.GBLink() as link:
            link.open_link()
            probe = 0x00006202
            answers = [link.transfer32(probe) for _ in range(8)]
    except Exception:
        return None
    # the 32-bit link shape carries the BIOS's 0x7202 in the TOP half
    if any(0x7202 in (a & 0xFFFF, a >> 16) for a in answers):
        return 'multiboot'
    if any(a == probe for a in answers):
        return 'monitor'
    return None


def run(payloads, out, state='multiboot'):
    # A monitor already resident is ready to take payloads; reinstalling it
    # would only cost a reboot and an upload.
    if state == 'monitor':
        log(out, 'a monitor is already running; using it as it is')
    else:
        monitor.install(log=lambda m: log(out, m))
    with monitor.Monitor() as m:
        m.ping()
        for spec in payloads:
            source, _, count = spec.partition(':')
            source, _, arglist = source.partition('@')
            args = [int(a, 0) for a in arglist.split(',')] if arglist else [0]
            code = monitor.assemble(source, out_dir='/tmp')
            name = os.path.basename(source)
            for arg in args:
                answer = m.run_payload(code, arg)
                log(out, f'{name}  arg={arg:#x}  r0={answer:#010x}')
            if count:
                words = as_words(m.read_mem(RESULTS, int(count)))
                data = b''.join(w.to_bytes(4, 'little') for w in words)
                log(out, '  ' + ' '.join(f'{b:02X}' for b in data))


def log(out, message):
    line = f'{time.strftime("%H:%M:%S")}  {message}'
    print(line, flush=True)
    with open(out, 'a') as f:
        f.write(line + '\n')


def main(argv):
    out, payloads = argv[1], argv[2:]
    deadline = time.time() + GIVE_UP_HOURS * 3600
    log(out, f'waiting for the console, {len(payloads)} payloads queued')
    while time.time() < deadline:
        state = console_state()
        if state:
            log(out, f'console is awake ({state})')
            try:
                run(payloads, out, state)
                log(out, 'done')
                return 0
            except Exception as e:
                log(out, f'failed: {e}')
                return 1
        time.sleep(POLL_SECONDS)
    log(out, 'gave up waiting')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
