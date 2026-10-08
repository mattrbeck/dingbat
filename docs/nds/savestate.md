# DS save states

Status: **working** (2026-10-01). `src/dingbat/nds/savestate.nim` snapshots
the whole DS so a run can be resumed, kept in slots and (next) rewound; a
state loaded into a fresh machine runs on byte-for-byte as the machine it
came from did, native or wasm.

## API

| | |
|---|---|
| `state_bytes(n, thumbnail = false): string` / `save_state(n): seq[uint8]` | plain image: header, payload, optional thumbnail |
| `load_state_bytes(n, data): bool` / `load_state(n, data)` | plain or packed image; on refusal the machine is untouched |
| `state_payload(n)` / `load_state_payload(n, payload)` | bare payload for rewind / run-ahead (no header, ROM check or hash) |
| `state_is_for(n, data)` | the image names this game (slot lists); never raises |
| `state_layout(n)` | the field walk as text (`ndsrun --state-layout`) |
| `pack_state` / `unpack_state` (common/serialize.nim) | the storage form: header plain, rest zlib |

Refusals set `last_state_reject_kind` (`StateRejectKind`) and
`last_state_error` (the detail): `srkNotAState`, `srkWrongCore` (a GB/GBA
state), `srkWrongRom`, `srkTooNew` (newer container or payload revision),
`srkTruncated`, `srkCorrupt` (hash, section marker or range check), and the
new `srkIncompatible` (appended, ordinal 8): a DS state for this game that
this build cannot restore -- another field layout, the other BIOS (a dump
vs the HLE BIOS: a CPU caught inside one BIOS's IRQ or SWI code would
resume in the other's, so the BIOS kinds and an fnv1a of each BIOS image
must match), or another device in the GBA slot. Firmware is not checked.

Wasm (`src/dingbat_nds_wasm.nim`): `nds_state_size(thumbnail)` serializes
and packs into a retained buffer and returns its length, `nds_state_data()`
points at it, `nds_state_load(ptr, len)` applies one (1 = ok),
`nds_state_error_kind()` / `nds_state_error()` say why not. The main app
uses them through `ndsCaptureState` / `ndsApplyState` (web/index.js,
"Nintendo DS"): quick save/load, slots and resume; its reject toasts read
the DS core's kind and detail while a DS game runs.
`tools/ndsrun.nim`: `--state-save FILE@F[,...]` (packed, with thumbnail,
after frame F), `--state-load FILE[@F]` (the run continues from frame F,
default the state's V-blank count, so `--press`/`--shots`/`--frames` keep
their numbers), `--state-layout`.

## Container

The GB/GBA one (common/serialize.nim, main's container 8 brought onto this
branch byte for byte): the 32-byte header with core `ckNDS = 2`, payload
revision `NDS_PAYLOAD_VERSION = 1`, the payload's length and fnv1a, and the
ROM identity: `rom_checksum` = fnv1a over the cartridge header
(0x000-0x1FF: title, game code, version, binary offsets and sizes, header
and secure-area CRCs) continued over the first 64 KB of the ARM9 binary,
`rom_size` = the file length. That costs microseconds per state, where the
GBA's 1 MB hash would cost a millisecond each rewind snapshot. Thumbnail
trailer: both screens at half size, 128x192 BGR555, top above bottom. No
whole-ROM trailer. Stored states are `pack_state`d (header plain, the rest
one zlib stream, flag 0x8000).

## Payload

A 28-byte preamble -- `"NDSS"`, the layout hash, the BIOS kinds (bit 0
ARM9 HLE, bit 1 ARM7 HLE), fnv1a of the ARM9 and ARM7 BIOS images, the
GBA-slot device and an identity of its cart (fnv1a of the GBA header's
first 0xC0 bytes and the ROM length) -- then one section per subsystem
object, each opened by a marker byte (0xFF at the end; a desynchronised
read stops at the next marker). The fixed-size sections come first and the
ones whose seqs change length while a game runs last, so between two
snapshots everything before them keeps its offset and a rewind ring's XOR
delta stays mostly zeros. In payload order:

| # | Section | Saved |
|---|---|---|
| 1 | machine (`NDS`) | CP15 (incl. TCM config), main RAM (4 MB), shared WRAM, ARM7 WRAM, ITCM, DTCM, WRAMCNT, EXMEMCNT/STAT and the GBA-slot timings, VCOUNT write, POSTFLGs, POWCNT2, BIOSPROT, bus wait and sequential-access trackers, DMA mode 4 armed channels, frame_done, sleeping, line start |
| 3, 4 | ARM9, ARM7 | r0-r15, CPSR, SPSR, banked r13/r14, FIQ and user r8-r12, banked SPSRs, next_pc, cur_pc, halted, cycles, base_cycles, vector base, no_load_interwork, instr_count, icycles |
| 5 | ARM9 memory timing | I/D cache tags, round-robin victims, set mask, last line; the data cache's main RAM lines (memory side, dirty flags, per-line slots); the instruction cache's lines (RAM line, kept copies: docs/nds/cache.md) |
| 6 | display (`Gpu`) | palette, OAM, capturing, DMA mode 4 pixels owed, POWCNT1, VCOUNT, H/V-blank, DISPSTATs, both output screens, frame_count |
| 7 | VRAM | all 656 KB, VRAMCNT A-I |
| 12 | 3D renderer | the rendered frame (`color`), the render registers 0x4000320-3BF (edge colours, fog, toon table, clear values...), line costs, RDLINES, underflow |
| 13-18 | IRQ, timers, DMA (per CPU) | IME/IE/IF; reload/control/counter/start time; channels incl. the running block's source, destination and count, fill words |
| 20, 21 | IPC sides | sync/IRQ/error/last-word state |
| 22 | DIV/SQRT | registers, results and busy-until times |
| 23 | input | keys held, KEYCNTs, stylus, lid, PENIRQ enable |
| 24 | SPI | SPICNT, the transfer in flight (reply, busy time), firmware-flash command state and write/erase busy, deep power-down, touchscreen ADC state, power-manager registers and index, chip select |
| 31 | GBA slot | device, save type and contents, FLASH/EEPROM state machines, GPIO, Rumble Pak latch and edge counts, Expansion Pak RAM (8 MB when present) and lock |
| 27 | sound | 16 channels (registers, timer, position, ADPCM state and loop copy, noise LFSR, read-ahead FIFO), SOUNDCNT/BIAS, both capture units, the next mixer tick, last output words |
| 28 | RTC | port, serial state machine, status/alarm/adjust/free registers, clock offsets, fixed start, time slept, INT1/INT2 latches and edge state, next check, RCNT |
| 29 | wifi | registers, packet RAM, BB and RF chips, IRQ line, random generator, microsecond counter, beacon/IRQ timers, the transmitter (source, stage, the frame being sent, retries, multiplay state), the receiver's frames in flight, channel, frame counters |
| 26 | backup chip | kind, contents, status, command state machine, IR front-end |
| 8, 9 | 2D engines A, B | every register, affine reference points and latches, window/mosaic latches, the line buffers, the main-memory display FIFO and line |
| 25 | card | chip ID, protocol mode (raw/KEY1/KEY2), reset, both KEY2 streams, seeds, the KEY1 command state, ROMCTRL, command, the transfer's reply buffer and position, AUXSPI |
| 19 | IPC FIFOs | both FIFOs' contents |
| 30 | microphone | the queued samples, read position and fraction, rate, last advance |
| 2 | scheduler | events (queue order, absolute master-cycle times), now, next |
| 10 | 3D engine | DISP3DCNT, GXSTAT IRQ mode, the GX FIFO + PIPE entries (with their arrival times), packed-command state, the running command and when it ends, the CPU stall, next V-blank, swap pending and its parameters, the renderer's polygon/vertex RAM, rendered flag, RDLINES, 3D line |
| 11 | 3D geometry | matrix mode, the five matrices and their stacks and pointers, vertex/texcoord/colour state, polygon attributes, the polygon being assembled, strip state, lights, materials, shininess table, viewport, the polygon/vertex RAM being filled, RAM_COUNT, overflow, test results |

`ndsrun --state-layout` prints the full walk (every field with its type,
about 800 lines). Encodings: bool and char 1 byte, enums int32, `int`/`uint`
8 bytes (states move between 64-bit native and 32-bit wasm builds), other
numbers and sets as little-endian bytes, numeric arrays and seqs as one
block, seqs and Deques prefixed by a u32 count, objects as their fields, a
wifi frame in flight (`AirFrame`, a ref) as a present flag and its fields.

### Not saved, and why

| Not saved | Why |
|---|---|
| ROM, BIOS, firmware images; the GBA cart ROM | supplied by the loading machine; ROM, BIOS and slot-2 identity checked |
| card `key1_table`, `key1`, `secure` | built from the ROM and BIOS7 at construction (`set_key1_table`), never changed after |
| VRAM page tables, fast pointers, VRAMSTAT | `remap()` rebuilds them from VRAMCNT |
| cachability tables, cache enables | `update_regions(cp15)` rebuilds them |
| engine palette/OAM pointers, `line3d`; the DMA mode 4 hook | point into the machine; set at construction or before each use |
| renderer depth, polygon IDs, flags, AA coverage, `below`, texture page pointers, sort order | per-frame scratch: `render_frame`'s clear and `build_pages` rewrite them before anything reads them |
| `spu.samples` | the host's output queue; emptied on load |
| `backup.dirty`, `slot2.dirty` | frontend bookkeeping; set on load, so the frontend writes out the save chips the state carries (as the GB/GBA cores do) |
| `rtc.fixed` | whether the clock follows emulated time is the frontend's choice (`ndsrun --rtc`); offsets, fixed start and the tick state are saved. On the host clock a resumed game reads the host's time, as on the GB/GBA cores |
| wifi `air`, `station`, `air_offset`, firmware copy, write masks | the Air is the frontend's link between machines, not one machine's state (a linked session saves each machine and links them again; the test does); masks are constant |
| debug switches (traces, profiles, I/O and card logs) | not machine state |

The `*_SKIP` tables in savestate.nim are this list. A new field is saved
without touching savestate.nim; a new field of reference or pointer type
stops the build until it is skipped and its object given a section (the
merge of the integrated branch's slot-2, card-crypto, mic, wifi-air and
peripheral work went exactly that way). The HLE BIOS keeps no host-side
state (its SWIs run to completion; IntrWait and the callback decompressors
run guest code), so the CPU and memory sections cover it.

### Compatibility

The layout hash is fnv1a of `state_layout`: every saved field's name and
type in walk order, enums with their members and ordinals. A build whose
walk differs refuses the state (`srkIncompatible`) instead of misreading
it, whether or not `NDS_PAYLOAD_VERSION` was bumped. One kind of change is
let through: a plain field added since (`ADDED_FIELDS` in savestate.nim,
newest last, with its type). A state whose layout hash is this build's
layout without the newest k of them loads with those fields left at the
loading machine's value, so only a field whose boot value is right at any
moment belongs there (`wifiwaitcnt`, round 10: games keep the 0030h boot
leaves). Any other change makes older DS states unloadable; once states
must survive those too, bump the revision and read the old layout in a
migration, as the GB/GBA loaders do. nds_savestate_test writes an older
build's payload (`state_payload_older`) and loads it.

### Range guards

Fixed-size buffers must match the loading machine's length; variable ones
have a ceiling (card transfer 16 KB, save chips 16 MB / 1 MB, polygon RAM
2048, vertex RAM 20480, GX FIFO 2^20, IPC FIFOs 16, events 64, wifi frames
256 of 64 KB, mic queue 2^20); enums are range-checked, sets may not carry
undefined bits, and after the walk the fields used as array indices are
checked (polygon assembly count, packed-command parameters, card position,
RTC/SPI/backup counters, ADPCM indices, main-memory FIFO indices, wifi
transmit source, mic read position, VCOUNT, no event booked twice). Any
refusal restores the machine from a payload taken just before.

The core is quirky (docs/nds/perf.md, "Error-flag checks"): past a failed
check it goes on, so a wild index is a stray access, not an IndexDefect.
`tools/statefuzz.nim` (a `.nds` ROM; built with `-d:nds_quirky=false
-d:nds_render_checks`, `nimble statefuzz_build`) sets each byte of a
state's fields in turn (the memories are left alone: the guest writes
them itself), reseals the payload hash, loads the result and runs four
frames, each in a child process, so a Defect, a signal or a hang (20 s) is
counted where it happens. What it found, and an audit of the fields it
had not reached (the GBA slot, DMA, the viewport, the stylus), the loader
now refuses (`after_load`, `check_clocks`, `check_caches`):

- **Clocks.** The master clock past 2^55 cycles; a CPU's clock more than
  a frame behind it (the CPU would run for hours to catch up) or 64 ahead;
  an event booked more than a frame in the past (it would repeat to catch
  up: the display line, the sound mixer's tick) or 2^40 cycles ahead; the
  current line's start, the mixer's next tick, cycles an instruction has
  not charged yet (`wait9`/`wait7`, `icycles`) outside their frame; an
  instruction cost, a timer unit's events, a DMA unit's or a display
  engine's identity other than the machine's own constants; the GBA slot's
  access times past 18. Every other dated field
  (timers, the divider, the busy flags, wifi's timers and frames in
  flight, the 3D engine's FIFO and rendering, the RTC's tick bases) within
  2^55 of zero, so a difference of two cannot overflow; the mic queue's
  position not after now, its rate at most 2^20 a second. `next`, the
  earliest booking, is rebuilt from the events rather than read: one later
  than the first event stopped the clock there for good.
- **ARM9 caches.** A line held is main RAM's and in the set its address
  picks, the data cache holds it in one slot, an empty slot holds nothing
  dirty, round-robin and victim pointers stay in their sets; the per-line
  and per-page tables built from the slots (`slot_of`, `page_apart`,
  `shadows`) are rebuilt instead of read.
- **3D.** A polygon's vertices inside its list, the vertex count, matrix
  mode, primitive, stack pointers and viewport within what the commands
  mask them to, the lines drawn so far of a frame within 192.
- **DMA and display.** A running block no longer than DMAxCNT can ask for
  (it runs to its end in one go), the main-memory display's pixels still
  to request within a frame, the stylus on the bottom screen.
- **Sound.** SOUNDxLEN within its 22 bits, the ADPCM decoder's sample
  within 16 bits, the read-ahead between the word playing and FIFO_WORDS
  past it, the timer count under a step past 0x10000, a start delay of at
  most 11 samples; a capture unit's gathered bytes and words left.
- **GBA slot.** The save chip's memory as long as its type's, a FLASH bank
  inside it (and a bank switch only on a 1 Mbit part), the EEPROM's bit
  counts; wifi's TX header address.

After the fixes, sweeps setting each byte to 0xFF, 0x7F and 0x00 in
fb_both (frame 120), 3d_texfmt (frame 60) and SoulSilver (p12 frame 7000,
also 0x80) -- 461,337 states -- and 4,200 random multi-byte mutants of the
three find nothing uncontained. `tests/nds_savestate_test.nim`
`hostile_fields` writes such values with the real saver and offers them to
another machine, which refuses each and stays as it was. Every check holds for states taken at 45 moments each of
eleven test ROMs (real and HLE BIOS) and 43 each from four SoulSilver
states (3000, 5000, 7000, 8000), which load and save back byte for byte.

## Evidence

`tests/nds_savestate_test.nim` (`nimble test_ndssavestate`; the test ROMs
from `~/.cache/dingbat-nds/roms`): for each case it saves at an awkward
moment, runs the original 90 frames, loads the state into a fresh machine
(one that has run a frame of its own) and runs 90 frames: both screens
after every frame and all the sound must hash the same, and at the end
every saved field of the two machines must be equal. Saving the loaded
machine again must give the same bytes, and the packed state must do the
same. The moments: mid-frame (3d_sort, Simple_Quad, 2Dplus3D), GX FIFO
entries queued behind SWAP_BUFFERS (3d_timing_fifo), a geometry-FIFO DMA
stopped mid-block (a 1000-word mode-7 DMA poked into fb_both behind a
pending swap), sound channels playing mid-frame (snd_suite), a card
transfer in flight (cardread), the BIOS's KEY1 card handshake in flight on
a firmware boot (hello_world; with the dumps), slot2_probe with a GBA cart
(FLASH) and with an Expansion Pak, mic samples queued (periph_suite), the
ARM7 asleep, and two machines on one Air with the wifi_link ROM, saved
with a frame in flight and linked again (every saved field of both
machines equal 120 frames on). Refusals: another game, a damaged payload,
a cut-off file, garbage, another layout, another BIOS kind (with dumps:
both directions), another GBA-slot device, a marker out of place -- each
leaving the machine untouched. The test machines' RTC runs on emulated
time: on the host clock its last-update time differs between two runs.
Passes with the BIOS dumps and with the HLE BIOS.

Cross-build: a state saved by native `ndsrun` (2Dplus3D, frame 60) loaded
into the wasm build, run 60 frames and saved again gives a file
byte-identical to native `ndsrun`'s own state at frame 120.

Pokemon SoulSilver (local only; the ROM is never in the repo), on the
integrated branch (worktree-nds-skeleton d785bd48 merged), real BIOS and
firmware, `--rtc 2004-01-01`, the p14 input script (p12's route to New
Bark Town, then the touch menu's SAVE): one uninterrupted run to frame
14000 wrote states at 3000 (the professor), 6600 (the 3D bedroom) and
10600 (New Bark Town); a separate `ndsrun --state-load` run from each,
also to 14000:

| Resumed from | Frames 8000 / 10600 / 12500 / 14000 | Sound | 512 KB FLASH at the end |
|---|---|---|---|
| 3000 | byte-identical PNGs | 6,017,666 stereo frames, the uninterrupted WAV's exact tail | identical |
| 6600 | byte-identical | 4,048,248 frames, exact tail | identical |
| 10600 (overworld) | 12500 / 14000 byte-identical | 1,860,005 frames, exact tail | identical |

Both CPUs' instruction counts at frame 14000 are the same in all four
runs. Between 10600 and 14000 the game saves to FLASH ("Saving a lot of
data...", done by 14000); booting a fresh machine on the FLASH image the
run resumed from the overworld state wrote shows CONTINUE with the player,
time 0:01 -- the state survived the load and the save after it. The same
held before the merge (the branch's own build: states at 3000/6600 resumed
to 12500, and the 10600 state through the save to 14000). The p12
regression frames 3000/5000/8000 are byte-identical to d785bd48's build:
the state code changes no emulation.

## Size and speed

Raw payload: about 5.45 MB for a homebrew game (4 MB main RAM, 656 KB
VRAM, the 192 KB 3D frame, the two 96 KB screens, WRAM/TCM), 6.05-6.18 MB
for SoulSilver (+ its 512 KB FLASH; the polygon/vertex RAM varies with the
scene), +8 MB with an Expansion Pak. Packed (zlib BestSpeed, the stored
form): 9-370 KB for the test ROMs, 1.92-2.10 MB for SoulSilver.

Native (Apple Silicon, release build, SoulSilver at New Bark Town; the
machine was shared with other jobs, load average 85, so medians run high):

| Step | Median | Min |
|---|---|---|
| `state_payload` (the walk) | 0.74 ms | 0.62 ms |
| `load_state_payload` (backup walk + apply + rebuild) | 1.42 ms | 1.12 ms |
| `state_bytes` (+ the container's fnv1a over 6 MB) | 18.3 ms | 12.9 ms |
| `pack_state` | 39.6 ms | 32.2 ms |
| `unpack_state` | 32.9 ms | 27.6 ms |
| `load_state_bytes`, plain / packed | 33.4 / 58.4 ms | 27.9 / 51.8 ms |

Wasm (headless Chromium, the danger build, 2Dplus3D, 5.46 MB / 363 KB
packed): `nds_state_size` (save + pack) 36 ms, `nds_state_load` (unpack +
load) 51 ms. The image's cost is the container -- the 6 MB fnv1a and zlib
-- not the walk; from the native/wasm ratio of the full path (about 1.5x),
a bare `state_payload` / `load_state_payload` in wasm should take 1-3 ms.

For rewind: two SoulSilver payloads one frame apart differ in 45,863
bytes (with the variable-length sections last; 362,360 before that
reorder), and their XOR deflates to 57 KB (132 KB before), against 1.87 MB
for one payload alone. A ring of one-frame deltas at 60 Hz is then about
3.4 MB per second of history before any thinning; snapshots a few frames
apart cost about the same each, since most of the change is the 3D frame,
the screens and the polygon RAM.

## Left

- Rewind and run-ahead in a frontend (`state_payload` /
  `load_state_payload` are the hooks; main's `common/rewind.nim` takes
  payload strings).
- Migrations once DS states must outlive a build (see Compatibility).
- Firmware writes (user settings saved through SPI) are not in the state:
  they persist in the firmware image the frontend keeps, if any.
