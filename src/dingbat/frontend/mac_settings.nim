## The native macOS Settings window (mac_settings.m) for config_editor's
## tabs: the same rows, edit, Apply / Revert / OK and closing questions as
## the ImGui window, in AppKit controls. macOS only.
##
## Controls change the edit at once (it is only an edit until Apply); the
## footer's actions and closing wait for `mac_settings_tick` in the main
## loop. The window refreshes from the rows there, at once after a change
## and every REFRESH_MS anyway (a capture finishing, a pad plugged in).

import std/[strutils, times]
import sdl3
import config_editor
import keybindings_widget
import settings_model

{.compile("mac_settings.m", "-fobjc-arc").}

{.push cdecl, importc.}
proc dbs_open(titles: ptr cstring; n, hidden: cint)
proc dbs_close()
proc dbs_is_key(): cint
proc dbs_ask_discard()
proc dbs_begin(tab: cint; sig: cstring): pointer
proc dbs_row(parent: pointer; kind, sid, arg: cint; title, help, hint, text: cstring;
             on, value: cint; options, values, option_on: cstring;
             inline, enabled, shown, valid: cint; width: cfloat; nkids: cint): pointer
proc dbs_dump(): cstring
proc dbs_do(tab, item, value: cstring): cint
proc dbs_key(key_code: cint)
proc dbs_close_button()
proc dbs_snapshot(path: cstring): cint
{.pop.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

type SettingsAction = enum
  saApply, saRevert, saOk, saResetDefaults, saClose, saApplyClose, saDiscardClose

const REFRESH_MS = 100

var
  ed: ConfigEditor
  hidden = false        # the GUI driver's: never on screen
  shown_now = false
  dirty = false
  last_refresh: float
  actions: seq[SettingsAction]
  pad_hint = ""         # SDL's background-joystick hint, restored on close

proc emit(parent: pointer; rows: seq[SettingRow]) =
  for r in rows:
    var on_mask = ""
    for b in r.option_on: on_mask.add(if b: '1' else: '0')
    # A binding waiting says so, as Mac apps' shortcut fields do
    let text = if r.kind == rkBinding and r.on:
                 (if r.id == siKeyBinding: "Press a key..." else: "Press a button...")
               else: r.text
    let kids = dbs_row(parent, cint(ord(r.kind)), cint(ord(r.id)), cint(r.arg),
                       cstring(r.title), cstring(r.help), cstring(r.hint), cstring(text),
                       cint(ord(r.on)), cint(r.value), cstring(r.options.join("\n")),
                       cstring(r.values.join(",")), cstring(on_mask), cint(ord(r.inline)),
                       cint(ord(r.enabled)), cint(ord(r.shown)), cint(ord(r.valid)),
                       cfloat(r.width), cint(r.rows.len))
    if r.rows.len > 0 and kids != nil: emit(kids, r.rows)

proc refresh() =
  for i, tab in ed.tabs():
    emit(dbs_begin(cint(i), cstring(signature(tab.rows))), tab.rows)
  dirty = false
  last_refresh = epochTime()

proc close() =
  ed.end_captures()
  ed.open = false
  ed.show_tab(-1)
  shown_now = false
  dbs_close()
  discard setHint(HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, cstring(pad_hint))

# AppKit calls these. Nothing may raise out of them into Objective-C.

proc dingbat_settings_set(id, value: cint; text: cstring) {.exportc, cdecl.} =
  if ed == nil or id < 0 or id > cint(ord(SettingId.high)): return
  try:
    ed.set_value(SettingId(id), int(value), $text)
    dirty = true
  except CatchableError as e: echo "settings: ", e.msg

proc dingbat_settings_activate(id, arg: cint) {.exportc, cdecl.} =
  if ed == nil or id < 0 or id > cint(ord(SettingId.high)): return
  try:
    ed.activate(SettingId(id), int(arg))
    dirty = true
  except CatchableError as e: echo "settings: ", e.msg

proc dingbat_settings_tab(tab: cint) {.exportc, cdecl.} =
  if ed != nil and shown_now:
    ed.show_tab(int(tab))
    dirty = true

proc dingbat_settings_action(action: cint) {.exportc, cdecl.} =
  if action >= 0 and action <= cint(ord(SettingsAction.high)):
    actions.add SettingsAction(action)

proc dingbat_settings_capturing(): cint {.exportc, cdecl.} =
  if ed == nil: 0
  else: cint(ord(ed.keybindings.wants_input()))

proc dingbat_settings_key(scancode: cint) {.exportc, cdecl.} =
  ## A key let go while a binding waits: its key as the SDL handler names
  ## it (the unshifted key of the scancode)
  if ed == nil: return
  try:
    let key = getKeyFromScancode(Scancode(scancode), Keymod(0), true)
    ed.keybindings.key_released(cint(key))
    dirty = true
  except CatchableError as e: echo "settings: ", e.msg

# ── For dingbat.nim ──

proc mac_settings_init*(editor: ConfigEditor; driven: bool) =
  ed = editor
  ed.native = true
  hidden = driven

proc mac_settings_show*() =
  ## Open (or bring forward) the window, with the edit started afresh as the
  ## ImGui window starts it.
  if not shown_now:
    ed.do_reset()
    ed.open = true
    shown_now = true
    # Its own window has the keyboard, so pads only reach SDL as background
    # events; the Controller tab's capture needs them
    let h = getHint(HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS)
    pad_hint = if h == nil: "0" else: $h
    discard setHint(HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1")
  var titles: seq[cstring]
  for t in TAB_TITLES: titles.add cstring(t)
  dbs_open(addr titles[0], cint(titles.len), cint(ord(hidden)))
  refresh()

proc mac_settings_tick*() =
  ## Once a main-loop iteration: the queued actions, then a refresh if due.
  if not shown_now and actions.len == 0: return
  let queued = move actions
  actions = @[]
  for a in queued:
    case a
    of saApply: ed.do_apply()
    of saRevert: ed.do_reset()
    of saOk:
      ed.do_apply()
      close()
    of saResetDefaults: ed.do_factory_reset()
    of saClose:
      # As the ImGui window's X: a capture ends; unapplied edits are asked about
      ed.end_captures()
      if ed.has_unapplied_edits(): dbs_ask_discard()
      else: close()
    of saApplyClose:
      ed.do_apply()
      close()
    of saDiscardClose: close()
    dirty = true
  if shown_now and (dirty or epochTime() - last_refresh >= REFRESH_MS / 1000):
    refresh()

proc mac_settings_has_keyboard*(): bool =
  ## The window is the key window: its keys are its own, not the game's.
  dbs_is_key() != 0

# ── For the GUI driver ──

proc mac_settings_dump*(): string =
  let p = dbs_dump()
  result = $p
  c_free(p)

proc mac_settings_do*(tab, item, value: string): int =
  ## A control by tab and title (tab "": the footer); 1 done, 0 none, -1 greyed
  result = int(dbs_do(cstring(tab), cstring(item), cstring(value)))
  dirty = true

proc mac_settings_key*(key_code: int) = dbs_key(cint(key_code))
proc mac_settings_close_button*() = dbs_close_button()
proc mac_settings_snapshot*(path: string): bool = dbs_snapshot(cstring(path)) != 0
proc mac_settings_shown*(): bool = shown_now
