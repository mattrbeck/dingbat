## What the desktop app writes for a game, checked headless against the real
## cores (formal/DesktopState/SavePersistence.lean has the traces):
## a battery write that fails keeps the game running and tells the player
## once per run of failures (finding 4).

import std/[os, strformat, tempfiles]
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/frontend/persist

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

let dir = createTempDir("dingbat_desktop_persist_", "")
let nowhere = dir / "missing-folder" / "game.sav"   # open(fmWrite) fails

proc make_gba_rom(name: string): string =
  ## A 4 KB ROM of zeros carrying the SRAM library ID (32 KB battery SRAM).
  var rom = newString(0x1000)
  for i, c in "SRAM_V113": rom[0x200 + i] = c
  result = dir / name & ".gba"
  writeFile(result, rom)

proc make_gb_rom(name: string): string =
  ## A 32 KB MBC1+RAM+BATTERY cartridge with 32 KB of RAM.
  var rom = newString(0x8000)
  rom[0x0147] = char(0x03)
  rom[0x0149] = char(0x03)
  result = dir / name & ".gb"
  writeFile(result, rom)

proc boot_gba(rom: string): GBA =
  result = new_gba("", rom, run_bios = false, use_hle = true)
  result.post_init()

proc boot_gb(rom: string): GB =
  new_gb("", rom, fifo = true, headless = true, run_bios = false)

echo "=== A battery write that fails (finding 4) ==="

block:  # GBA: write_save used to let the IOError out of the frame loop
  let g = boot_gba(make_gba_rom("gba_fail"))
  let st = g.storage
  let good = st.save_path
  st.save_path = nowhere
  st.memory[0] = 0x5A
  st.dirty = true
  var raised = false
  try: st.write_save()
  except CatchableError: raised = true
  check(not raised, "GBA: a failed battery write does not raise")
  check(st.dirty, "GBA: the RAM stays dirty, so the next frame retries")
  check(st.save_error.len > 0 and st.save_error_new,
        "GBA: the failure is recorded and flagged as a new run")

  var n: BatteryNotice
  n.poll(st.save_path, st.save_error, st.save_error_new)
  check(n.text.len > 0 and n.hint == st.save_error and not st.save_error_new,
        "GBA: the notice opens and consumes the run's flag")
  st.write_save()
  n.poll(st.save_path, st.save_error, st.save_error_new)
  check(n.text.len > 0, "GBA: still failing: the notice stays up")
  n.dismiss()
  st.write_save()
  n.poll(st.save_path, st.save_error, st.save_error_new)
  check(n.text.len == 0, "GBA: dismissed, the same run does not reopen it")

  st.save_path = good
  st.write_save()
  check(not st.dirty and st.save_error.len == 0 and fileExists(good) and
        readFile(good)[0] == char(0x5A),
        "GBA: a write that lands clears the error and saves the RAM")
  n.poll(st.save_path, st.save_error, st.save_error_new)
  check(n.text.len == 0, "GBA: no notice once the write lands")

  st.save_path = nowhere
  st.dirty = true
  st.write_save()
  n.poll(st.save_path, st.save_error, st.save_error_new)
  check(n.text.len > 0, "GBA: a new run of failures after a success says so again")
  st.save_path = good
  st.write_save()
  n.poll(st.save_path, st.save_error, st.save_error_new)
  check(n.text.len == 0, "GBA: a write that lands takes an open notice down")

block:  # GB: mbc_save caught the error but only said so on stdout, once ever
  let g = boot_gb(make_gb_rom("gb_fail"))
  let cart = g.cartridge
  let good = cart.sav_path
  cart.sav_path = nowhere
  cart.ram[0] = 0xA5
  cart.ram_dirty = true
  cart.mbc_save()
  check(cart.ram_dirty and cart.save_error.len > 0 and cart.save_error_new,
        "GB: a failed battery write is recorded and flagged, RAM stays dirty")
  var n: BatteryNotice
  n.poll(cart.sav_path, cart.save_error, cart.save_error_new)
  check(n.text.len > 0, "GB: the notice opens")
  n.dismiss()
  cart.sav_path = good
  cart.mbc_save()
  check(not cart.ram_dirty and cart.save_error.len == 0 and
        readFile(good)[0] == char(0xA5),
        "GB: a write that lands clears the error and saves the RAM")
  cart.sav_path = nowhere
  cart.ram_dirty = true
  cart.mbc_save()
  n.poll(cart.sav_path, cart.save_error, cart.save_error_new)
  check(n.text.len > 0, "GB: a later run of failures is reported again")

removeDir(dir)

if failures > 0:
  echo &"{failures} check(s) FAILED"
  quit(1)
echo "ok"
