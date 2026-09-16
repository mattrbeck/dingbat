"""Battery-file analysis: what each emulator wrote, whether the files agree
on format, and (for games with a decoder) whether their contents are valid
and equivalent.

Interchange format: a raw dump of the cartridge's save chip, no header.
Canonical sizes are the chip sizes; some emulators append trailers (an RTC
block, or pad EEPROM/SRAM to a larger size), which other emulators may or
may not accept, so anything beyond the chip size is reported explicitly.
"""
import hashlib
import os
import struct

# ROM ID string -> (chip, canonical sizes)
CHIP_IDS = [
    (b'EEPROM_V', 'EEPROM', (512, 8192)),
    (b'SRAM_F_V', 'SRAM', (32768,)),
    (b'SRAM_V', 'SRAM', (32768,)),
    (b'FLASH1M_V', 'FLASH1M', (131072,)),
    (b'FLASH512_V', 'FLASH512', (65536,)),
    (b'FLASH_V', 'FLASH512', (65536,)),
]


def rom_info(rom_path):
    with open(rom_path, 'rb') as f:
        data = f.read()
    chips = [(name, sizes) for tag, name, sizes in CHIP_IDS if tag in data]
    # every non-EEPROM library named at once: a chipless cart (see dingbat's
    # storage.nim find_storage_type)
    if b'SRAM_V' in data and b'FLASH512_V' in data and b'FLASH1M_V' in data:
        chips = [('none', ())]
    # FLASH_V is a substring match hazard only for FLASH512_V/FLASH1M_V, which
    # are listed first; keep the first hit
    chip, sizes = chips[0] if chips else (None, ())
    return {
        'title': data[0xA0:0xAC].rstrip(b'\0').decode('latin-1'),
        'game_code': data[0xAC:0xB0].decode('latin-1'),
        'chip': chip,
        'canonical_sizes': list(sizes),
        'rtc': b'SIIRTC_V' in data,
    }


def describe(path, rom):
    if not path or not os.path.exists(path):
        return {'exists': False}
    data = open(path, 'rb').read()
    size = len(data)
    canon = rom['canonical_sizes']
    body = next((c for c in sorted(canon, reverse=True) if size >= c), None)
    info = {
        'exists': True, 'size': size, 'sha1': hashlib.sha1(data).hexdigest(),
        'canonical': size in canon,
        'trailer_bytes': size - body if body is not None else None,
        'blank': data.count(b'\xff') == size or data.count(b'\0') == size,
    }
    if size == 0:
        info['blank'] = True
    return info


def diff_ranges(a, b, limit=12):
    """Merged [start, end) ranges where two equal-length byte strings differ."""
    ranges = []
    n = min(len(a), len(b))
    i = 0
    while i < n:
        if a[i] != b[i]:
            j = i
            while j < n and (a[j] != b[j] or (j + 16 < n and a[j:j + 16] != b[j:j + 16])):
                j += 1
            ranges.append([i, j])
            i = j
        else:
            i += 1
    total = sum(e - s for s, e in ranges)
    return {'ranges': [[hex(s), hex(e)] for s, e in ranges[:limit]], 'count': len(ranges), 'bytes': total}


def compare(path_a, path_b, rom):
    a = open(path_a, 'rb').read()
    b = open(path_b, 'rb').read()
    out = {'same_size': len(a) == len(b), 'identical': a == b, 'sizes': [len(a), len(b)]}
    body = min(len(a), len(b))
    canon = [c for c in rom['canonical_sizes'] if c <= body]
    if canon:
        body = max(canon)
    out['chip_body_identical'] = a[:body] == b[:body]
    if a[:body] != b[:body]:
        out['diff'] = diff_ranges(a[:body], b[:body])
    decoder = DECODERS.get(rom['game_code'][:3])
    if decoder:
        da, db = decoder(a), decoder(b)
        out['decoded'] = [da, db]
        out['decoded_equivalent'] = da.get('summary') == db.get('summary') and da.get('valid') and db.get('valid')
    return out


# ------------------------------------------------------------------ decoders
# Pokemon Ruby/Sapphire/Emerald/FireRed/LeafGreen: public save-block layout
# (two 14-section slots of 0x1000 bytes at 0x0000 and 0xE000; each section's
# footer holds id, checksum, signature 0x08012025 and a save counter).

GEN3_SIZES = {0: 3884, 13: 2000}
GEN3_CHARS = {0x00: ' ', 0xAB: '!', 0xAC: '?', 0xAD: '.', 0xAE: '-', 0xFF: ''}
for i in range(10):
    GEN3_CHARS[0xA1 + i] = str(i)
for i in range(26):
    GEN3_CHARS[0xBB + i] = chr(ord('A') + i)
    GEN3_CHARS[0xD5 + i] = chr(ord('a') + i)


def gen3_text(raw):
    out = ''
    for c in raw:
        if c == 0xFF:
            break
        out += GEN3_CHARS.get(c, '?')
    return out


def gen3_slot(data, base):
    sections = {}
    counter = None
    bad = []
    for k in range(14):
        off = base + k * 0x1000
        sec = data[off:off + 0x1000]
        if len(sec) < 0x1000:
            return None
        sid, csum, sig, cnt = struct.unpack_from('<HHII', sec, 0xFF4)
        if sig != 0x08012025:
            return None
        size = GEN3_SIZES.get(sid, 3968)
        words = struct.unpack_from('<%dI' % (size // 4), sec, 0)
        total = sum(words) & 0xFFFFFFFF
        calc = ((total >> 16) + total) & 0xFFFF
        if calc != csum:
            bad.append(sid)
        sections[sid] = sec
        counter = cnt if counter is None else counter
    return {'counter': counter, 'bad_checksums': bad, 'sections': sections}


def decode_gen3(data):
    slots = [s for s in (gen3_slot(data, 0), gen3_slot(data, 0xE000)) if s]
    if not slots:
        return {'valid': False, 'why': 'no slot with a valid signature'}
    good = [s for s in slots if not s['bad_checksums'] and len(s['sections']) == 14]
    if not good:
        return {'valid': False, 'why': f"checksum errors in sections {slots[0]['bad_checksums']}"}
    cur = max(good, key=lambda s: s['counter'])
    t = cur['sections'][0]
    hours, minutes, seconds = struct.unpack_from('<HBB', t, 0x0E)
    # summary = what the player chose (must match across emulators);
    # details = values seeded by timing (RNG, frame counters) that legitimately
    # differ when emulators reach the save on different frames
    summary = {'name': gen3_text(t[0:7]), 'gender': 'girl' if t[8] else 'boy'}
    details = {'trainer_id': struct.unpack_from('<H', t, 0x0A)[0],
               'play_time': f'{hours}:{minutes:02}:{seconds:02}'}
    return {'valid': True, 'slots_valid': len(good), 'save_counter': cur['counter'],
            'summary': summary, 'details': details}


DECODERS = {
    'AXV': decode_gen3, 'AXP': decode_gen3,   # Ruby, Sapphire
    'BPE': decode_gen3,                       # Emerald
    'BPR': decode_gen3, 'BPG': decode_gen3,   # FireRed, LeafGreen
}
