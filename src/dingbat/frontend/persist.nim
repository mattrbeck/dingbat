## What the desktop app decides about a game's files that needs no SDL, ImGui
## or GL, so tests/desktop_persist_test.nim can run it headless: when to tell
## the player their battery save is not being written. dingbat.nim draws.

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
