## Which dingbat window owns a game's files. Two windows on one ROM would
## each rewrite the whole `.sav` from their own battery RAM, one over the
## other's progress, and would share the save-state slots and the cheat list,
## so a second window on a game is refused.
##
## A window holds two OS advisory locks (flock / LockFileEx) on files under
## `config_dir/locks`, not next to the ROM (its folder may be read-only):
##
## * the battery and cheat files: the ROM's folder (symlinks resolved) plus
##   its name minus the extension, which is what `<rom>.sav` and `<rom>.cht`
##   are named from. A zip's ROM lives in the zip's own cache folder, keyed by
##   the zip's real path, so this covers a zip opened twice as well;
## * the save-state slots: `<rom file name>-<identity>` (persist.nim), which
##   are shared by every folder's copy of a game under the same file name.
##
## The OS drops a lock when its process ends, however it ends, so a crash or
## a kill never leaves a game unopenable. No SDL here:
## tests/desktop_persist_test.nim runs two "windows" in one process, since two
## open file descriptions conflict under both flock and LockFileEx.

import std/[os, strformat, strutils]
import persist

when defined(windows):
  import std/winlean

  proc lock_file_ex(h: Handle; flags, reserved, len_low, len_high: DWORD;
                    ov: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "LockFileEx".}

  const
    LOCKFILE_FAIL_IMMEDIATELY = 1'i32
    LOCKFILE_EXCLUSIVE_LOCK   = 2'i32
else:
  import std/posix

  var LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  var LOCK_NB {.importc, header: "<sys/file.h>".}: cint
  proc c_flock(fd, op: cint): cint {.importc: "flock", header: "<sys/file.h>".}

type
  FileLock* = object
    ## One lock. `key` names what it covers ("" = nothing); `held` is false
    ## for a claim that reuses the window's own lock (a Reset) or that went
    ## ahead without one (the lock file could not be made).
    key*: string
    held*: bool
    when defined(windows):
      h: Handle
    else:
      fd: cint

  LockResult* = enum
    lrTaken    ## this window has it now
    lrBusy     ## another process has it
    lrNoLock   ## the lock file could not be made or opened: go ahead unlocked

  GameLock* = object
    ## What a window holds for its running game, or what `load_rom` has
    ## claimed for the game it is loading.
    files*:  FileLock   ## `.sav` and `.cht`
    states*: FileLock   ## the save-state slots

  Refusal* = enum
    rfNone, rfFiles, rfStates

proc fnv1a64(s: string): uint64 =
  ## A lock file's name: stable across builds (two versions of dingbat may run
  ## at once), unlike `hashes.hash`.
  result = 0xcbf29ce484222325'u64
  for c in s:
    result = (result xor uint64(ord(c))) * 0x100000001b3'u64

proc fold(key: string): string =
  ## macOS and Windows file systems ignore case by default: `Pokemon.gba`
  ## and `pokemon.gba` are one file there, and one `.sav`.
  when defined(windows) or defined(macosx): key.toLowerAscii() else: key

proc canonical_dir(path: string): string =
  let dir = path.absolutePath().parentDir()
  try: expandFilename(dir)
  except OSError: dir

proc files_key*(rom_path: string): string =
  ## What `<rom>.sav` and `<rom>.cht` are named from: the folder, symlinks
  ## resolved, and the file name minus its extension. Two spellings of one
  ## path share it; so do `Tetris.gb` and `Tetris.gbc` beside each other,
  ## which share `Tetris.sav`.
  fold(canonical_dir(rom_path) / rom_path.extractFilename().changeFileExt(""))

proc states_key*(rom_path: string; identity: uint32): string =
  ## What the save-state slots are named from (persist.nim `state_file_name`):
  ## every slot of a game under that file name, in whatever folder.
  fold(state_file_name(rom_path, identity, 0))

proc lock_path*(lock_dir, kind, key: string): string =
  lock_dir / &"{kind}-{fnv1a64(key).toHex(16).toLowerAscii()}.lock"

proc release*(l: var FileLock) =
  ## Closing the handle drops the lock. The file stays: removing it could let
  ## a process that opened it just before lock a file no longer in the folder
  ## while a third locks a new one under the same name.
  if l.held:
    when defined(windows):
      discard closeHandle(l.h)
    else:
      discard posix.close(l.fd)
  l = FileLock()

proc try_lock*(path, key: string; l: var FileLock): LockResult =
  ## Takes the lock in the file at `path` for `key`, without waiting.
  l = FileLock(key: key)
  try:
    createDir(path.parentDir())
  except OSError, IOError:
    return lrNoLock
  when defined(windows):
    # Not inheritable (no security attributes): a child process never keeps
    # the lock alive after dingbat ends.
    let h = createFileW(newWideCString(path), GENERIC_READ or GENERIC_WRITE,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                        nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, Handle(0))
    if h == INVALID_HANDLE_VALUE: return lrNoLock
    var ov: OVERLAPPED
    if lock_file_ex(h, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0,
                    1, 0, addr ov) == 0:
      let err = getLastError()
      discard closeHandle(h)
      return (if err == ERROR_LOCK_VIOLATION: lrBusy else: lrNoLock)
    l.h = h
  else:
    # O_CLOEXEC: a child process never keeps the lock alive after dingbat ends.
    let fd = posix.open(cstring(path), O_RDWR or O_CREAT or O_CLOEXEC, 0o644)
    if fd < 0: return lrNoLock
    if c_flock(fd, LOCK_EX or LOCK_NB) != 0:
      let err = errno
      discard posix.close(fd)
      return (if err == EWOULDBLOCK or err == EAGAIN: lrBusy else: lrNoLock)
    l.fd = fd
  l.held = true
  lrTaken

proc claim(held: FileLock; lock_dir, kind, key: string; c: var FileLock): bool =
  ## The window's own lock is reused (a Reset, or the same file under another
  ## spelling); otherwise take it. False only when another window has it.
  if held.key.len > 0 and held.key == key:
    c = FileLock(key: key)
    return true
  let r = try_lock(lock_path(lock_dir, kind, key), key, c)
  if r == lrNoLock:
    echo "Couldn't lock ", kind, " for ", key, "; opening it anyway"
  r != lrBusy

proc claim_files*(held: GameLock; lock_dir, rom_path: string;
                  c: var GameLock): bool =
  ## Before the new core reads `<rom>.sav`: false when another window has
  ## this game's battery and cheat files.
  claim(held.files, lock_dir, "files", files_key(rom_path), c.files)

proc claim_states*(held: GameLock; lock_dir, rom_path: string;
                   identity: uint32; c: var GameLock): bool =
  ## Once the new core has said what cart it is: false when another window
  ## has a copy of this game under the same file name.
  claim(held.states, lock_dir, "states", states_key(rom_path, identity), c.states)

proc abandon*(c: var GameLock) =
  ## The load was refused or failed: let go of what it took (never the
  ## window's own locks, which a claim only reuses).
  c.files.release()
  c.states.release()

proc commit_one(held, c: var FileLock) =
  if not c.held and c.key.len > 0 and c.key == held.key:
    c = FileLock()        # reused: the window keeps its own
  else:
    held.release()
    held = c
    c = FileLock()

proc commit*(held: var GameLock; c: var GameLock) =
  ## The new game is running: its locks replace the old game's, and the old
  ## game's are released only now.
  commit_one(held.files, c.files)
  commit_one(held.states, c.states)

# What the Link Cable window and a refused load say about pairing two
# windows on one computer.
const LINK_SAME_MACHINE_HINT* =
  "To link two windows on this computer, open a different game in each " &
  "(Ruby and Sapphire, say) or a copy of the ROM file under another name."

proc refusal_notice*(why: Refusal; name, rom_name: string): (string, string) =
  ## The load notice for a refused game (the text, the hint below it).
  case why
  of rfNone: ("", "")
  of rfFiles:
    (&"{name} is already open in another dingbat window.",
     &"Both windows would write {rom_name.changeFileExt(\".sav\")}, each " &
     "over the other's progress. " & LINK_SAME_MACHINE_HINT)
  of rfStates:
    (&"A copy of {name} is already open in another dingbat window.",
     &"Both copies are called {rom_name}, so they would share save states. " &
     "Rename this copy, or link with a different game in each window " &
     "(Ruby and Sapphire, say).")
