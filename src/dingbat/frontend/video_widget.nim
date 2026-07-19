import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/config
import util

type
  VideoWidget* = ref object
    cfg*:         Config
    gb_renderer*: cint   # 0 = FIFO, 1 = scanline
    gb_rumble*:   bool
    filter*:      cint   # 0 = None, 1 = hq4x, 2 = xBR (VideoFilter ordinal)
    scanlines*:   bool
    frame_blend*: bool
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
  discard igCheckbox("Rumble", addr v.gb_rumble)
  igSameLine(0, -1)
  help_marker("Vibrate the controller and shake the screen while a rumble " &
              "cartridge's motor runs (MBC5 rumble carts)")
  igSeparator()
  igText("Upscale filter:")
  igSameLine(0, -1)
  help_marker("GPU pixel-art smoothing. hq4x and xBR are clean-room " &
              "implementations of the well-known edge-directed upscalers. " &
              "None keeps crisp nearest-neighbor pixels. Color correction and " &
              "scanlines still apply on top.")
  igIndent(106)
  discard igRadioButton_IntPtr("None (crisp)", addr v.filter, 0)
  discard igRadioButton_IntPtr("hq4x", addr v.filter, 1)
  discard igRadioButton_IntPtr("xBR", addr v.filter, 2)
  igUnindent(106)
  igSeparator()
  discard igCheckbox("Scanlines", addr v.scanlines)
  igSameLine(0, -1)
  help_marker("Darken a strip across each emulated pixel row")
  discard igCheckbox("Interframe blending", addr v.frame_blend)
  igSameLine(0, -1)
  help_marker("Blend the previous frame into the current one, like the LCD's ghosting")

proc reset*(v: VideoWidget) =
  v.gb_renderer = if v.cfg.gb_fifo: 0'i32 else: 1'i32
  v.gb_rumble   = v.cfg.gb_rumble
  v.filter      = cint(ord(v.cfg.video_filter))
  v.scanlines   = v.cfg.scanlines
  v.frame_blend = v.cfg.frame_blend

proc apply*(v: VideoWidget) =
  v.cfg.gb_fifo     = v.gb_renderer == 0
  v.cfg.gb_rumble   = v.gb_rumble
  v.cfg.video_filter = VideoFilter(v.filter)
  v.cfg.scanlines   = v.scanlines
  v.cfg.frame_blend = v.frame_blend
