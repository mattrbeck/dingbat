"""Drive the resident GBA monitor (tests/roms/gbamon.s) over the link cable.

Upload the monitor once with `install`; after that every experiment is just
link traffic, so a run needs nobody at the console:

    python3 monitor.py install            # needs the console power-cycled first
    python3 monitor.py ping
    python3 monitor.py run <payload.s>    # assemble, upload, call, print r0

From Python:

    with Monitor() as m:
        m.ping()
        m.write_mem(0x02004000, words)
        r0 = m.call(0x02004000, arg)
        results = m.read_mem(0x02008000, 16)

Each command is a 32-bit word and its operands, and every host transfer
pairs with exactly one on the console, so the answer to a transfer arrives
on that transfer. The exception is `call`: while the payload runs the
console is not clocking the link, so the host reads an idle line until
'DONE' appears.

A payload is ARM code entered with r0 = the argument and returning with
`bx lr`; its r0 comes back. It may use memory freely (the monitor keeps its
own state in memory and re-establishes the stack, RCNT and the serial mode
every iteration), but it must return: nothing here can recover a payload
that hangs or masks interrupts, and that costs a power cycle. Try a payload
in an emulator before sending it.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gblink import GBLink, multiboot, DEFAULT_DEV   # noqa: E402

CMD_PING = 0x50494E47
CMD_WRITE = 0x57523E3E
CMD_READ = 0x52443E3E
CMD_CALL = 0x43414C4C
CMD_GETR = 0x47455452
CMD_BOOT = 0x424F4F54
ANS_PONG = 0x504F4E47
ANS_DONE = 0x444F4E45

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MONITOR_IMAGE = os.path.join(REPO, 'tests', 'roms', 'gbamon.mb.gba')
# Payloads land in IWRAM, which is 32 bits wide and has no wait states, so a
# timing experiment measures what it means to measure rather than the cost of
# fetching itself out of EWRAM. Results go in EWRAM, well clear of both.
PAYLOAD_ADDRESS = 0x03000000
RESULT_ADDRESS = 0x02008000


class MonitorError(RuntimeError):
    pass


class Monitor:
    def __init__(self, dev=DEFAULT_DEV):
        self.link = GBLink(dev)
        self.link.open_link()
        # The first transfer or two after the link is re-armed catch the
        # console mid-cycle and read back noise or an idle line; throw them
        # away so the first real command is not the one that gets lost.
        for _ in range(4):
            self.link.transfer32(0)

    def close(self):
        self.link.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _x(self, word=0):
        return self.link.transfer32(word & 0xFFFFFFFF)

    def ping(self, tries=4):
        for _ in range(tries):
            self._x(CMD_PING)
            got = self._x()
            if got == ANS_PONG:
                return True
        raise MonitorError(f'ping answered 0x{got:08X}, not PONG')

    def alive(self):
        """The monitor echoes any word it does not recognise."""
        probe = 0x1234ABCD
        self._x(probe)
        return self._x() == probe

    def write_mem(self, address, words):
        self._x(CMD_WRITE)
        self._x(address)
        self._x(len(words))
        for w in words:
            self._x(w)

    def read_mem(self, address, count):
        self._x(CMD_READ)
        self._x(address)
        self._x(count)
        return [self._x() for _ in range(count)]

    def call(self, address, arg=0, timeout=10.0):
        self._x(CMD_CALL)
        self._x(address)
        self._x(arg)
        end = time.time() + timeout
        while time.time() < end:
            if self._x() == ANS_DONE:
                break
            time.sleep(0.002)
        else:
            raise MonitorError('the payload never came back')
        self._x(CMD_GETR)
        return self._x()

    def reboot(self):
        """Send the console back through its BIOS boot, which with no
        cartridge leaves it waiting for an upload again. This is what makes
        replacing the monitor a software step rather than a power cycle."""
        self._x(CMD_BOOT)
        self._x()

    def run_payload(self, code, arg=0, address=PAYLOAD_ADDRESS):
        """Upload a blob of ARM code, call it, return r0."""
        data = bytearray(code)
        while len(data) % 4:
            data.append(0)
        words = [int.from_bytes(data[i:i + 4], 'little')
                 for i in range(0, len(data), 4)]
        self.write_mem(address, words)
        back = self.read_mem(address, len(words))
        if back != words:
            raise MonitorError('the payload did not read back as written')
        return self.call(address, arg)


def assemble(source_path, out_dir=None):
    """Assemble an ARM payload to a flat blob. Position-independent: the
    monitor loads it wherever it is told to."""
    out_dir = out_dir or os.path.dirname(os.path.abspath(source_path))
    stem = os.path.splitext(os.path.basename(source_path))[0]
    obj = os.path.join(out_dir, stem + '.o')
    elf = os.path.join(out_dir, stem + '.elf')
    binary = os.path.join(out_dir, stem + '.bin')
    subprocess.run(['arm-none-eabi-as', '-mcpu=arm7tdmi', '-o', obj,
                    source_path], check=True)
    subprocess.run(['arm-none-eabi-ld', f'-Ttext={PAYLOAD_ADDRESS:#x}',
                    '-o', elf, obj], check=True)
    subprocess.run(['arm-none-eabi-objcopy', '-O', 'binary', elf, binary],
                   check=True)
    code = open(binary, 'rb').read()
    for scratch in (obj, elf):
        os.remove(scratch)
    return code


def install(image=MONITOR_IMAGE, dev=DEFAULT_DEV, log=print):
    """Upload the monitor. The console must be waiting for an upload: either
    just powered on with no cartridge, or already running a monitor, which
    `reboot` puts back into that state by itself."""
    try:
        with Monitor(dev) as running:
            if running.alive():
                log('a monitor is already running; rebooting it to take an upload')
                running.reboot()
                time.sleep(4.0)      # the BIOS boot splash has to play out
    except OSError:
        pass
    with GBLink(dev) as link:
        link.set_voltage_3v3()
        time.sleep(0.15)
        ok, message = multiboot(link, open(image, 'rb').read(), log=log)
        if not ok:
            return False, message
    # The monitor has its own start-up to do, and the adapter has just been
    # switched out of the shape the upload used; give both room before
    # deciding the upload failed.
    last = None
    for _ in range(5):
        time.sleep(0.5)
        try:
            with Monitor(dev) as m:
                m.ping()
            return True, 'monitor installed and answering'
        except (MonitorError, OSError) as e:
            last = e
    return False, f'uploaded, but {last}'


def main(argv):
    what = argv[1] if len(argv) > 1 else 'ping'
    if what == 'install':
        ok, message = install()
        print(message)
        return 0 if ok else 1
    with Monitor() as m:
        if what == 'ping':
            print('PONG' if m.ping() else 'no answer')
        elif what == 'read':
            address, count = int(argv[2], 0), int(argv[3], 0)
            for i, w in enumerate(m.read_mem(address, count)):
                print(f'{address + i * 4:08X}: {w:08X}')
        elif what == 'reboot':
            m.reboot()
            print('rebooting; the console will be waiting for an upload')
        elif what == 'run':
            code = assemble(argv[2])
            arg = int(argv[3], 0) if len(argv) > 3 else 0
            print(f'r0 = 0x{m.run_payload(code, arg):08X}')
        else:
            print(__doc__)
            return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
