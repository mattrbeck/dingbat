"""Cartridge-logo injection for the hand-built test ROMs.

Real hardware refuses a cart whose header logo differs from the boot ROM's
copy (DMG/CGB: 48 bytes at $104; GBA BIOS: 156 bytes at 0x04, also checked
on a multiboot image). The bytes are Nintendo's, so the builders here do
not carry them: each writes every other header field itself and then hands
the file to the platform's header tool, exactly as mooneye, mealybug,
cgb-acid2 (rgbfix -v) and jsmolka's gba-tests / the mGBA suite (gbafix) do.
Only the logo is written (rgbfix -f l; gbafix leaves other fields as given),
so a rebuild is byte-identical to a ROM patched by hand.

rgbfix comes from rgbds (tools/gbprobe/build.sh fetches it into .scratch/);
gbafix from devkitPro. Both are looked up on PATH first.
"""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def _find(name, extra):
    tool = shutil.which(name)
    if tool:
        return tool
    for d in extra:
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    raise SystemExit(f"{name} not found on PATH or in {extra}")


def gb_logo(path):
    """Write the Game Boy logo into an otherwise finished .gb file."""
    rgbfix = _find("rgbfix", [os.path.join(REPO, ".scratch", "rgbds"),
                              os.path.join(REPO, "scratch", "rgbds")])
    subprocess.run([rgbfix, "-f", "l", path], check=True)


def gba_logo(path):
    """Write the GBA logo into an otherwise finished .gba or multiboot image
    (0x04-0x9F; the fixed 0x96 byte and the complement are rewritten with
    the values the builder already set)."""
    dkp = os.environ.get("DEVKITPRO", "/opt/devkitpro")
    gbafix = _find("gbafix", [os.path.join(dkp, "tools", "bin")])
    subprocess.run([gbafix, path], check=True, stdout=subprocess.DEVNULL)
