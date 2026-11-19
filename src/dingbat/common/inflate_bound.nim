# Inflating a zlib stream to no more than a given size. zippy's uncompress
# grows its output to whatever the stream asks for, and a deflate stream can
# ask for about 1032 times its own size; a state from a link peer or an
# imported file is such a stream.
#
# The decoding is zlib's own (vendor/zlib, the inflate half of 1.3.2,
# unmodified): it writes into the buffer it is handed and no further, so
# the limit is this file's loop and nothing in the decoder.

const
  ZDIR = "../vendor/zlib/"
  ZFLAGS = "-DZ_SOLO -DZ_PREFIX -DNO_GZIP"

{.compile(ZDIR & "inflate.c", ZFLAGS).}
{.compile(ZDIR & "inftrees.c", ZFLAGS).}
{.compile(ZDIR & "inffast.c", ZFLAGS).}
{.compile(ZDIR & "adler32.c", ZFLAGS).}
{.compile(ZDIR & "zutil.c", ZFLAGS).}
{.compile("inflate_zlib.c", ZFLAGS).}

type
  InflateError* = object of CatchableError
    too_big*: bool   ## well formed as far as it was read, but past the limit

proc dingbat_inflate_open(src: pointer; len: cuint; raw: cint): pointer {.importc, cdecl.}
proc dingbat_inflate_run(s, dst: pointer; cap: cuint; made, left: var cuint): cint {.importc, cdecl.}
proc dingbat_inflate_close(s: pointer) {.importc, cdecl.}

proc fail(msg: string; too_big = false) {.noreturn, noinline.} =
  var e = newException(InflateError, msg)
  e.too_big = too_big
  raise e

proc inflate_capped(src: pointer; len, limit, hint: int; raw: bool): string =
  # zlib counts in 32 bits; nothing here is asked for that much.
  if len < 1: fail("the stream is too short")
  if len > int32.high or limit < 0 or limit > int32.high: fail("too large to inflate")
  let s = dingbat_inflate_open(src, cuint(len), cint(ord(raw)))
  if s == nil: fail("no memory to inflate with")
  defer: dingbat_inflate_close(s)
  # `hint` is the size expected, from whoever wrote the stream: where the
  # buffer starts, held to what a stream this long could plausibly need.
  var dst = newString(max(0, min(limit, min(len * 16 + 4096,
                                            if hint > 0: hint else: len * 4))))
  var op = 0
  var made, left: cuint
  while true:
    if op == dst.len:
      if dst.len < limit:
        dst.setLen(min(limit, max(dst.len * 2, 4096)))
      else:
        # At the limit: the stream may end here, or have one byte more.
        var spare: uint8
        case dingbat_inflate_run(s, addr spare, 1, made, left)
        of 1:
          if made == 0: break
          fail("the stream inflates past " & $limit & " bytes", too_big = true)
        of 0: fail("the stream inflates past " & $limit & " bytes", too_big = true)
        else: fail("the stream is damaged")
    case dingbat_inflate_run(s, addr dst[op], cuint(dst.len - op), made, left)
    of 1:
      op += int(made)
      break
    of 0: op += int(made)
    else: fail("the stream is damaged")
  # A zlib stream is the whole of what it was given as; a zip entry's
  # deflate stream is read as far as its end.
  if not raw and left != 0: fail("bytes after the end of the stream")
  dst.setLen(op)
  dst

proc zlib_inflate_capped*(src: pointer; len: int; limit: int; hint = 0): string =
  ## The zlib stream at `src`, inflated and checked against its Adler-32.
  ## Raises InflateError for a stream that is not well formed, and (too_big
  ## set) when the output would pass `limit`.
  inflate_capped(src, len, limit, hint, raw = false)

proc deflate_inflate_capped*(src: pointer; len: int; limit: int; hint = 0): string =
  ## The same for a bare deflate stream (a zip entry's), which carries no
  ## header and no checksum of its own.
  inflate_capped(src, len, limit, hint, raw = true)
