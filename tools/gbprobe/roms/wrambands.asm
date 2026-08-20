; wrambands — measure the BIT BIAS of power-up work RAM, per 256-byte block.
;
; WHY THIS AND NOT MORE COUNTING. `wramscan` established that power-up WRAM is
; neither all-zero nor uniform noise: Matt's AGS gave 369 bytes of $00 and 221
; of $FF out of 8192, where uniform random predicts about 32 of each. That is
; enough to reject both constant fills and a plain RNG, and not enough to say
; what the pattern IS. Pan Docs only states the principle — "The console's WRAM
; and HRAM are random on power-up. Different models tend to exhibit different
; patterns" — and quantifies nothing.
;
; So measure the quantity a rule would have to predict: how many BITS ARE SET
; in each 256-byte block. Out of 2048 bits per block:
;
;   ~0400   uniform random (half the bits set)
;    >0400  the block is biased towards 1s (an OR-like decay pattern)
;    <0400  biased towards 0s (an AND-like one)
;    0000   all zero        0800  all ones
;
; 256 bytes is deliberately the granularity: it is the finest split that still
; fits the screen, and a bias that ALTERNATES between adjacent blocks is exactly
; the shape that byte-level counts cannot see. Two numbers per row, so the pair
; on one line is the even and odd 256-byte half of a 512-byte span — if the
; console alternates, every row reads high-low (or low-high) and the effect is
; unmistakable at a glance rather than a statistical argument.
;
; This is OUR measurement of OUR hardware. If the answer happens to agree with
; what another emulator does, that is corroboration and worth having; it is not
; where the number came from.
;
; Run on a COLD boot, and boot the cart DIRECTLY to the ROM if you can — going
; through a menu overwrote ~924 bytes with zeroes last time (see
; flashcart-kit/9's README).
;
; Layout: 16 rows. `R  EVEN ODD`, R = row number 0-F in hex. Row R covers
; $C000 + R*512; the EVEN column is its first 256 bytes, the ODD column its
; second.
;
; Writes NOTHING to WRAM before measuring it: HRAM stack, HRAM scratch,
; everything drawn straight to VRAM.

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
