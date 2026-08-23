; wrambands -- the BIT BIAS of power-up work RAM, per 256-byte block.
;
; Pan Docs says only that WRAM and HRAM are random at power-up and that models
; differ; wramscan showed it is neither all-zero nor uniform noise. This
; counts how many of each block's 2048 bits are set:
;
;   ~0400   uniform random (half the bits set)
;    >0400  biased towards 1s        <0400  biased towards 0s
;    0000   all zero                 0800   all ones
;
; Layout: 16 rows, `R  EVEN ODD`, R = row number 0-F in hex. Row R covers
; $C000 + R*512; EVEN is its first 256 bytes, ODD its second, so a bias that
; alternates between adjacent blocks reads high-low down every row.
;
; Run on a COLD boot, booting the cart directly to the ROM (a flashcart menu
; overwrites part of WRAM). Writes NOTHING to WRAM before measuring it: HRAM
; stack, HRAM scratch, everything drawn straight to VRAM.

INCLUDE "hw.inc"

SECTION "hram", HRAM
hIsCgb:  db
hCntLo:  db
hCntHi:  db

SECTION "entry", ROM0[$100]
    nop
    jp Start
    DS $150 - @

SECTION "main", ROM0

; Count set bits in the 256 bytes at DE. Result in HL. DE advanced past them.
CountBlock:
    ld hl, 0
    ld b, 0                    ; 256 iterations
.byteLoop
    ld a, [de]
    inc de
    ld c, 8
.bitLoop
    srl a
    jr nc, .noBit
    inc hl
.noBit
    dec c
    jr nz, .bitLoop
    dec b
    jr nz, .byteLoop
    ret

Start:
    di
    ld sp, $FFFE               ; HRAM stack: a WRAM stack would overwrite the
    ldh [hIsCgb], a            ; bytes this ROM exists to read
    call LcdOff
    call ClearVram
    call InitVideo

    ld de, $C000
    ld c, 0                    ; block index 0..31
.blocks
    push bc
    call CountBlock            ; hl = set bits, de advanced
    ld a, l
    ldh [hCntLo], a
    ld a, h
    ldh [hCntHi], a
    pop bc

    push bc
    push de
    ; row = block >> 1, column = 2 or 7 depending on block & 1
    ld a, c
    srl a
    ld d, a                    ; d = screen line
    ld a, c
    and 1
    jr nz, .oddCol
    ld e, 2
    jr .haveCol
.oddCol
    ld e, 7
.haveCol
    push de
    ; leading row digit, only for the even column
    ld a, c
    and 1
    jr nz, .noLabel
    ld a, c
    srl a
    ld e, 0
    call PutNibble
.noLabel
    pop de
    ldh a, [hCntHi]
    call PutByte
    inc e
    inc e
    ldh a, [hCntLo]
    call PutByte
    pop de
    pop bc

    inc c
    ld a, c
    cp 32
    jr nz, .blocks

    call LcdOnText
.done
    halt
    jr .done

INCLUDE "common.inc"
