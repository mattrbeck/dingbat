## The desktop app's menus as data. dingbat.nim describes them once (titles,
## shortcuts, what each item does, whether it is enabled or ticked) and two
## menu bars draw that: the in-window Dear ImGui bar (imgui_menu.nim) on
## Windows and Linux, and the macOS menu bar (mac_menu.nim).
##
## A chosen item is queued here as (cmd, arg) and run by the main loop at
## its next iteration, never from inside a menu: AppKit calls back while it
## tracks a menu, deep inside SDL's event pump, and ImGui while it draws.
## No SDL, ImGui or GL, so tests build it headless.

import std/strutils

type
  MenuCmd* = enum
    mcNone
    # Submenus that can be greyed out
    mcRecentMenu, mcChannelsMenu
    # File (and the macOS app menu)
    mcOpenRom, mcOpenRecent, mcClearRecents, mcQuickSave, mcQuickLoad,
    mcSaveStates, mcScreenshot, mcCloseGame, mcSettings, mcQuit, mcHelp
    # Emulation
    mcReset, mcPause, mcFrameAdvance, mcRewind, mcTurbo, mcFastForward,
    mcCloseLid, mcCheats, mcLinkCable
    # Audio/Video
    mcVolume, mcVolumeDone, mcMute, mcPitchCorrect, mcAudioInterp,
    mcAnalogFilter, mcMp2kHle, mcColorCorrection, mcChannel, mcFrameSize,
    mcFullscreen
    # Debug
    mcOverlay, mcGbaDebug, mcGbDebug
    # Edit (macOS): an ImGui text field's, when the game's window has the keyboard
    mcUndo, mcRedo, mcCut, mcCopy, mcPaste, mcSelectAll

  MenuKind* = enum
    mkAction     ## runs `cmd` with `arg`
    mkSeparator
    mkSubmenu    ## `items`; greyed out when `cmd`'s state says so
    mkSlider     ## `cmd` with the value while dragging, `done` once let go
    mkEdit       ## macOS only: Edit's `selector` ("copy:") for a native
                 ## field, or `cmd` for the ImGui field in the game's window
    mkSystem     ## macOS only: AppKit's own action `selector` ("hide:"), or
                 ## "services" for the Services submenu

  ShownKey* = enum
    ## macOS: a key the SDL key handler owns, shown beside the item. Bound
    ## in AppKit only so it is drawn; the item ignores that key's own press.
    ## Not printable keys: a menu that takes a key takes its typed text too.
    skNone, skTab, skShiftTab, skF12

  MenuItem* = object
    kind*:     MenuKind
    title*:    string
    cmd*:      MenuCmd
    arg*:      int
    key*:      string    ## a Cmd (macOS) / Ctrl shortcut, lowercase ("s", ",")
    alt*:      bool      ## `key` with Option too (macOS Hide Others)
    shift*:    bool      ## `key` with Shift too (macOS Redo, Close Window)
    hint*:     string    ## ImGui's shortcut column ("Tab"), not bound
    shown*:    ShownKey
    enabled*:  bool
    checked*:  bool
    value*, lo*, hi*: int
    done*:     MenuCmd
    selector*: string
    items*:    seq[MenuItem]

  MenuState* = tuple[enabled, checked: bool]

proc action*(title: string; cmd: MenuCmd; arg = 0; key = ""; hint = "";
             shown = skNone): MenuItem =
  MenuItem(kind: mkAction, title: title, cmd: cmd, arg: arg, key: key,
           hint: hint, shown: shown, enabled: true)

proc separator*(): MenuItem = MenuItem(kind: mkSeparator, enabled: true)

proc submenu*(title: string; items: seq[MenuItem]; cmd = mcNone): MenuItem =
  MenuItem(kind: mkSubmenu, title: title, cmd: cmd, items: items, enabled: true)

proc slider*(title: string; cmd, done: MenuCmd; value, lo, hi: int): MenuItem =
  MenuItem(kind: mkSlider, title: title, cmd: cmd, done: done, value: value,
           lo: lo, hi: hi, enabled: true)

proc edit*(title: string; cmd: MenuCmd; selector, key: string; shift = false): MenuItem =
  MenuItem(kind: mkEdit, title: title, cmd: cmd, selector: selector, key: key,
           shift: shift, enabled: true)

proc system*(title, selector: string; key = ""; alt = false; shift = false): MenuItem =
  MenuItem(kind: mkSystem, title: title, selector: selector, key: key,
           alt: alt, shift: shift, enabled: true)

proc apply_state*(items: var seq[MenuItem];
                  state: proc(cmd: MenuCmd; arg: int): MenuState) =
  ## Fill each action's and submenu's enabled/checked from `state`.
  for it in items.mitems:
    if it.kind in {mkAction, mkSubmenu} and it.cmd != mcNone:
      (it.enabled, it.checked) = state(it.cmd, it.arg)
    if it.kind == mkSubmenu: apply_state(it.items, state)

proc imgui_label*(it: MenuItem; mod_name: string): string =
  ## The ImGui bar writes a shortcut into the title: "Quick Save  Ctrl+S".
  if it.key.len == 0: it.title
  else: it.title & "  " & mod_name & "+" & it.key.toUpperAscii

proc find*(items: seq[MenuItem]; path: openArray[string];
           found: var MenuItem): bool =
  ## The item at `path` by titles (["File", "Quick Save"]).
  if path.len == 0: return false
  for it in items:
    if it.title == path[0]:
      if path.len == 1:
        found = it
        return true
      if it.kind == mkSubmenu: return find(it.items, path[1 .. ^1], found)
  false

# ── The queue of chosen items ──

var pending: seq[(MenuCmd, int)]

proc push_cmd*(cmd: MenuCmd; arg = 0) = pending.add((cmd, arg))

proc take_cmds*(): seq[(MenuCmd, int)] =
  result = move pending
  pending = @[]
