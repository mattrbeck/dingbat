## Settings > General as edited, until Apply: how a game opens from the
## library, and an Advanced section, folded on every open as the web's is,
## holding DS Beta (rows: config_editor.nim).

import ../common/config

type
  GeneralWidget* = ref object
    cfg*:     Config
    library_resume*: bool
    ds_beta*: bool
    visible*: bool

proc new_general_widget*(cfg: Config): GeneralWidget =
  GeneralWidget(cfg: cfg)

proc reset*(g: GeneralWidget) =
  g.library_resume = g.cfg.library_resume
  g.ds_beta = g.cfg.ds_beta

proc apply_to*(g: GeneralWidget; cfg: Config) =
  cfg.library_resume = g.library_resume
  cfg.ds_beta = g.ds_beta

proc apply*(g: GeneralWidget) = g.apply_to(g.cfg)
