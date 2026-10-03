#!/bin/sh
# build_testroms.sh [workdir]
# Fetch and build the third-party DS test ROMs of docs/nds/test-roms.md into
# ${DINGBAT_NDS_ROMS:-~/.cache/dingbat-nds/roms} (never into git):
#   polyrastertest/polyrastertest.nds   Jakly's polyrastertest v1.0.2-b (MIT, prebuilt release)
#   kuribo/gx_powcnt.nds, gx_clear.nds  a forum's "Hardware test ROMs" thread (docs/oracles.md; no licence given)
#   gbeplus/arm9_*.nds                  shonumi/gbe-plus-nds-tests (GPLv2), all six with libnds;
#                                       the timer test's duplicate PRINT_VALUE block renamed
#   blocksds/{tests,examples}/*.nds     BlocksDS SDK's tests and examples (CC0 / per example)
#   misc/cached_memory_performance.nds  asiekierka/nds-misc-tests (CC0)
# Needs curl, python3, the libnds toolchain (setup_libnds.sh, default
# ~/.cache/dingbat-dkp) and BlocksDS (setup_blocksds.sh, default
# ~/.cache/dingbat-wf). Commits are pinned below.
set -e
here=$(cd "$(dirname "$0")" && pwd)
roms="${DINGBAT_NDS_ROMS:-$HOME/.cache/dingbat-nds/roms}"
work="${1:-$(mktemp -d)}"
dkp="${DINGBAT_DKP:-$HOME/.cache/dingbat-dkp}"
wf="${DINGBAT_WF:-$HOME/.cache/dingbat-wf}"
mkdir -p "$work" "$roms"
cd "$work"

POLY_URL=https://github.com/Jaklyy/polyrastertest/releases/download/v1.0.2-b/polyrastertestv1.0.2-b.zip
GBEPLUS=a0df034a757afc29ff56271cde6d169477b6bdf9
BLOCKSDS_SDK=01df02b5179a4f52bc0311ff46323d16bba73d85
MISC=9c78f60cf5965ee32a0d293159168bba159d46eb

# polyrastertest (hardware-recorded spans, self-checking)
mkdir -p "$roms/polyrastertest"
curl -sfL -o poly.zip "$POLY_URL"
python3 -c "import zipfile,sys; z=zipfile.ZipFile('poly.zip'); n=[x for x in z.namelist() if x.endswith('.nds')][0]; open(sys.argv[1],'wb').write(z.read(n))" \
  "$roms/polyrastertest/polyrastertest.nds"

# The forum thread's test ROMs (binaries only; docs/oracles.md)
mkdir -p "$roms/kuribo"
curl -sfL -o "$roms/kuribo/gx_powcnt.nds" 'https://kuribo64.net/get.php?id=rTyl4Zf1Vx9zYuuB'
curl -sfL -o "$roms/kuribo/gx_clear.nds" 'https://kuribo64.net/get.php?id=XDLS990mUUC0zdHA'

# gbe-plus-nds-tests
curl -sfL "https://codeload.github.com/shonumi/gbe-plus-nds-tests/tar.gz/$GBEPLUS" | tar xz
mkdir -p "$roms/gbeplus"
python3 - "gbe-plus-nds-tests-$GBEPLUS/src/ARM9/Timer/source/common.s" <<'EOF'
import sys
# upstream defines PRINT_VALUE twice; the second block is the 4-digit
# PRINT_U16 its header names (unused by the test)
p = sys.argv[1]; s = open(p).read()
head, sep, tail = s.partition("@ PRINT_U16    @")
if sep:
    for a, b in (("PRINT_VALUE_RET", "PRINT_U16_RET"), ("PRINT_VALUE:", "PRINT_U16:"), ("PARSE_VALUE", "PARSE_U16")):
        tail = tail.replace(a, b)
    open(p, "w").write(head + sep + tail)
EOF
for t in Memory THUMB IRQ Math DMA Timer; do
  d="gbe-plus-nds-tests-$GBEPLUS/src/ARM9/$t"
  "$here/with_libnds.sh" "$dkp" make -C "$d" >/dev/null
  cp "$d/$t.nds" "$roms/gbeplus/arm9_$(echo "$t" | tr A-Z a-z).nds"
done

# BlocksDS SDK tests and examples
curl -sfL "https://codeberg.org/blocksds/sdk/archive/$BLOCKSDS_SDK.tar.gz" | tar xz
python3 - "$work/sdk" "$wf" "$roms/blocksds" <<'EOF'
import concurrent.futures as cf, glob, os, shutil, subprocess, sys
sdk, wf, out = sys.argv[1:4]
skip = ("dswifi", "dsp", "atheros", "cmake", "dynamic_libs", "teak")
env = dict(os.environ, WONDERFUL_TOOLCHAIN=wf, BLOCKSDS=f"{wf}/thirdparty/blocksds/core",
           BLOCKSDSEXT=f"{wf}/thirdparty/blocksds/external")
dirs = []
for top in ("tests", "examples"):
    for mk in glob.glob(f"{sdk}/{top}/**/Makefile", recursive=True):
        d = os.path.dirname(mk); rel = os.path.relpath(d, sdk)
        if any(s in rel.split("/") for s in skip) or os.path.basename(d) in ("arm7", "arm9"):
            continue
        txt = open(mk).read()
        if "SUBDIRS" in txt and "find" in txt:
            continue
        dirs.append((top, d, rel))
def build(item):
    top, d, rel = item
    subprocess.run(["make", "-j2"], cwd=d, env=env, capture_output=True)
    nds = glob.glob(f"{d}/*.nds")
    if not nds:
        return rel, False
    os.makedirs(f"{out}/{top}", exist_ok=True)
    shutil.copy(nds[0], f"{out}/{top}/" + rel.split("/", 1)[1].replace("/", "__") + ".nds")
    return rel, True
with cf.ThreadPoolExecutor(8) as ex:
    res = list(ex.map(build, dirs))
for rel, ok in sorted(res):
    if not ok: print("blocksds: did not build", rel)
print("blocksds:", sum(ok for _, ok in res), "of", len(res), "built")
EOF

# asiekierka/nds-misc-tests
curl -sfL "https://codeload.github.com/asiekierka/nds-misc-tests/tar.gz/$MISC" | tar xz
make -C "nds-misc-tests-$MISC/cached-memory-performance" WONDERFUL_TOOLCHAIN="$wf" \
  BLOCKSDS="$wf/thirdparty/blocksds/core" BLOCKSDSEXT="$wf/thirdparty/blocksds/external" >/dev/null 2>&1
mkdir -p "$roms/misc"
cp "nds-misc-tests-$MISC/cached-memory-performance/cached_memory_performance.nds" "$roms/misc/"
echo "test ROMs in $roms"
