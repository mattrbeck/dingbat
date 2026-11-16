## Settings > BIOS as edited, until Apply (rows: config_editor.nim).

import std/os
import ../common/config

type
  BiosSelection* = ref object
    cfg*:       Config
    path*:      string  # the GBA BIOS file, as typed or browsed
    run_bios*:  bool
    bios_mode*: cint    # 0 = HLE, 1 = real BIOS, 2 = real BIOS init + HLE SWIs
    visible*:   bool
    overrides*: string  # command-line BIOS options in force this run (describe())
    # The DS's dumps, shown only with DS Beta on: ARM9 BIOS, ARM7 BIOS, firmware
    show_ds*:   bool
    ds_paths*:  array[3, string]

proc new_bios_selection*(cfg: Config): BiosSelection =
  BiosSelection(cfg: cfg)

proc path_valid*(path: string): bool =
  ## Empty (none chosen) or a file that is there
  path.len == 0 or fileExists(path)

proc reset*(b: BiosSelection) =
  b.path      = b.cfg.bios_path
  b.run_bios  = b.cfg.run_bios
  b.bios_mode = if b.cfg.hle_after_bios: 2'i32
                elif b.cfg.use_hle: 0'i32
                else: 1'i32
  b.ds_paths  = [b.cfg.nds_bios9_path, b.cfg.nds_bios7_path,
                 b.cfg.nds_firmware_path]

proc apply_to*(b: BiosSelection; cfg: Config) =
  cfg.bios_path      = b.path
  cfg.run_bios       = b.run_bios
  cfg.use_hle        = b.bios_mode == 0
  cfg.hle_after_bios = b.bios_mode == 2
  cfg.nds_bios9_path    = b.ds_paths[0]
  cfg.nds_bios7_path    = b.ds_paths[1]
  cfg.nds_firmware_path = b.ds_paths[2]

proc apply*(b: BiosSelection) = b.apply_to(b.cfg)
