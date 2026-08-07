import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/config
import util

type
  VideoWidget* = ref object
    cfg*:         Config
    gb_renderer*: cint   # 0 = FIFO, 1 = scanline
    filter*:      cint   # 0 = None, 1 = hq4x, 2 = xBR (VideoFilter ordinal)
    scanlines*:   bool
    frame_blend*: bool
    preserve_aspect*: bool
    sgb_enable*:  bool
    sgb_border*:  bool
    visible*:     bool

proc new_video_widget*(cfg: Config): VideoWidget =
  VideoWidget(cfg: cfg)

proc render*(v: VideoWidget) =
  igText("GB / GBC renderer:")
  igSameLine(0, -1)
  help_marker("The FIFO renderer emulates the pixel pipeline cycle by cycle. " &
              "The scanline renderer draws whole lines at once, which is faster " &
              "but less accurate. Takes effect on the next ROM load or reset.")
  igIndent(106)
  discard igRadioButton_IntPtr("FIFO (cycle accurate)", addr v.gb_renderer, 0)
  discard igRadioButton_IntPtr("Scanline (fast)", addr v.gb_renderer, 1)
  igUnindent(106)
  igSeparator()
  igText("Upscale filter:")
  igSameLine(0, -1)
  help_marker("GPU pixel-art smoothing. hq4x and xBR are clean-room " &
              "implementations of the well-known edge-directed upscalers. " &
              "None keeps crisp nearest-neighbor pixels. Color correction " &
              "still applies on top; scanlines are suspended while a filter " &
              "is active.")
  igIndent(106)
  discard igRadioButton_IntPtr("None (crisp)", addr v.filter, 0)
  discard igRadioButton_IntPtr("hq4x", addr v.filter, 1)
  discard igRadioButton_IntPtr("xBR", addr v.filter, 2)
  igUnindent(106)
  igSeparator()
  # Grayed while a filter is active — same as the web settings modal. The
  # checkbox keeps its state for when the filter turns off.
  igBeginDisabled(v.filter != 0)
  discard igCheckbox("Scanlines", addr v.scanlines)
  igEndDisabled()
  igSameLine(0, -1)
  help_marker("Darken a strip across each emulated pixel row" &
              (if v.filter != 0: " (suspended by the upscale filter)" else: ""))
  discard igCheckbox("Interframe blending", addr v.frame_blend)
  igSameLine(0, -1)
  help_marker("Blend the previous frame into the current one, like the LCD's ghosting")
  discard igCheckbox("Preserve aspect ratio", addr v.preserve_aspect)
  igSameLine(0, -1)
  help_marker("Letterbox the picture instead of stretching it to fill the " &
              "window. Only visible when the window is not an exact multiple " &
              "of the console's resolution — fullscreen, or after a manual resize.")
  igSeparator()
  igText("Super Game Boy:")
  igSameLine(0, -1)
  help_marker("Run monochrome carts whose header unlocks SGB functions on the " &
              "Super Game Boy adapter: per-region colour palettes and, where " &
              "the cart ships one, a 256x224 border. Carts without the SGB " &
              "header bits are unaffected, and a Game Boy Color cart always " &
              "runs as a Game Boy Color even if it is also SGB-enhanced. " &
              "Takes effect on the next ROM load or reset.")
  igIndent(106)
  discard igCheckbox("Super Game Boy mode", addr v.sgb_enable)
  igBeginDisabled(not v.sgb_enable)
  discard igCheckbox("Show SGB border", addr v.sgb_border)
  igEndDisabled()
  igSameLine(0, -1)
  help_marker("The border makes the picture 256x224 instead of 160x144, so " &
              "the window resizes when one appears." &
              (if not v.sgb_enable: " (Super Game Boy mode is off.)" else: ""))
  igUnindent(106)

proc reset*(v: VideoWidget) =
  v.gb_renderer = if v.cfg.gb_fifo: 0'i32 else: 1'i32
  v.filter      = cint(ord(v.cfg.video_filter))
  v.scanlines   = v.cfg.scanlines
  v.frame_blend = v.cfg.frame_blend
  v.preserve_aspect = v.cfg.preserve_aspect
  v.sgb_enable  = v.cfg.sgb_enable
  v.sgb_border  = v.cfg.sgb_border

proc apply*(v: VideoWidget) =
  v.cfg.gb_fifo     = v.gb_renderer == 0
  v.cfg.video_filter = VideoFilter(v.filter)
  v.cfg.scanlines   = v.scanlines
  v.cfg.frame_blend = v.frame_blend
  v.cfg.preserve_aspect = v.preserve_aspect
  v.cfg.sgb_enable  = v.sgb_enable
  v.cfg.sgb_border  = v.sgb_border
