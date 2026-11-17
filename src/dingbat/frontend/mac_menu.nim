## The macOS menu bar (mac_menu.m) for menu_model's menus, and the native
## pieces beside it: the Open panel, recent documents for the Dock and the
## Apple menu, the title bar's document icon. macOS only.
##
## Cmd shortcuts belong to the menu bar here: AppKit fires them even while an
## ImGui field has the keyboard, as in any Mac app, so the SDL key handler
## leaves them alone while `installed`. Tab, Shift+Tab and F12 stay with the
## key handler and are only shown.

import sdl3
import menu_model

{.compile("mac_menu.m", "-fobjc-arc").}
{.passL: "-framework Cocoa -framework UniformTypeIdentifiers".}

{.push cdecl, importc.}
proc dbm_install(titles: ptr cstring; fixed: ptr cint; n: cint; version: cstring;
                 sdl_window: pointer)
proc dbm_add_edit(menu: pointer; title: cstring; cmd: cint; selector, key: cstring;
                  shift: cint)
proc dbm_add_action(menu: pointer; title: cstring; cmd, arg: cint; key: cstring;
                    alt, shown: cint)
proc dbm_add_submenu(menu: pointer; title: cstring; cmd: cint): pointer
proc dbm_add_separator(menu: pointer)
proc dbm_add_system(menu: pointer; title, selector, key: cstring; alt: cint)
proc dbm_add_slider(menu: pointer; title: cstring; cmd, done, lo, hi, value: cint)
proc dbm_open_panel(nswindow: pointer; exts_csv, dir: cstring)
proc dbm_note_recent(path: cstring)
proc dbm_clear_recents()
proc dbm_set_document(nswindow: pointer; path: cstring)
proc dbm_free_aspect(nswindow: pointer)
proc dbm_perform_key(chars: cstring; shift: cint): cint
proc dbm_dump(): cstring
proc dbm_pick(path: cstring): cint
proc dbm_watch_blocked()
proc dbm_track_for(ms: cint)
{.pop.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

var
  installed* = false
  build_bar: proc(): seq[MenuItem]
  state_of: proc(cmd: MenuCmd; arg: int): MenuState
  opened = ""   # what the Open panel returned, until taken
  on_blocked: proc()

proc populate(menu: pointer; items: seq[MenuItem]) =
  for it in items:
    case it.kind
    of mkSeparator: dbm_add_separator(menu)
    of mkAction:
      dbm_add_action(menu, cstring(it.title), cint(ord(it.cmd)), cint(it.arg),
                     cstring(it.key), cint(ord(it.alt)), cint(ord(it.shown)))
    of mkSubmenu:
      populate(dbm_add_submenu(menu, cstring(it.title), cint(ord(it.cmd))), it.items)
    of mkSlider:
      dbm_add_slider(menu, cstring(it.title), cint(ord(it.cmd)), cint(ord(it.done)),
                     cint(it.lo), cint(it.hi), cint(it.value))
    of mkSystem:
      dbm_add_system(menu, cstring(it.title), cstring(it.selector),
                     cstring(it.key), cint(ord(it.alt)))
    of mkEdit:
      dbm_add_edit(menu, cstring(it.title), cint(ord(it.cmd)), cstring(it.selector),
                   cstring(it.key), cint(ord(it.shift)))

# AppKit calls these. Nothing may raise out of them into Objective-C.

proc dingbat_menu_populate(menu: pointer; top: cint) {.exportc, cdecl.} =
  try:
    let bar = build_bar()
    if top >= 0 and top < bar.len: populate(menu, bar[top].items)
  except CatchableError as e:
    echo "menu: ", e.msg

proc dingbat_menu_state(cmd, arg: cint; checked: ptr cint): cint {.exportc, cdecl.} =
  checked[] = 0
  if cmd < 0 or cmd > cint(ord(MenuCmd.high)): return 0
  try:
    let (on, ticked) = state_of(MenuCmd(cmd), int(arg))
    checked[] = cint(ord(ticked))
    cint(ord(on))
  except CatchableError:
    0

proc dingbat_menu_action(cmd, arg: cint) {.exportc, cdecl.} =
  if cmd >= 0 and cmd <= cint(ord(MenuCmd.high)):
    push_cmd(MenuCmd(cmd), int(arg))

proc dingbat_open_panel_done(path: cstring) {.exportc, cdecl.} =
  if path != nil: opened = $path

proc dingbat_main_loop_blocked() {.exportc, cdecl.} =
  if on_blocked == nil: return
  try: on_blocked()
  except CatchableError as e:
    echo "blocked: ", e.msg

# ── For dingbat.nim ──

proc nswindow(window: Window): pointer =
  getPointerProperty(getWindowProperties(window), PROP_WINDOW_COCOA_WINDOW_POINTER, nil)

proc mac_menu_install*(window: Window; build: proc(): seq[MenuItem];
                       state: proc(cmd: MenuCmd; arg: int): MenuState;
                       version: string) =
  ## Replace SDL's stock menus with `build()`'s. The app menu (first), Window
  ## and Help are built once, as AppKit adds items of its own to them; the
  ## rest are rebuilt each time they open.
  build_bar = build
  state_of = state
  let bar = build()
  var titles: seq[cstring]
  var fixed: seq[cint]
  for i, top in bar:
    titles.add cstring(top.title)
    fixed.add cint(ord(i == 0 or top.title in ["Window", "Help"]))
  dbm_install(addr titles[0], addr fixed[0], cint(bar.len), cstring(version),
              nswindow(window))
  installed = true

proc mac_open_panel*(window: Window; exts: openArray[string]; dir: string) =
  ## The Open panel as a sheet; its choice comes back by `mac_take_opened`.
  var csv = ""
  for i, e in exts:
    if i > 0: csv.add ','
    csv.add e
  dbm_open_panel(nswindow(window), cstring(csv), cstring(dir))

proc mac_take_opened*(): string =
  result = opened
  opened = ""

proc mac_note_recent*(path: string) = dbm_note_recent(cstring(path))
proc mac_clear_recents*() = dbm_clear_recents()

proc mac_set_document*(window: Window; path: string) =
  ## The title bar's document icon (drag it, Cmd-click the title for its folder).
  dbm_set_document(nswindow(window), cstring(path))

proc mac_free_aspect*(window: Window) =
  ## After SDL_SetWindowAspectRatio(0, 0): resizing really is free again.
  dbm_free_aspect(nswindow(window))

proc mac_menu_key*(key: string; shift: bool): bool =
  ## A Cmd shortcut through the menu bar, as AppKit takes a real one.
  dbm_perform_key(cstring(key), cint(ord(shift))) != 0

proc mac_while_blocked*(cb: proc()) =
  ## `cb` about every 100 ms while AppKit holds the main loop in a run loop of
  ## its own: a menu open (inside SDL's event pump), a live resize, a modal
  ## panel. Only what is safe between two loop iterations belongs in it.
  on_blocked = cb
  dbm_watch_blocked()

proc mac_track_for*(ms: int) =
  ## The GUI driver's stand-in for a menu held open: the run loop in AppKit's
  ## menu-tracking mode for `ms`.
  dbm_track_for(cint(ms))

proc mac_menu_dump*(): string =
  ## Every menu as it would show now, one item a line.
  let p = dbm_dump()
  result = $p
  c_free(p)

proc mac_menu_pick*(path: string): int =
  ## Choose "File>Quick Save" as a click would: 1 done, 0 no such item,
  ## -1 greyed out.
  int(dbm_pick(cstring(path)))
