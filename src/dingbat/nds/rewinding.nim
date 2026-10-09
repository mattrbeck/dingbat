## The DS core's rewind ring (common/rewind.nim) as the web and iOS front
## ends keep it: an aligned payload (savestate.nim "Rewind's aligned
## payloads") every REWIND_INTERVAL frames, a thumbnail of both screens
## once a second for the scrubber and Report a Bug's timeline, and no
## keyframes: each would be a ~2 MB zlib of the whole payload, a visible
## stall every few seconds, so a seek inflates its way back from the newest
## snapshot instead (docs/nds/savestate.md "Rewind").

import ../common/[rewind, serialize]
import nds, savestate

const
  NDS_RW_THUMB_W* = 80    ## both screens, top above bottom: 2:3, the
  NDS_RW_THUMB_H* = 120   ## pixel count of the GBA's 120x80 strip frames

proc nds_rewind_thumb*(n: NDS): RewindThumb =
  var both = newSeq[uint16](256 * 384)
  copyMem(addr both[0], unsafeAddr n.gpu.top[0], 256 * 192 * 2)
  copyMem(addr both[256 * 192], unsafeAddr n.gpu.bottom[0], 256 * 192 * 2)
  RewindThumb(w: NDS_RW_THUMB_W, h: NDS_RW_THUMB_H,
              pixels: downscale_bgr555(both, 256, 384, NDS_RW_THUMB_W, NDS_RW_THUMB_H))

proc new_nds_rewind*(cap: int): Rewind =
  new_rewind(cap, key_every = 0)

proc nds_rewind_tick*(rw: Rewind; n: NDS) =
  ## Once per emulated frame (a powered-off DS is not recorded: there is
  ## nothing to come back to).
  if rw == nil or n.powered_off(): return
  discard rw.maybe_push(proc(): string = n.state_payload(aligned = true),
                        proc(): RewindThumb = n.nds_rewind_thumb())

proc nds_save_chip*(n: NDS): seq[byte] =
  ## What reaches the game's battery file: the cart's save chip. A scrubber
  ## commit that would change it asks first, as for GB/GBA.
  n.cart.backup.data
