"""Wait for the console to be switched on, then run payloads unattended.

The rig can only talk to a GBA that is powered on and sitting in its
multiboot wait loop, which is where a BIOS boot with no cartridge leaves it.
That is the one part of a hardware session a person still has to do. This
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


def console_is_awake():
    """True when the GBA answers the multiboot handshake."""
    try:
        with gblink.GBLink() as link:
            link.open_link()
            return any(link.transfer32(0x00006202) & 0xFFFF == 0x7202
                       for _ in range(8))
    except Exception:
        return False


def run(payloads, out):
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
                words = m.read_mem(RESULTS, int(count))
                data = b''.join(int(w, 16).to_bytes(4, 'little') for w in words)
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
        if console_is_awake():
            log(out, 'console is awake')
            try:
                run(payloads, out)
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
