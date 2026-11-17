## The app's notices as macOS alerts (mac_alert.m): a sheet on the game's
## window instead of notice.nim's ImGui modal, with the macOS menu bar.
##
## Each loop iteration the caller passes the one notice that should be up
## (the same order the ImGui modals take turns in) and takes the OK, which
## AppKit only queues. A notice cleared from outside takes its alert away.

import sdl3

{.compile("mac_alert.m", "-fobjc-arc").}

{.push cdecl, importc.}
proc dba_show(nswindow: pointer; serial: cint; text, hint: cstring)
proc dba_close()
proc dba_dump(): cstring
proc dba_answer(): cint
proc dba_key(key_code: cint): cint
proc dba_snapshot(path: cstring): cint
{.pop.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

var
  shown_key, shown_text, shown_hint = ""   # what the alert up now says
  serial: cint = 0                         # which alert an answer is for
  answered = false

proc dingbat_alert_answered(s: cint) {.exportc, cdecl.} =
  if s == serial: answered = true

proc mac_alert_take_ok*(): string =
  ## The key of the notice whose alert was answered since the last call
  ## (its alert is gone), or "".
  if not answered: return ""
  answered = false
  result = shown_key
  shown_key = ""
  shown_text = ""
  shown_hint = ""

proc mac_alert_show*(window: Window; key, text, hint: string) =
  ## The alert for notice `key`, or none for "". The same notice again is
  ## left as it is; another (or new wording) replaces it.
  if key == shown_key and text == shown_text and hint == shown_hint: return
  shown_key = key
  shown_text = text
  shown_hint = hint
  inc serial
  answered = false
  if key.len == 0:
    dba_close()
  else:
    let ns = getPointerProperty(getWindowProperties(window),
                                PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
    dba_show(ns, serial, cstring(text), cstring(hint))

# ── For the GUI driver ──

proc mac_alert_dump*(): string =
  ## "none", or "sheet"/"asking" then the title and the text below it
  let p = dba_dump()
  result = $p
  c_free(p)

proc mac_alert_answer*(): bool = dba_answer() != 0
proc mac_alert_key*(key_code: int): bool = dba_key(cint(key_code)) != 0
proc mac_alert_snapshot*(path: string): bool = dba_snapshot(cstring(path)) != 0
