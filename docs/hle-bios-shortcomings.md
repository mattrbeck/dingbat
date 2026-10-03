# HLE BIOS: known gaps

`src/dingbat/gba/hle_bios.nim`. The HLE BIOS passes the same mGBA suite rows as
the official BIOS except where noted in `tests/results_mgba_suite.md`. What
it deliberately does not model:

* **The BIOS-resident MP2K sound driver** (`hle_sound.nim`) is modelled
  from the real BIOS's observed behaviour (probe ROMs and harness in
  `tools/biosdrv`, `tests/biosdrv_probe.nim`): SoundDriverInit, Mode, VSync,
  VSyncOff, VSyncOn, ChannelClear, SoundDriverMain's PCM mixer, MidiKey2Freq
  and every SoundGetJumpList function (the score commands, TrackStop with
  its CgbOscOff calls, FadeOutBody, TrkVolPitSet, SampleFreqSet,
  RealClearChain). Results, register and SoundArea stores are exact in the
  probes; the setup routines, SampleFreqSet and the jump-list functions are
  cycle-exact in them too (the jump list for structures and scores in
  IWRAM, EWRAM and the cartridge), each sound/timer/DMA register write
  lands on the real routine's cycle from every caller region, and what the
  routines leave on the stack below sp matches. A sound DMA that drains the
  slot SoundDriverMain is mixing (the first passes after a start) reads the
  bytes the real routine had written by then. On the real-game set (1800 frames each, HLE vs the real BIOS
  image) the FIFO A/B byte streams are identical for Namco Museum 50th
  (U, E), Lizzie McGuire On The Go and (E), Mail de Cute, Pocket Professor,
  Rampage Puzzle Attack, X-Men Reign of Apocalypse, Phantasy Star Collection
  (U, E), Cyberdrive Zoids, Saibara Rieko no Dendou Mahjong and Atari
  Anniversary Advance. Not modelled:
  - the mixer's time is charged by a per-path model, within 1-3 cycles of
    the real routine on most passes (a pass that starts many resampled
    channels at once was 12 short, a one-shot ending in the pass that
    started it in an EWRAM SoundArea 3 long); its CGB side is the game's
    +0x28 callback, as on the real BIOS;
  - SoundDriverMain's mixing locals below sp-48, and the three words under
    Init's and VSyncOff's real pushes (sp-36..-44 keep the HLE frame);
    other registers than the ones the probes pin (r1 after the mix is 0);
  - the timing of each mixing write is the cost model's (within ~20 cycles
    of the real stores), so a DMA read racing the pass can differ at the
    byte the model misplaces;
  - Init's first two writes (the DMA stops) land up to ~20 cycles late when
    the caller's region makes the HLE's return refill longer than the real
    dispatch's lead;
  - the MusicPlayer SWIs 0x20-0x24 and the BIOS's own sequencer entry
    (SoundInfo +0x38, 0x2425) are stubs: no title in the library census
    calls them;
  - a MidiKey2Freq key negative as a signed word is clamped (the real
    routine indexes out of its table);
  - an ARM callback at exactly 0x03000000 is entered 10 cycles later than
    by the real call; Cyberdrive Zoids' voice command with its tone table
    in the cartridge returns a cycle early.
  Left in that set: 15 of Cyberdrive Zoids' frames from 968 (it reads stale
  stack words; what still differs there is SoundDriverMain's mixing
  locals), Gameboy Player
  Controller's stream from byte 11282 (its multiboot LZ77UnCompWram, EWRAM
  to EWRAM, runs ~243k cycles short of the real one, which moves the sound
  start), the FFCC loader's frame 3 and last silent FIFO burst (its first
  SoundDriverMain pass, on a SoundArea it set up itself, runs ~20 cycles
  long; not pinned down), Phantasy Star Collection's one lag frame, Lizzie
  McGuire (E)'s frames from 372 and X-Men's from 1680 (streams identical).
* **Interrupted copies** (CpuSet, CpuFastSet) run instruction by
  instruction (`hle_copy.nim`) and take an interrupt at the console's
  boundary, parked in BIOS code with their state in registers, so the call
  times and interrupt entries match the official BIOS on tools/biosdrv/
  cpusi.c, cpusi4.c and fastsi.c. Not modelled: an interrupt that arrives
  in the dispatcher between its `msr` and the routine (7 cycles: the push,
  `add lr`, `bx`) or in the routine's setup before its loop is taken at the
  loop's first boundary; the DMA a store to I/O arms is granted on the
  console's cycle because the store lands a cycle early; while parked, the
  System stack still holds the routine's frame where the console has
  popped part of it (only in the exit), and r0-r12 hold the HLE's state, not
  the console routine's registers.
* **Interrupted decompression sees finished output.** The decompressors,
  Diff filters, BitUnPack, the affine sets and GetBiosChecksum write their
  output (the math routines Div, DivArm, Sqrt, ArcTan and ArcTan2 their
  result registers) up front and then charge the whole cost model as
  routine time that stops on the cycle an interrupt line rises; the
  remainder rides the halt-resume path (also at the end of a video frame,
  so the frame loop stops where the console's does). A handler inspecting
  the destination mid-call sees the completed output, and so does the
  renderer: a frame drawn while a long LZ77UnCompVram is under way shows
  tiles the console has not written yet (Top Gun - Combat Zones' fade at
  frame 1328). A DMA burst inside one of these bodies stalls the whole model
  where the console grants it at the routine's access boundaries and runs
  part of it under internal cycles: Castlevania - Circle of the Moon's sound
  FIFO bursts inside its LZ77UnCompWrams move each call a cycle or two (the
  same stream, no DMA: exact), which shifts its busy-wait loop from frame
  324 and a particle at frame 5318. The interrupt is taken on
  the cycle the line rises; the console takes it at the end of the BIOS
  instruction in progress, 0-5 cycles later (Castlevania - Circle of the
  Moon's timer IRQ inside a cartridge LZ77UnCompWram lands 2 cycles early,
  which is enough to move its busy-wait loop's phase and, at frame 5319,
  a timer-seeded particle). An LZ77UnCompWram from the cartridge runs 5-7%
  short of the real routine on small streams (tools/biosdrv/lz77t.c: 99-143
  cycles on a 64-byte one); from EWRAM it is exact, preempted or not
  (lz77i.c, Thumb caller in the cartridge too).
* **Renderer contention in routine bodies is read ahead.** A routine that
  writes (or, LZ77UnCompVram, reads back) palette RAM, VRAM or OAM pays the
  renderer's waits for each access at the cycle its model places it,
  computed when the call starts with the display registers as they stand.
  The interrupt handlers and DMA bursts that will run inside the call shift
  the real accesses against the renderer, and display writes made during
  the call change its fetch pattern; neither is seen. Banjo-Kazooie -
  Grunty's Revenge's two title LZ77UnCompVrams (7 and 8 IRQs, sound DMA
  throughout) run 10 cycles short and 2053 long of the console's ~1M each,
  where without contention they ran 9639 and 17136 short. Where in
  each step the accesses fall is the official BIOS's own timing for
  LZ77UnCompVram, CpuSet and CpuFastSet, assumed for the rest. Even where
  it is the BIOS's own, a cartridge-to-VRAM CpuFastSet during the display
  still lands up to ~100 cycles either side of the console's (Fire Emblem:
  The Sacred Stones' 256-word copies; not pinned down).
* **Interrupted RegisterRamReset** encodes its continuation in r0 (bit 31
  marker, bit 30 a stop at a frame's end, the body time reached in bits
  8-29, the flags). A caller passing bit 31 set with garbage mid bits would
  be misread; compilers emit clean flag bytes. A resume after an interrupt
  pays a second dispatch (a frame-end resume does not); with WAITCNT's
  prefetch on, a call with the other-I/O group returns a cycle late.
* **The reset vector (a jump to 0) re-runs an HLE boot** that waits out the
  real duration (270 vblanks plus the tail to scanline 126, measured against
  real-BIOS execution) with the display force-blanked and hands over the
  measured post-boot state — but VRAM/palette keep the pre-jump contents
  (no logo) and the jingle is silent. A jump landing exactly on a vblank
  start counts that vblank.
* **`IntrWait(discard=0)` returns without halting when a masked flag is
  already set.** The real routine halts at least once, and its first halt
  uses the caller's stale r12 for the HALTCNT store. No ROM in the tree
  exercises the difference; Assumed.
* **Handler-visible r2/r4/lr/r11 during a wait** keep caller values (real:
  mirror value / 1 / BIOS return address / spsr scratch). No known convention
  reads them. r12 = 0x04000000 is modelled (the devkitARM crt0 IntrWait ack).
* **Nested IntrWait** (a handler calling IntrWait/Stop while one is active)
  overwrites the single set of resume fields; the real BIOS nests through the
  stack. The parked decompression/RamReset remainder shares those fields.
  Halt is exempt: it parks in the stub BIOS on the `bx lr` after its HALTCNT
  write, keeps its return on the SVC and System stacks, and returns through
  a trap at 0x170 (`hle_halt`), so it nests, and an interrupt taken during
  it pushes the BIOS address the console's does. Its SVC frame holds the
  caller's CPSR where the console's dispatcher keeps r11.
