## Settings > General as edited, until Apply. Only an Advanced section for
## now, folded on every open as the web's is, holding DS Beta (rows:
## config_editor.nim).

import ../common/config

type
  GeneralWidget* = ref object
    cfg*:     Config
    ds_beta*: bool
    visible*: bool

proc new_general_widget*(cfg: Config): GeneralWidget =
  GeneralWidget(cfg: cfg)

proc reset*(g: GeneralWidget) =
  g.ds_beta = g.cfg.ds_beta

proc apply_to*(g: GeneralWidget; cfg: Config) =
  cfg.ds_beta = g.ds_beta

proc apply*(g: GeneralWidget) = g.apply_to(g.cfg)
