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
  to EWRAM, ran ~243k cycles short of the real one before the routine ran
  as stub-BIOS code, which moved the sound start; not re-measured since), the FFCC loader's frame 3 and last silent FIFO burst (its first
  SoundDriverMain pass, on a SoundArea it set up itself, runs ~20 cycles
  long; not pinned down), Phantasy Star Collection's one lag frame, Lizzie
  McGuire (E)'s frames from 372 and X-Men's from 1680 (streams identical).
* **The routines run as stub-BIOS code** (`hle_unc.nim`): RegisterRamReset,
  IntrWait, VBlankIntrWait, Div, DivArm, Sqrt, ArcTan, ArcTan2, CpuSet,
  CpuFastSet, GetBiosChecksum, BgAffineSet, ObjAffineSet, BitUnPack,
  LZ77UnCompWram/Vram, HuffUnComp, RLUnCompWram/Vram, the Diff filters,
  SoundBias and MidiKey2Freq, and the SWI dispatch and return around them.
  Each console instruction is a step of its own in the stub BIOS that makes
  that instruction's accesses and internal cycles, in its order, so
  interrupts are taken at the console's boundaries (the dispatcher's window
  between its `msr` and the routine included), DMA is granted between the
  accesses and runs under the internal cycles, renderer contention meets
  each access as it is made, a handler or the renderer sees the output
  written so far, the frame loop stops between two steps and a save state
  holds a routine in progress. Every step of every call matches the
  official BIOS in this core on the tools/biosdrv probes (steptrace.nim,
  stepcmp.py; docs/playtest-bugs.md, the stub-BIOS section). Not modelled:
  - the registers an interrupt handler finds are the console's for
    LZ77UnCompWram/Vram and IntrWait (r12 = 0x04000000, r4 = 1, r2 the
    mirror, lr the console's return addresses); in the other routines r0-r12
    mid-call hold this file's state (within the registers the console's
    routine uses; the values left at the end are the console's), and the
    IRQ's lr and the return addresses pushed on the System stack are stub
    label addresses, not the console's BIOS addresses. The dispatcher's
    r12 is a label address too;
  - a BIOS read from a routine's body (the open-bus value an access to an
    unmapped region returns, a BIOS-source CpuSet or decompression stream)
    sees the stub, not the official image; GetBiosChecksum returns the
    official sum, but a handler sees no partial sum in r0 mid-call;
  - Div and DivArm with a zero divisor and a dividend of 2 or more hang the
    console; here they return as for a dividend of 1;
  - a MidiKey2Freq key negative as a signed word is clamped (the console
    indexes out of its table);
  - the step labels' order is part of the save-state format (a state holds
    r15 inside the stub): new steps may only be appended to the enums;
  - a state saved by an earlier build mid-copy, mid-decompression or inside
    an IntrWait resumes on the old parked paths (`hle_copy.nim`, the
    halt-resume fields), which keep the earlier gaps (no nesting, finished
    output seen mid-call); one saved in an interrupted RegisterRamReset
    (r0 bit 31, the old continuation) runs the routine again from its
    start on the flags in r0's low byte.
* **Halt and Stop** keep their models. Halt parks in the stub BIOS on the
  `bx lr` after its HALTCNT write, keeps its return on the SVC and System
  stacks, and returns through a trap at 0x170 (`hle_halt`), so it nests,
  and an interrupt taken during it pushes the BIOS address the console's
  does. Its SVC frame holds the caller's CPSR where the console's
  dispatcher keeps r11.
* **The reset vector (a jump to 0) re-runs an HLE boot** that waits out the
  real duration (270 vblanks plus the tail to scanline 126, measured against
  real-BIOS execution) with the display force-blanked and hands over the
  measured post-boot state — but VRAM/palette keep the pre-jump contents
  (no logo) and the jingle is silent. A jump landing exactly on a vblank
  start counts that vblank.
