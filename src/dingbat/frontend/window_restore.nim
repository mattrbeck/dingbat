## Whether dingbat opens fullscreen: it does when it quit fullscreen and the
## platform's convention is to bring a window back as the user left it.
##
## macOS leaves that to the user: System Settings > Desktop & Dock > "Close
## windows when quitting an application" (NSQuitAlwaysKeepsWindows, the
## inverse). AppKit apps come back fullscreen only when it is off; SDL opts
## dingbat out of AppKit's restoration (ApplePersistenceIgnoreState), so the
## setting is read here. Windows and Linux have no such setting, and the
## apps people play on them (browsers' F11 in Firefox and Chrome, games'
## display mode) come back the way they were left.
##
## And, while running, whether the window is fullscreen however it got
## there (`FullscreenTrack`).

when defined(macosx):
  {.passL: "-framework CoreFoundation".}

  const CF_HEADER = "<CoreFoundation/CoreFoundation.h>"
  const kCFStringEncodingUTF8 = 0x08000100'u32

  var kCFPreferencesCurrentApplication {.importc, header: CF_HEADER.}: pointer
  proc CFStringCreateWithCString(alloc: pointer; cStr: cstring;
                                 encoding: uint32): pointer
    {.importc, header: CF_HEADER.}
  proc CFPreferencesGetAppBooleanValue(key, applicationID: pointer;
                                       keyExistsAndHasValidFormat: ptr uint8): uint8
    {.importc, header: CF_HEADER.}
  proc CFRelease(cf: pointer) {.importc, header: CF_HEADER.}

proc restores_windows*(keeps_windows, is_set: bool): bool =
  ## macOS: NSQuitAlwaysKeepsWindows as read. Unset counts as "Close
  ## windows" on, as NSUserDefaults' boolForKey reads it: opening windowed
  ## when unsure is the smaller surprise.
  is_set and keeps_windows

proc system_restores_windows*(): bool =
  ## The platform asks apps to reopen their windows as they were at quit.
  when defined(macosx):
    let key = CFStringCreateWithCString(nil, "NSQuitAlwaysKeepsWindows",
                                        kCFStringEncodingUTF8)
    if key == nil: return false
    var is_set = 0'u8
    # The app's own domain, then the global one, as NSUserDefaults reads it
    let keeps = CFPreferencesGetAppBooleanValue(
      key, kCFPreferencesCurrentApplication, addr is_set)
    CFRelease(key)
    restores_windows(keeps != 0, is_set != 0)
  else:
    true

proc start_fullscreen*(quit_fullscreen, system_restores: bool): bool =
  ## A crash or kill counts as quitting in the state last saved.
  quit_fullscreen and system_restores

# ── While running: the window's real fullscreen state ──

type
  FullscreenTrack* = object
    ## What the window really is, as window events read it, next to what
    ## the app believes (`app.fullscreen`: the menu's checkmark and the
    ## saved flag). macOS puts a window in a fullscreen Space from its green
    ## button or Ctrl+Cmd+F without the app asking, and SDL 2 does not
    ## report that (no flag, only the resize).
    seen:   bool   ## the real state at the last reading
    refit*: bool   ## the window was to be sized to the picture while it
                   ## was fullscreen: do it once it is a window again

  FullscreenChange* = enum
    fcNone     ## nothing to adopt
    fcEntered  ## the OS made the window fullscreen
    fcLeft     ## the OS gave it back as a window

proc observe*(t: var FullscreenTrack; real, believed: bool): FullscreenChange =
  ## One reading of the real state. Only a change counts: the app's own
  ## toggles land late (macOS animates into and out of a Space), and a
  ## reading taken before one lands must not undo it. A window starts
  ## windowed, even one created fullscreen, which gets there by a
  ## transition like any other.
  if real == t.seen: return fcNone
  t.seen = real
  if real == believed: fcNone
  elif real: fcEntered
  else: fcLeft

proc take_refit*(t: var FullscreenTrack; real: bool): bool =
  ## Whether to size the window to the picture now: it is a window again,
  ## and a sizing came while it was not (a game loaded, a Super Game Boy
  ## border, the frame size), or it would come back the old game's shape.
  if t.refit and not real:
    t.refit = false
    return true
  false

when defined(macosx):
  {.passL: "-lobjc".}
  proc sel_registerName(name: cstring): pointer
    {.importc, header: "<objc/runtime.h>".}
  proc objc_msgSend() {.importc, header: "<objc/message.h>".}

  proc ns_window_fullscreen*(nswindow: pointer): bool =
    ## `[nswindow styleMask] & NSWindowStyleMaskFullScreen`: AppKit's own
    ## answer, whoever put the window there.
    type StyleMask = proc (self, op: pointer): uint {.cdecl.}
    const NSWindowStyleMaskFullScreen = 1'u shl 14
    if nswindow == nil: return false
    let send = cast[StyleMask](objc_msgSend)
    (send(nswindow, sel_registerName("styleMask")) and
      NSWindowStyleMaskFullScreen) != 0
