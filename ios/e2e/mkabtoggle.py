"""abtoggle.gba: the backdrop is white while A is held, black otherwise;
nothing else ever changes (an input-latency target)."""
import struct, sys

code = [
    0xE3A00301,  # mov   r0, #0x04000000
    0xE3A01000,  # mov   r1, #0
    0xE1C010B0,  # strh  r1, [r0]        DISPCNT 0: the backdrop only
    0xE3A02405,  # mov   r2, #0x05000000
    0xE2804E13,  # add   r4, r0, #0x130  KEYINPUT
    0xE3A05C7F,  # mov   r5, #0x7F00
    0xE38550FF,  # orr   r5, r5, #0xFF   white
    0xE1D430B0,  # loop: ldrh r3, [r4]
    0xE3130001,  # tst   r3, #1          A (active low)
    0x01A01005,  # moveq r1, r5          held: white
    0x13A01000,  # movne r1, #0          else black
    0xE1C210B0,  # strh  r1, [r2]        backdrop
    0xEAFFFFF9,  # b     loop
]
open(sys.argv[1], "wb").write(struct.pack("<%dI" % len(code), *code).ljust(0x8000, b"\0"))
