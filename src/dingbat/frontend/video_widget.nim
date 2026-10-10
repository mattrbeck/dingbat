import imguin/[cimgui, impl_opengl]
import ../common/config
import util

type
  VideoWidget* = ref object
    cfg*:         Config
    filter*:      cint   # VideoFilter ordinal (smoothing + screen looks)
    lcd_resp*:    bool   # panel-response model on/off (panel resolved from the machine)
    preserve_aspect*: bool
    sgb_enable*:  bool
    sgb_border*:  bool
    nds_hd*:      cint   # DS 3D resolution, 1..4 (shown only with DS Beta on)
    show_ds*:     bool
    visible*:     bool

proc new_video_widget*(cfg: Config): VideoWidget =
  VideoWidget(cfg: cfg)

proc render*(v: VideoWidget) =
  igText("Filter:")
  igSameLine(0, -1)
  help_marker("One look for the picture, GPU-drawn either way. hq4x and xBR " &
              "are clean-room implementations of the well-known " &
              "edge-directed smoothers; LCD grid and RGB subpixels draw the " &
              "screen's own structure instead of smoothing (the grid is the " &
              "pixel matrix every Game Boy LCD shows; RGB subpixels imitates " &
              "the GBC/GBA TFT's stripe triads — a DMG panel has no " &
              "subpixels, so there it is a stylised look). None keeps crisp " &
              "nearest-neighbor pixels. Color correction still applies on top.")
  igIndent(106)
  discard igRadioButton_IntPtr("None (crisp)", addr v.filter, 0)
  discard igRadioButton_IntPtr("hq4x", addr v.filter, 1)
  discard igRadioButton_IntPtr("xBR", addr v.filter, 2)
  discard igRadioButton_IntPtr("LCD grid", addr v.filter, 3)
  discard igRadioButton_IntPtr("RGB subpixels", addr v.filter, 4)
  igUnindent(106)
  igSeparator()
  discard igCheckbox("Preserve aspect ratio", addr v.preserve_aspect)
  igSameLine(0, -1)
  help_marker("Letterbox the picture instead of stretching it to fill the " &
              "window. Only visible when the window is not an exact multiple " &
              "of the console's resolution — fullscreen, or after a manual resize.")
  discard igCheckbox("LCD response", addr v.lcd_resp)
  igSameLine(0, -1)
  help_marker("Emulate how slowly the real screen's pixels settle: quick to " &
              "darken, slow to fade back to light, which is why a moving dark " &
              "object on hardware has a crisp leading edge and a trail behind " &
              "it. Games that flicker a sprite every other frame to fake " &
              "transparency were counting on this — without it they strobe. " &
              "The response follows whichever console the game runs on, and " &
              "stays out of the way under Super Game Boy, where the picture " &
              "leaves through a television and never meets an LCD.")
  igSeparator()
  igText("Super Game Boy:")
  igSameLine(0, -1)
  help_marker("Run monochrome carts whose header unlocks SGB functions on the " &
              "Super Game Boy adapter: per-region colour palettes and, where " &
              "the cart ships one, a 256x224 border. Carts without the SGB " &
              "header bits are unaffected, and a Game Boy Color cart always " &
              "runs as a Game Boy Color even if it is also SGB-enhanced. " &
              "Off by default — stock Game Boy behaviour until you ask for it.")
  igIndent(106)
  discard igCheckbox("Super Game Boy mode", addr v.sgb_enable)
  # Kept visible: the adapter is chosen at cartridge insertion, so ticking
  # this changes nothing about the running game.
  igTextDisabled("Applies on the next ROM load or reset.")
  igBeginDisabled(not v.sgb_enable)
  discard igCheckbox("Show SGB border", addr v.sgb_border)
  igEndDisabled()
  igSameLine(0, -1)
  help_marker("The border makes the picture 256x224 instead of 160x144, so " &
              "the window resizes when one appears. This one takes effect " &
              "immediately — it only hides a layer the core already has." &
              (if not v.sgb_enable: " (Super Game Boy mode is off.)" else: ""))
  igUnindent(106)
  if v.show_ds:
    igSeparator()
    igText("Nintendo DS:")
    igIndent(106)
    igText("3D resolution:")
    igSameLine(0, -1)
    help_marker("Draws the 3D scenes at a higher resolution: sharper edges " &
                "and models, the same textures. 2D stays as it is. Each step " &
                "costs a lot more work a frame, so a slower computer may not " &
                "keep full speed.")
    for (label, k) in [("Native", 1'i32), ("2x", 2'i32), ("3x", 3'i32), ("4x", 4'i32)]:
      if k > 1: igSameLine(0, -1)
      discard igRadioButton_IntPtr(cstring(label & "##nds_hd"), addr v.nds_hd, k)
    igUnindent(106)

proc reset*(v: VideoWidget) =
  v.filter      = cint(ord(v.cfg.video_filter))
  v.lcd_resp    = v.cfg.lcd_response
  v.preserve_aspect = v.cfg.preserve_aspect
  v.sgb_enable  = v.cfg.sgb_enable
  v.sgb_border  = v.cfg.sgb_border
  v.nds_hd      = cint(v.cfg.nds_hd)

proc apply_to*(v: VideoWidget; cfg: Config) =
  cfg.video_filter = VideoFilter(v.filter)
  cfg.lcd_response = v.lcd_resp
  cfg.preserve_aspect = v.preserve_aspect
  cfg.sgb_enable  = v.sgb_enable
  cfg.sgb_border  = v.sgb_border
  cfg.nds_hd      = int(v.nds_hd)

proc apply*(v: VideoWidget) = v.apply_to(v.cfg)
