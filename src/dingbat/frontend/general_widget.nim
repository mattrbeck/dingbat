## Settings > General. Only an Advanced section for now, folded on every
## open as the web's is, holding DS Beta.

import imguin/cimgui
import ../common/config
import util

type
  GeneralWidget* = ref object
    cfg*:     Config
    ds_beta*: bool
    visible*: bool

proc new_general_widget*(cfg: Config): GeneralWidget =
  GeneralWidget(cfg: cfg)

proc render*(g: GeneralWidget) =
  if igCollapsingHeader_TreeNodeFlags("Advanced", 0):
    discard igCheckbox("DS Beta", addr g.ds_beta)
    igSameLine(0, -1)
    help_marker("Lets DS games load. An early, incomplete Nintendo DS core.")
    igTextDisabled("Takes effect on the next game opened.")

proc reset*(g: GeneralWidget) =
  g.ds_beta = g.cfg.ds_beta

proc apply_to*(g: GeneralWidget; cfg: Config) =
  cfg.ds_beta = g.ds_beta

proc apply*(g: GeneralWidget) = g.apply_to(g.cfg)
