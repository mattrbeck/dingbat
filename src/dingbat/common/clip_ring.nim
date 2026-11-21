## The clip ring's anchors and how they age, shared by the iOS and web cores
## (their clip_* procs): a state a second for the newest minute, then one
## every 5 s further back, so a longer window costs about a fifth as much
## per second past the first minute. A replay pre-rolls silently from the
## anchor at or before its start, at most 5 s past the first minute.

type ClipAnchor* = object
  frame*: int          ## canonical frame index this state is the start of
  packed*: string      ## zlib'd state payload
  thumb*: seq[byte]    ## zlib'd BGR555 thumbnail (may be empty)
  tw*, th*: int

const
  ClipSnapInterval* = 60         ## anchor + thumbnail cadence (frames)
  ClipRecentFrames* = 60 * 60    ## the newest minute keeps every anchor
  ClipThinEvery* = 5 * 60        ## older anchors kept on this grid
  ClipDefaultWindow* = 60 * 60   ## frames a clip may reach back, unless set

proc anchorSize*(a: ClipAnchor): int = a.packed.len + a.thumb.len

proc trimAnchors*(anchors: var seq[ClipAnchor]; bytes: var int;
                  now, window, cap: int) =
  ## Drop what the window or the byte budget no longer holds, oldest first,
  ## and thin anchors older than a minute to the 5 s grid. The oldest anchor
  ## stays until the window passes it (it is where the window starts).
  let oldest = now - window
  while anchors.len > 1 and anchors[1].frame <= oldest:
    bytes -= anchorSize(anchors[0])
    anchors.delete(0)
  if window > ClipRecentFrames:
    let recent = now - ClipRecentFrames
    var i = 1
    while i < anchors.len and anchors[i].frame < recent:
      if anchors[i].frame mod ClipThinEvery != 0:
        bytes -= anchorSize(anchors[i])
        anchors.delete(i)
      else:
        inc i
  while anchors.len > 1 and bytes > cap:
    bytes -= anchorSize(anchors[0])
    anchors.delete(0)
