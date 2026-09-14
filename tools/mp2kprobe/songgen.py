#!/usr/bin/env python3
"""songgen.py -- a tiny assembler for MP2K / M4A ("Sappy") music data.

Builds a SongHeader + track byte-code + voicegroup (tone table) + WaveData
sample blobs into ONE relocatable binary blob for a given ROM base address,
so that a synthetic "probe song" can be injected into a real game and played
by Nintendo's own driver under emulation (ground truth for our audio HLE).

Provenance
----------
Every format detail here is derived from public documentation only:

  [1] loveemu, "Summary of GBA standard sound driver (MusicPlayer2000)",
      https://loveemu.github.io/vgmdocs/Summary_of_GBA_Standard_Sound_Driver_MusicPlayer2000.html
      -- the sequence command table (0x00-0xFF), the 48-entry note length
      table, MEMACC, tempo = BPM/2, PPQN 24, pan 0/64/127, and the note that
      samples are 8-bit signed PCM (opposite sign to Microsoft WAVE).

  [2] Bregalad (with later additions by ipatix), 'GBA "Sappy" sound engine
      information', v1.3/v1.4, romhacking.net document #462 -- designated by
      [1] as *the* specification ("Almost everything is explained in the
      following document").  Source of: the 12-byte instrument definition,
      the instrument type bytes, the 16-byte sample header, the
      pitch = 1024 * mid-C-sample-rate relation, the song header layout, the
      argument-omission / "repeat last repeatable command" rules, and the
      sound driver operation-mode word.

  [3] GBATEK (Martin Korth) -- GBA memory map (ROM is mapped at 0x08000000, so
      every stored pointer is an absolute address with bit 27 set) and the
      sound driver operation mode bitfield, which [2] Appendix A reproduces.

No emulator source, no music-player source, and no Nintendo decompilation was
consulted.  A few details are NOT covered by [1]/[2] and are implemented from
this project's own emulator interface facts; each is marked "PROJECT FACT"
below and listed as an open ambiguity in the module's AMBIGUITIES string:
the extended voice type bits 0x10/0x20 and the BDPCM compressed wave codec.

Stdlib only, Python 3.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys

# --------------------------------------------------------------------------
# Constants from the documentation
# --------------------------------------------------------------------------

# [1]: const u8 noteLengthTable[48].  Index i is reachable as wait command
# 0x81+i and as note command 0xD0+i.  0x80 is W00 == "wait zero time" ([2]).
NOTE_LENGTH_TABLE = (
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 28, 30, 32, 36, 40, 42, 44, 48,
    52, 54, 56, 60, 64, 66, 68, 72, 76, 78, 80, 84, 88, 90, 92, 96,
)
_LEN_INDEX = {n: i for i, n in enumerate(NOTE_LENGTH_TABLE)}

# [1] sequence command opcodes.
OP_WAIT0 = 0x80          # W00 .. W96 == 0x80 .. 0xB0
OP_FINE = 0xB1
OP_GOTO = 0xB2
OP_PATT = 0xB3
OP_PEND = 0xB4
OP_REPT = 0xB5
OP_MEMACC = 0xB9
OP_PRIO = 0xBA
OP_TEMPO = 0xBB
OP_KEYSH = 0xBC
OP_VOICE = 0xBD
OP_VOL = 0xBE
OP_PAN = 0xBF
OP_BEND = 0xC0
OP_BENDR = 0xC1
OP_LFOS = 0xC2
OP_LFODL = 0xC3
OP_MOD = 0xC4
OP_MODT = 0xC5
OP_TUNE = 0xC8
OP_XCMD = 0xCD
OP_EOT = 0xCE
OP_TIE = 0xCF
OP_NOTE0 = 0xD0          # N01 .. N96 == 0xD0 .. 0xFF

XCMD_ECHO_VOL = 0x08     # xIECV
XCMD_ECHO_LEN = 0x09     # xIECL

# [2] 2.1, instrument type byte.
VOICE_DIRECT = 0x00      # DirectSound sample, resampled to the note's pitch
VOICE_SQUARE1 = 0x01
VOICE_SQUARE2 = 0x02
VOICE_WAVE = 0x03
VOICE_NOISE = 0x04
VOICE_DIRECT_FIXED = 0x08  # DirectSound, never resampled (plays at engine rate)
VOICE_KEYSPLIT = 0x40
VOICE_DRUMS = 0x80

# Type *bits* that may be OR-ed onto a DirectSound voice.
TYPE_FIXED = 0x08        # [2]: type 0x08, "never resampled"
TYPE_REVERSED = 0x10     # PROJECT FACT -- not in [1]/[2]
TYPE_COMPRESSED = 0x20   # PROJECT FACT -- not in [1]/[2] (BDPCM, Pokemon-style)
TYPE_KEYSPLIT = 0x40     # [2] 2.4
TYPE_DRUMS = 0x80        # [2] 2.5

# [2] section 6, the 16-byte sample header.
WAVE_TYPE_PCM = 0
WAVE_TYPE_COMPRESSED = 1   # PROJECT FACT -- BDPCM; [2] documents PCM only.
WAVE_FLAG_LOOP = 0x4000    # [2]: header byte 3 is 0x00 unlooped / 0x40 looped,
                           # i.e. the u16 at offset 2 is 0x0000 / 0x4000.

# [2] Appendix A / [3]: the engine's selectable DirectSound mixing rates.
ENGINE_RATES = (
    5734, 7884, 10512, 13379, 15768, 18157,
    21024, 26758, 31536, 36314, 40137, 42048,
)
DEFAULT_RATE = 13379       # [1]/[2]: engine default (mode field value 4)

MIDDLE_C_KEY = 60          # "mid-C" in [2]; MIDI key 60.
PPQN = 24                  # [1]: "PPQN is 24"; a length of 96 is a whole note.

# "raw" (no ADSR) envelope, [2] 2.2: attack 0xFF, decay 0x00, sustain 0xFF,
# release 0x00.
ADSR_RAW = (0xFF, 0x00, 0xFF, 0x00)

AMBIGUITIES = """\
Open questions the docs do not settle (to be resolved empirically by running
the real driver -- see PROBES.md):

 A1. WaveData `size` / `loopStart` bias.  [2] section 6 says the header holds
     "Loop relative starting point *minus one*" and "Size of the sample
     *minus one*", but this project's emulator interface treats both as plain
     sample counts/indices.  songgen defaults to the plain reading
     (size_bias=0, loop_bias=0) and always appends one guard sample after the
     data, which satisfies both readings for playback.  Pass --bias to emit
     Bregalad's minus-one reading instead and A/B the two in the driver.

 A2. BDPCM (compressed wave) is a PROJECT FACT, absent from [1] and [2].
     [1] only notes that the Pokemon series "uses compressed samples".  The
     33-byte/64-sample block layout, the skipped first high nibble, and the
     n<8 -> +n**2 / n>=8 -> -(16-n)**2 delta table are implemented exactly as
     specified by this project's emulator interface.  Probe P8 (a compressed
     sample against its PCM twin) is the check.

 A3. Voice type bits 0x10 (reversed) and 0x20 (compressed) are PROJECT FACTs.
     [2] 2.1 documents only 0x00, 0x08, 0x40, 0x80 and says "anything else =
     invalid (the engine crashes)" -- true of the stock driver, so a probe
     using them needs a host game with the extended driver.  Probe P9.

 A4. Loop alignment for compressed waves is unspecified.  songgen asserts
     loop_start % 64 == 0, since a BDPCM block is self-contained only at a
     block boundary.  Unverified.

 A5. Note gate-time (the optional 3rd argument).  [2] says it "is directly
     added to the length from the lookup table"; [1] calls it "fine adjustment
     of gate time".  songgen implements ADD.  If the driver instead replaces
     the length, notes with a non-table length will be wrong -- detectable in
     probe P3.

 A6. VOICE (0xBD) repeatability.  [1]'s table marks VOICE "Repeatable: Yes";
     [2] says "set instrument (1 byte). Non repeatable."  songgen never uses
     running status (it always emits an explicit opcode + arguments), so the
     conflict cannot bite; noted only for completeness.

 A7. SongHeader byte 1 ("blockCount" here) is "Unknown" in [2] and absent from
     [1].  songgen writes 0, which is what real songs appear to use.

 A8. The reverb byte's low 7 bits are only consulted when bit 7 is set ([2]),
     and reverb is global to all DirectSound channels.  Whether a song header
     reverb of 0x80 (apply, amount 0) actually clears a previously set global
     value is untested -- probe P6.

 A9. TUNE (0xC8) range.  [1] says "0: one semitone lower ... 127: one semitone
     higher"; [2] says "0x00 is two semitones lower and 0x7F is two semitones
     higher".  songgen passes the raw byte through and takes no position;
     probe P4 settles it.
"""


# --------------------------------------------------------------------------
# Pitch helpers
# --------------------------------------------------------------------------

def pitch_from_rate(hz):
    """[2] section 6: "Pitch adj = 1024 * sample-rate for Mid-C".

    Cross-check against [2]'s own table: 1024 * 13379 == 0xD10C00.
    """
    v = int(round(1024.0 * hz))
    if not 0 <= v <= 0xFFFFFFFF:
        raise ValueError("pitch out of range for rate %r Hz" % (hz,))
    return v


def rate_from_pitch(pitch):
    """Inverse of pitch_from_rate()."""
    return pitch / 1024.0


def pitch_for_single_cycle_loop(loop_len_samples):
    """[2] section 6 shortcut: when the loop is exactly one oscillation,
    pitch = 267905 * (loop_end - loop_start)."""
    return 267905 * loop_len_samples


# --------------------------------------------------------------------------
# BDPCM codec (PROJECT FACT -- see AMBIGUITIES A2)
# --------------------------------------------------------------------------

BDPCM_BLOCK_SAMPLES = 64
BDPCM_BLOCK_BYTES = 33      # 1 raw s8 base byte + 32 nibble bytes

# nibble n: n < 8 -> +n**2, n >= 8 -> -(16-n)**2
BDPCM_DELTA_TABLE = tuple(
    (n * n) if n < 8 else -((16 - n) * (16 - n)) for n in range(16)
)


def _wrap_s8(v):
    """8-bit signed wraparound."""
    return ((int(v) + 128) & 0xFF) - 128


def bdpcm_encode(samples):
    """Encode signed 8-bit samples to BDPCM.

    Layout per 33-byte block (64 samples):
      byte 0            raw s8: sample 0 of the block
      bytes 1..32       64 nibbles, high nibble of a byte before its low one
      nibble 0          UNUSED (the high nibble of byte 1) -- written as 0
      nibble k (k>=1)   the delta producing sample k

    The input is zero-padded to a whole number of blocks.  Encoding is greedy:
    each nibble is the one whose delta lands the wrapping accumulator nearest
    the target sample.
    """
    s = [_wrap_s8(x) for x in samples]
    if len(s) % BDPCM_BLOCK_SAMPLES:
        s += [0] * (BDPCM_BLOCK_SAMPLES - len(s) % BDPCM_BLOCK_SAMPLES)

    out = bytearray()
    for base in range(0, len(s), BDPCM_BLOCK_SAMPLES):
        block = s[base:base + BDPCM_BLOCK_SAMPLES]
        out.append(block[0] & 0xFF)
        nibbles = [0] * BDPCM_BLOCK_SAMPLES   # nibble 0 is unused
        acc = block[0]
        for k in range(1, BDPCM_BLOCK_SAMPLES):
            target = block[k]
            best_n, best_err, best_acc = 0, None, acc
            for n, d in enumerate(BDPCM_DELTA_TABLE):
                cand = _wrap_s8(acc + d)
                err = abs(cand - target)
                if best_err is None or err < best_err:
                    best_n, best_err, best_acc = n, err, cand
                    if err == 0:
                        break
            nibbles[k] = best_n
            acc = best_acc
        for i in range(0, BDPCM_BLOCK_SAMPLES, 2):
            out.append(((nibbles[i] & 0xF) << 4) | (nibbles[i + 1] & 0xF))
    return bytes(out)


def bdpcm_decode(data, count=None):
    """Decode BDPCM back to signed 8-bit samples (inverse of bdpcm_encode)."""
    if len(data) % BDPCM_BLOCK_BYTES:
        raise ValueError("BDPCM stream is not a whole number of 33-byte blocks")
    out = []
    for base in range(0, len(data), BDPCM_BLOCK_BYTES):
        blk = data[base:base + BDPCM_BLOCK_BYTES]
        acc = _wrap_s8(blk[0])
        out.append(acc)
        for k in range(1, BDPCM_BLOCK_SAMPLES):
            byte = blk[1 + (k >> 1)]
            nib = (byte >> 4) if (k & 1) == 0 else (byte & 0xF)
            acc = _wrap_s8(acc + BDPCM_DELTA_TABLE[nib])
            out.append(acc)
    if count is not None:
        out = out[:count]
    return out


# --------------------------------------------------------------------------
# Wave generators
# --------------------------------------------------------------------------

def wave_dc(value=64, count=64):
    """Constant (DC) sample -- the workhorse probe wave: whatever comes out of
    the mixer is the driver's gain chain and nothing else."""
    return [_wrap_s8(value)] * int(count)


def wave_impulse(count=64, pos=0, amp=127):
    """A single non-zero sample; everything else silent.  Reveals the
    resampling kernel and the note-on alignment."""
    s = [0] * int(count)
    s[int(pos)] = _wrap_s8(amp)
    return s


def wave_sine(cycle_len, cycles=1, amp=127, phase=0.0):
    """`cycles` periods of a sine, `cycle_len` samples per period."""
    n = int(cycle_len) * int(cycles)
    return [_wrap_s8(round(amp * math.sin(2.0 * math.pi
                                          * ((i / float(cycle_len)) + phase))))
            for i in range(n)]


def wave_saw(cycle_len, cycles=1, amp=127):
    """Rising sawtooth from -amp to +amp, `cycle_len` samples per period."""
    n = int(cycle_len) * int(cycles)
    out = []
    for i in range(n):
        frac = (i % int(cycle_len)) / float(cycle_len)
        out.append(_wrap_s8(round(-amp + 2.0 * amp * frac)))
    return out


def wave_noise(count=64, seed=1, amp=127):
    """Deterministic pseudo-noise (xorshift32), so a probe is reproducible."""
    x = int(seed) & 0xFFFFFFFF or 1
    out = []
    for _ in range(int(count)):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= (x >> 17)
        x ^= (x << 5) & 0xFFFFFFFF
        x &= 0xFFFFFFFF
        out.append(_wrap_s8(round(amp * (((x >> 8) & 0xFF) - 127.5) / 127.5)))
    return out


def wave_from_raw_s8(path):
    """Load a headerless signed-8-bit PCM file.  Note [1]: MP2K samples are
    signed, the opposite sign convention to Microsoft WAVE."""
    with open(path, "rb") as fh:
        return [_wrap_s8(b if b < 128 else b - 256) for b in fh.read()]


# --------------------------------------------------------------------------
# Wave (sample) object
# --------------------------------------------------------------------------

class Wave(object):
    """One WaveData blob: 16-byte header ([2] section 6) + sample bytes.

        u16 type        0 = PCM, 1 = compressed (BDPCM)
        u16 flags       0x4000 = looped
        u32 freq        1024 * the sample's playback rate at MIDI key 60
        u32 loopStart   sample index the loop returns to
        u32 size        number of samples
        s8  data[size]  (+ one guard sample; see AMBIGUITIES A1)
    """

    def __init__(self, samples, sample_rate=DEFAULT_RATE, loop_start=None,
                 compressed=False, name=None, freq=None):
        self.samples = [_wrap_s8(x) for x in samples]
        if not self.samples:
            raise ValueError("a Wave needs at least one sample")
        self.sample_rate = sample_rate
        self.freq = pitch_from_rate(sample_rate) if freq is None else int(freq)
        self.loop_start = loop_start
        self.compressed = bool(compressed)
        self.name = name or ("wave@%d" % id(self))

        if loop_start is not None:
            if not 0 <= loop_start < len(self.samples):
                raise ValueError("loop_start %d outside the sample" % loop_start)
            if self.compressed and loop_start % BDPCM_BLOCK_SAMPLES:
                # AMBIGUITIES A4
                raise ValueError(
                    "a compressed wave's loop_start must be a multiple of %d"
                    % BDPCM_BLOCK_SAMPLES)

    @property
    def looped(self):
        return self.loop_start is not None

    def payload(self):
        """The sample bytes as stored, including the trailing guard sample."""
        if self.compressed:
            body = bdpcm_encode(self.samples)
            # The guard sample of a compressed wave is implicit: encoding pads
            # the last block with zeroes, so there is always at least one byte
            # of slack past `size`.  Add a whole block only if it divided evenly.
            if len(self.samples) % BDPCM_BLOCK_SAMPLES == 0:
                body += bytes(BDPCM_BLOCK_BYTES)
            return body
        guard = self.samples[self.loop_start] if self.looped else 0
        return bytes((x & 0xFF) for x in self.samples + [guard])

    def header(self, size_bias=0, loop_bias=0):
        wtype = WAVE_TYPE_COMPRESSED if self.compressed else WAVE_TYPE_PCM
        flags = WAVE_FLAG_LOOP if self.looped else 0
        # AMBIGUITIES A1: the biases let a probe emit Bregalad's "minus one"
        # reading.  A loop start of 0 has no minus-one form, so it stays 0
        # rather than underflowing to 0xFFFFFFFF.
        loop = self.loop_start or 0
        if loop > 0:
            loop = max(0, loop + loop_bias)
        size = len(self.samples) + size_bias
        if size < 0:
            raise ValueError("size_bias %d underflows a %d-sample wave"
                             % (size_bias, len(self.samples)))
        return struct.pack("<HHIII", wtype, flags, self.freq,
                           loop & 0xFFFFFFFF, size & 0xFFFFFFFF)

    def encode(self, size_bias=0, loop_bias=0):
        return self.header(size_bias, loop_bias) + self.payload()


# --------------------------------------------------------------------------
# Voicegroup (tone table)
# --------------------------------------------------------------------------

class _Voice(object):
    """One 12-byte instrument definition ([2] 2.1/2.2/2.3)."""

    __slots__ = ("type_byte", "base_key", "length", "pan", "wave", "word",
                 "attack", "decay", "sustain", "release")

    def __init__(self, type_byte, base_key, length, pan, wave, word,
                 attack, decay, sustain, release):
        self.type_byte = type_byte & 0xFF
        self.base_key = base_key & 0xFF
        self.length = length & 0xFF
        self.pan = pan & 0xFF
        self.wave = wave            # a Wave, or None when `word` is used
        self.word = word            # literal u32 when there is no wave pointer
        self.attack = attack & 0xFF
        self.decay = decay & 0xFF
        self.sustain = sustain & 0xFF
        self.release = release & 0xFF


class Voicegroup(object):
    """A tone table: an array of 12-byte instrument definitions."""

    def __init__(self):
        self.voices = []

    def __len__(self):
        return len(self.voices)

    def _add(self, v):
        self.voices.append(v)
        return len(self.voices) - 1

    def direct_sound(self, wave, attack=0xFF, decay=0x00, sustain=0xFF,
                     release=0x00, type_bits=0, base_key=MIDDLE_C_KEY, pan=0):
        """A DirectSound (sampled) voice, [2] 2.2.

        `type_bits` may OR in TYPE_FIXED / TYPE_REVERSED / TYPE_COMPRESSED.
        The default envelope is [2]'s "raw" (no ADSR) setting.
        Returns the voice's index, for use with Track.voice().
        """
        if not isinstance(wave, Wave):
            raise TypeError("direct_sound() needs a Wave")
        if wave.compressed and not (type_bits & TYPE_COMPRESSED):
            raise ValueError("a compressed Wave needs type_bits=TYPE_COMPRESSED")
        if (type_bits & TYPE_COMPRESSED) and not wave.compressed:
            raise ValueError("TYPE_COMPRESSED set but the Wave is plain PCM")
        if type_bits & ~(TYPE_FIXED | TYPE_REVERSED | TYPE_COMPRESSED):
            raise ValueError("type_bits %#x is not a DirectSound bit" % type_bits)
        return self._add(_Voice(VOICE_DIRECT | type_bits, base_key, 0, pan,
                                wave, None, attack, decay, sustain, release))

    def psg_square(self, channel=1, duty=2, attack=0, decay=0, sustain=0x0F,
                   release=0, base_key=0, length=0, sweep=0x08):
        """A PSG square voice ([2] 2.3).  `sweep` 0x08 disables the sweep,
        which matters only on channel 1."""
        if channel not in (1, 2):
            raise ValueError("square channel must be 1 or 2")
        return self._add(_Voice(channel, base_key, length, sweep,
                                None, duty & 0xFF, attack, decay, sustain,
                                release))

    def psg_noise(self, period=0, attack=0, decay=0, sustain=0x0F, release=0,
                  base_key=0, length=0):
        """A PSG noise voice ([2] 2.3): period 0 = normal, 1 = metallic."""
        return self._add(_Voice(VOICE_NOISE, base_key, length, 0,
                                None, period & 0xFF, attack, decay, sustain,
                                release))

    def raw(self, twelve_bytes):
        """An escape hatch: 12 literal bytes, no pointer relocation."""
        b = bytes(twelve_bytes)
        if len(b) != 12:
            raise ValueError("a voice is exactly 12 bytes")
        return self._add(_Voice(b[0], b[1], b[2], b[3], None,
                                struct.unpack("<I", b[4:8])[0],
                                b[8], b[9], b[10], b[11]))

    def unused(self):
        """[2] 2.6: the canonical 'unused instrument' filler."""
        return self.raw(bytes((0x01, 0x3C, 0x00, 0x00, 0x02, 0x00,
                               0x00, 0x00, 0x00, 0x00, 0x0F, 0x00)))


# --------------------------------------------------------------------------
# Track byte-code
# --------------------------------------------------------------------------

def _u8(name, v, lo=0, hi=127):
    v = int(v)
    if not lo <= v <= hi:
        raise ValueError("%s must be %d..%d, got %d" % (name, lo, hi, v))
    return v


def split_wait(ticks):
    """Express `ticks` as a list of wait-command lengths.

    [1]'s table tops out at 96, so longer rests become several W commands.
    Greedy: take the largest table entry that fits, and make sure the
    remainder is itself representable (every value 1..96 is in the table or is
    reachable by a further split, since 1..24 are all present).
    """
    ticks = int(ticks)
    if ticks < 0:
        raise ValueError("negative wait")
    out = []
    while ticks > 0:
        pick = None
        for n in reversed(NOTE_LENGTH_TABLE):
            if n <= ticks:
                pick = n
                break
        # Avoid stranding a remainder that is not in the table: every value
        # 1..24 is, so any leftover below 25 is always emittable.
        if pick is None:
            raise ValueError("cannot express a wait of %d ticks" % ticks)
        out.append(pick)
        ticks -= pick
    return out


def encode_note_length(ticks):
    """Return (table_index, gate_extra) for a note of `ticks` ticks.

    [2]: the optional 3rd note argument "is directly added to the length from
    the lookup table" (see AMBIGUITIES A5), so a length off the table is the
    largest table entry <= ticks plus a gate remainder of at most 127.
    """
    ticks = int(ticks)
    if ticks < 1:
        raise ValueError("a note must last at least 1 tick")
    idx = None
    for i in range(len(NOTE_LENGTH_TABLE) - 1, -1, -1):
        if NOTE_LENGTH_TABLE[i] <= ticks:
            idx = i
            break
    if idx is None:
        raise ValueError("note length %d is below the table" % ticks)
    extra = ticks - NOTE_LENGTH_TABLE[idx]
    if extra > 127:
        raise ValueError(
            "note length %d needs a gate of %d (>127); use tie()/eot() for "
            "notes longer than %d ticks"
            % (ticks, extra, NOTE_LENGTH_TABLE[-1] + 127))
    return idx, extra


class Track(object):
    """One sequence track.  Commands are emitted explicitly -- songgen never
    uses the 0x00-0x7F "repeat the last repeatable command" running status
    ([1]/[2]), because an omitted argument would make a probe's meaning depend
    on driver state we are trying to measure."""

    def __init__(self, name=None):
        self.data = bytearray()
        self.name = name
        self._labels = {}          # label -> offset within this track
        self._fixups = []          # (offset within track, label)
        self._ticks = 0            # running tick count, for probe bookkeeping

    # -- raw emission ------------------------------------------------------
    def raw(self, *vals):
        for v in vals:
            self.data.append(int(v) & 0xFF)
        return self

    def label(self, name):
        if name in self._labels:
            raise ValueError("duplicate label %r" % name)
        self._labels[name] = len(self.data)
        return self

    def _ptr(self, label):
        self._fixups.append((len(self.data), label))
        self.data.extend(b"\0\0\0\0")

    # -- timing ------------------------------------------------------------
    def wait(self, ticks):
        """W00..W96.  Splits lengths above 96 into several commands."""
        ticks = int(ticks)
        if ticks == 0:
            self.data.append(OP_WAIT0)          # W00, "a musical NOP" [2]
            return self
        for n in split_wait(ticks):
            self.data.append(OP_WAIT0 + 1 + _LEN_INDEX[n])
            self._ticks += n
        return self

    def note(self, key, velocity=127, ticks=24, gate=None):
        """N01..N96 + key [+ velocity [+ gate]].

        A length that is not in the table is emitted as the nearest lower
        table entry plus a gate remainder ([2]; AMBIGUITIES A5).
        """
        idx, extra = encode_note_length(ticks)
        if gate is not None:
            extra = _u8("gate", gate)
        self.data.append(OP_NOTE0 + idx)
        self.data.append(_u8("key", key))
        self.data.append(_u8("velocity", velocity))
        if extra:
            self.data.append(extra)
        return self

    def tie(self, key, velocity=127):
        """TIE (0xCF): note on, length undetermined until EOT ([1])."""
        self.data.append(OP_TIE)
        self.data.append(_u8("key", key))
        self.data.append(_u8("velocity", velocity))
        return self

    def eot(self, key=None):
        """EOT (0xCE): tie end / note off.  With no key, all tied notes."""
        self.data.append(OP_EOT)
        if key is not None:
            self.data.append(_u8("key", key))
        return self

    # -- control -----------------------------------------------------------
    def tempo(self, bpm):
        """TEMPO (0xBB) stores half the BPM ([1]); 75 means 1 tick/frame."""
        half = int(round(bpm / 2.0))
        if not 11 <= half <= 255:
            raise ValueError("tempo/2 must be 11..255, got %d" % half)
        return self.raw(OP_TEMPO, half)

    def voice(self, n):
        return self.raw(OP_VOICE, _u8("voice", n, 0, 255))

    def vol(self, v):
        return self.raw(OP_VOL, _u8("vol", v))

    def pan(self, v):
        """PAN (0xBF): 0 left, 64 centre, 127 right ([1]/[2])."""
        return self.raw(OP_PAN, _u8("pan", v))

    def pan_signed(self, v):
        """Convenience: -64 (left) .. 0 (centre) .. +63 (right)."""
        return self.pan(_u8("pan", v + 64, 0, 127))

    def prio(self, v):
        return self.raw(OP_PRIO, _u8("prio", v, 0, 255))

    def keysh(self, semitones):
        """KEYSH (0xBC): the one command taking a signed argument ([2])."""
        v = int(semitones)
        if not -128 <= v <= 127:
            raise ValueError("keysh must be -128..127")
        return self.raw(OP_KEYSH, v & 0xFF)

    def bend(self, v=64):
        return self.raw(OP_BEND, _u8("bend", v))

    def bendr(self, semitones=2):
        return self.raw(OP_BENDR, _u8("bendr", semitones))

    def lfos(self, v):
        return self.raw(OP_LFOS, _u8("lfos", v))

    def lfodl(self, ticks):
        return self.raw(OP_LFODL, _u8("lfodl", ticks))

    def mod(self, depth):
        return self.raw(OP_MOD, _u8("mod", depth))

    def modt(self, kind):
        """MODT (0xC5): 0 pitch, 1 volume, 2 pan ([1])."""
        return self.raw(OP_MODT, _u8("modt", kind, 0, 2))

    def tune(self, v=64):
        return self.raw(OP_TUNE, _u8("tune", v))

    def xcmd(self, sub, value):
        return self.raw(OP_XCMD, _u8("xcmd sub", sub, 0, 255),
                        _u8("xcmd value", value))

    def echo_vol(self, v):
        """XCMD xIECV ([1], 0xCD 0x08)."""
        return self.xcmd(XCMD_ECHO_VOL, v)

    def echo_len(self, frames):
        """XCMD xIECL ([1], 0xCD 0x09), in frames (xx/60 s)."""
        return self.xcmd(XCMD_ECHO_LEN, frames)

    def memacc(self, mem_set, adr, dat, dest=None):
        """MEMACC (0xB9); `dest` (a label) only for the branch forms ([1])."""
        self.raw(OP_MEMACC, _u8("mem_set", mem_set, 0, 17),
                 _u8("adr", adr, 0, 255), _u8("dat", dat, 0, 255))
        if dest is not None:
            self._ptr(dest)
        return self

    # -- flow --------------------------------------------------------------
    def goto(self, label):
        self.data.append(OP_GOTO)
        self._ptr(label)
        return self

    def patt(self, label):
        """PATT (0xB3): subroutine call; [2] warns calls cannot nest."""
        self.data.append(OP_PATT)
        self._ptr(label)
        return self

    def pend(self):
        return self.raw(OP_PEND)

    def rept(self, count, label):
        """REPT (0xB5): u8 count then the destination ([1])."""
        self.data.append(OP_REPT)
        self.data.append(_u8("rept count", count, 0, 255))
        self._ptr(label)
        return self

    def fine(self):
        return self.raw(OP_FINE)


# --------------------------------------------------------------------------
# Song + builder
# --------------------------------------------------------------------------

class Song(object):
    """SongHeader ([2] 7b):

        u8  trackCount
        u8  blockCount   (unknown in [2]; 0 -- AMBIGUITIES A7)
        u8  priority
        u8  reverb       (bit 7 set = apply, low 7 bits = amount)
        u32 voicegroup
        u32 track[trackCount]
    """

    def __init__(self, reverb=None, priority=0, blocks=0, voicegroup=None):
        self.tracks = []
        self.voicegroup = voicegroup if voicegroup is not None else Voicegroup()
        self.priority = priority & 0xFF
        self.blocks = blocks & 0xFF
        if reverb is None:
            self.reverb = 0x00                      # bit 7 clear: leave global
        else:
            self.reverb = 0x80 | _u8("reverb", reverb)

    def track(self, name=None):
        t = Track(name)
        self.tracks.append(t)
        return t

    def add_track(self, t):
        self.tracks.append(t)
        return t


def _align4(blob):
    while len(blob) & 3:
        blob.append(0)


def build(song, base_addr, size_bias=0, loop_bias=0):
    """Assemble `song` into one blob to be placed at `base_addr`.

    Returns (blob_bytes, header_addr).  The header is first, so
    header_addr == base_addr.  Every stored pointer is base_addr + offset;
    [2] notes that ROM pointers are absolute addresses (ROM is mapped at
    0x08000000 per [3]), so pass the real target address here.

    Layout: header | voicegroup | wave headers+data | track byte-code.
    Each struct is 4-byte aligned; [2] 7a notes track data alone need not be.
    """
    if not song.tracks:
        raise ValueError("a song needs at least one track")
    if len(song.tracks) > 255:
        raise ValueError("too many tracks")
    if base_addr & 3:
        raise ValueError("base_addr must be 4-byte aligned")

    blob = bytearray()
    wave_off = {}        # id(Wave) -> offset

    # 1) header (placeholders for the pointers)
    header_off = 0
    blob += struct.pack("<BBBB", len(song.tracks), song.blocks,
                        song.priority, song.reverb)
    vg_ptr_off = len(blob)
    blob += b"\0\0\0\0"
    track_ptr_off = len(blob)
    blob += b"\0\0\0\0" * len(song.tracks)
    _align4(blob)

    # 2) voicegroup (patched once the waves are placed)
    _align4(blob)
    vg_off = len(blob)
    vg_wave_fixups = []
    for v in song.voicegroup.voices:
        blob += struct.pack("<BBBB", v.type_byte, v.base_key, v.length, v.pan)
        if v.wave is not None:
            vg_wave_fixups.append((len(blob), v.wave))
            blob += b"\0\0\0\0"
        else:
            blob += struct.pack("<I", (v.word or 0) & 0xFFFFFFFF)
        blob += struct.pack("<BBBB", v.attack, v.decay, v.sustain, v.release)

    # 3) waves (deduplicated by identity)
    for v in song.voicegroup.voices:
        if v.wave is None or id(v.wave) in wave_off:
            continue
        _align4(blob)
        wave_off[id(v.wave)] = len(blob)
        blob += v.wave.encode(size_bias, loop_bias)

    # 4) tracks
    track_offs = []
    for t in song.tracks:
        _align4(blob)
        off = len(blob)
        track_offs.append(off)
        blob += t.data
        for at, label in t._fixups:
            if label not in t._labels:
                raise ValueError("track %r references undefined label %r"
                                 % (t.name, label))
            target = base_addr + off + t._labels[label]
            struct.pack_into("<I", blob, off + at, target & 0xFFFFFFFF)

    _align4(blob)

    # 5) patch the header and voicegroup pointers
    struct.pack_into("<I", blob, vg_ptr_off, (base_addr + vg_off) & 0xFFFFFFFF)
    for i, off in enumerate(track_offs):
        struct.pack_into("<I", blob, track_ptr_off + 4 * i,
                         (base_addr + off) & 0xFFFFFFFF)
    for at, wave in vg_wave_fixups:
        struct.pack_into("<I", blob, at,
                         (base_addr + wave_off[id(wave)]) & 0xFFFFFFFF)

    return bytes(blob), base_addr + header_off


# --------------------------------------------------------------------------
# A minimal reader, used by --selftest (and handy for eyeballing a blob)
# --------------------------------------------------------------------------

def parse_header(blob, base_addr, at=0):
    """Read a SongHeader back out of a blob.  Returns a dict of offsets."""
    ntr, blocks, prio, reverb = struct.unpack_from("<BBBB", blob, at)
    (vg,) = struct.unpack_from("<I", blob, at + 4)
    trks = list(struct.unpack_from("<%dI" % ntr, blob, at + 8))
    return {
        "track_count": ntr, "blocks": blocks, "priority": prio,
        "reverb": reverb, "voicegroup": vg, "tracks": trks,
        "voicegroup_off": vg - base_addr,
        "track_offs": [t - base_addr for t in trks],
    }


def disassemble(blob, off, limit=4096):
    """Decode track byte-code into (mnemonic, args) tuples until FINE/GOTO.

    Implements the argument-omission rules of [1]/[2] well enough to verify
    what songgen emits: a note/tie/eot argument list ends at the first byte
    >= 0x80, and 0x00-0x7F repeats the last repeatable command.
    """
    out = []
    last_repeatable = None
    i = off
    end = min(len(blob), off + limit)
    while i < end:
        op = blob[i]
        i += 1
        if op < 0x80:
            # Running status: re-run the last repeatable command with this
            # byte as its first argument.
            i -= 1
            if last_repeatable is None:
                out.append(("?ARG", [op]))
                i += 1
                continue
            op = last_repeatable
            # fall through with i still pointing at the argument byte
        if 0x80 <= op <= 0xB0:
            n = 0 if op == 0x80 else NOTE_LENGTH_TABLE[op - 0x81]
            out.append(("W%02d" % n, []))
        elif op == OP_FINE:
            out.append(("FINE", []))
            break
        elif op in (OP_GOTO, OP_PATT):
            (dst,) = struct.unpack_from("<I", blob, i)
            i += 4
            out.append(("GOTO" if op == OP_GOTO else "PATT", [dst]))
            if op == OP_GOTO:
                break
        elif op == OP_PEND:
            out.append(("PEND", []))
        elif op == OP_REPT:
            cnt = blob[i]
            (dst,) = struct.unpack_from("<I", blob, i + 1)
            i += 5
            out.append(("REPT", [cnt, dst]))
        elif op in (OP_PRIO, OP_TEMPO, OP_KEYSH, OP_VOICE, OP_VOL, OP_PAN,
                    OP_BEND, OP_BENDR, OP_LFOS, OP_LFODL, OP_MOD, OP_MODT,
                    OP_TUNE):
            name = {OP_PRIO: "PRIO", OP_TEMPO: "TEMPO", OP_KEYSH: "KEYSH",
                    OP_VOICE: "VOICE", OP_VOL: "VOL", OP_PAN: "PAN",
                    OP_BEND: "BEND", OP_BENDR: "BENDR", OP_LFOS: "LFOS",
                    OP_LFODL: "LFODL", OP_MOD: "MOD", OP_MODT: "MODT",
                    OP_TUNE: "TUNE"}[op]
            out.append((name, [blob[i]]))
            i += 1
            last_repeatable = op
        elif op == OP_XCMD:
            out.append(("XCMD", [blob[i], blob[i + 1]]))
            i += 2
            last_repeatable = op
        elif op in (OP_EOT, OP_TIE) or op >= OP_NOTE0:
            maxargs = 2 if op == OP_TIE else (1 if op == OP_EOT else 3)
            args = []
            while len(args) < maxargs and i < end and blob[i] < 0x80:
                args.append(blob[i])
                i += 1
            if op == OP_EOT:
                out.append(("EOT", args))
            elif op == OP_TIE:
                out.append(("TIE", args))
            else:
                out.append(("N%02d" % NOTE_LENGTH_TABLE[op - OP_NOTE0], args))
            last_repeatable = op
        else:
            out.append(("?%02X" % op, []))
    return out


# --------------------------------------------------------------------------
# Demo song
# --------------------------------------------------------------------------

def demo_song():
    """One DirectSound voice on a looping DC sample, VOL 127, PAN centre,
    a few notes at different keys, then FINE."""
    song = Song(reverb=None, priority=0)

    # A DC sample: 64 samples all at +64, looping over the whole thing.  Under
    # the driver this should come out as a flat level whose height is the whole
    # gain chain (velocity * VOL * master volume * ADSR) and nothing else.
    wave = Wave(wave_dc(64, 64), sample_rate=DEFAULT_RATE, loop_start=0,
                name="dc64")
    v = song.voicegroup.direct_sound(wave, *ADSR_RAW)

    t = song.track("lead")
    t.keysh(0)
    t.tempo(150)            # 75 after the /2, i.e. exactly 1 tick per frame
    t.voice(v)
    t.vol(127)
    t.pan(64)
    for key in (36, 48, 60, 72, 84):
        t.note(key, 127, 24)
        t.wait(24)
    t.fine()
    return song


# --------------------------------------------------------------------------
# Selftest
# --------------------------------------------------------------------------

def selftest():
    fails = []

    def check(cond, msg):
        print("%-5s %s" % ("ok" if cond else "FAIL", msg))
        if not cond:
            fails.append(msg)

    print("== pitch field ==")
    check(pitch_from_rate(13379) == 0xD10C00,
          "1024 * 13379 Hz == 0xD10C00 (doc [2] table)")
    doc_table = (0x599800, 0x7B3000, 0xA44000, 0xD10C00, 0xF66000, 0x11BB400,
                 0x1488000, 0x1A21800, 0x1ECC000, 0x2376800, 0x2732400,
                 0x2910000)
    check(all(pitch_from_rate(hz) == want
              for hz, want in zip(ENGINE_RATES, doc_table)),
          "all 12 engine rates reproduce doc [2]'s pitch table")

    print("== note length table ==")
    check(len(NOTE_LENGTH_TABLE) == 48 and NOTE_LENGTH_TABLE[-1] == 96,
          "48 entries ending at 96")
    check(OP_WAIT0 + len(NOTE_LENGTH_TABLE) == 0xB0,
          "W00..W96 spans 0x80..0xB0")
    check(OP_NOTE0 + len(NOTE_LENGTH_TABLE) - 1 == 0xFF,
          "N01..N96 spans 0xD0..0xFF")

    print("== BDPCM round trip ==")
    # Exact cases: the codec must be lossless where the deltas allow it.
    dc = wave_dc(50, 64)
    check(bdpcm_decode(bdpcm_encode(dc), 64) == dc,
          "DC round-trips exactly (delta 0 is nibble 0)")
    enc = bdpcm_encode(dc)
    check(len(enc) == BDPCM_BLOCK_BYTES,
          "64 samples encode to exactly 33 bytes")
    check(enc[0] == (50 & 0xFF), "block byte 0 is the raw first sample")
    check(enc[1] & 0x0F == 0,
          "nibble 1 (the low nibble of byte 1) carries sample 1")

    # A ramp with step 1 is exactly representable (nibble 1 == +1).
    ramp = [(-32 + i) for i in range(64)]
    check(bdpcm_decode(bdpcm_encode(ramp), 64) == ramp,
          "unit ramp round-trips exactly")

    # The unused first high nibble must not disturb the decode.
    poked = bytearray(bdpcm_encode(dc))
    poked[1] |= 0xF0
    check(bdpcm_decode(bytes(poked), 64) == dc,
          "the first high nibble is ignored by the decoder")

    # Lossy cases.  BDPCM is a slew-rate-limited delta coder: a step larger
    # than +49/-64 per sample simply cannot be tracked, so white noise is
    # expected to show a large peak error.  The property that must hold for
    # *any* signal is greedy optimality -- each decoded sample is the closest
    # value to the target that is reachable from the previous decoded sample.
    for name, sig, bound in (("sine", wave_sine(32, 8, 100), 8),
                             ("saw", wave_saw(40, 6, 110), 8),
                             ("noise", wave_noise(192, seed=12345, amp=90), None)):
        dec = bdpcm_decode(bdpcm_encode(sig), len(sig))
        check(len(dec) == len(sig), "%s: length preserved (%d)" % (name, len(sig)))
        err = max(abs(a - b) for a, b in zip(sig, dec))
        rms = math.sqrt(sum((a - b) ** 2 for a, b in zip(sig, dec)) / len(sig))
        print("      %s: peak err %d, rms err %.2f" % (name, err, rms))
        if bound is not None:
            check(err <= bound,
                  "%s: band-limited signal tracks within %d LSB" % (name, bound))
        # greedy optimality, checked inside each block (the block boundary
        # resets the accumulator to a raw sample)
        worse = 0
        for k in range(len(sig)):
            if k % BDPCM_BLOCK_SAMPLES == 0:
                continue
            prev = dec[k - 1]
            best = min(abs(_wrap_s8(prev + d) - sig[k]) for d in BDPCM_DELTA_TABLE)
            if abs(dec[k] - sig[k]) > best:
                worse += 1
        check(worse == 0,
              "%s: every sample is the nearest reachable value (greedy optimal)"
              % name)

    pad = bdpcm_encode(wave_dc(10, 100))
    check(len(pad) == 2 * BDPCM_BLOCK_BYTES,
          "100 samples pad up to 2 blocks (66 bytes)")
    check(len(BDPCM_DELTA_TABLE) == 16
          and BDPCM_DELTA_TABLE[7] == 49 and BDPCM_DELTA_TABLE[8] == -64
          and BDPCM_DELTA_TABLE[15] == -1,
          "delta table: n<8 -> +n^2, n>=8 -> -(16-n)^2")
    check(_wrap_s8(127 + 49) == -80, "the accumulator wraps at 8 bits")

    print("== note/wait length encoding ==")
    bad = []
    for t in range(1, 97):
        tr = Track()
        tr.note(60, 127, t)
        dis = disassemble(bytes(tr.data) + b"\xb1", 0)
        mnem, args = dis[0]
        got = int(mnem[1:]) + (args[2] if len(args) > 2 else 0)
        if got != t:
            bad.append((t, mnem, args))
    check(not bad, "every note length 1..96 re-decodes exactly (%s)"
          % ("ok" if not bad else bad[:3]))

    bad = []
    for t in list(range(0, 100)) + [96, 97, 191, 250]:
        tr = Track()
        tr.wait(t)
        total = sum(int(m[1:]) for m, _ in disassemble(bytes(tr.data) + b"\xb1", 0)
                    if m.startswith("W"))
        if total != t:
            bad.append((t, total))
    check(not bad, "every wait 0..99 (+250) re-decodes to the same tick count")

    print("== pointer resolution ==")
    song = demo_song()
    blobA, hdrA = build(song, 0x08000000)
    blobB, hdrB = build(song, 0x08F00000)
    check(len(blobA) == len(blobB), "relocation does not change the blob size")
    check(hdrA == 0x08000000 and hdrB == 0x08F00000,
          "the header sits at base_addr")

    hA = parse_header(blobA, 0x08000000)
    hB = parse_header(blobB, 0x08F00000)
    check(hA["voicegroup_off"] == hB["voicegroup_off"]
          and hA["track_offs"] == hB["track_offs"],
          "every pointer is base_addr + the same offset")
    check(hA["track_count"] == 1 and hA["blocks"] == 0,
          "header track count / blockCount")
    check(hA["voicegroup"] == 0x08000000 + hA["voicegroup_off"]
          and 0 < hA["voicegroup_off"] < len(blobA),
          "the voicegroup pointer lands inside the blob")

    # Every 4-byte-aligned pointer field must differ by exactly the base delta.
    delta = 0x08F00000 - 0x08000000
    ptr_offsets = [4] + [8 + 4 * i for i in range(hA["track_count"])]
    vg = hA["voicegroup_off"]
    for i in range(len(song.voicegroup)):
        ptr_offsets.append(vg + 12 * i + 4)
    ok = True
    for o in ptr_offsets:
        a = struct.unpack_from("<I", blobA, o)[0]
        b = struct.unpack_from("<I", blobB, o)[0]
        if b - a != delta or not (0x08000000 <= a < 0x08000000 + len(blobA)):
            ok = False
    check(ok, "all %d pointer fields relocate by exactly the base delta"
          % len(ptr_offsets))

    print("== voicegroup + wave layout ==")
    check(len(song.voicegroup) * 12 == 12, "one 12-byte voice")
    vgb = blobA[vg:vg + 12]
    check(vgb[0] == VOICE_DIRECT, "voice type byte is 0x00 (DirectSound)")
    check(tuple(vgb[8:12]) == ADSR_RAW, "ADSR bytes are the 'raw' setting")
    wav_addr = struct.unpack_from("<I", blobA, vg + 4)[0]
    wo = wav_addr - 0x08000000
    check(wo % 4 == 0, "the wave is 4-byte aligned")
    wtype, wflags, wfreq, wloop, wsize = struct.unpack_from("<HHIII", blobA, wo)
    check((wtype, wflags, wfreq, wloop, wsize)
          == (WAVE_TYPE_PCM, WAVE_FLAG_LOOP, 0xD10C00, 0, 64),
          "wave header: PCM, looped(0x4000), 0xD10C00, loop 0, size 64")
    check(blobA[wo + 16 + 64] == 64,
          "one guard sample follows the data (== sample[loop_start])")

    print("== track byte-code ==")
    dis = disassemble(blobA, hA["track_offs"][0])
    mnems = [m for m, _ in dis]
    check(mnems[:5] == ["KEYSH", "TEMPO", "VOICE", "VOL", "PAN"],
          "demo preamble decodes as KEYSH TEMPO VOICE VOL PAN")
    check(dis[1][1] == [75], "TEMPO 150 BPM stores 75 (BPM/2)")
    check(dis[4][1] == [64], "PAN centre is 64")
    check(mnems[-1] == "FINE", "the track ends with FINE")
    check([a[0] for m, a in dis if m.startswith("N")] == [36, 48, 60, 72, 84],
          "the five note keys decode back")
    check(all(a[1] == 127 for m, a in dis if m.startswith("N")),
          "every note carries an explicit velocity of 127")

    print("== flow control ==")
    s2 = Song()
    w = Wave(wave_dc(32, 64), loop_start=0)
    s2.voicegroup.direct_sound(w, *ADSR_RAW)
    t2 = s2.track()
    t2.vol(100)
    t2.label("top")
    t2.note(60, 127, 12)
    t2.wait(12)
    t2.goto("top")
    b2, _ = build(s2, 0x08123456 & ~3)
    h2 = parse_header(b2, 0x08123456 & ~3)
    d2 = disassemble(b2, h2["track_offs"][0])
    goto_dst = [a[0] for m, a in d2 if m == "GOTO"][0]
    top = (0x08123456 & ~3) + h2["track_offs"][0] + 2   # after VOL 100
    check(goto_dst == top, "GOTO resolves to the label's absolute address")

    print("== reverb byte ==")
    check(Song(reverb=None).reverb == 0x00,
          "reverb=None leaves bit 7 clear (global untouched)")
    check(Song(reverb=50).reverb == 0x80 | 50,
          "reverb=50 sets bit 7 with the amount in the low 7 bits")

    print()
    if fails:
        print("%d FAILURE(S)" % len(fails))
        for f in fails:
            print("  -", f)
        return 1
    print("all selftests passed")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _parse_addr(s):
    return int(s, 16) if not s.lower().startswith("0x") else int(s, 16)


def main(argv=None):
    p = argparse.ArgumentParser(
        description="MP2K/M4A song data assembler (see module docstring for "
                    "provenance).")
    p.add_argument("--demo", metavar="BASE_ADDR_HEX",
                   help="build the demo song for this ROM address, e.g. 8F00000")
    p.add_argument("--out", metavar="FILE", help="write the blob here")
    p.add_argument("--selftest", action="store_true",
                   help="run the BDPCM round trip and pointer-resolution checks")
    p.add_argument("--ambiguities", action="store_true",
                   help="print the list of unresolved format questions")
    p.add_argument("--bias", action="store_true",
                   help="emit Bregalad's 'minus one' reading of the WaveData "
                        "size/loopStart fields (see AMBIGUITIES A1)")
    p.add_argument("--dump", action="store_true",
                   help="also disassemble the built blob to stdout")
    args = p.parse_args(argv)

    if args.ambiguities:
        print(AMBIGUITIES)
        return 0

    rc = 0
    if args.selftest:
        rc = selftest()

    if args.demo is not None:
        base = _parse_addr(args.demo)
        if base & 3:
            p.error("base address must be 4-byte aligned")
        bias = -1 if args.bias else 0
        blob, hdr = build(demo_song(), base, size_bias=bias, loop_bias=bias)
        print("header address : 0x%08X" % hdr)
        print("blob size      : %d bytes" % len(blob))
        h = parse_header(blob, base)
        print("track count    : %d" % h["track_count"])
        print("voicegroup     : 0x%08X (+0x%X)" % (h["voicegroup"],
                                                   h["voicegroup_off"]))
        for i, (a, o) in enumerate(zip(h["tracks"], h["track_offs"])):
            print("track %-2d       : 0x%08X (+0x%X)" % (i, a, o))
        if args.dump:
            for i, o in enumerate(h["track_offs"]):
                print("--- track %d ---" % i)
                for mnem, a in disassemble(blob, o):
                    print("  %-6s %s" % (mnem, " ".join("%d" % x for x in a)))
        if args.out:
            with open(args.out, "wb") as fh:
                fh.write(blob)
            print("wrote %s" % args.out)
    elif not args.selftest and not args.ambiguities:
        p.print_help()

    return rc


if __name__ == "__main__":
    sys.exit(main())
