## Whole-file replacement that never leaves a half-written file behind.
##
## `writeFile` truncates the destination and then writes: a crash, a power
## loss or a full disk part-way through leaves a short file where the last
## good one was (a `.sav` that loads as valid but blank past the cut, a Quick
## Save slot with nothing in it). This writes a sibling temp file, flushes it,
## and renames it over the destination, which on every platform dingbat runs
## on replaces the name in one step: a reader sees the old file or the new
## one, never a mix. On failure the old file is untouched and the temp is
## removed before the error propagates.

import std/os
when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean
  proc flush_file_buffers(h: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "FlushFileBuffers".}

proc write_file_atomic*(path: string; data: string; sync = true) =
  ## Replaces `path` with `data`. `sync` pushes the bytes to the disk before
  ## the rename, so a power loss cannot leave the new name pointing at data
  ## that never landed; pass false for writes frequent enough that a lost
  ## last copy is acceptable but a torn one is not.
  let tmp = path & ".tmp" & $getCurrentProcessId()
  var f: File
  # Unbuffered: the whole buffer goes out in writeBuffer, which reports a
  # short write. Buffered, the tail would leave in flushFile, which ignores
  # fflush's error, and a disk that fills there renamed a short file over
  # the good one (tests/desktop_persist_test.nim cuts writes 16 bytes short).
  if not open(f, tmp, fmWrite, bufSize = 0):
    raise newException(IOError, "cannot open file for writing: " & tmp)
  try:
    try:
      if data.len > 0:
        if f.writeBuffer(unsafeAddr data[0], data.len) != data.len:
          raise newException(IOError, "short write: " & tmp)
      f.flushFile()
      when not defined(emscripten):
        if sync:
          when defined(posix):
            if fsync(f.getOsFileHandle()) != 0:
              raiseOSError(osLastError(), tmp)
          elif defined(windows):
            if flush_file_buffers(f.getOsFileHandle()) == 0:
              raiseOSError(osLastError(), tmp)
    finally:
      f.close()
    moveFile(tmp, path)
  except CatchableError:
    discard tryRemoveFile(tmp)
    raise
