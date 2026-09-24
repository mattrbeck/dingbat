## What the desktop app decides about a game's files that needs no SDL, ImGui
## or GL, so tests/desktop_persist_test.nim can run it headless: when to tell
## the player their battery save is not being written, what to say when a
## save state could not be written, and what the save-state slot files are
## called. dingbat.nim draws and does the file work.

import std/[os, strutils]

type
  BatteryNotice* = object
    ## The "save file can't be written" modal. A core records every failed
    ## battery write (`save_error`) and flags the first of a run
    ## (`save_error_new`); this turns that into one message per run, gone
    ## when the player dismisses it or when a write lands.
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

# ──────────────────────────── Save-state slot files ────────────────────────────
#
# A slot file is named by the ROM's file name and its ROM identity (a hash
# of the whole ROM file: `state_rom_identity`), so two different games that
# share a file name (a hack beside the original, two zips whose inner ROMs
# share a name) keep separate slots. Older builds named slots by the file
# name alone and then, for GBA, by the file name and a hash of the ROM's
# first 1 MB (`state_prior_rom_identity`); such a file is still read when
# the slot has no file of its own and the state names this cart, and is
# never written.

proc state_file_name*(rom_path: string; identity: uint32; slot: int): string =
  ## `<rom file name>-<identity, 8 hex digits>[.slotN].state`; slot 0 is the
  ## Quick slot.
  result = rom_path.extractFilename() & "-" & identity.toHex(8)
  if slot != 0: result.add ".slot" & $slot
  result.add ".state"

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
