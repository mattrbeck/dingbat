; probe_cart -- is the flash cartridge returning the ROM's real bytes?
;
; Every other probe assumes the cart hands the CPU the bytes in the .gb. The
; GB bus has no wait states, so a late or wrong byte from marginal flash is
; silently executed. This ROM checksums its own 32 KiB three ways and hammers
; two addresses at opposite ends of the ROM; run it once per session and
; compare the numbers with an emulator's run of the same .gb.
;
;   00  hhll   sum16 of $0000-$7FFF read FORWARD
;   01  hhll   the same bytes read BACKWARD
;   02  hhll   the same bytes in a 251-byte STRIDE (odd, so every address is
;              visited exactly once)
;   03  ..cc   disagreements while alternating reads of $0104 and $7F04,
;              4096 times each, against the values first read there
;   04  ..aa   A at boot: $01 DMG-family, $11 CGB-family. Context, not a check
;
; Rows 00-02 cover the same bytes and are identical on a healthy cart; they
; differ in access order. The stride and the $0104/$7F04 alternation (fifteen
; address lines toggling per access) are the patterns most likely to expose a
; cart that settles late. The boot ROM already checks the logo and header
; checksum, so a cart that mangles the first $34 bytes never gets this far.

INCLUDE "hw.inc"

DEF FLAK_ITERS EQU 4096
DEF STRIDE EQU 251
DEF ADDR_LO EQU $0104
DEF ADDR_HI EQU $7F04

SECTION "entry", ROM0[$100]
    nop
    jp Start
    ds $150 - @, $00

SECTION "hram", HRAM
hIsCgb: db

SECTION "wram", WRAM0
wFwd:  dw
wRev:  dw
wStr:  dw
wFlak: db
wBoot: db

SECTION "main", ROM0[$150]

Start:
    di
    ld sp, $DFFF
    ldh [hIsCgb], a
    ld [wBoot], a
    call InitVideo              ; LCD off, VRAM cleared, font loaded

; ---------------------------------------------------------------- forward ---
    ld bc, 0                    ; sum
    ld de, 0                    ; address
    ld hl, $8000                ; count
.fwd:
    ld a, [de]
    add c
    ld c, a
    jr nc, .fwdNoCarry
    inc b
.fwdNoCarry:
    inc de
    dec hl
    ld a, h
    or l
    jr nz, .fwd
    ld a, c
    ld [wFwd], a
    ld a, b
    ld [wFwd + 1], a

; ---------------------------------------------------------------- reverse ---
    ld bc, 0
    ld de, $7FFF
    ld hl, $8000
.rev:
    ld a, [de]
    add c
    ld c, a
    jr nc, .revNoCarry
    inc b
.revNoCarry:
    dec de
    dec hl
    ld a, h
    or l
    jr nz, .rev
    ld a, c
    ld [wRev], a
    ld a, b
    ld [wRev + 1], a

; ----------------------------------------------------------------- stride ---
; DE walks the ROM in steps of STRIDE, wrapped into $0000-$7FFF; STRIDE is
; odd, so the walk is a permutation of the same 32768 bytes.
    ld bc, 0
    ld de, 0
    ld hl, $8000
.str:
    ld a, [de]
    add c
    ld c, a
    jr nc, .strNoCarry
    inc b
.strNoCarry:
    push hl
    ld hl, STRIDE
    add hl, de
    ld a, h
    and $7F
    ld d, a
    ld e, l
    pop hl
    dec hl
    ld a, h
    or l
    jr nz, .str
    ld a, c
    ld [wStr], a
    ld a, b
    ld [wStr + 1], a

; ------------------------------------------------------------------- flaky ---
; Alternate the two addresses and count disagreements with the first reads.
    ld a, [ADDR_LO]
    ld d, a
    ld a, [ADDR_HI]
    ld e, a
    ld bc, FLAK_ITERS
    ld hl, 0                    ; L = mismatches, saturating at $FF
.flak:
    ld a, [ADDR_LO]
    cp d
    jr z, .flakHi
    inc l
    jr z, .flakSat              ; wrapped past $FF
.flakHi:
    ld a, [ADDR_HI]
    cp e
    jr z, .flakNext
    inc l
    jr nz, .flakNext
.flakSat:
    ld l, $FF
.flakNext:
    dec bc
    ld a, b
    or c
    jr nz, .flak
    ld a, l
    ld [wFlak], a

; -------------------------------------------------------------------- draw ---
    call LcdOff

    ld d, 0                     ; row 0: forward
    ld e, 0
    xor a
    call PutByte
    ld e, 3
    ld a, [wFwd + 1]
    call PutByte
    ld e, 5
    ld a, [wFwd]
    call PutByte

    ld d, 1                     ; row 1: reverse
    ld e, 0
    ld a, $01
    call PutByte
    ld e, 3
    ld a, [wRev + 1]
    call PutByte
    ld e, 5
    ld a, [wRev]
    call PutByte

    ld d, 2                     ; row 2: stride
    ld e, 0
    ld a, $02
    call PutByte
    ld e, 3
    ld a, [wStr + 1]
    call PutByte
    ld e, 5
    ld a, [wStr]
    call PutByte

    ld d, 3                     ; row 3: flaky count
    ld e, 0
    ld a, $03
    call PutByte
    ld e, 5
    ld a, [wFlak]
    call PutByte

    ld d, 4                     ; row 4: boot A
    ld e, 0
    ld a, $04
    call PutByte
    ld e, 5
    ld a, [wBoot]
    call PutByte

    call LcdOnText
    IDLE_FOREVER

INCLUDE "common.inc"
