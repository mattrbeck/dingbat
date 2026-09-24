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
@ (memory note gba-hardware-link-2026-09-17).  Re-read on the SP by
@ dbsuite's own multiboot run (README "Provenance").
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
@ alignments, and 0/1/2 instructions after an immediate DMA whose last
@ word is DEADBEE3.
@ WHY: ARM reads the opcode at $+8 (here E58A0000); a Thumb read from
@ IWRAM is composed from the two most recent fetches, each in the half its
@ own address bit 1 selects -- NOT a duplicated [$+4] (3E0260A8 and
@ 61283E02 are the same two opcodes swapped).  The DMA's word survives on
@ the bus for exactly one instruction.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.1 quotes 3E0260A8 / 61283E02; memory note
@ gba-hardware-link-2026-09-17 "obusprobe.s closed THUMBBUS"); the full
@ block re-read on the SP by dbsuite's multiboot run.
    payload_blob pl_obusprobe, "obusprobe.bin"
    cword "obus-arm-reads-pc-plus-8", run_payload, 0x100, 0xE58A0000, 0, pl_obusprobe, 0
    cword "obus-thumb-ldr-align-a", RUN_SAME, 0x108, 0x3E0260A8
    cword "obus-thumb-ldr-align-b", RUN_SAME, 0x110, 0x61283E02
    cword "obus-thumb-ldrh-align-a", RUN_SAME, 0x118, 0x000061A8
    cword "obus-thumb-ldrh-align-b", RUN_SAME, 0x120, 0x00003E02
    cword "obus-0-insns-after-dma", RUN_SAME, 0x128, 0xE59F0068
    cword "obus-1-insn-after-dma",  RUN_SAME, 0x12C, 0xE59F0040
    cword "obus-2-insns-after-dma", RUN_SAME, 0x130, 0xE59F0024

@ WHAT: tests/roms/payloads/obuswin.s -- the same DMA, then one kind of
@ work, then the unmapped read (ARM, IWRAM).  The gamepak-load rows are
@ left out: the rig ran them with an empty slot.
@ WHY: what ends the post-DMA window is the CPU's next bus access of any
@ kind, opcode fetches included -- not specifically the next gamepak
@ access, and not a count of instructions or cycles.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.2); re-read by dbsuite's multiboot run.
    payload_blob pl_obuswin, "obuswin.bin"
    cword "obuswin-nothing",        run_payload, 0x100, 0xE59F0198, 0, pl_obuswin, 0
    cword "obuswin-1-nop",          RUN_SAME, 0x104, 0xE59F0170
    cword "obuswin-2-nops",         RUN_SAME, 0x108, 0xE59F0144
    cword "obuswin-mul",            RUN_SAME, 0x10C, 0xE59F011C
    cword "obuswin-ldr-iwram",      RUN_SAME, 0x110, 0xE59F00F4
    cword "obuswin-ldr-ewram",      RUN_SAME, 0x114, 0xE59F00CC
    cword "obuswin-ldm-4-regs",     RUN_SAME, 0x124, 0xE59F0030

@ WHAT: tests/roms/payloads/obuswint.s -- the post-DMA window from Thumb
@ code in IWRAM, 0-3 NOPs after the burst.
@ WHY: the latch is per halfword: two NOPs after the burst the console
@ returns DEAD6019 -- the DMA word's high half beside a fresh opcode
@ halfword.  A model that answers "the whole DMA word or none" cannot
@ produce it.
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.2 quotes DEAD6019); re-read by dbsuite's multiboot run.
    payload_blob pl_obuswint, "obuswint.bin"
    cword "obuswint-0-nops",        run_payload, 0x100, 0x60196028, 0, pl_obuswint, 0
    cword "obuswint-1-nop",         RUN_SAME, 0x104, 0x60196068
    cword "obuswint-2-nops",        RUN_SAME, 0x108, 0x60A86019
    cword "obuswint-3-nops",        RUN_SAME, 0x10C, 0x60E84770

@ WHAT: tests/roms/payloads/obusbus.s -- the identical Thumb block run from
@ IWRAM, EWRAM, VRAM and OAM, reading 0x10000000 four ways (LDR and LDRH
@ at both alignments).
@ WHY: how much of the open-bus latch one fetch fills decides the answer:
@ 16-bit memories (EWRAM, VRAM) mirror the fetched halfword into both
@ halves, IWRAM drives only its own half, OAM fills the whole word.  Bus
@ width alone is the wrong rule (OAM is 32-bit and differs from IWRAM).
@ PROVENANCE: AGB SP through tools/hwlink, 2026-09-18 (docs/gbatek-
@ upstream.md 1.1 table; display on and in forced blank alike); re-read
@ by dbsuite's multiboot run.
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
