#!/bin/sh
# setup_blocksds.sh [PREFIX]
# Install the BlocksDS SDK and its ARM toolchain (Wonderful Toolchain's
# arm-none-eabi gcc + picolibc) into a user prefix, default
# ~/.cache/dingbat-wf, without wf-pacman, root or /opt: the packages are
# fetched from the two pacman repositories and unpacked. BlocksDS builds
# the third-party test ROMs that need it (build_testroms.sh): Jakly's
# polyrastertest, the BlocksDS SDK's own tests and examples.
#
# Then build a BlocksDS project with
#   make WONDERFUL_TOOLCHAIN=$PREFIX BLOCKSDS=$PREFIX/thirdparty/blocksds/core \
#        BLOCKSDSEXT=$PREFIX/thirdparty/blocksds/external
#
# The macOS binaries link /opt/wonderful/lib/libzstd.1.dylib; they are
# re-pointed at Homebrew's libzstd (install_name_tool, ad-hoc re-signed).
set -e
prefix="${1:-$HOME/.cache/dingbat-wf}"
mkdir -p "$prefix"
python3 - "$prefix" <<'EOF'
import os, platform, re, subprocess, sys, tempfile, urllib.request
prefix = sys.argv[1]
osname = {"Darwin": "darwin", "Linux": "linux"}[platform.system()]
arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}[platform.machine()]
repos = {"wonderful": f"https://wonderful.asie.pl/packages/rolling/{osname}/{arch}/",
         "blocksds": f"https://blocksds.skylyrac.net/packages/rolling/{osname}/{arch}/"}
want = [("blocksds", "blocksds-toolchain"),
        ("wonderful", "toolchain-gcc-arm-none-eabi-binutils"),
        ("wonderful", "toolchain-gcc-arm-none-eabi-gcc"),
        ("wonderful", "toolchain-gcc-arm-none-eabi-gcc-libs"),
        ("wonderful", "toolchain-gcc-arm-none-eabi-picolibc-generic"),
        ("wonderful", "toolchain-gcc-arm-none-eabi-libstdcxx-picolibc")]
listing = {r: urllib.request.urlopen(u).read().decode() for r, u in repos.items()}
def newest(repo, name):
    files = re.findall(r'href="(' + re.escape(name) + r'-[^"/]*\.pkg\.tar\.(?:xz|zst|gz))"', listing[repo])
    files = [f for f in files if re.fullmatch(re.escape(name) + r'-\d[^-]*-\d+-(any|' + arch + r')\.pkg\.tar\.\w+', f)
             or re.fullmatch(re.escape(name) + r'-\d+~[^-]*-\d+-(any|' + arch + r')\.pkg\.tar\.\w+', f)]
    if not files: sys.exit(f"no {name} in {repos[repo]}")
    return sorted(files, key=lambda f: [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', f)])[-1]
with tempfile.TemporaryDirectory() as tmp:
    for repo, name in want:
        f = newest(repo, name)
        print("fetch", f)
        path = os.path.join(tmp, f)
        urllib.request.urlretrieve(repos[repo] + f, path)
        subprocess.run(["tar", "xf", path, "-C", prefix, "--exclude", ".BUILDINFO", "--exclude", ".MTREE",
                        "--exclude", ".PKGINFO", "--exclude", ".INSTALL"], check=True)
if osname == "darwin":
    for d, _, fs in os.walk(os.path.join(prefix, "toolchain")):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p) or not os.access(p, os.X_OK):
                continue
            r = subprocess.run(["otool", "-L", p], capture_output=True, text=True)
            libs = [l.strip().split(" (")[0] for l in r.stdout.splitlines()[1:]
                    if l.strip().startswith("/opt/wonderful/lib/")]
            for lib in libs:
                alt = "/opt/homebrew/lib/" + os.path.basename(lib)
                if not os.path.exists(alt):
                    sys.exit(f"{p} needs {lib}; no {alt} (brew's zstd)")
                subprocess.run(["install_name_tool", "-change", lib, alt, p], check=True, capture_output=True)
            if libs:
                subprocess.run(["codesign", "--force", "-s", "-", p], check=True, capture_output=True)
print("BlocksDS", open(os.path.join(prefix, "thirdparty/blocksds/core/version.txt")).read().strip(), "in", prefix)
EOF
