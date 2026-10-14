"""Emulator process wrappers for the playtest harness.

Each emulator runs as a persistent driver process (tools/playtest/drivers)
inside its own environment directory: a symlink to the ROM named game.gba and
whatever battery file (game.sav) the emulator itself writes beside it. No
emulator ever sees another's directory, so saves cannot cross-pollinate
unless the harness copies one across deliberately.
"""
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, 'bin')
DEFAULT_BIOS = os.path.expanduser(os.environ.get(
    'PLAYTEST_BIOS', '~/code/dingbat/tests/roms/gba_bios.bin'))

KEYS = ['A', 'B', 'SELECT', 'START', 'RIGHT', 'LEFT', 'UP', 'DOWN', 'R', 'L']

# name -> (driver binary, uses real BIOS, extra driver flags). The four
# dingbat configurations separate what the HLE BIOS and idle-loop
# fast-forwarding each change: `dingbat` is the shipped default (HLE BIOS,
# waitloop skipping on). The references always run the official BIOS.
EMULATORS = {
    'dingbat':           ('dingbat_driver', False, ()),
    'dingbat-nowl':      ('dingbat_driver', False, ('--no-waitloop',)),
    'dingbat-bios':      ('dingbat_driver', True, ()),
    'dingbat-bios-nowl': ('dingbat_driver', True, ('--no-waitloop',)),
    # the HLE BIOS with Nintendo's image mapped: what a player with a BIOS
    # file installed and the HLE on runs (every frontend passes the file
    # when it exists). The SWIs the HLE leaves to the image run the image's
    # own code; Metroid Fusion hung here and nowhere else (§55)
    'dingbat-hleimg':    ('dingbat_driver', True, ('--hle',)),
    'mgba':              ('mgba_driver', True, ()),
    'nba':               ('nba_driver', True, ()),
}
DINGBAT_CONFIGS = [n for n in EMULATORS if n.startswith('dingbat')]
REFERENCES = ['mgba', 'nba']
ALL = DINGBAT_CONFIGS + REFERENCES
# Played only when asked (`--emus all`, the nightly suite): dingbat-bios-nowl
# checks that waitloop skipping is exact under the official BIOS. It matched
# dingbat-bios in every stored run (2,259 games to 2026-10-14), the skip has
# no BIOS-specific path, and dingbat-nowl keeps the check on the shipped
# default in every run; it cost a sixth of a train.
OCCASIONAL = ['dingbat-bios-nowl']
DEFAULT = [n for n in ALL if n not in OCCASIONAL]


def parse_emus(spec):
    """--emus: a comma list, or `all` for every configuration."""
    return list(ALL) if spec == 'all' else spec.split(',')


def key_mask(keys):
    mask = 0
    for k in keys:
        mask |= 1 << KEYS.index(k.upper())
    return mask


class DriverError(RuntimeError):
    pass


_fresh_checked = set()
ROOT = os.path.dirname(os.path.dirname(HERE))
# What the dingbat driver is built from: the GBA core imports nothing
# outside gba/ and common/ (the DS core and the frontends are not in it)
DRIVER_SOURCES = ('src/dingbat/gba', 'src/dingbat/common', 'tools/playtest/drivers/dingbat_driver.nim',
                  'nim.cfg', 'tools/playtest/build.sh')


def source_sum(root=ROOT):
    """sha1 over the dingbat driver's sources, by path and content."""
    h = hashlib.sha1()
    files = []
    for rel in DRIVER_SOURCES:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            files.append(rel)
        for d, dirs, fs in os.walk(p):
            dirs.sort()
            files += [os.path.relpath(os.path.join(d, f), root) for f in sorted(fs) if not f.startswith('.')]
    for rel in files:
        h.update(rel.encode() + b'\0')
        with open(os.path.join(root, rel), 'rb') as f:
            h.update(hashlib.sha1(f.read()).digest())
    return h.hexdigest()


def check_driver_fresh(path):
    """Refuse a dingbat driver built from other sources than this checkout's:
    a run on a stale bin/ silently tests old code (an HLE comparison on
    2026-10-03 ran a driver from before the commit it was checking). build.sh
    writes the sources' sum beside the binary (<binary>.srcsum); a copy of a
    driver that keeps its stamp stays valid in a checkout of the same
    sources, which modification times could not say (the train's second run
    of base, 2026-10-12, refused every game)."""
    if path in _fresh_checked:
        return
    rebuild = 'rebuild it with `bash tools/playtest/build.sh dingbat_driver dingbat_driver_trace`'
    try:
        built = open(path + '.srcsum').read().strip()
    except OSError:
        raise DriverError(f'{path} has no {os.path.basename(path)}.srcsum: {rebuild}')
    if built != source_sum():
        raise DriverError(f'{path} was built from other sources than this checkout: {rebuild}')
    _fresh_checked.add(path)


class Emulator:
    def __init__(self, name, rom, envdir, bios=DEFAULT_BIOS, rtc_epoch=None,
                 save_in=None, extra_args=(), audio=None):
        """Start `name` on `rom` in a fresh `envdir`. `save_in` seeds the
        emulator's battery file before boot (a copy, never a link). `audio`
        names a file for the raw output (s16le stereo, 32768 Hz)."""
        binary, real_bios, flags = EMULATORS[name]
        self.name = name
        self.envdir = os.path.abspath(envdir)
        if os.path.exists(self.envdir):
            shutil.rmtree(self.envdir)
        os.makedirs(self.envdir)
        self.rom = os.path.join(self.envdir, 'game.gba')
        os.symlink(os.path.abspath(rom), self.rom)
        self.save_path = os.path.join(self.envdir, 'game.sav')
        if save_in:
            shutil.copyfile(save_in, self.save_path)
        path = os.path.join(BIN, binary)
        if binary == 'dingbat_driver':
            # a variant build under test (tools/knobsweep.py) without touching bin/
            path = os.environ.get('PLAYTEST_DINGBAT_DRIVER', path)
            # bin/'s drivers (dingbat_driver_trace included) are this
            # checkout's; a variant build elsewhere is the caller's business
            if os.path.dirname(os.path.abspath(path)) == BIN:
                check_driver_fresh(path)
        cmd = [path, self.rom, bios if real_bios else 'hle']
        if rtc_epoch is not None:
            cmd += ['--rtc', str(rtc_epoch)]
        cmd += list(flags) + list(extra_args)
        self.audio = os.path.abspath(audio) if audio else None
        if audio:
            cmd += ['--audio', self.audio]
        env = dict(os.environ, TZ='UTC')
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(self.envdir, 'stderr.log'), 'w'),
                                     text=True, bufsize=1, env=env, cwd=self.envdir)
        self.frame = 0
        self.held = 0
        self.ready = self._read()
        if not self.ready.startswith('ready'):
            raise DriverError(f'{name}: bad handshake {self.ready!r}')

    def _read(self):
        while True:
            line = self.proc.stdout.readline()
            if not line:
                code = self.proc.wait()
                log = open(os.path.join(self.envdir, 'stderr.log')).read()[-400:]
                raise DriverError(f'{self.name}: driver exited ({code}): {log}')
            line = line.rstrip('\n')
            # a core's own log output can share stdout; protocol replies
            # always start with one of these words
            if line == 'ok' or line.startswith(('ok ', 'err', 'ready')):
                return line

    def cmd(self, line):
        self.proc.stdin.write(line + '\n')
        self.proc.stdin.flush()
        out = self._read()
        if out.startswith('err'):
            raise DriverError(f'{self.name}: {line!r} -> {out}')
        return out[3:] if out.startswith('ok ') else ''

    @property
    def alive(self):
        return self.proc.poll() is None

    def set_keys(self, keys):
        mask = key_mask(keys) if not isinstance(keys, int) else keys
        if mask != self.held:
            self.cmd(f'keys {mask}')
            self.held = mask

    def run(self, n):
        # counted here, not taken from the driver: a state load rewinds the
        # harness's frame count but not the driver's
        if n > 0:
            self.cmd(f'run {n}')
            self.frame += n

    def runhash(self, n):
        hashes = self.cmd(f'runhash {n}').split()
        self.frame += n
        return hashes

    def hash(self):
        return self.cmd('hash')

    def shot(self, path):
        self.cmd(f'shot {os.path.abspath(path)}')
        return path

    def state_save(self, path):
        self.cmd(f'state_save {os.path.abspath(path)}')

    def state_load(self, path):
        self.cmd(f'state_load {os.path.abspath(path)}')

    def quit(self):
        """Shut down the way a user closing the emulator would; the battery
        file is flushed. Returns the save path (may not exist)."""
        if self.alive:
            try:
                self.cmd('quit')
            except DriverError:
                pass
            self.proc.wait(timeout=30)
        return self.save_path

    def kill(self):
        if self.alive:
            self.proc.kill()
            self.proc.wait()


if __name__ == '__main__':
    # build.sh: `emu.py srcsum` prints the driver sources' sum for the stamp
    if sys.argv[1:] == ['srcsum']:
        print(source_sum())
