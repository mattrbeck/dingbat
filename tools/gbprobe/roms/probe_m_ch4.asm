; probe (m): channel 4's output, one M-cycle at a time, after a trigger and up
; to two more writes -- where the LFSR clocks, not just whether one read
; agrees. Built for the DocBoy CH4 rows (docs/gb-failure-triage.md I1), whose
; prologue it copies instruction for instruction so the APU sits at the same
; phase: DIV reset, APU off, KEY1 + STOP into double speed (DSPD=1), APU on.
;
; Then: Wait PRE; NR42 = $F0; NR43 = NR43V; NR44 = $80; [Wait D1; second
; write] [Wait D2; third write]; Wait XW + phase; then NSAMP samples of PCM34
; ($FF77), one every 4 M-cycles (`ldh a,[c]` / `ld [hl+],a`): sample j is
; read 7 + XW + phase + 4j M-cycles after the last write. The second and
; third writes are retriggers (NR44 = $80), or, with NR43B defined, the
; second is NR43 = NR43B. A -1 delay leaves that write out.
;
; QUAD=1 (the photograph build): the whole run four times, phase 0..3, 80
; samples each, so one screen holds the timeline at one-M-cycle resolution.
; Between runs the CPU goes back to single speed (one more KEY1 + STOP) so
; every run starts from the same prologue. Otherwise one run at PHASE.
;
; Readout: one glyph per sample, the high nibble of PCM34 (channel 4; channel
; 3 is off), 20 to a row from the top-left (QUAD: phase p in rows 4p..4p+3);
; row 17 carries the build's parameters. Raw values, no expectation. CGB
; only (PCM34).
INCLUDE "hw.inc"

IF !DEF(DSPD)
DEF DSPD EQU 1
ENDC
IF !DEF(PRE)
DEF PRE EQU 0
ENDC
IF !DEF(NR43V)
DEF NR43V EQU $08
ENDC
IF !DEF(D1)
DEF D1 EQU -1
ENDC
IF !DEF(D2)
DEF D2 EQU -1
ENDC
IF !DEF(XW)
DEF XW EQU 0
ENDC
IF !DEF(PHASE)
DEF PHASE EQU 0
ENDC
IF !DEF(QUAD)
DEF QUAD EQU 0
ENDC
IF QUAD == 1
DEF NSAMP EQU 80
ELIF !DEF(NSAMP)
DEF NSAMP EQU 160
ENDC

DEF rNR42  EQU $FF21
DEF rNR43  EQU $FF22
DEF rNR44  EQU $FF23
DEF rNR50  EQU $FF24
DEF rNR51  EQU $FF25
DEF rNR52  EQU $FF26

; DocBoy's delay macros, re-derived: Wait N burns exactly N M-cycles.
MACRO NopsM
REPT \1
    nop
ENDR
ENDM

MACRO ShortWaitM
IF \1 > 16
    ld de, ((\1) / 8) - ((\1) % 8 < 2)   ; 3
.loop\@
    dec de            ; 2
    ld a, d           ; 1
    or e              ; 1
    jp nz, .loop\@    ; 4 / 3
    REPT (((\1) % 8) + 8 - 2) % 8
        nop
    ENDR
ELSE
    NopsM \1
ENDC
ENDM

; A wait before a write: the delay loop leaves A = 0, so a long one ends by
; reloading the value in its last two M-cycles.
MACRO WaitThenM
IF \1 > 16
    ShortWaitM (\1) - 2
    ld a, \2              ; 2
ELSE
    NopsM \1
ENDC
ENDM

; N M-cycles that end with A = \2 (N >= 2).
MACRO LoadWaitM
IF \1 > 16
    ShortWaitM (\1) - 2
    ld a, \2              ; 2
ELSE
    ld a, \2              ; 2
    NopsM (\1) - 2
ENDC
ENDM

; One measurement: the prologue, the writes, the samples into \1.
MACRO RunM
    ld hl, rNR44
    xor a
    ldh [rDIV], a
    ld a, $00
    ldh [rNR52], a
IF DSPD == 1
    ld a, $01
    ldh [rKEY1], a
    stop
ENDC
    ld a, $80
    ldh [rNR52], a
    ld a, $FF
    ldh [rNR51], a
    ld a, $00
    ldh [rNR50], a
    ShortWaitM PRE
    ld a, $F0
    ldh [rNR42], a
    ld a, NR43V
    ldh [rNR43], a
    ld a, $80
    ldh [rNR44], a
IF D1 >= 0
IF DEF(NR43B)
    ld hl, rNR43          ; 3, inside the delay (D1 >= 5)
    LoadWaitM (D1) - 3, NR43B
ELSE
    WaitThenM D1, $80
ENDC
    ld [hl], a
ENDC
IF D2 >= 0
IF DEF(NR43B)
    ld hl, rNR44          ; 3, inside the delay (D2 >= 5)
    LoadWaitM (D2) - 3, $80
ELSE
    WaitThenM D2, $80
ENDC
    ld [hl], a
ENDC
    ShortWaitM XW + \2
    ld hl, \1              ; 3
    ld c, $77              ; 2
REPT NSAMP
    ldh a, [c]
    ld [hl+], a
ENDR
ENDM

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "wram", WRAM0[$C000]
wSamples: ds NSAMP * 4

SECTION "main", ROM0[$150]
Start:
IF QUAD == 1
    RunM wSamples, 0
    ld a, $01
    ldh [rKEY1], a
    stop
    RunM wSamples + NSAMP, 1
    ld a, $01
    ldh [rKEY1], a
    stop
    RunM wSamples + 2 * NSAMP, 2
    ld a, $01
    ldh [rKEY1], a
    stop
    RunM wSamples + 3 * NSAMP, 3
DEF NSHOW EQU NSAMP * 4
ELSE
    RunM wSamples, PHASE
DEF NSHOW EQU NSAMP
ENDC
    ; ---- readout (timing no longer matters) ----
    di
    ld sp, $DFFF
    ld a, $11
    ldh [hIsCgb], a
    call InitVideo
    ld hl, wSamples
    ld d, 0
    ld e, 0
    ld bc, NSHOW
.put:
    ld a, [hl+]
    push hl
    push bc
    swap a
    call PutNibble
    pop bc
    pop hl
    inc e
    ld a, e
    cp 20
    jr nz, .next
    ld e, 0
    inc d
.next:
    dec bc
    ld a, b
    or c
    jr nz, .put
    ; parameters on row 17: PRE NR43 D1 D2 XW PHASE/QUAD
    ld d, 17
    ld e, 0
    ld a, PRE
    call PutByte
    ld e, 3
    ld a, NR43V
    call PutByte
    ld e, 6
    ld a, LOW(D1)
    call PutByte
    ld e, 9
    ld a, LOW(D2)
    call PutByte
    ld e, 12
    ld a, HIGH(XW)
    call PutByte
    ld e, 14
    ld a, LOW(XW)
    call PutByte
    ld e, 17
    ld a, PHASE + QUAD * $10
    call PutByte
    call LcdOnText
    IDLE_FOREVER

INCLUDE "common.inc"
