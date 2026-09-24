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
