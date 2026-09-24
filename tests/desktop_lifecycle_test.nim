## The desktop's game lifecycle (src/dingbat/frontend/game_load.nim, called by
## load_rom in src/dingbat.nim; formal/DesktopState/GameLifecycle.lean):
## a file that is not a ROM is refused before anything of the running game is
## touched, instead of an IndexDefect out of main().

import std/[os, tempfiles]
import dingbat/frontend/game_load
import dingbat/gb/gb

let dir = createTempDir("dingbat_lifecycle_", "")

proc opts(): CoreOptions =
  CoreOptions(headless: true, use_hle: true)

block short_roms_are_refused:
  # Zero bytes, a header's worth, and one byte short of the smallest cart:
  # each one crashed the app (in the constructor or at the first frame).
  for n in [0, 0x150, 0x7FFF]:
    let p = dir / "short.gb"
    writeFile(p, newString(n))
    let b = build_core(p, opts())
    doAssert b.error.len > 0 and b.gb == nil and b.gba == nil, $n
  for n in [0, 0xBF]:
    let p = dir / "short.gba"
    writeFile(p, newString(n))
    let b = build_core(p, opts())
    doAssert b.error.len > 0 and b.gb == nil and b.gba == nil, $n

block missing_file_is_refused:
  let b = build_core(dir / "gone.gba", opts())
  doAssert b.error.len > 0 and b.gba == nil

block good_roms_build:
  let gbp = dir / "ok.gb"
  writeFile(gbp, newString(0x8000))
  let g = build_core(gbp, opts())
  doAssert g.error == "" and g.gb != nil and g.gba == nil
  g.gb.run_until_frame()
  let gbap = dir / "ok.gba"
  writeFile(gbap, newString(0x400))
  let a = build_core(gbap, opts())
  doAssert a.error == "" and a.gba != nil and a.gb == nil

removeDir(dir)
echo "ok"
