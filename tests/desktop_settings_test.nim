## Unit tests for the desktop app's settings file (src/dingbat/common/config.nim).
## Whatever the Settings window can store must come back from the file
## unchanged: a keypad key or a non-US letter bound to an input used to be
## written as a blank key and dropped on the next start, leaving that input
## with no key at all.

import std/[os, tables, tempfiles]
import dingbat/common/[config, input]

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

let dir = createTempDir("dingbat_settings_", "")

const KP_8    = cint(0x40000060)  # SDLK_KP_8: no config-file name
const E_ACUTE = cint(233)         # a French keyboard's e-acute key

proc same_settings(a, b: Config): bool =
  ## Every field the file carries.
  a.explorer_dir == b.explorer_dir and a.keybindings == b.keybindings and
    a.controller_bindings == b.controller_bindings and a.recents == b.recents and
    a.run_bios == b.run_bios and a.bios_path == b.bios_path and
    a.gb_bootrom_path == b.gb_bootrom_path and a.gb_fifo == b.gb_fifo and
    a.gb_rumble == b.gb_rumble and a.use_hle == b.use_hle and
    a.hle_after_bios == b.hle_after_bios and a.volume == b.volume and
    a.mute == b.mute and a.color_correction == b.color_correction and
    a.video_filter == b.video_filter and a.lcd_response == b.lcd_response and
    a.preserve_aspect == b.preserve_aspect and a.sgb_enable == b.sgb_enable and
    a.sgb_border == b.sgb_border and a.rewind == b.rewind and
    a.pitch_correct_ff == b.pitch_correct_ff and a.audio_lowpass == b.audio_lowpass and
    a.fifo_interp == b.fifo_interp and a.mp2k_hle == b.mp2k_hle and
    a.speed_mode == b.speed_mode

echo "Key bindings survive a restart"
block:
  let path = dir / "roundtrip.yml"
  let cfg = new_config()
  # The widget unbinds the key an input had when it takes a new one
  cfg.keybindings = initTable[cint, Input]()
  for k, v in default_keybindings().pairs:
    if v notin {Input.UP, Input.A}: cfg.keybindings[k] = v
  cfg.keybindings[KP_8] = Input.UP
  cfg.keybindings[E_ACUTE] = Input.A
  save_config_file(cfg, path)
  let back = load_config_file(path)
  check back.keybindings.getOrDefault(KP_8, Input.R) == Input.UP, "keypad 8 still bound to UP"
  check back.keybindings.getOrDefault(E_ACUTE, Input.R) == Input.A, "e-acute still bound to A"
  check back.keybindings == cfg.keybindings, "every binding comes back"

echo "Every stored setting round-trips"
block:
  let path = dir / "fields.yml"
  let cfg = new_config()
  cfg.explorer_dir = dir / "roms: \"odd\" #name"
  cfg.recents = @[dir / "a b.gba", dir / "c-d.gb"]
  cfg.run_bios = true
  cfg.bios_path = dir / "gba_bios.bin"
  cfg.gb_bootrom_path = dir / "cgb_boot.bin"
  cfg.gb_fifo = false
  cfg.gb_rumble = false
  cfg.use_hle = false
  cfg.hle_after_bios = true
  cfg.volume = 37
  cfg.mute = true
  cfg.color_correction = false
  cfg.video_filter = vfXbr
  cfg.lcd_response = true
  cfg.preserve_aspect = false
  cfg.sgb_enable = true
  cfg.sgb_border = false
  cfg.rewind = false
  cfg.pitch_correct_ff = true
  cfg.audio_lowpass = true
  cfg.fifo_interp = false
  cfg.mp2k_hle = true
  cfg.speed_mode = true
  cfg.keybindings = homerow_keybindings()
  cfg.keybindings[KP_8] = Input.SELECT
  cfg.controller_bindings = {cint(0): Input.B, cint(1): Input.A}.toTable
  save_config_file(cfg, path)
  check same_settings(load_config_file(path), cfg), "load(save(cfg)) = cfg"
  save_config_file(new_config(), path)
  check same_settings(load_config_file(path), new_config()), "defaults round-trip too"

removeDir(dir)

if failures > 0:
  echo failures, " check(s) failed"
  quit(1)
echo "ok"
