"""Run a probe ROM on a real GBA over a USB link-cable adapter.

The adapter (a GB-Link USB, RP2040) appears as a USB CDC port. Its wire
format is one frame per message:

    'G' 'B' | channel:1 | length:2 little-endian | payload[length]

with channel 0 for commands to the adapter, 1 for link data in both
directions, and 2 for status. Payloads are at most 64 bytes. Commands used
here: 0x00 set mode, 0x0F firmware version, 0x30 transfer timing, 0x40
3.3 V (a GBA needs this; the poll answers 0xFFFFFFFF without it), 0x42 LED.

`multiboot` uploads an image over the link the way the BIOS expects
(GBATEK, "Multiboot"): poll until the GBA answers 0x7202, send the 0xC0-byte
header, swap handshake tokens to derive the session seed, then stream the
rest encrypted, checking the offset the GBA echoes for every word. The image
must be linked at 0x02000000 (EWRAM) and carry a valid header logo.

The GBA only listens for an upload while its BIOS is in the multiboot wait
loop, which means powered on with no cartridge. Once a ROM is running the
poll stops answering 0x7202 and the console has to be power-cycled before
another upload.

After the upload the adapter still clocks the link, so a probe ROM can
answer with its results instead of being photographed: set the GBA to
normal serial mode as the slave and re-arm SIOCNT after every transfer (see
tests/roms/linkecho.s). Re-send the mode and timing commands before reading,
since the upload leaves the adapter configured for its own transfer shape.

    python3 gblink.py info
    python3 gblink.py poll [n]
    python3 gblink.py boot <image.mb.gba>
    python3 gblink.py read [n]        # 32-bit words a running ROM sends back
"""
import os
import select
import sys
import termios
import time

SYNC = b'GB'
CH_COMMAND, CH_DATA, CH_STATUS = 0, 1, 2
CMD_SET_MODE, CMD_FIRMWARE_INFO = 0x00, 0x0F
CMD_TIMING, CMD_3V3, CMD_LED = 0x30, 0x40, 0x42
MODE_LINK = 0x02
MAX_PAYLOAD = 64
# 14 words is 56 bytes, the most that fits a frame without filling it exactly
BATCH_WORDS = 14
DEFAULT_DEV = os.environ.get('GBLINK_DEV', '/dev/cu.usbmodem1102')


class LinkDead(RuntimeError):
    """The adapter is talking but the link to the console is not up."""


class GBLink:
    def __init__(self, dev=DEFAULT_DEV):
        self.fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        a = termios.tcgetattr(self.fd)
        a[0] = a[1] = a[3] = 0                       # raw: no translation
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        self.queues = {CH_DATA: [], CH_STATUS: []}
        self._rx = b''

    def close(self):
        os.close(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    # --- framing ---
    def _write_frame(self, channel, payload):
        if len(payload) > MAX_PAYLOAD:
            raise ValueError('payload too large for one frame')
        frame = (SYNC + bytes([channel, len(payload) & 0xFF,
                               (len(payload) >> 8) & 0xFF]) + payload)
        sent = 0
        while sent < len(frame):
            sent += os.write(self.fd, frame[sent:])

    def _parse(self):
        while True:
            i = self._rx.find(SYNC)
            if i < 0 or len(self._rx) < i + 5:
                return
            channel = self._rx[i + 2]
            length = self._rx[i + 3] | (self._rx[i + 4] << 8)
            if length > MAX_PAYLOAD:       # not a frame start after all
                self._rx = self._rx[i + 2:]
                continue
            if len(self._rx) < i + 5 + length:
                return
            payload = self._rx[i + 5:i + 5 + length]
            self._rx = self._rx[i + 5 + length:]
            if channel in self.queues:
                self.queues[channel].append(payload)

    def read_channel(self, channel, timeout=1.0):
        if self.queues[channel]:
            return self.queues[channel].pop(0)
        end = time.time() + timeout
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [],
                                        max(0, end - time.time()))
            if not ready:
                break
            try:
                chunk = os.read(self.fd, 4096)
            except BlockingIOError:
                continue
            if chunk:
                self._rx += chunk
                self._parse()
                if self.queues[channel]:
                    break
        return self.queues[channel].pop(0) if self.queues[channel] else None

    # --- adapter commands ---
    def command(self, *payload):
        self._write_frame(CH_COMMAND, bytes(payload))

    def firmware_info(self):
        self.command(CMD_FIRMWARE_INFO)
        r = self.read_channel(CH_DATA)
        if r and len(r) >= 4 and r[0] == CMD_FIRMWARE_INFO:
            return (r[1], r[2], r[3])
        return None

    def set_voltage_3v3(self):
        self.command(CMD_3V3)

    def set_mode(self, mode):
        self.command(CMD_SET_MODE, mode)

    def set_timing(self, microseconds, bytes_per_transfer):
        self.command(CMD_TIMING, microseconds & 0xFF,
                     (microseconds >> 8) & 0xFF, (microseconds >> 16) & 0xFF,
                     bytes_per_transfer & 0xFF)

    def led(self, r, g, b, on=True):
        self.command(CMD_LED, r, g, b, 1 if on else 0)

    def open_link(self, tries=40):
        """3.3 V, raw link relay, one 32-bit transfer at a time.

        Bringing the link up is unreliable: measured over 25 cold opens, only
        3 came up. What makes it tractable is that the failure is entirely in
        initialisation -- an open that comes up is then solid, every transfer
        clean -- so the fix is to check and re-issue rather than to slow
        anything down. A dead link reads FFFFFFFF forever; a live one answers
        something else whatever state the console is in (0x7202 from the
        multiboot wait loop, an echo from a running monitor), so one benign
        probe word tells the two apart without knowing which we are talking
        to. Before this, a dead link looked exactly like an absent console,
        which cost a morning of power-cycling a console that was answering
        perfectly well.
        """
        for attempt in range(tries):
            self.set_voltage_3v3()
            time.sleep(0.15)
            self.set_mode(MODE_LINK)
            time.sleep(0.2)
            self.drain_status()
            self.set_timing(36, 4)
            time.sleep(0.05)
            # 0x6202 is the multiboot poll and is not a monitor command, so it
            # is answered or echoed but never acted on
            if any(self.transfer32(0x6202) != 0xFFFFFFFF for _ in range(4)):
                return attempt
        raise LinkDead(f'the link would not come up in {tries} attempts; '
                       'the console reads FFFFFFFF, which is a dead link and '
                       'not necessarily an absent console')

    def drain_status(self, timeout=0.3):
        """Read off whatever the adapter has queued on the status channel."""
        out = []
        while True:
            m = self.read_channel(CH_STATUS, timeout=timeout)
            if m is None:
                return out
            out.append(m)

    # --- link transfers ---
    def transfer32(self, value, timeout=2.0):
        self._write_frame(CH_DATA, value.to_bytes(4, 'big'))
        r = self.read_channel(CH_DATA, timeout)
        return int.from_bytes(r[:4], 'big') if r and len(r) >= 4 else 0

    def transfer32_batch(self, values, timeout=2.0):
        self._write_frame(CH_DATA, b''.join(v.to_bytes(4, 'big') for v in values))
        want = len(values) * 4
        got = b''
        while len(got) < want:
            chunk = self.read_channel(CH_DATA, timeout)
            if not chunk:
                return None
            got += chunk
        return [int.from_bytes(got[i * 4:i * 4 + 4], 'big')
                for i in range(len(values))]


def _crc_step(crc, value):
    for _ in range(32):
        bit = (crc ^ value) & 1
        crc = (crc >> 1) ^ (0xC37B if bit else 0)
        value >>= 1
    return crc


def multiboot(link, image, log=print, poll_limit=3000):
    """Upload a multiboot image. Returns (ok, message)."""
    data = bytearray(image)
    size = len(data)
    if size > 0x40000:
        return False, 'a multiboot image is at most 256 KB'
    if size < 0x1A0:
        return False, 'image too small: the length word would underflow'
    data += bytes(0x10)

    link.set_mode(MODE_LINK)
    time.sleep(0.1)
    link.set_timing(36, 4)

    log('waiting for the GBA (powered on, no cartridge)...')
    for attempt in range(poll_limit):
        if (link.transfer32(0x6202) >> 16) == 0x7202:
            break
        time.sleep(0.01)
    else:
        return False, 'no GBA answered the multiboot poll'
    log('GBA is listening; sending the header')

    link.transfer32(0x6102)
    header = [data[i] | (data[i + 1] << 8) for i in range(0, 0xC0, 2)]
    for i in range(0, len(header), BATCH_WORDS):
        if link.transfer32_batch(header[i:i + BATCH_WORDS]) is None:
            return False, f'header stalled at word {i}'

    link.transfer32(0x6200)
    link.transfer32(0x6202)
    link.transfer32(0x63D1)
    token = link.transfer32(0x63D1)
    if (token >> 24) != 0x73:
        return False, f'handshake token 0x{token:08X}, expected 0x73xxxxxx'

    crc_a = (token >> 16) & 0xFF
    seed = (0xFFFF00D1 | (crc_a << 8)) & 0xFFFFFFFF
    crc_a = (crc_a + 0x0F) & 0xFF
    link.transfer32(0x6400 | crc_a)

    size = (size + 0x0F) & ~0x0F
    crc_b = (link.transfer32((size - 0x190) // 4) >> 16) & 0xFF
    crc_c = 0xC387

    log(f'sending {size} bytes')
    offset = 0xC0
    while offset < size:
        count = min(BATCH_WORDS, (size - offset) // 4)
        words = []
        for w in range(count):
            at = offset + w * 4
            raw = int.from_bytes(data[at:at + 4], 'little')
            crc_c = _crc_step(crc_c, raw)
            seed = (seed * 0x6F646573 + 1) & 0xFFFFFFFF
            words.append((seed ^ raw ^ ((0xFE000000 - at) & 0xFFFFFFFF)
                          ^ 0x43202F2F) & 0xFFFFFFFF)
        got = link.transfer32_batch(words)
        if got is None:
            return False, f'transfer stalled at 0x{offset:X}'
        for w in range(count):
            at = offset + w * 4
            if ((got[w] >> 16) & 0xFFFF) != (at & 0xFFFF):
                return False, (f'the GBA echoed 0x{(got[w] >> 16) & 0xFFFF:04X} '
                               f'at 0x{at:X}, not 0x{at & 0xFFFF:04X}')
        offset += count * 4

    crc_c = _crc_step(crc_c, (0xFFFF0000 | (crc_b << 8) | crc_a) & 0xFFFFFFFF)
    link.transfer32(0x0065)
    while (link.transfer32(0x0065) >> 16) != 0x0075:
        time.sleep(0.01)
    link.transfer32(0x0066)
    link.transfer32(crc_c & 0xFFFF)
    return True, 'upload complete; the GBA is running the image'


REPORT_MAGIC = 0x4C525054          # 'LRPT', see tests/roms/linkreport.inc


def read_report(link, limit=4096):
    """Read a result block from a probe ROM that includes linkreport.inc.

    The ROM streams 'LRPT', a word count, and the block, over and over, so
    listening can start at any moment. The whole block is read twice and the
    copies compared, because the adapter drops a transfer now and then and a
    dropped one would go unnoticed inside a block of numbers."""
    def one():
        for _ in range(limit):
            if link.transfer32(0) == REPORT_MAGIC:
                break
        else:
            return None
        count = link.transfer32(0)
        if not 0 < count <= limit:
            return None
        return [link.transfer32(0) for _ in range(count)]

    first = one()
    if first is None:
        return None, 'no probe is reporting on the link'
    if one() != first:
        return None, 'the block did not read back the same twice'
    return first, f'{len(first)} words'


def boot_and_read(path, words=8, log=print, dev=DEFAULT_DEV):
    """Upload an image, then read back what it sends over the link."""
    with GBLink(dev) as link:
        link.set_voltage_3v3()
        time.sleep(0.15)
        ok, message = multiboot(link, open(path, 'rb').read(), log=log)
        if not ok:
            return None, message
        time.sleep(0.3)
        link.open_link()          # the upload left its own transfer shape
        return [link.transfer32(0) for _ in range(words)], message


def main(argv):
    what = argv[1] if len(argv) > 1 else 'info'
    if what == 'boot':
        values, message = boot_and_read(argv[2],
                                        int(argv[3]) if len(argv) > 3 else 8)
        print(message)
        if values:
            print('  read back: ' + ' '.join(f'{v:08X}' for v in values))
        return 0 if values is not None else 1
    with GBLink() as link:
        if what == 'info':
            print('firmware', link.firmware_info())
        elif what == 'poll':
            link.open_link()
            for k in range(int(argv[2]) if len(argv) > 2 else 8):
                print(f'poll {k}: 0x{link.transfer32(0x6202):08X}')
        elif what == 'read':
            link.open_link()
            for k in range(int(argv[2]) if len(argv) > 2 else 8):
                print(f'read {k}: 0x{link.transfer32(0):08X}')
        elif what == 'report':
            link.open_link()
            values, message = read_report(link)
            print(message)
            if values:
                for i, v in enumerate(values):
                    print(f'  {i:3}: {v:10} (0x{v:08X})')
        else:
            print(__doc__)
            return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
