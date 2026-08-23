# HLE BIOS: known gaps

`src/dingbat/gba/hle_bios.nim`. The HLE BIOS passes the same mGBA suite rows as
the official BIOS except where noted in `tests/results_mgba_suite.md`. What
it deliberately does not model:

* **The BIOS-resident MP2K sound driver body.** `SoundGetJumpList` (SWI
  0x2A) returns the real BIOS's 36 pointers and only entry 35 (channel
  clear) does anything. `SoundDriverMain` (SWI 0x1C) performs the real
  ident-magic lock, calls the two game-registered callbacks
  (`[info+32]([info+36])`, `[info+40](info)`) in SVC mode and unlocks; the
  PCM/CGB mixer is not modelled, so no BIOS-driver audio is produced, the
  SoundInfo bookkeeping (`pcmDmaCounter`…) never updates, and the MPlay
  score handlers behind the jump list are inert. Games that sequence music
  through the BIOS engine wedge where they block on that state (Cyberdrive
  Zoids at its title, Saibara Rieko no Dendou Mahjong in its frame loop).
  Fixing it means the score interpreter (~26 routines) plus the mixer's
  SoundInfo protocol.
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
  uses the caller's stale r12 for the HALTCNT store. Pinned only by oracle
  comparison.
* **Handler-visible r2/r4/lr/r11 during a wait** keep caller values (real:
  mirror value / 1 / BIOS return address / spsr scratch). No known convention
  reads them. r12 = 0x04000000 is modelled (the devkitARM crt0 IntrWait ack).
* **Nested IntrWait** (a handler calling IntrWait/Halt while one is active)
  overwrites the single set of resume fields; the real BIOS nests through the
  stack. The parked decompression/RamReset remainder shares those fields.
