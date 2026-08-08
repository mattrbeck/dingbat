import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/config
import ../common/lcd_response
import util

type
  VideoWidget* = ref object
    cfg*:         Config
    gb_renderer*: cint   # 0 = FIFO, 1 = scanline
    filter*:      cint   # 0 = None, 1 = hq4x, 2 = xBR (VideoFilter ordinal)
    scanlines*:   bool
    lcd_resp*:    cint   # LcdMode ordinal
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
  igSeparator()
  igText("LCD response:")
  igSameLine(0, -1)
  help_marker("Emulate how slowly the real screen's pixels settle. Every Game " &
              "Boy panel is a normally-white liquid-crystal cell: driving it " &
              "dark is quick, letting it relax back to light is slow, which is " &
              "why a moving dark object on hardware has a crisp leading edge " &
              "and a trail behind it. Games that flicker a sprite every other " &
              "frame to fake transparency were counting on this — without it " &
              "they strobe. Auto picks the panel the running machine shipped " &
              "with; the rest force one (AGB-001 is the unlit GBA, AGS-101 the " &
              "backlit SP, which barely ghosts at all).")
  igIndent(106)
  discard igRadioButton_IntPtr("Off", addr v.lcd_resp, cint(ord(lmOff)))
  discard igRadioButton_IntPtr("Auto (match the machine)", addr v.lcd_resp, cint(ord(lmAuto)))
  discard igRadioButton_IntPtr("DMG", addr v.lcd_resp, cint(ord(lmDmg)))
  discard igRadioButton_IntPtr("Game Boy Color", addr v.lcd_resp, cint(ord(lmCgb)))
  discard igRadioButton_IntPtr("GBA (AGB-001)", addr v.lcd_resp, cint(ord(lmAgb)))
  discard igRadioButton_IntPtr("GBA SP (AGS-101)", addr v.lcd_resp, cint(ord(lmAgs)))
  igUnindent(106)

proc reset*(v: VideoWidget) =
  v.gb_renderer = if v.cfg.gb_fifo: 0'i32 else: 1'i32
  v.filter      = cint(ord(v.cfg.video_filter))
  v.scanlines   = v.cfg.scanlines
  v.lcd_resp    = cint(ord(v.cfg.lcd_response))

proc apply*(v: VideoWidget) =
  v.cfg.gb_fifo     = v.gb_renderer == 0
  v.cfg.video_filter = VideoFilter(v.filter)
  v.cfg.scanlines   = v.scanlines
  v.cfg.lcd_response = LcdMode(v.lcd_resp)
