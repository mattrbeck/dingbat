## Settings > Video as edited, until Apply (rows: config_editor.nim).

import ../common/config

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
