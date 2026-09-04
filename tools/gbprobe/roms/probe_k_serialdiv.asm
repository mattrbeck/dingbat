; probe_k_serialdiv -- where inside its own M-cycle is a $FF04 store compared
; against the serial tap?
;
; serial.nim SERIAL_DIV_WRITE_LEAD_T (ships 4): "T-cycles before the end of
; its own M-cycle at which a `$FF04` store's divider reset is compared against
; the serial tap ... gambatte serial/start_late_div_write_* pins the M-cycle;
; the T-cycle within it is assumed, no ROM pins it."
;
; WHAT A REAL GAME BOY CAN AND CANNOT DO. A CPU cannot place a store at a
; sub-M-cycle offset, so no ROM can sweep the four T-cycles directly. What it
; CAN do is find the M-cycle at which the store's verdict flips, and that
; boundary moves by one M-cycle as the comparison point crosses a T-cycle
; boundary. The tap is bit 7 of the system counter read at (counter + phase),
; phase = SERIAL_TAP_DMG / SERIAL_TAP_CGB (mooneye boot_sclk_align-dmgABCmgb
; pins the DMG's to [4,7]); the counter advances 4 per M-cycle, so
;
;     was_high = bit7(counter_at_end_of_the_store - LEAD_T + phase)
;
; flips at the M-cycle where counter_at_end >= 128k + LEAD_T - phase: the
; boundary sits ceil((LEAD_T - phase) / 4) M-cycles from the tap's own edge.
; With the phase held at its mooneye value the boundary pins LEAD_T mod 4, and
; since LEAD_T is in 1..4 that is LEAD_T. This page reads that boundary. It
; measures the PAIR (phase, LEAD_T) as one number; that is the only thing
; hardware can say, and the page says so rather than pretending otherwise.
;
; THE MEASUREMENT, one case per value of m = M0 .. M0+31:
;
;     xor a / ldh [rIF], a    ; no stale serial request
;     xor a / ldh [rDIV], a   ; counter := 0 -- the alignment, so a case does
;                             ;   not depend on how the ROM got here
;     ld a, $81 / ldh [rSC],a ; start a transfer on the INTERNAL clock. No
;                             ;   cable: the line floats high, eight 1s shift
;                             ;   in, and the unit completes on its own. No
;                             ;   MBC and no cartridge line is touched, so
;                             ;   nothing here is the flashcart's FPGA talking.
;     <m nops>                ; the swept offset, one M-cycle apart
;     xor a / ldh [rDIV], a   ; THE STORE UNDER TEST
;     <count M-cycles until IF bit 3 sets>
;
; The store under test zeroes the counter, so everything after it is fixed:
; the transfer finishes 2*bits - (a slot is open ? 1 : 0) tap falling edges
; later, 256 T apart. The one thing m changes is whether the store's own reset
; takes the tap DOWN (it was high: a falling edge happens on the spot, moving
; a bit slot) or not. That is one whole tap period, 256 T = 64 M, in the
; completion time. So the count is flat in m with exactly one step, and the m
; at which it steps is the answer.
;
; IME is off throughout and the LCD is off for the whole sweep, so the count
; is pure CPU cycles and nothing else can reach IF.
;
; THE PICTURE. 32 half-height bars: case 2r on the TOP four pixel rows of
; screen row r+1, case 2r+1 on the bottom four; bar length
; BARMUL * (count - min count) tiles clipped to 18, drawn from column 1. A
; flat block with one step in it; the step is m*. Row 0 is the column ruler
; (the digit is the tile column), row 17 the label:
;
;     52 01 MM HH LL AA   page code, version, M0 (the first m), the minimum
;                         count as a 16-bit hex pair (high byte then low), and
;                         the boot value of A ($01 DMG, $FF MGB, $11 CGB/AGB).
;
; Every count is also stored raw at $C000 (32 little-endian words) for a
; save-state or a debugger; the bars are what a photograph reads.
;
; READING. m* = the case at which the bar length CHANGES. dingbat draws a
; block of long bars for m = 0..21 (the store's own reset took the tap down,
; costing the transfer a whole tap period) and short ones from m = 22, so
; m* = 22 on dmg, cgbc, cgbd and agb alike.
;
; WHAT m* PINS, measured by rebuilding dingbat and re-shooting this page:
;
;     SERIAL_TAP phase   SERIAL_DIV_WRITE_LEAD_T    m*
;         4 (ships)            4 (ships)            22
;         6                    4                    22
;         7                    4                    22
;         0                    4                    23
;         7                    1                    21
;
; So m* pins the DIFFERENCE (phase - LEAD_T) to a multiple of four, and NOT
; LEAD_T on its own. That is not a weakness of the page, it is the shape of
; the hardware: the tap is bit 7 of a counter that advances four per M-cycle,
; and with the shipping phase of 4 the four candidate LEAD_T values put the
; comparison inside the same 4-T window, so THEY ARE INDISTINGUISHABLE FROM
; SOFTWARE. No ROM can pin SERIAL_DIV_WRITE_LEAD_T while the phase is 4; this
; page is the demonstration of that, and it is the reason the constant should
; stay documented as free rather than hunted.
;
; What the page DOES settle is the phase itself, where the suites disagree:
; serial.nim says "gambatte serial/* puts the phase at [0,3]; mooneye
; boot_sclk_align-dmgABCmgb puts the DMG's at [4,7], where it ships".
; m* = 22 on hardware is the mooneye range; m* = 23 is the gambatte range.
; And it settles it PER MACHINE: dingbat gives the DMG and the CGB the same
; phase, so the two photos must give the same m*.
;
; dingbat's prediction: tools/gbprobe/expected/probe_k_serialdiv.<model>.png.

INCLUDE "hw.inc"

DEF VERSION  EQU $01
DEF PAGECODE EQU $52

DEF rSB EQU $FF01
DEF rSC EQU $FF02
DEF IEF_SERIAL EQU %00001000

IF !DEF(M0)
DEF M0 EQU 0                 ; the first m; the sweep is M0 .. M0+31
ENDC
DEF CASES  EQU 32
DEF SLEDM  EQU M0 + CASES    ; the nop sled must be at least M0 + CASES - 1
DEF BARMAX EQU 18            ; bar columns 1..18
IF !DEF(BARMUL)
DEF BARMUL EQU 1             ; tiles per unit of count (one unit = 10 M)
ENDC

DEF T_TOP    EQU $01         ; pixel rows 0..3 black
DEF T_BOT    EQU $02         ; pixel rows 4..7 black
DEF T_BOTH   EQU $03
DEF T_CORNER EQU $06

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "results", WRAM0[$C000]
wCount: ds CASES * 2         ; the raw M-cycle counts, little-endian
wBar:   ds CASES             ; bar lengths in tiles
wMinLo: db
wMinHi: db

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo           ; leaves the LCD OFF, which is where the sweep runs

    ; ---- the sweep: 32 cases, about 1000 M-cycles each.
    ld e, M0
    ld hl, wCount
.sweep:
    push hl
    push de
    call Measure             ; -> BC = M-cycles from the store to IF bit 3
    pop de
    pop hl
    ld a, c
    ld [hl+], a
    ld a, b
    ld [hl+], a
    inc e
    ld a, e
    cp M0 + CASES
    jr nz, .sweep

    ; ---- bar[i] = BARMUL * (count[i] - min), clipped to BARMAX
    call MinCount
    ld a, e
    ld [wMinLo], a
    ld a, d
    ld [wMinHi], a
    ld hl, wCount
    ld de, wBar
    ld c, CASES
.bars:
    ld a, [hl+]              ; count low
    push hl
    ld hl, wMinLo
    sub [hl]
    ld b, a                  ; B = difference, low byte
    pop hl
    ld a, [hl+]              ; count high
    push hl
    ld hl, wMinHi
    sbc [hl]
    pop hl
    or a
    jr z, .small
    ld a, BARMAX             ; 256+ counts apart: peg the bar
    jr .put
.small:
    ld a, b
FOR mul_i, 1, BARMUL
    add a, a
    jr c, .peg
ENDR
    jr c, .peg
    cp BARMAX + 1
    jr c, .put
.peg:
    ld a, BARMAX
.put:
    ld [de], a
    inc de
    dec c
    jr nz, .bars

    ; ---- tiles: the two half-height blocks and the solid one
    ld hl, $8000 + T_TOP * 16
    ld b, 8
.toph:
    ld a, $FF
    ld [hl+], a
    dec b
    jr nz, .toph
    ld b, 8
.topl:
    xor a
    ld [hl+], a
    dec b
    jr nz, .topl
    ld b, 8                  ; HL is now $8000 + T_BOT*16
.both0:
    xor a
    ld [hl+], a
    dec b
    jr nz, .both0
    ld b, 8
.both1:
    ld a, $FF
    ld [hl+], a
    dec b
    jr nz, .both1
    ld b, 16                 ; HL is now $8000 + T_BOTH*16
.solid:
    ld a, $FF
    ld [hl+], a
    dec b
    jr nz, .solid
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16
.corner:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .corner

    ; ---- the bars: screen row r+1 carries case 2r on top, 2r+1 below
    ld d, 1
.row:
    ld e, 1
.col:
    ld a, d
    dec a
    add a, a                 ; A = 2*(d-1), the top case index
    ld l, a
    ld h, 0
    ld bc, wBar
    add hl, bc
    ld a, [hl+]              ; top bar length
    ld c, a
    ld b, [hl]               ; bottom bar length
    ld h, 0
    ld a, c
    cp e                     ; carry iff bar < column
    jr c, .notop
    ld h, T_TOP
.notop:
    ld a, b
    cp e
    jr c, .nobot
    ld a, h
    or T_BOT
    ld h, a
.nobot:
    ld a, h
    push de
    call PutTile
    pop de
    inc e
    ld a, e
    cp BARMAX + 1
    jr nz, .col
    inc d
    ld a, d
    cp 17
    jr nz, .row

    ; ---- row 0: corners and the ruler; row 17: corners and the label.
    ld a, T_CORNER
    ld [_SCRN0 + 0], a
    ld [_SCRN0 + 19], a
    ld [_SCRN0 + 17 * 32 + 0], a
    ld [_SCRN0 + 17 * 32 + 19], a
    ld hl, _SCRN0 + 1
    ld c, 1
.ruler:
    ld a, c
    and $0F
    add FONT_BASE
    ld [hl+], a
    inc c
    ld a, c
    cp 19
    jr nz, .ruler

    ld d, 17
    ld e, 1
    ld a, PAGECODE
    call PutByte
    ld e, 4
    ld a, VERSION
    call PutByte
    ld e, 7
    ld a, M0
    call PutByte
    ld e, 10
    ld a, [wMinHi]
    call PutByte
    ld e, 13
    ld a, [wMinLo]
    call PutByte
    ld e, 16
    ldh a, [hIsCgb]
    call PutByte

    call LcdOnText
    IDLE_FOREVER

; ---------------------------------------------------------------------------
; PutTile -- write tile A at (E, D). LCD must be off.
PutTile:
    ld b, a
    push bc
    call MapAddr
    pop bc
    ld [hl], b
    ret

; ---------------------------------------------------------------------------
; MinCount -- D:E = the smallest of the CASES counts (D high, E low).
MinCount:
    ld hl, wCount
    ld d, $FF
    ld e, $FF
    ld c, CASES
.loop:
    ld a, [hl+]
    ld b, a                  ; B = low
    ld a, [hl+]              ; A = high
    cp d
    jr c, .take              ; high < min high
    jr nz, .skip             ; high > min high
    ld a, b
    cp e
    jr nc, .skip             ; equal high, low not smaller
    ld a, d                  ; equal high, smaller low: keep the high byte
.take:
    ld d, a
    ld e, b
.skip:
    dec c
    jr nz, .loop
    ret

; ---------------------------------------------------------------------------
; Measure -- one case. E = m, the nops between the transfer start and the
; $FF04 store under test. Returns BC = M-cycles from the store to IF bit 3.
;
; The sled is entered m nops from its end, so m is a run-time value at no
; run-time cost: `ld hl` plus `jp hl` is a constant 4 M whatever m is.
Measure:
    ld hl, SledEnd
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc 0
    ld h, a                  ; HL = SledEnd - m
    xor a
    ldh [rIF], a             ; 3 M -- no stale serial request
    ldh [rDIV], a            ; 3 M -- counter := 0 (the alignment)
    ld a, $81
    ldh [rSC], a             ; 3 M -- start, internal clock, no cable
    jp hl                    ; 1 M
Sled:
    NOPS SLEDM
SledEnd:
    xor a
    ldh [rDIV], a            ; 3 M -- THE STORE UNDER TEST
    ld bc, 0
.poll:
    inc bc                   ; 2 M
    ldh a, [rIF]             ; 3 M
    and IEF_SERIAL           ; 2 M
    jr z, .poll              ; 3 M taken, 2 M not
    ret

CornerTile:
    dw `00000000
    dw `00000000
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00333330
    dw `00000000

INCLUDE "common.inc"
