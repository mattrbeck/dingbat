; probe_k_oamclass -- WHICH instruction classes corrupt OAM in mode 2?
; docs/pandocs-audit.md row A8.
;
; Pan Docs (OAM Corruption Bug, "Affected Operations") says "Any memory access
; instruction, if it accesses OAM" corrupts a row of the OAM the scan is on.
; dingbat only wires the 16-bit IDU family -- inc/dec rr, ld [hl+/-],a,
; ld a,[hl+/-], push/call/rst/interrupt-dispatch, pop/ret -- and a plain load
; through the same address goes down the ordinary memory path
; (ppu.nim oam_bug_if call sites; the audit row: "blargg `oam_bug` is green
; either way (its causes ROMs never test plain accesses). Assumed; no ROM pins
; this"). This page tests sixteen classes side by side.
;
; ONE BAND = ONE CLASS, sixteen bands, and each band is one frame:
;
;   1. wait for LY = 145, then OAM-DMA the pristine pattern from $C000, so
;      every band starts from the same OAM whatever the last one did to it.
;      (The pattern is byte i = i, so every byte in the table is unique and
;      OAM row r's byte 2 is 8r+2 -- a row's corruption always copies bytes
;      2..7 down from the row before it, so ONE byte per row detects it.)
;   2. halt on LYC = ALINE, wake inside that line's mode 2, and J M-cycles
;      later run ONE instruction of the class with an OAM address on the bus.
;      With J = 10 and dingbat's wake at line dot 1 (DMG) the access M-cycle
;      begins at dot 41, which is OAM row 11 of 20 -- clear of row 0 (Pan
;      Docs: "objects 0 and 1 are not affected") and of row 20 (the scan has
;      let go).
;   3. wait for LY = 145 again and read byte 2 of all twenty rows, comparing
;      each with its pristine value. Twenty bits, one band.
;
; No dot precision is needed beyond "inside mode 2", which is forty dots wide
; at J = 10; no register latency and no fetch grid is involved. The page is
; free of every constant probe (h) and probe (j) depend on.
;
; THE CLASSES. Column 0 of each band carries the digit:
;
;   0  nop                 the control: no OAM address on the bus at all
;   1  inc hl              \
;   2  dec hl               |  the 16-bit IDU family: a bare address on the
;   3  inc de               |  bus with neither read nor write asserted.
;   4  ld a, [hl+]          |  dingbat corrupts for all seven.
;   5  ld [hl+], a          |
;   6  push bc              |  (SP = $FE20; three writes, M2..M4)
;   7  pop bc              /   (SP = $FE20; a read+IDU then a read)
;   8  ld a, [bc]          \
;   9  ld [bc], a           |
;   A  ld a, [hl]           |  PLAIN memory accesses through an OAM address.
;   B  ld [hl], a           |  Pan Docs' sentence covers these; dingbat does
;   C  ld [hl], $5A         |  NOT corrupt for any of them.
;   D  inc [hl]             |  (read-modify-write, M2 read then M3 write)
;   E  ld a, [$FE10]        |  (16-bit absolute, the access on M4)
;   F  ld [$FE10], a       /
;
; Every class's nop lead is chosen so its FIRST OAM-bus M-cycle is the J-th
; after the wake, so all sixteen bands hit the same OAM row and the pictures
; are directly comparable. HL, DE and BC are reloaded with $FE10 before each
; band; the two stack bands save SP to WRAM first and put THAT value back
; afterwards (a constant would strand Sweep's own return address).
;
; THE PICTURE. Screen rows 1..16 are the sixteen bands. Column 0 is the class
; digit; columns 1..19 are OAM ROWS 1..19, black when that row's byte 2 no
; longer reads its pristine value. Row 0 is the column ruler (the digit is the
; tile column, so the OAM row is the column number) and row 17 the label:
;
;     56 01 JJ LL AA HH   page code, version, J, ALINE, the boot value of A
;                         ($01 DMG, $FF MGB, $11 CGB/AGB), the CGB flag.
;
; READING.
;
;   band 0 blank                       the harness itself corrupts nothing
;   bands 1..7 marked, 8..F blank      dingbat's rule: only the IDU family
;   bands 8..F marked too              Pan Docs' sentence is right and the
;                                      audit row A8 must be wired
;   some of 8..F only                  the rule is narrower than "any memory
;                                      access": the digits say which
;   a band marks SEVERAL rows          the instruction put an OAM address on
;                                      the bus on more than one M-cycle
;                                      (push and pop are expected to)
;   nothing anywhere on a CGB/AGS      Pan Docs: "CGB and AGB are not
;                                      affected, even running monochrome
;                                      software" -- which this page also tests
;
; dingbat's prediction: bands 1..7 each mark ONE row on a DMG/MGB (push and
; pop mark more), bands 0 and 8..F blank, and every band blank on cgbc, cgbd
; and agb. See tools/gbprobe/expected/probe_k_oamclass.<model>.png.
;
; No MBC and no cartridge line is touched, so nothing here is the flashcart's
; FPGA answering.

INCLUDE "hw.inc"

DEF VERSION  EQU $01
DEF PAGECODE EQU $56

IF !DEF(J)
DEF J EQU 10                 ; M-cycles from the wake to the OAM-bus M-cycle
ENDC
IF !DEF(ALINE)
DEF ALINE EQU 100            ; the line whose mode 2 is under test
ENDC
IF !DEF(BANDS)
DEF BANDS   EQU 16
ENDC
DEF OAMROWS EQU 20
DEF OAMADDR EQU $FE10        ; the address every class puts on the bus
DEF SPADDR  EQU $FE20        ; push/pop's stack pointer

DEF T_CELL   EQU $01         ; solid black
DEF T_CORNER EQU $06

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db
hDma:   ds 8                 ; ldh [rDMA],a / ld b,40 / dec b / jr nz / ret

SECTION "oamcopy", WRAM0[$C000]
wOam:   ds 160               ; the pristine pattern, byte i = i

SECTION "results", WRAM0[$C100]
wDiff:  ds BANDS * OAMROWS
wSaveSp: dw                  ; push/pop's bands move SP into OAM and back

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    call InitVideo

    ; ---- the pristine OAM pattern: byte i = i.
    ld hl, wOam
    ld b, 160
    xor a
.pat:
    ld [hl+], a
    inc a
    dec b
    jr nz, .pat

    ; ---- the DMA trampoline in HRAM (the CPU may not read ROM during a DMA)
    ld hl, hDma
    ld de, DmaCode
    ld b, DmaCodeEnd - DmaCode
.hram:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .hram

    ; ---- tiles
    ld hl, $8000 + T_CELL * 16
    ld b, 16
.cell:
    ld a, $FF
    ld [hl+], a
    dec b
    jr nz, .cell
    ld hl, $8000 + T_CORNER * 16
    ld de, CornerTile
    ld b, 16
.corner:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .corner

    ; The bug needs the LCD ON: it is a mode-2 effect. Objects stay OFF, so
    ; the pattern in OAM never reaches the screen and the sweep runs on a
    ; blank page.
    call LcdOnText
    call Sweep

    ; ---- draw
    call LcdOff
    ld hl, _SCRN0
    ld bc, 32 * 32
    xor a
.clrmap:
    ld [hl+], a
    dec bc
    ld a, b
    or c
    ld a, 0
    jr nz, .clrmap

    ld hl, wDiff
    ld d, 1                  ; screen row = band + 1
.drow:
    ; column 0: the class digit
    ld a, d
    dec a
    push hl
    push de
    ld e, 0
    call PutNibble
    pop de
    pop hl
    ld e, 0                  ; OAM row counter
.dcol:
    ld a, [hl+]
    ld c, a
    ld a, e
    or a
    jr z, .skip              ; OAM row 0 has no column of its own
    push hl
    push de
    ld a, c
    or a
    ld a, 0
    jr z, .blank
    ld a, T_CELL
.blank:
    call PutTile             ; at (E, D): column E = OAM row E
    pop de
    pop hl
.skip:
    inc e
    ld a, e
    cp OAMROWS
    jr nz, .dcol
    inc d
    ld a, d
    cp BANDS + 1
    jr nz, .drow

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
    ld a, J
    call PutByte
    ld e, 10
    ld a, ALINE
    call PutByte
    ld e, 13
    ldh a, [hIsCgb]
    call PutByte
    ld e, 16
    ld a, [$0143]
    and $C0
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
; RestoreOam -- wait for VBlank and DMA the pristine pattern back into OAM.
RestoreOam:
.wait:
    ldh a, [rLY]
    cp 145
    jr nz, .wait
    ld a, HIGH(wOam)
    jp hDma                  ; hDma ends in `ret`, so this returns for us

; ---------------------------------------------------------------------------
; Snapshot -- E = band index. Wait for VBlank, then compare byte 2 of every
; OAM row with its pristine value and write twenty flags to wDiff + 20*E.
Snapshot:
.wait:
    ldh a, [rLY]
    cp 145
    jr nz, .wait
    ld h, 0
    ld l, e
    add hl, hl               ; 2E
    add hl, hl               ; 4E
    ld b, h
    ld c, l
    add hl, hl               ; 8E
    add hl, hl               ; 16E
    add hl, bc               ; 20E
    ld bc, wDiff
    add hl, bc
    ld de, $FE02
    ld b, 2                  ; the pristine value of OAM row 0 byte 2
    ld c, OAMROWS
.loop:
    ld a, [de]
    cp b
    ld a, 0
    jr z, .same
    inc a
.same:
    ld [hl+], a
    ld a, e
    add 8
    ld e, a
    ld a, b
    add 8
    ld b, a
    dec c
    jr nz, .loop
    ret

DmaCode:
    ldh [rDMA], a
    ld b, 40
.dwait:
    dec b
    jr nz, .dwait
    ret
DmaCodeEnd:

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

; ---------------------------------------------------------------- sweep ----
SECTION "sweep", ROMX[$4000], BANK[1]

; CLASS b -- the nop lead and the one instruction for band b. The lead is
; J minus the index of the instruction's FIRST OAM-bus M-cycle, so every band
; puts its address on the bus on the same M-cycle after the wake.
; RESTORE_SP -- put SP back where the band prologue found it. It must be the
; saved value and not a constant: Sweep was reached with `call`, so its return
; address is under whatever SP held then.
MACRO RESTORE_SP
    ld hl, wSaveSp
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld sp, hl
ENDM

MACRO CLASS
IF (\1) == 0
    NOPS J
    nop                      ; control: no OAM address on the bus
ELIF (\1) == 1
    NOPS J - 1
    inc hl
ELIF (\1) == 2
    NOPS J - 1
    dec hl
ELIF (\1) == 3
    NOPS J - 1
    inc de
ELIF (\1) == 4
    NOPS J - 1
    ld a, [hl+]
ELIF (\1) == 5
    NOPS J - 1
    ld [hl+], a
ELIF (\1) == 6
    NOPS J - 1
    push bc
    RESTORE_SP
ELIF (\1) == 7
    NOPS J - 1
    pop bc
    RESTORE_SP
ELIF (\1) == 8
    NOPS J - 1
    ld a, [bc]
ELIF (\1) == 9
    NOPS J - 1
    ld [bc], a
ELIF (\1) == 10
    NOPS J - 1
    ld a, [hl]
ELIF (\1) == 11
    NOPS J - 1
    ld [hl], a
ELIF (\1) == 12
    NOPS J - 2               ; ld [hl],n: M2 fetches the byte, M3 writes
    ld [hl], $5A
ELIF (\1) == 13
    NOPS J - 1               ; inc [hl]: M2 reads, M3 writes
    inc [hl]
ELIF (\1) == 14
    NOPS J - 3               ; ld a,[nn]: M2 and M3 fetch nn, M4 reads
    ld a, [OAMADDR]
ELSE
    NOPS J - 3               ; ld [nn],a: M2 and M3 fetch nn, M4 writes
    ld [OAMADDR], a
ENDC
ENDM

Sweep:
FOR bi, 0, BANDS
    ; ---- band {d:bi}
    call RestoreOam
    ld hl, OAMADDR
    ld de, OAMADDR
    ld bc, OAMADDR
    IF bi == 6 || bi == 7
    ld [wSaveSp], sp
    ld sp, SPADDR
    ENDC
    ANCHOR ALINE
    CLASS bi
    ld e, bi
    call Snapshot
ENDR
    ret
