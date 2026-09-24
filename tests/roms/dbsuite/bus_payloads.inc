@ bus_gen.inc -- the bus suite's link-rig payloads (included by
@ suite_bus.inc).  Each payload is carried byte for byte and run at
@ 0x03000000, as the rig's monitor ran it; SLOT+0x100 holds the result
@ block it leaves at 0x02008000.

@ ─────────────────────── cartridge-window wait states ─────────────────────
@ WHAT: tests/roms/payloads/waitcnt.s -- 64 sequential 32-bit reads of the
@ cartridge window past any image (0x09000000), timed from IWRAM, at six
@ WAITCNT settings.
@ WHY: wait states are the memory controller's, cartridge or not: an
@ emulator whose gamepak timing ignores WAITCNT, or charges an empty
@ window nothing, fails.  Prefetch on/off makes no difference to data
@ loads from IWRAM code.
@ PROVENANCE: AGB SP through tools/hwlink (payloadcmp), 2026-09-17, no
@ cartridge in the slot: the console, dingbat and mGBA agreed on all six
@ (memory note gba-hardware-link-2026-09-17); the values are that run's.
    payload_blob pl_waitcnt, "waitcnt.bin"
    cpay "rom-window-64-reads-ws0-4-2", pl_waitcnt, 0x0000, 0x0000037E
    cpay "rom-window-64-reads-ws0-3-2", pl_waitcnt, 0x0004, 0x0000033E
    cpay "rom-window-64-reads-ws0-2-2", pl_waitcnt, 0x0008, 0x000002FE
    cpay "rom-window-64-reads-ws0-3-1", pl_waitcnt, 0x0014, 0x000002FE
    cpay "rom-window-64-reads-ws0-3-1-pf", pl_waitcnt, 0x4014, 0x000002FE
    cpay "rom-window-64-reads-ws0-4-2-pf", pl_waitcnt, 0x4000, 0x0000037E

@ ───────────────────── open bus from ARM and Thumb code ────────────────────
@ WHAT: tests/roms/payloads/obusprobe.s -- a read of unmapped memory
@ (0x10000000) from ARM code, from Thumb LDR and LDRH at both word
@ alignments (loads at 0x030000F0/FA and 0x03000104/10E), and 0/1/2
@ instructions after an immediate 4-word DMA whose last word is DEADBEE3.
@ WHY: ARM reads the opcode at $+8 (E58A0000 here); a Thumb read from
@ IWRAM is composed from the two most recent fetches, each in the half its
@ OWN address bit 1 selects -- not a duplicated [$+4]: 3E0260A8 and
@ 61283E02 are the same two opcodes in swapped halves, and LDRH takes the
@ half the read address selects.  The DMA's last word is on the bus for
@ exactly one instruction: the read right after the enabling store sees an
@ opcode (the burst has not run), the next sees DEADBEE3, the one after an
@ opcode again.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18: docs/gbatek-
@ upstream.md 1.1 quotes 3E0260A8 (0x030000F0) and 61283E02 (0x030000FA);
@ the window's shape is quoted in tests/roms/payloads/obuswin.s's header.
@ The LDRH and opcode cells are those rules applied to this payload's own
@ bytes (it is carried byte for byte).
    payload_blob pl_obusprobe, "obusprobe.bin"
    cword "obus-arm-reads-pc-plus-8", run_payload, 0x100, 0xE58A0000, 0, pl_obusprobe, 0
    cword "obus-thumb-ldr-align-a", RUN_SAME, 0x108, 0x3E0260A8
    cword "obus-thumb-ldr-align-b", RUN_SAME, 0x110, 0x61283E02
    cword "obus-thumb-ldrh-align-a", RUN_SAME, 0x118, 0x000061A8
    cword "obus-thumb-ldrh-align-b", RUN_SAME, 0x120, 0x00003E02
    cword "obus-0-insns-after-dma", RUN_SAME, 0x128, 0xE59F0068
    cword "obus-1-insn-after-dma-dma-word", RUN_SAME, 0x12C, 0xDEADBEE3
    cword "obus-2-insns-after-dma", RUN_SAME, 0x130, 0xE59F0024

@ WHAT: tests/roms/payloads/obuswin.s -- the same DMA, then one kind of
@ work, then the unmapped read (ARM, IWRAM).  Only the rows the record
@ states are checked.
@ WHY: the read one 1-cycle NOP after the burst sees the DMA's word, two
@ NOPs after it does not, and a single MUL -- no data access at all --
@ already ends it: what ends the window is the CPU's next bus access of any
@ kind, opcode fetches included, not the next gamepak access.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.2; obuswint.s's header: "the read one 1-cycle NOP after
@ the burst sees the DMA's word, the read two NOPs after does not").  The
@ opcode cells are ARM's [$+8] in this payload's bytes.
    payload_blob pl_obuswin, "obuswin.bin"
    cword "obuswin-nothing-burst-not-run", run_payload, 0x100, 0xE59F0198, 0, pl_obuswin, 0
    cword "obuswin-1-nop-dma-word",  RUN_SAME, 0x104, 0xDEADBEE3
    cword "obuswin-2-nops-closed",   RUN_SAME, 0x108, 0xE59F0144
    cword "obuswin-mul-closes",      RUN_SAME, 0x10C, 0xE59F011C

@ WHAT: tests/roms/payloads/obuswint.s -- the post-DMA window from Thumb
@ code in IWRAM, 0-3 NOPs after the burst.
@ WHY: the latch is per halfword: two NOPs after the burst the console
@ returns DEAD6019 -- the DMA word's high half beside a fresh opcode
@ halfword.  A model that answers "the whole DMA word or none" cannot
@ produce it.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.2 quotes DEAD6019).
    payload_blob pl_obuswint, "obuswint.bin"
    cword "obuswint-2-nops-half-dma-word", run_payload, 0x108, 0xDEAD6019, 0, pl_obuswint, 0

@ WHAT: tests/roms/payloads/obusbus.s -- the identical Thumb block run from
@ IWRAM, EWRAM, VRAM and OAM, reading 0x10000000 four ways (LDR and LDRH
@ at both alignments).
@ WHY: how much of the open-bus latch one fetch fills decides the answer:
@ 16-bit memories (EWRAM, VRAM) mirror the fetched halfword into both
@ halves, IWRAM drives only its own half, OAM fills the whole word.  Bus
@ width alone is the wrong rule (OAM is 32-bit and differs from IWRAM).
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.1 table; display on and in forced blank alike).  The cell
@ values are that table's rule applied to this payload's own bytes (dingbat
@ implements the rule since 326f55591).
    payload_blob pl_obusbus, "obusbus.bin"
    cword "obusbus-iwram-ldr-a",    run_payload, 0x100, 0x3E026028, 0, pl_obusbus, 0
    cword "obusbus-iwram-ldr-b",    RUN_SAME, 0x108, 0x60A83E02
    cword "obusbus-iwram-ldrh-a",   RUN_SAME, 0x110, 0x00006128
    cword "obusbus-iwram-ldrh-b",   RUN_SAME, 0x118, 0x00003E02
    cword "obusbus-ewram-ldr-a",    RUN_SAME, 0x140, 0x60286028
    cword "obusbus-ewram-ldr-b",    RUN_SAME, 0x148, 0x60A860A8
    cword "obusbus-ewram-ldrh-a",   RUN_SAME, 0x150, 0x00006128
    cword "obusbus-ewram-ldrh-b",   RUN_SAME, 0x158, 0x000061A8
    cword "obusbus-vram-ldr-a",     RUN_SAME, 0x180, 0x60286028
    cword "obusbus-vram-ldr-b",     RUN_SAME, 0x188, 0x60A860A8
    cword "obusbus-vram-ldrh-a",    RUN_SAME, 0x190, 0x00006128
    cword "obusbus-vram-ldrh-b",    RUN_SAME, 0x198, 0x000061A8
    cword "obusbus-oam-ldr-a",      RUN_SAME, 0x1C0, 0x606E6028
    cword "obusbus-oam-ldr-b",      RUN_SAME, 0x1C8, 0x60A83E02
    cword "obusbus-oam-ldrh-a",     RUN_SAME, 0x1D0, 0x00006128
    cword "obusbus-oam-ldrh-b",     RUN_SAME, 0x1D8, 0x00003E02
