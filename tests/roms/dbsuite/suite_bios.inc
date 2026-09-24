@ suite_bios.inc -- what the BIOS's arithmetic calls answer at their
@ edges: division by zero, the one overflowing quotient, both ends of
@ Sqrt, ArcTan and ArcTan2 on the axes and at the origin.

    suite "bios"

@ WHAT/WHY: tests/roms/payloads/swiedge.s -- 24 SWI results at 0x02008000.
@ An HLE BIOS is its author's code standing in for Nintendo's; these are
@ the inputs where an implementation had to make a decision (Div 1/0
@ answers quotient 1, remainder 1; -1/0 keeps the sign; 0x80000000/-1
@ returns 0x80000000; ArcTan2 of the origin is 0).
@ PROVENANCE: AGB SP through tools/hwlink (payloadcmp), 2026-09-18, the
@ real BIOS: 0 of 96 bytes differ from dingbat's HLE (memory note
@ gba-hardware-link-2026-09-17, "swiedge closed"), and dingbat's answers
@ are the values below; re-read on the SP by dbsuite's multiboot run.
    payload_blob pl_swiedge, "swiedge.bin"
    cword "get-bios-checksum",      run_payload, 0x100, 0xBAAE187F, 0, pl_swiedge, 0
    cword "div-10-3-quotient",      RUN_SAME, 0x104, 3
    cword "div-10-3-remainder",     RUN_SAME, 0x108, 1
    cword "div-neg7-2-quotient",    RUN_SAME, 0x10C, 0xFFFFFFFD
    cword "div-neg7-2-remainder",   RUN_SAME, 0x110, 0xFFFFFFFF
    cword "div-1-0-quotient",       RUN_SAME, 0x114, 1
    cword "div-1-0-remainder",      RUN_SAME, 0x118, 1
    cword "div-neg1-0-quotient",    RUN_SAME, 0x11C, 0xFFFFFFFF
    cword "div-min-neg1-quotient",  RUN_SAME, 0x120, 0x80000000
    cword "div-min-neg1-remainder", RUN_SAME, 0x124, 0
    cword "divarm-10-3-quotient",   RUN_SAME, 0x128, 3
    cword "sqrt-0",                 RUN_SAME, 0x12C, 0
    cword "sqrt-1",                 RUN_SAME, 0x130, 1
    cword "sqrt-3fffffff",          RUN_SAME, 0x134, 0x7FFF
    cword "sqrt-ffffffff",          RUN_SAME, 0x138, 0xFFFF
    cword "arctan-0",               RUN_SAME, 0x13C, 0
    cword "arctan-1",               RUN_SAME, 0x140, 0x2000
    cword "arctan-neg1",            RUN_SAME, 0x144, 0xFFFFE000
    cword "arctan2-origin",         RUN_SAME, 0x148, 0
    cword "arctan2-pos-x",          RUN_SAME, 0x14C, 0
    cword "arctan2-pos-y",          RUN_SAME, 0x150, 0x4000
    cword "arctan2-neg-x",          RUN_SAME, 0x154, 0x8000
    cword "arctan2-neg-y",          RUN_SAME, 0x158, 0xC000
    cword "arctan2-diagonal",       RUN_SAME, 0x15C, 0x2000
