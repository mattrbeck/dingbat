@ defs.inc -- dbsuite constants, the memory map, and the macros every suite
@ uses to declare its cases.  Included first by dbsuite.s.
@
@ Memory map (the same in the cartridge and the multiboot build):
@
@   0x02000000  SLOT      512 bytes: what the case's run routine observed
@   0x02001000  SCRATCH   IRQ scratch (+0x48 TM0 stamp, +0x4C first-entry
@                         flag, +0x50 interrupted return address)
@   0x02002000  MARKER    per-row watchdog (+8 state 1 armed / 2 fired,
@                         +12 saved sp, +16 phase, +20 recovery, +24 CPSR)
@   0x02004000  EWDST     DMA / store destination area
@   0x02008000  CAPDST    16 KB ring; also where link-rig payloads leave a
@                         result block (their RESULTS = 0x02008000)
@   0x02010000- payload scratch (irqstorm, breakram, dmatime: 0x02010000
@   0x02023FFF            and 0x02020000, 16 KB each)
@   0x02014000  RESULTS   the documented results block (README.md)
@   0x02018000  RT        runtime state (runner, menu, output buffer)
@   0x02024000  MB_HOME   where the multiboot build's body runs from
@   0x03000000  PAYLOAD   link-rig payloads run here, as on the console
@   0x03000200  IWBLOCK   copied-code blocks

.equ IOBASE,    0x04000000
.equ SLOT,      0x02000000
.equ SLOTSZ,    512
.equ SCRATCH,   0x02001000
.equ MARKER,    0x02002000
.equ EWDST,     0x02004000
.equ CAPDST,    0x02008000
.equ PRESULTS,  0x02008000
.equ RESULTS,   0x02014000
.equ RT,        0x02018000
.equ MB_HOME,   0x02024000
.equ PAYLOAD,   0x03000000
.equ IWBLOCK,   0x03000200
.equ VRAM,      0x06000000

@ results block (README.md "Results block")
.equ RB_MAGIC,    0x00             @ 'DBSU'
.equ RB_VERSION,  0x04
.equ RB_DONE,     0x08             @ 'DONE', written last
.equ RB_STATE,    0x0C             @ 0 idle, 1 running, 2 finished
.equ RB_FLAGS,    0x10             @ bit0 multiboot build
.equ RB_NCASES,   0x14
.equ RB_NSUITES,  0x18
.equ RB_CURRENT,  0x1C             @ case in flight, -1 none
.equ RB_TOTALS,   0x20             @ pass fail timeout crash skip notrun
.equ RB_RESUMES,  0x38             @ crash-resumes taken this run
.equ RB_RUNEND,   0x3C             @ one past the last case of this run
.equ RB_SUITES,   0x40             @ 16 x 16 bytes
.equ RB_CASES,    0x140            @ N x 16 bytes
.equ MAX_SUITES,  16
.equ MAGIC_WORD,  0x55534244       @ "DBSU"
.equ DONE_WORD,   0x454E4F44       @ "DONE"
.equ RB_VER,      1

@ per-suite record: +0 pass +2 fail +4 timeout +6 crash +8 skip +10 total
@ +12 first case +14 case count (all u16)
@ per-case record: +0 status +1 suite +2 kind +3 0, +4 got, +8 exp lo,
@ +12 exp hi

.equ ST_NOTRUN,  0
.equ ST_PASS,    1
.equ ST_FAIL,    2
.equ ST_TIMEOUT, 3
.equ ST_CRASH,   4
.equ ST_SKIP,    5

@ runtime state (RT)
.equ RT_SAVED_SP,  0x00
.equ RT_INFLIGHT,  0x04            @ 1 case running under the watchdog,
                                   @ 2 the watchdog fired
.equ RT_GROUP_ST,  0x08            @ status of the last run routine
.equ RT_LAST_RUN,  0x0C
.equ RT_LAST_P0,   0x10
.equ RT_LAST_P1,   0x14
.equ RT_MGBA,      0x18            @ 1 = mGBA debug registers answered
.equ RT_NOCASH,    0x1C            @ 1 = no$gba debug port answered
.equ RT_SBPOS,     0x20            @ output line length
.equ RT_INK,       0x24
.equ RT_PAPER,     0x26
.equ RT_KEYS,      0x28            @ previous KEYINPUT (active high)
.equ RT_CURSOR,    0x2C
.equ RT_SCROLL,    0x30
.equ RT_VERDICT,   0x34            @ 0 none yet, 1 green, 2 red
.equ RT_VIEW,      0x38            @ suite shown by the detail view, -1 all
.equ RT_FAILROW,   0x3C            @ next row of the run screen's fail list
.equ RT_LINKON,    0x40            @ link report armed
.equ RT_RUNSTART,  0x44
.equ RT_SAVED_CPSR,0x48
.equ RT_BEACON,   0x4C            @ the beacon word, re-armed after each read
.equ RT_LR_STATE,  0x50            @ 12 bytes for linkreport.inc
.equ RT_SB,        0x100           @ 256-byte output line

@ case descriptor (32 bytes, see the `case` macro)
.equ CD_RUN,   0
.equ CD_P0,    4
.equ CD_P1,    8
.equ CD_NAME,  12
.equ CD_INFO,  16                  @ bits 0-3 kind, 4 cart only, 16-27 offset
.equ CD_MASK,  20
.equ CD_LO,    24
.equ CD_HI,    28
.equ CD_SIZE,  32

.equ K_RANGE,  0                   @ lo <= got <= hi (lo = hi: exact)
.equ K_TWO,    1                   @ got = lo or got = hi (two answers seen)
.equ K_SLOT,   2                   @ got = the SLOT word at byte lo, masked
.equ F_RISKY,  0x20                @ provokes UNPREDICTABLE CPU state: SKIP
                                   @ when rom_config bit 2 is set
.equ F_CART,   0x10               @ needs the cartridge bus: SKIP when the
                                   @ multiboot build runs from EWRAM

.set NCASES, 0
.set NSUITES, 0

@ The run routine a case names is called with r0 = its descriptor, in
@ System mode with IRQs enabled, IME set and TM3 armed as a 4-second
@ watchdog; it leaves what it saw in SLOT and returns with `bx lr` (it
@ may clobber every register but sp).  A case whose run is RUN_SAME
@ checks the SLOT the previous case's run left.
.equ RUN_SAME, 0

@ case "name", run, p0, p1, offset, mask, lo, hi, kind, flags
.macro case name:req, run:req, p0=0, p1=0, off=0, mask=0xFFFFFFFF, lo=0, hi=0, kind=K_RANGE, flags=0
    .pushsection .text, 2
.Lcname\@:
    .asciz "\name"
    .popsection
    .pushsection .text, 1
    .align 2
    .word \run, \p0, \p1, .Lcname\@
    .word (\kind) | (\flags) | ((\off) << 16)
    .word \mask, \lo, \hi
    .popsection
    .set NCASES, NCASES + 1
.endm

@ exact checks on a word, a halfword or a byte of SLOT
.macro cword name, run, off, val, flags=0, p0=0, p1=0
    case "\name", \run, \p0, \p1, \off, 0xFFFFFFFF, \val, \val, K_RANGE, \flags
.endm
.macro chalf name, run, off, val, flags=0, p0=0, p1=0
    case "\name", \run, \p0, \p1, \off, 0xFFFF, \val, \val, K_RANGE, \flags
.endm
.macro cbyte name, run, off, val, flags=0, p0=0, p1=0
    case "\name", \run, \p0, \p1, \off, 0xFF, \val, \val, K_RANGE, \flags
.endm
@ a jittery count, checked against the band hardware's answers sit in
.macro crange name, run, off, mask, lo, hi, flags=0, p0=0, p1=0
    case "\name", \run, \p0, \p1, \off, \mask, \lo, \hi, K_RANGE, \flags
.endm

@ one payload call: p0 = the payload's blob record, p1 = its argument;
@ the returned r0 is SLOT+0 and is held to \val
.macro cpay name, blob, arg, val, flags=0
    case "\name", run_payload, \blob, \arg, 0, 0xFFFFFFFF, \val, \val, K_RANGE, \flags
.endm
.macro cpay2 name, blob, arg, val1, val2, flags=0
    case "\name", run_payload, \blob, \arg, 0, 0xFFFFFFFF, \val1, \val2, K_TWO, \flags
.endm
.macro cpaym name, blob, arg, mask, lo, hi, flags=0
    case "\name", run_payload, \blob, \arg, 0, \mask, \lo, \hi, K_RANGE, \flags
.endm

@ suite "name": the cases declared after it, up to the next suite
.macro suite name:req
    .pushsection .text, 2
.Lsname\@:
    .asciz "\name"
    .popsection
    .pushsection .text, 3
    .align 2
    .word .Lsname\@, NCASES
    .popsection
    .set NSUITES, NSUITES + 1
.endm

@ a link-rig payload, assembled for PAYLOAD by build.py and carried here
@ byte for byte: blob_name: .word start, end
.macro payload_blob label, file
    .pushsection .text, 4
    .align 2
\label\()_bin:
    .incbin "\file"
    .align 2
\label\()_end:
    .popsection
    .pushsection .text, 5
    .align 2
\label:
    .word \label\()_bin, \label\()_end
    .popsection
.endm

@ Row-level watchdog for probe rows that provoke UNPREDICTABLE behaviour
@ (hwverified's): a TM3 overflow in 65536 cycles diverts the IRQ return to
@ \rec.  wdg_disarm puts the case-level watchdog back.
.macro wdg_arm rec
    ldr r2, =MARKER
    ldr r0, =\rec
    str r0, [r2, #20]
    mov r0, #1
    str r0, [r2, #8]
    ldr r2, =0x0400010C            @ TM3
    mov r0, #0
    str r0, [r2]
    ldr r0, =0x00C00000            @ enable + IRQ, prescaler 1, reload 0
    str r0, [r2]
    ldr r2, =0x04000200
    mov r0, #0x40
    strh r0, [r2]                  @ IE = timer 3
    ldr r2, =0x04000208
    mov r0, #1
    strh r0, [r2]                  @ IME on
.endm
.macro wdg_disarm
    ldr r2, =0x04000208
    mov r0, #0
    strh r0, [r2]
    ldr r2, =0x04000200
    strh r0, [r2]
    ldr r0, =0x3FFF
    strh r0, [r2, #2]
    ldr r2, =0x0400010C
    mov r0, #0
    str r0, [r2]
    ldr r0, =0x00C30000            @ the case-level watchdog again: TM3
    str r0, [r2]                   @ /1024 from 0, IRQ
    ldr r2, =0x04000200
    mov r0, #0x40
    strh r0, [r2]
    mov r0, #1
    strh r0, [r2, #8]
.endm
