# mp2kprobe

Tools for poking at the MP2K / M4A ("Sappy") sound driver that most GBA games
ship, from the outside: the ROM bytes are the only input.

## songtable.py — locate and repoint the song table

`songtable.py` finds the MP2K song table in a GBA ROM by structural scanning
and can write a patched copy of the ROM in which every song index points at one
SongHeader you supply. That lets a harness play "song N" for any N and get a
known, hand-written sequence instead of whatever the game had there.

Background reference: loveemu, [*Summary of GBA Standard Sound Driver
MusicPlayer2000*](https://loveemu.github.io/vgmdocs/Summary_of_GBA_Standard_Sound_Driver_MusicPlayer2000.html),
plus GBATEK for the cartridge address window. Nothing in the scanner is derived
from a game's source, a decompilation, or another emulator; every address it
prints came out of its own scan.

### What it looks for

A song table entry is 8 bytes and tables are long contiguous runs of them:

```
u32 songHeader     ROM pointer (0x08xxxxxx / 0x09xxxxxx), 4-byte aligned
u16 playerIndex    small
u16 playerIndex    small (equal to the first in every ROM measured below)
```

and a SongHeader is

```
u8  trackCount     0..16   (0 == an empty / "stop" song)
u8  blockCount
u8  priority
u8  reverb
u32 voicegroup     ROM pointer, 4-byte aligned
u32 track[trackCount]   ROM pointers into byte-code streams (byte-aligned)
```

An entry is *plausible* when the header pointer is a 4-aligned pointer into
this ROM, both player indices are below 256, `trackCount <= 16`, the voicegroup
pointer is a 4-aligned ROM pointer, and every one of the `trackCount` track
pointers lands inside the ROM. An entry whose `trackCount` is 0 is accepted on
the pointer and the player indices alone: it has no tracks, so nothing else in
its header is ever dereferenced, and its voicegroup word may be junk (it is
`0x40000000` in Kirby and Minish Cap, 0 in Advance Wars). Many entries of a
real table share one such header, so this case has to be tolerated — `scan()`
instead insists that a candidate run contain at least a handful of real songs.

### How the scan stays fast

One regex pass over the whole image finds *seeds*: byte positions where two
consecutive entries have the right silhouette (pointer high byte 0x08/0x09,
bytes +5 and +7 zero). The pattern is a zero-width lookahead, so `finditer`
steps a byte at a time and a misaligned false match cannot swallow the real,
4-aligned one behind it. Only seeds get the full header validation, and each
run is grown outwards from its seed with a one-entry gap tolerance. A 32 MB
image scans in well under a second.

Candidates are ranked by **longest run**, then most non-empty songs, then
lowest offset. `--all` lists every run it found.

### Validation

Six ROMs, read-only, current code. Every one yields exactly **one** candidate
run with **zero** rejected entries inside it, so there was no tie to break.

| ROM | size | table address | entries | songs / empty | voicegroups | clean? |
|---|---|---|---|---|---|---|
| Pokémon Emerald (U) | 16 MB | `0x086B49F0` | 610 | 529 / 81 | 176 | yes |
| Pokémon FireRed (U) v1.0 | 16 MB | `0x084A32CC` | 347 | 346 / 1 | 65 | yes |
| Pokémon Ruby | 16 MB | `0x084554A0` | 468 | 416 / 52 | 105 | yes |
| Zelda: The Minish Cap (U) | 16 MB | `0x08A11DBC` | 546 | 507 / 39 | 502 | yes |
| Kirby: Nightmare in Dream Land | 8 MB | `0x0860B460` | 579 | 329 / 250 | 3 | yes |
| Advance Wars (USA) (Rev 1) | 4 MB | `0x08143800` | 225 | 160 / 65 | 2 | yes |

Internal cross-checks that back those runs up (no external table was consulted):

* **Track streams are sequences.** All 6405 track pointers across the six
  tables start with a byte >= 0x80, i.e. a command and not data, per the
  loveemu ranges. 6291 of them start with `0xBC` and the rest with `0xBE` —
  both in the 0xB1..0xCE control range, as a track prologue should be.
* **The tail boundary is real.** The word immediately after every one of the
  six runs is `0x00000000`, which is what stops the scan. In five of the six
  (all but FireRed) the run ends *exactly* at the address of that ROM's shared
  empty-song header, i.e. the header the table's empty entries point at is
  placed immediately after the table.
* **The head boundary is real.** The word immediately before every run is a
  RAM pointer (`0x03xxxxxx`, or `0x020381A0` in Minish Cap) preceded by a small
  count — the music-player table that conventionally sits just ahead of the
  song table. It is not a plausible entry, so the run cannot grow backwards.
* **Player indices agree.** In all 2775 entries the two u16 player indices are
  equal, matching the "usually equal" expectation.
* **Counts are in range.** The Pokémon titles land in the hundreds (they carry
  SFX in the same table); Advance Wars, the smallest ROM, has the fewest.

Two heuristics had to be loosened to get there, both times because a ROM was
right and the first guess was too strict:

* Kirby's shared empty header has a **non-ROM voicegroup word** (`0x40000000`),
  which split its single 579-entry table into four runs of 197/59/57/15 until
  empty songs stopped being required to have a valid voicegroup.
* Minish Cap uses **player indices up to 31**, so a `< 8`/`< 16` ceiling
  chopped its table into thirteen runs of 38 entries and fewer. The ceiling is
  now 256 (the u16 high byte must be zero); the header check carries the
  weight.

With either heuristic still tight, those two ROMs were the ambiguous ones. With
both relaxed, no ROM in the set is ambiguous.

### Patching round-trip

Patching Emerald's 610 entries to a header at `0x09000100` and padding to 32 MB
leaves every byte outside the table identical, keeps all the player indices,
fills the new space with `0xFF`, and re-scans to the same table address with all
610 entries reported as one-header songs.

### CLI

```sh
# report the table and the first 8 entries
python3 tools/mp2kprobe/songtable.py "/path/to/Pokemon - Emerald Version (U).gba"

# show every candidate run and more entries
python3 tools/mp2kprobe/songtable.py "/path/to/rom.gba" --all --limit 32

# force a known table instead of scanning
python3 tools/mp2kprobe/songtable.py "/path/to/rom.gba" --table 6B49F0 --count 610

# point every song at a SongHeader placed at 0x09000100 in a 32 MB copy
# (Emerald is exactly 16 MB, so the header has to live past the original end)
python3 tools/mp2kprobe/songtable.py "/path/to/Pokemon - Emerald Version (U).gba" \
    --patch 0x09000100 --extend 32 --out /tmp/emerald-mp2k.gba

# just grow a ROM copy to 32 MB, no patching
python3 tools/mp2kprobe/songtable.py "/path/to/rom.gba" --extend 32 --out /tmp/big.gba
```

The header bytes themselves are the caller's business: write a SongHeader (and
the track streams and voicegroup it points at) into the padded region of the
output file, then hand the ROM to the emulator and ask it for any song index.

As a library:

```python
import songtable
rom = open(path, "rb").read()
best = songtable.scan(rom)[0]                       # longest plausible run
out  = songtable.patch(rom, best["offset"], best["count"], 0x09000100)
out  = songtable.extend_rom(out, 32)
songtable.describe(rom, best["offset"], best["count"], limit=16)
```


## songgen.py — assemble a probe song

`songgen.py` builds MP2K music data — SongHeader, track byte-code, voicegroup
and WaveData blobs — as one relocatable blob for a chosen ROM address, from the
formats documented by loveemu and by Bregalad & ipatix's *GBA "Sappy" sound
engine information*. `python3 songgen.py --selftest` runs its 40 checks;
`--ambiguities` lists the points where the documents disagree or are silent and
which probe settles each. Wave generators: DC, impulse, sine, saw, seeded noise,
raw s8; a BDPCM encoder/decoder pair for compressed waves.

## probes.py — the probe songs

`python3 probes.py <p1..p11> <host.gba> <out.gba>` writes one probe song into a
host that `songtable.py --patch 0x09000100 --extend 32` prepared, so whatever
song the game starts plays the probe through the game's own driver. Each probe
isolates one mixer behaviour (PROBES.md sketches the catalogue): P1 volume
staircase on a DC sample, P2 impulse (kernel and note-on timing), P3 envelope
stages, P4 pitch, P5 pan, P6 reverb, P7 loop points, P8 BDPCM vs PCM, P9
reversed/fixed-rate types, P10 channel cap and overflow, P11 loop wraps at
fractional steps.

## tests/mp2k_probe.nim — read the driver's answer

Built with `-d:mp2kwav -d:test_harness`, the harness boots a ROM and records,
per V-blank, the slot of the driver's pcmBuffer that the pass just mixed (the
driver's output at its own rate, before the FIFO), the per-channel SoundChannel
fields, and the HLE's render. `DINGBAT_PROBE_ZOH=1` makes the real FIFO stream
a verbatim replay of that buffer, which is how the pipeline was validated
(correlation 0.985, amplitude exactly 2.0 on Emerald).

## Vintages probed

P1/P2/P3/P6 (and P11 on Emerald) were played through the drivers shipped in
Pokémon Emerald, Pokémon FireRed, Advance Wars, Breath of Fire, Mother 3 (its
modified, VSyncOff driver, driven through the health screen) and The Minish
Cap (mono, 15768 Hz), plus Estopolis Densetsu, Shin Megami Tensei II, Ochaken
no Heya and Beast Shooter: every one reproduces the laws below to the byte.
Kirby: Nightmare in Dream Land starts the injected song on two players at
once, so it is unconfirmed by the probes; the library sweep rates it as
matching. Castlevania: Circle of the Moon runs two configurations in one
boot — nine 176-byte slots at 10512 Hz through the intro, then two 704-byte
slots at 42048 Hz inside the same 1584-byte half, its title track a pair of
31-second streamed samples — and is matched by the sweep once the HLE
re-learns the ring per configuration (below).

## rig.py — drive the mixer with our own samples

`songtable.py --patch` plus the silent probe song gives a host whose
sequencer never allocates a channel; `rig.py` then places WaveData blobs of
its own in the padded ROM copy and emits a per-frame script of SoundChannel
writes that `tests/mp2k_probe.nim` applies at frame end
(`DINGBAT_PROBE_SCRIPT`). The game boots and brings its driver up as usual;
the channel table is then ours and the mixer plays exactly what the script
says. Scenarios: `dc` (gain law), `imp` (kernel and timing by impulse), `env`
(attack/decay/release), `iec` (pseudo-echo floor), `types` (loop, reversed,
fixed-rate, compressed), `side` (per-side bytes written at the hook), `offs`
(the count field at note-on), `cap` (every channel at once). It is how the
per-side-bytes rule, the pseudo-echo hold and the count-field difference
below were settled without a sequencer in the way.

## How the HLE finds the mixer (2026-09-13)

There is no ROM signature. Every m4a build keeps a pointer to its SoundInfo
work area at IWRAM 0x03007FF0, and SoundMain holds ident+1 for the whole
pass. While that lock is held the HLE watches RAM-fetched instructions with
r0 == &SoundInfo and keeps those that are call targets (a BL aimed at the
instruction, a BL to a `bx rN` stub — the compiled call through a function
pointer — or `mov lr, pc; bx rN`). After eight passes the candidates that
fired in every pass are ranked in pass order and the first is hooked.

Two classes of build turned up in the library:

* **SoundMainRAM alone in RAM** (Emerald, FireRed, Minish Cap, Advance Wars,
  Breath of Fire, Mother 3, Beast Shooter, Ochaken, Estopolis, GT Advance 3,
  BB Ball): one candidate, the mixer entry, reached after the sequencer.
* **SoundMain itself in RAM** (EZ-Talk, Super Dodgeball Advance, Mega Man
  Battle Network, Castlevania: Circle of the Moon, Advance GTA, Hudson Best
  Collection): the first candidate is SoundMain, whose sequencer runs after
  the hook, and the mixer proper is the second. The HLE detects the wrong
  vantage from the channel table — an envelope that does not match one hook
  later, or a channel first seen ON without its START bit (the mixer clears
  START as it initialises a channel, so a hook after the sequencer always
  sees it) — and moves to the next candidate; a move that predicts no better
  returns to the entry.

A driver whose ident reads locked at every V-blank (BB Ball) delimits its
passes by re-sighting an entry instead of by an idle poll.

## What the driver does (2026-09-13, Emerald's driver; the vintages above agree; count field and ring re-timing 2026-09-14)

| Behaviour | Measured |
|---|---|
| Per-channel gain | byte = floor(sample × envelopeVolume{R,L} / 256), summed per channel; the s8 buffer wraps past ±127 (3 × 50 → −106) |
| Envelope timing | every frame is mixed flat at the envelope the pass computes; no ramp on attack, decay or release. At the mixer entry hook the per-side bytes are the previous pass's |
| Envelope stages | attack: ev += rate, clamp 255; decay: ev = ev·rate/256 down to sustain; release: ev = ev·rate/256, channel dropped at 0; release 0 kills in that pass, mixing nothing |
| Note-on | starts at sample 0 of that pass's frame. The count field at note-on differs by vintage: Emerald's mixer honours it as a start offset (rig `offs`), Minish Cap's ignores it; no sequencer in the library sets one (census: 58,777 ignored, 49 noise), so the HLE ignores it |
| Resampler | linear interpolation between adjacent source samples, no anti-aliasing when decimating |
| Sample bounds | `size` is a count (indices 0..size−1), the loop returns to `loopStart` interpolating toward it; a one-shot goes silent at its end and the channel is dropped |
| Type bits | 0x08 plays at pcmFreq whatever the key; 0x10 plays from data[size−1] downward; both combine; compressed (BDPCM) decodes as the HLE does |
| Reverb | before a pass mixes, the slot it overwrites is seeded with (A+B of that slot + A+B of the next slot) × reverb/512: two taps at P−1 and P frames; an impulse of 50 with reverb 64, period 7 echoes 12, 12 then 3, 6, 3 |
| Stereo halves | the first pcmBuffer half (DMA1 → FIFO A) carries the right-volume mix, the second the left; Emerald routes A right / B left (and plays mono by default) |
| Latency | the real FIFO stream lags the pass by 553 APU samples on Emerald (one V-blank + 4), 228 on Minish Cap, set by where the DMA is in the ring at the pass, plus 28 source-rate samples of FIFO whatever the rate (the 32-byte FIFO refilled 16 at a time; measured 22–32 on six titles at each of nine engine rates) |
| Ring geometry | period × slot bytes, the period read from pcmDmaCounter's cycle; a driver may re-time mid-run (Castlevania: 9 × 176 at 10512 Hz, then 2 × 704 at 42048 Hz), so the period is re-learnt whenever the rate or the frame length changes |

## What the HLE deliberately does differently

The probes also show where the HLE's render is not the driver's, by design:

* **Reconstruction.** The HLE interpolates (cubic) at 32768 Hz; the driver
  emits one byte per source-rate sample and the hardware holds it. Sampled at
  the driver's own instants the HLE's frames match it (Emerald: per-frame
  correlation median 0.991, 96 % of frames above 0.95; energy 0.99–1.00 of
  the driver's with DC removed).
* **No truncation DC.** The driver floors each channel's product, which parks
  its output at about −0.5 per active voice (−11 on a ten-voice mix). The HLE
  has no such offset, so raw-RMS comparisons read it as quieter; the sweep's
  loudness ratio is therefore DC-free.
* **No wrap.** Past ±127 the driver's byte wraps; the HLE clamps.
* **Kernel droop and aliasing.** Voices played at more than about two source
  samples per output sample are dulled by the driver's linear interpolation
  and folded by its unfiltered decimation; the HLE keeps more of their
  treble (Breath of Fire's strings come out ~1.2× louder than the driver's,
  ~1.14× below 4 kHz). This is the audible "improvement" and also the largest
  remaining deviation from hardware.
* **Latency.** The HLE predicts each pass's envelope from the P3 rules
  (checked against the real bytes one hook later: zero misses on every title
  above, including Beast Shooter's pseudo-echo tails), renders the frame at
  the pass, and holds it until the sound DMA reaches that slot, a latency it
  measures per title from the DMA cursor. Against the real stream (waveform
  cross-correlation, 32768 Hz): Emerald +7 samples, Minish Cap +12, Beast
  Shooter +13, Hudson Best Collection +12, Castlevania +24, Super Dodgeball
  +32, Battle Network +38, Estopolis +84; by the P2 impulse itself, played
  through each driver: Emerald +8, Ochaken +2, Minish Cap +5, Beast Shooter
  +34 samples.
