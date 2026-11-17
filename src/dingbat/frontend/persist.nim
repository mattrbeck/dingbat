## The desktop's windowless decisions about a game's files (headless in
## tests/desktop_persist_test.nim): the battery-write failure notice, the
## state-save failure text, slot and session file names, and when a session
## counts. dingbat.nim draws and does the file work.

import std/[os, strutils, times]
import ../common/serialize

type
  BatteryNotice* = object
    ## The "save file can't be written" modal: one per run of failures
    ## (`save_error_new` flags the first), gone on dismiss or when a write
    ## lands.
    text*: string   ## what the modal says; "" = nothing to show
    hint*: string   ## the OS's wording, shown smaller

proc battery_notice_sentence*(path: string): string =
  "dingbat can't write this game's save file, so progress saved in the " &
  "game is not being kept. Check that the folder is writable and the disk " &
  "has room; it keeps retrying.\n\n" & path

proc poll*(n: var BatteryNotice; path, err: string; fresh: var bool) =
  ## Once per loop iteration with the running core's save path, `save_error`
  ## and `save_error_new` (consumed here). No core: pass "" for `err`.
  if err.len == 0:
    n.text = ""   # a write landed, or another game is running
    n.hint = ""
  elif fresh:
    fresh = false
    n.text = battery_notice_sentence(path)
    n.hint = err

proc dismiss*(n: var BatteryNotice) =
  ## The player's OK: not shown again until a write succeeds and then fails.
  n.text = ""
  n.hint = ""

const
  # A state write goes to a temp file and is renamed over the slot only once
  # it is whole, so a failed one (full disk, unwritable folder) changed nothing.
  QUICK_SAVE_FAILED* =
    "Quick Save didn't work, so nothing was changed: the Quick slot still " &
    "holds what it held before."
  SLOT_SAVE_FAILED* =
    "Saving didn't work; that slot still holds what it held before."
  # Close Game writes the battery first; if it can't, the game stays open
  CLOSE_BATTERY_FAILED* =
    "dingbat can't write this game's save file, so the game is still open: " &
    "closing it now would lose what was saved in the game. Check that the " &
    "folder is writable and the disk has room, then close it again."

# ──────────────────────────── Save-state slot files ────────────────────────────
#
# A slot file is named by the ROM's file name and identity (a hash of the
# whole ROM: `state_rom_identity`), so two games sharing a file name keep
# separate slots. Older names (file name alone; for GBA, file name plus
# `state_prior_rom_identity`, a hash of the first 1 MB) are still read when
# the slot has no file of its own and the state names this cart; never
# written.

proc state_file_name*(rom_path: string; identity: uint32; slot: int): string =
  ## `<rom file name>-<identity, 8 hex digits>[.slotN].state`; slot 0 is the
  ## Quick slot.
  result = rom_path.extractFilename() & "-" & identity.toHex(8)
  if slot != 0: result.add ".slot" & $slot
  result.add ".state"

proc session_file_name*(rom_path: string; identity: uint32): string =
  ## The session snapshot a game leaves (Close Game, a switch, quitting) and
  ## Resume puts back (web `stateauto:<game>`): `<rom file name>-<identity>.session.state`,
  ## beside the slots but none of them, so Save States never lists it.
  rom_path.extractFilename() & "-" & identity.toHex(8) & ".session.state"

proc session_battery_name*(session: string): string =
  ## Beside a session: the signature of the battery it was taken with (web
  ## `saveSig`), one line
  session & ".battery"

proc battery_signature*(sav_path: string): string =
  ## A battery file's contents as one word: "none" for no file or an empty
  ## one (a game that has never saved), else its FNV-1a. "" when it cannot be
  ## read, which matches no session.
  if sav_path.len == 0 or not fileExists(sav_path): return "none"
  try:
    let data = readFile(sav_path)
    if data.len == 0: "none" else: fnv1a(data).toHex(8)
  except CatchableError: ""

proc session_battery*(session: string): string =
  ## The signature a session was taken with; "" for none (taken before
  ## sessions had one: not proof either way, so never resumed, as the web's)
  try: readFile(session_battery_name(session)).strip()
  except CatchableError: ""

proc session_counts*(session, sav_path: string): bool =
  ## A session to go back into: there, and taken with the battery that is on
  ## disk now. One the game has saved past would put the older save back.
  if session.len == 0 or not fileExists(session): return false
  let sig = session_battery(session)
  sig.len > 0 and sig == battery_signature(sav_path)

proc session_age*(session: string): string =
  ## How long ago a session was taken, as the web's toast says it (fmtAgo)
  var m = 0'i64
  try: m = ((getTime() - getLastModificationTime(session)).inSeconds + 30) div 60
  except OSError: discard
  m = max(0'i64, m)
  if m < 1: return "moments ago"
  if m < 60: return $m & "m ago"
  let h = (m + 30) div 60
  if h < 48: return $h & "h ago"
  $((h + 12) div 24) & "d ago"

proc legacy_state_file_name*(rom_path: string; slot: int): string =
  ## What builds before the identity names called the slot.
  result = rom_path.extractFilename()
  if slot != 0: result.add ".slot" & $slot
  result.add ".state"

proc legacy_state_is_ours(path: string; ours: proc(data: string): bool): bool =
  if not fileExists(path): return false
  try: ours(readFile(path))
  except CatchableError: false

proc older_state_files(dir, rom_path: string; identity, prior: uint32;
                       slot: int): seq[string] =
  ## An older build's names for the slot, newest first.
  if prior != identity: result.add dir / state_file_name(rom_path, prior, slot)
  result.add dir / legacy_state_file_name(rom_path, slot)

proc state_read_path*(dir, rom_path: string; identity: uint32; slot: int;
                      ours: proc(data: string): bool;
                      prior = identity): string =
  ## The file a slot shows and loads: its own, else an older build's file
  ## that names this cart (`ours`), else its own name (not there). `prior`
  ## is the identity the previous names used (`state_prior_rom_identity`).
  result = dir / state_file_name(rom_path, identity, slot)
  if fileExists(result): return
  for old in older_state_files(dir, rom_path, identity, prior, slot):
    if legacy_state_is_ours(old, ours): return old

proc state_delete_paths*(dir, rom_path: string; identity: uint32; slot: int;
                         ours: proc(data: string): bool;
                         prior = identity): seq[string] =
  ## Every file Delete must remove so the slot shows empty: its own and any
  ## older build's for this cart. Never another game's.
  let own = dir / state_file_name(rom_path, identity, slot)
  if fileExists(own): result.add own
  for old in older_state_files(dir, rom_path, identity, prior, slot):
    if legacy_state_is_ours(old, ours): result.add old
