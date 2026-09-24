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
  IWRAM, EWRAM and the cartridge), and so is what they leave on the stack
  below sp. On the real-game set (1800 frames each, HLE vs the real BIOS
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
  - the MusicPlayer SWIs 0x20-0x24 and the BIOS's own sequencer entry
    (SoundInfo +0x38, 0x2425) are stubs: no title in the library census
    calls them;
  - a MidiKey2Freq key negative as a signed word is clamped (the real
    routine indexes out of its table);
  - an ARM callback at exactly 0x03000000 is entered 10 cycles later than
    by the real call; Cyberdrive Zoids' voice command with its tone table
    in the cartridge returns a cycle early.
  Left in that set: Cyberdrive Zoids' frames from 531 (its loop reads stack
  words the real BIOS's non-sound SWIs leave different), Gameboy Player
  Controller's stream from byte 11282 (its multiboot LZ77UnCompWram, EWRAM
  to EWRAM, runs ~243k cycles short of the real one, which moves the sound
  start), the FFCC loader's frame 3 and last silent FIFO burst (its first
  SoundDriverMain pass, on a SoundArea it set up itself, runs ~20 cycles
  long; not pinned down), Phantasy Star Collection's one lag frame, Lizzie
  McGuire (E)'s frames from 519 and X-Men's from 1718 (streams identical).
* **Interrupted-copy register remnants.** An IRQ preempting CpuSet /
  CpuFastSet leaves the continuation in r0/r1/r2 (PC rewound onto the SWI).
  On that path only, the halfword forms advance r0/r1 (the real routine
  leaves them) and r2's count counts down; each preemption re-pays the SWI
  dispatch (~50 cycles).
* **Interrupted decompression sees finished output.** LZ77/Huffman/RL are
  preempted at faithful cycle positions (the uncharged remainder rides the
  halt-resume path), but the destination is written up front, so a handler
  inspecting it mid-call sees the completed output. Diff/BitUnPack are
  atomic.
* **Interrupted RegisterRamReset** encodes its continuation in r0 (bit 31
  marker, remaining phase charge in bits 8–29, pending flags). A caller
  passing bit 31 set with garbage mid bits would be misread; compilers emit
  clean flag bytes.
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
