## What the desktop app writes for a game, checked headless against the real
## cores (formal/DesktopState/SavePersistence.lean has the traces):
## a battery write that fails keeps the game running and tells the player
## once per run of failures (finding 4); a battery or save-state write cut
## short leaves the previous file whole (finding 18); two games with the same
## file name keep their own save-state slots (finding 2), also when they
## differ only past their first 1 MB; a second window on a game another
## window has open is refused (finding 1).

import std/[os, osproc, streams, strformat, strutils, tempfiles]
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/common/serialize
import dingbat/frontend/persist
import dingbat/frontend/game_lock
when defined(posix):
  import std/posix

# A child process for the lock test: takes the lock at the given path and
# holds it until it is killed.
if paramCount() == 2 and paramStr(1) == "--hold-lock":
  var l: FileLock
  echo (if try_lock(paramStr(2), "child", l) == lrTaken: "locked" else: "busy")
  stdout.flushFile()
  discard stdin.readLine()
  quit(0)

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

let dir = createTempDir("dingbat_desktop_persist_", "")
let nowhere = dir / "missing-folder" / "game.sav"   # open(fmWrite) fails

proc make_gba_rom(name: string; folder = ""; mark = 0'u8; size = 0x1000;
                  late_mark = 0'u8): string =
  ## A ROM of zeros (4 KB unless `size`) carrying the SRAM library ID (32 KB
  ## battery SRAM); `mark` makes a different game under the same name, and
  ## `late_mark` one that differs only past the first 1 MB.
  var rom = newString(size)
  for i, c in "SRAM_V113": rom[0x200 + i] = c
  rom[0x800] = char(mark)
  if late_mark != 0: rom[0x100800] = char(late_mark)
  createDir(dir / folder)
  result = dir / folder / name & ".gba"
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
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  result.post_init()

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

echo "=== A write cut short (finding 18) ==="

proc no_temp_left(): bool =
  for f in walkDirRec(dir):
    if ".tmp" in f.extractFilename: return false
  true

when defined(posix):
  # RLIMIT_FSIZE makes a write past the limit fail part way (EFBIG), the way
  # a disk that fills mid-save does; SIGXFSZ would otherwise kill the test.
  var RLIMIT_FSIZE {.importc: "RLIMIT_FSIZE", header: "<sys/resource.h>".}: cint
  discard signal(SIGXFSZ, SIG_IGN)

  proc cut_at(bytes: int; body: proc()) =
    var old: RLimit
    discard getrlimit(RLIMIT_FSIZE, old)
    var lim = old
    lim.rlim_cur = bytes
    discard setrlimit(RLIMIT_FSIZE, lim)
    try: body()
    finally: discard setrlimit(RLIMIT_FSIZE, old)

  block:  # GBA battery: the previous .sav survives, whole
    let g = boot_gba(make_gba_rom("gba_cut"))
    let st = g.storage
    for b in st.memory.mitems: b = 0x11
    st.dirty = true
    st.write_save()
    let before = readFile(st.save_path)
    for cut in [1000, before.len - 16]:
      for b in st.memory.mitems: b = 0x22
      st.dirty = true
      cut_at(cut, proc() = st.write_save())
      check(readFile(st.save_path) == before,
            &"GBA: a write cut at {cut} bytes leaves the previous .sav whole")
      check(st.dirty and st.save_error.len > 0,
            &"GBA: cut at {cut}: reported, RAM kept dirty for the retry")
    st.write_save()
    check(readFile(st.save_path) == repeat(char(0x22), before.len),
          "GBA: the retry after the cut writes the new RAM")

  block:  # GB battery: the same through mbc_save
    let g = boot_gb(make_gb_rom("gb_cut"))
    let cart = g.cartridge
    for b in cart.ram.mitems: b = 0x33
    cart.ram_dirty = true
    cart.mbc_save()
    let before = readFile(cart.sav_path)
    for cut in [1000, before.len - 16]:
      for b in cart.ram.mitems: b = 0x44
      cart.ram_dirty = true
      cut_at(cut, proc() = cart.mbc_save())
      check(readFile(cart.sav_path) == before,
            &"GB: a write cut at {cut} bytes leaves the previous .sav whole")

  block:  # a Quick Save that fails part way: the slot keeps the last good state
    let g = boot_gba(make_gba_rom("gba_state"))
    let path = dir / "states" / "slot.state"
    check(g.save_state(path, thumbnail = true), "a state saves")
    let before = readFile(path)
    g.storage.memory[0] = 0x77   # the next state differs
    for cut in [1000, before.len - 16]:
      last_state_error = ""
      var ok = true
      cut_at(cut, proc() = ok = g.save_state(path, thumbnail = true))
      check(not ok and last_state_error.len > 0,
            &"state cut at {cut}: save_state says it failed, and why")
      check(readFile(path) == before,
            &"state cut at {cut}: the previous state file is untouched")
    check(g.load_state(path), "the surviving state still loads")

  check(no_temp_left(), "no temp file is left behind by a failed write")

echo "=== Same file name, different game (finding 2) ==="

block:
  let a = boot_gba(make_gba_rom("Pokemon", "usa"))
  let b = boot_gba(make_gba_rom("Pokemon", "hacks", mark = 1))
  let sdir = dir / "slots"
  createDir(sdir)
  let a_own = sdir / state_file_name(a.rom_path, a.state_rom_identity(), 0)
  let b_own = sdir / state_file_name(b.rom_path, b.state_rom_identity(), 0)
  check(a_own != b_own, "two games named Pokemon.gba get different Quick slot files")
  check(state_file_name(a.rom_path, a.state_rom_identity(), 3) !=
        state_file_name(a.rom_path, a.state_rom_identity(), 0),
        "each slot has its own file")
  proc a_ours(data: string): bool = a.state_is_for(data)
  proc b_ours(data: string): bool = b.state_is_for(data)

  check(b.save_state(b_own, thumbnail = true), "B's Quick Save writes its own file")
  check(state_read_path(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours) == a_own and
        not fileExists(a_own), "A's Quick slot does not show B's state")

  # A state an older build wrote under the bare file name, for A.
  let legacy = sdir / legacy_state_file_name(a.rom_path, 0)
  check(a.save_state(legacy), "an older build's Quick slot file for A")
  check(state_read_path(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours) == legacy,
        "A reads its older-build Quick slot")
  check(a.load_state(state_read_path(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours)),
        "and loads it")
  check(state_read_path(sdir, b.rom_path, b.state_rom_identity(), 0, b_ours) == b_own,
        "B never reads A's older-build file")
  check(legacy notin state_delete_paths(sdir, b.rom_path, b.state_rom_identity(), 0, b_ours),
        "B's Delete never removes A's older-build file")
  check(state_delete_paths(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours) == @[legacy],
        "A's Delete removes its older-build file")
  check(a.save_state(a_own), "A's next Quick Save writes the new name")
  check(state_read_path(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours) == a_own,
        "and the new file is what the slot shows")
  check(state_delete_paths(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours) ==
        @[a_own, legacy], "A's Delete then removes both, so the slot shows empty")
  check(fileExists(b_own) and b.load_state(b_own), "B's own state is untouched throughout")

block:  # GB: the same identity test
  let g = boot_gb(make_gb_rom("gb_ident"))
  let path = dir / "gb_ident.state"
  check(g.save_state(path), "a GB state saves")
  check(g.state_is_for(readFile(path)), "its header names its cart")
  let other = boot_gba(make_gba_rom("gba_ident"))
  check(not other.state_is_for(readFile(path)), "a GBA cart does not claim a GB state")

echo "=== A hack that differs only past 1 MB keeps its own slots ==="

proc without_whole_rom(img: string): string =
  ## A state as a build before the whole-ROM trailer wrote it.
  result = img[0 ..< img.len - 4 - WHOLE_ROM_TRAILER_LEN]
  result[14] = char(uint8(result[14]) and not uint8(STATE_FLAG_WHOLE_ROM))

block:
  let a = boot_gba(make_gba_rom("Emerald", "orig", size = 0x200000))
  let h = boot_gba(make_gba_rom("Emerald", "hack", size = 0x200000, late_mark = 1))
  check(a.state_prior_rom_identity() == h.state_prior_rom_identity() and
        a.state_rom_identity() != h.state_rom_identity(),
        "the carts share their first 1 MB and not their whole-ROM identity")
  let sdir = dir / "slots-whole"
  createDir(sdir)
  proc a_ours(data: string): bool = a.state_is_for(data)
  proc h_ours(data: string): bool = h.state_is_for(data)
  proc a_read(): string =
    state_read_path(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours,
                    a.state_prior_rom_identity())
  proc h_read(): string =
    state_read_path(sdir, h.rom_path, h.state_rom_identity(), 0, h_ours,
                    h.state_prior_rom_identity())
  proc a_dels(): seq[string] =
    state_delete_paths(sdir, a.rom_path, a.state_rom_identity(), 0, a_ours,
                       a.state_prior_rom_identity())
  proc h_dels(): seq[string] =
    state_delete_paths(sdir, h.rom_path, h.state_rom_identity(), 0, h_ours,
                       h.state_prior_rom_identity())
  let a_own = sdir / state_file_name(a.rom_path, a.state_rom_identity(), 0)
  let h_own = sdir / state_file_name(h.rom_path, h.state_rom_identity(), 0)
  # The name the previous build gave both carts' Quick slot: the 1 MB identity
  let prior = sdir / state_file_name(a.rom_path, a.state_prior_rom_identity(), 0)
  check(a_own != h_own and prior != a_own and prior != h_own,
        "each cart gets its own Quick slot file, apart from the previous name")

  check(h.save_state(h_own), "the hack's Quick Save writes its own file")
  check(a_read() == a_own and not fileExists(a_own),
        "the original's Quick slot does not show the hack's state")
  check(not a.load_state(h_own), "nor loads it")

  # The previous build's file for the original, under the 1 MB name
  writeFile(prior, without_whole_rom(a.state_bytes(thumbnail = true)))
  check(a_read() == prior, "the original reads the previous build's Quick slot")
  check(a.load_state(a_read()), "and loads it")
  check(h_read() == h_own, "the hack still shows its own file")
  check(a_dels() == @[prior], "the original's Delete removes the previous build's file")

  # A file under the previous name that says which cart it is for
  removeFile(h_own)
  check(a.save_state(prior), "a state naming the original, under the previous name")
  check(h_read() == h_own and not fileExists(h_own),
        "the hack's empty slot does not show it")
  check(prior notin h_dels(), "the hack's Delete never removes it")
  check(a_read() == prior, "the original's slot does")

  check(a.save_state(a_own), "the original's next Quick Save writes the new name")
  check(a_read() == a_own, "and the new file is what the slot shows")
  check(a_dels() == @[a_own, prior],
        "Delete then removes both, so the slot shows empty")

  # A cart of 1 MB or less keeps the name it had
  let s = boot_gba(make_gba_rom("Small"))
  check(s.state_rom_identity() == s.state_prior_rom_identity(),
        "a cart under 1 MB keeps its slot names")

echo "=== A second window on an open game is refused (finding 1) ==="

let locks = dir / "locks"

proc open_game(w: var GameLock; rom: string; builds = true): Refusal =
  ## load_rom's order: the battery/cheat lock before the .sav is read, the
  ## core built, the save-state lock once the cart is known, and the old
  ## game's locks let go only when the new game is running.
  var c: GameLock
  if not w.claim_files(locks, rom, c): return rfFiles
  if not builds:
    c.abandon()
    return rfNone
  let g = boot_gba(rom)
  if not w.claim_states(locks, rom, g.state_rom_identity(), c):
    c.abandon()
    return rfStates
  w.commit(c)
  rfNone

block:
  let ruby = make_gba_rom("Ruby", "lock")
  let sapphire = make_gba_rom("Sapphire", "lock", mark = 1)
  var w1, w2: GameLock
  check(w1.open_game(ruby) == rfNone, "window 1 opens Ruby")
  check(w2.open_game(ruby) == rfFiles, "window 2 is refused Ruby")
  check(w2.files.key == "" and w2.states.key == "",
        "and the refused load holds nothing")
  let rel = relativePath(ruby, getCurrentDir())
  check(w2.open_game(rel) == rfFiles, "also when the path is spelled relative")
  when defined(posix):
    let linked_dir = dir / "lock-link"
    createSymlink(dir / "lock", linked_dir)
    check(w2.open_game(linked_dir / "Ruby.gba") == rfFiles,
          "also through a symlinked folder (the same Ruby.sav)")
  check(w1.open_game(ruby) == rfNone, "window 1's Reset keeps its game")
  check(w1.files.held and w1.states.held, "and its locks")
  check(w2.open_game(ruby) == rfFiles, "window 2 is still refused after the Reset")
  check(w2.open_game(sapphire) == rfNone, "window 2 opens Sapphire")
  check(w1.open_game(sapphire) == rfFiles,
        "window 1 is refused Sapphire and keeps running Ruby")
  check(w1.files.key == files_key(ruby), "window 1 still holds Ruby")
  check(w2.open_game(ruby) == rfFiles, "so window 2 is still refused Ruby")
  check(w2.files.key == files_key(sapphire), "window 2 keeps Sapphire")

  # A file that turns out not to be a ROM lets go of the lock it took
  let emerald = make_gba_rom("Emerald", "lock", mark = 2)
  check(w1.open_game(emerald, builds = false) == rfNone and
        w1.files.key == files_key(ruby), "a failed load leaves window 1 on Ruby")
  var w3: GameLock
  check(w3.open_game(emerald) == rfNone, "and Emerald is free for another window")

  # Switching is what releases: window 1 moves on, and Ruby is free
  let leaf = make_gba_rom("LeafGreen", "lock", mark = 3)
  check(w1.open_game(leaf) == rfNone, "window 1 switches to LeafGreen")
  check(w2.open_game(ruby) == rfNone, "and window 2 can now open Ruby")

  # Tetris.gb and Tetris.gbc beside each other write one Tetris.sav
  check(files_key(dir / "Tetris.gb") == files_key(dir / "Tetris.gbc"),
        "same folder and name, other extension: the same battery lock")

  # Copies: under another name, a second save of their own; under the same
  # name in another folder, the save states would be shared
  let copy = dir / "lock" / "Ruby copy.gba"
  copyFile(ruby, copy)
  var w4: GameLock
  check(w4.open_game(copy) == rfNone, "a copy under another name opens")
  let other = make_gba_rom("Ruby", "elsewhere")
  var w5: GameLock
  check(w5.open_game(other) == rfStates,
        "a copy under the same name elsewhere is refused (shared slots)")
  check(w5.files.key == "" and w5.states.key == "", "and holds nothing")
  let big_orig = make_gba_rom("Emerald", "lock-orig", size = 0x200000)
  let big_hack = make_gba_rom("Emerald", "lock-hack", size = 0x200000, late_mark = 1)
  var w6, w7: GameLock
  check(w6.open_game(big_orig) == rfNone and w7.open_game(big_hack) == rfNone,
        "a same-named hack that differs only past 1 MB opens beside the " &
        "original: its slots are its own")

  when defined(macosx) or defined(windows):
    check(files_key(dir / "lock" / "RUBY.gba") == files_key(ruby),
          "the name's case does not matter where the file system ignores it")

  let (text, hint) = refusal_notice(rfFiles, "Ruby.gba", "Ruby.gba")
  check("another dingbat window" in text and "Ruby.sav" in hint and
        "Sapphire" in hint and "copy of the ROM file" in hint,
        "the notice says why and what works for linking")

block:  # the OS lets go when the holder dies, however it dies
  let path = lock_path(locks, "files", "held by a child")
  let p = startProcess(getAppFilename(), args = ["--hold-lock", path],
                       options = {poStdErrToStdOut})
  let said = p.outputStream.readLine()
  check(said == "locked", "a child process takes the lock")
  var l: FileLock
  check(try_lock(path, "parent", l) == lrBusy, "the parent cannot while it lives")
  p.kill()
  discard p.waitForExit()
  p.close()
  check(try_lock(path, "parent", l) == lrTaken, "and can once it is killed")
  l.release()

block:  # no lock file can be made: the game opens anyway
  let blocked = dir / "not-a-folder"
  writeFile(blocked, "")
  var l: FileLock
  check(try_lock(blocked / "x.lock", "k", l) == lrNoLock,
        "a lock folder that cannot be made is not a refusal")
  var w: GameLock
  var c: GameLock
  check(w.claim_files(blocked, make_gba_rom("Unlockable"), c) and not c.files.held,
        "the load goes ahead unlocked")

removeDir(dir)

if failures > 0:
  echo &"{failures} check(s) FAILED"
  quit(1)
echo "ok"
