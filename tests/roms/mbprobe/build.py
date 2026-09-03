#!/usr/bin/env python3
"""Builds the multiboot probe set (see README.md).

  build/sender.gba              cart ROM for the flashcart GBA (#1): menu,
                                GBATEK multiboot initiation, SWI 25h, then
                                fetches the slave's result bytes back.
  build/payload_<p>.mb          multiboot images linked at 0x02000000, one per
                                probe; .incbin'd into the sender.
  build/payload_<p>_cart.gba    the SAME source linked at 0x08000000 with a
                                cart header so ./dingbat_test can run it and
                                predict the reading (no multiboot receive in
                                dingbat).  The mirror variant is padded to
                                exactly 1 MiB so dingbat materialises its
                                4x mirror window.

The Nintendo logo is imported from ../gbaedge.py (single source in the repo);
every header (cart and multiboot) is patched with it plus the 0xA0-0xBC
complement, which the slave BIOS verifies for the multiboot header too
(GBATEK "Multiboot Slave Header").

Requires arm-none-eabi-{as,ld,objcopy} on PATH.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from gbaedge import LOGO                                   # noqa: E402

BUILD = os.path.join(HERE, "build")
PAYLOADS = ["eeprom", "tilt", "gyro", "mirror"]

# Cart-boot game codes.  dingbat detects tilt (KYG*/KHPJ) and gyro (RZW*)
# carts by game code, so the cart-boot variants borrow the retail codes to
# get dingbat's model of that hardware; the others are private codes.
CART_CODE = {"eeprom": b"MBPE", "tilt": b"KYGE", "gyro": b"RZWE",
             "mirror": b"MBPM", "sender": b"MBPS"}

# 5x7 glyphs in 6x8 cells, drawn at 2x (12x16 px): 20 columns x 10 rows.
# ASCII 0x20..0x5F; undefined codes render blank.  mbprobe_ocr.py reads the
# same table back out of a dingbat screenshot.
FONT = {
    " ": ["     "] * 7,
    "0": [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "],
    "1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    "2": [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
    "3": ["#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### "],
    "4": ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
    "5": ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
    "6": ["  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "],
    "7": ["#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "],
    "8": [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
    "9": [" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "],
    "A": [" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "B": ["#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "],
    "C": [" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "],
    "D": ["###  ", "#  # ", "#   #", "#   #", "#   #", "#  # ", "###  "],
    "E": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
    "F": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "],
    "G": [" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ####"],
    "H": ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "I": [" ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    "J": ["  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  "],
    "K": ["#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"],
    "L": ["#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"],
    "M": ["#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #"],
    "N": ["#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"],
    "O": [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "P": ["#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "],
    "Q": [" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"],
    "R": ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
    "S": [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
    "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    "U": ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "V": ["#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "],
    "W": ["#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #"],
    "X": ["#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"],
    "Y": ["#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
    "Z": ["#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"],
    "-": ["     ", "     ", "     ", "#####", "     ", "     ", "     "],
    ".": ["     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "],
    ":": ["     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "],
    "=": ["     ", "     ", "#####", "     ", "#####", "     ", "     "],
    "/": ["    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    "],
    ">": ["#    ", " #   ", "  #  ", "   # ", "  #  ", " #   ", "#    "],
    "<": ["    #", "   # ", "  #  ", " #   ", "  #  ", "   # ", "    #"],
    "+": ["     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "],
    "?": [" ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  "],
    "#": [" # # ", " # # ", "#####", " # # ", "#####", " # # ", " # # "],
}


def glyph_rows(ch):
    """7 row bytes, bit 7 = leftmost of the 5 columns."""
    rows = FONT.get(ch, FONT[" "])
    out = []
    for r in rows:
        v = 0
        for i, c in enumerate(r):
            if c == "#":
                v |= 0x80 >> i
        out.append(v)
    return out


def gen_font_inc():
    lines = [".global font_data", ".balign 4", "font_data:"]
    for code in range(0x20, 0x60):
        rows = glyph_rows(chr(code)) + [0]
        lines.append("    .byte " + ",".join(f"0x{b:02X}" for b in rows) +
                     f"   @ '{chr(code)}'")
    lines.append(".balign 4")
    with open(os.path.join(HERE, "mbfont.inc"), "w") as f:
        f.write("\n".join(lines) + "\n")


def run(cmd):
    subprocess.run(cmd, check=True, cwd=HERE)


def assemble(src, out_bin, text_base, defsyms=()):
    o = out_bin + ".o"
    elf = out_bin + ".elf"
    cmd = ["arm-none-eabi-as", "-mcpu=arm7tdmi", "-I", HERE]
    for d in defsyms:
        cmd += ["--defsym", d]
    cmd += ["-o", o, os.path.join(HERE, src)]
    run(cmd)
    run(["arm-none-eabi-ld", f"-Ttext=0x{text_base:08X}", "-o", elf, o])
    run(["arm-none-eabi-objcopy", "-O", "binary", elf, out_bin])
    os.unlink(o)
    os.unlink(elf)
    return bytearray(open(out_bin, "rb").read())


def patch_header(rom, title, code):
    """Cart/multiboot header per GBATEK "GBA Cartridge Header": logo at
    0x04-0x9F, title 0xA0, game code 0xAC, maker 0xB0, fixed 0x96 at 0xB2,
    zeros to 0xBC, complement at 0xBD = -(sum(0xA0..0xBC) + 0x19)."""
    rom[0x04:0xA0] = LOGO
    rom[0xA0:0xAC] = title.encode("ascii").ljust(12, b"\0")
    rom[0xAC:0xB0] = code
    rom[0xB0:0xB2] = b"01"
    rom[0xB2] = 0x96
    rom[0xB3:0xBD] = bytes(10)
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF
    rom[0xBE:0xC0] = b"\0\0"


def check_mb_header(img, name):
    """The fields the slave BIOS relies on (GBATEK "Additional Multiboot
    Header Entries"): a branch at 0xC0 (RAM entry), 0xC4/0xC5 zero for the
    BIOS to overwrite, a branch at 0xE0 (JOYBUS entry)."""
    def is_branch(off):
        return (img[off + 3] & 0x0F) == 0x0A and (img[off + 3] >> 4) == 0xE
    assert is_branch(0x00), f"{name}: 0x00 is not a B opcode"
    assert is_branch(0xC0), f"{name}: 0xC0 (RAM entry) is not a B opcode"
    assert img[0xC4] == 0 and img[0xC5] == 0, f"{name}: 0xC4/0xC5 not zero"
    assert is_branch(0xE0), f"{name}: 0xE0 (JOYBUS entry) is not a B opcode"
    assert img[0xB2] == 0x96
    length = len(img) - 0xC0
    assert length % 16 == 0 and 0x100 <= length <= 0x3FF40, \
        f"{name}: transfer length 0x{length:X} out of SWI 25h range"


def build_payload(name):
    src = f"payload_{name}.s"
    # multiboot image at 0x02000000
    mb = os.path.join(BUILD, f"payload_{name}.mb")
    img = assemble(src, mb, 0x02000000)
    # SWI 25h: length (excluding the 0xC0 header) multiple of 0x10, >= 0x100
    n = max(len(img), 0xC0 + 0x100)
    n = (n + 15) & ~15
    img += bytes(n - len(img))
    patch_header(img, f"MBP{name.upper()}"[:12], CART_CODE[name])
    check_mb_header(img, name)
    open(mb, "wb").write(img)
    # cart-boot twin at 0x08000000 for dingbat
    cart = os.path.join(BUILD, f"payload_{name}_cart.gba")
    img = assemble(src, cart, 0x08000000, ["CARTBOOT=1"])
    if name == "mirror":
        img += bytes(0x100000 - len(img))          # exactly 1 MiB
    patch_header(img, f"MBP{name.upper()}"[:12], CART_CODE[name])
    open(cart, "wb").write(img)
    print(f"{mb}: {n} bytes; {cart}: {len(img)} bytes")


def build_sender():
    out = os.path.join(BUILD, "sender.gba")
    img = assemble("sender.s", out, 0x08000000)
    patch_header(img, "MBPROBE", CART_CODE["sender"])
    open(out, "wb").write(img)
    print(f"{out}: {len(img)} bytes")


if __name__ == "__main__":
    os.makedirs(BUILD, exist_ok=True)
    gen_font_inc()
    for p in PAYLOADS:
        build_payload(p)
    build_sender()
