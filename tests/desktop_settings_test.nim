## Unit tests for the desktop app's settings (src/dingbat/common/config.nim).
## Whatever the Settings window can store must come back from the file
## unchanged (a keypad key bound to an input used to be dropped on the next
## start); a save must keep what a second dingbat window saved, never
## overwrite a file it could not read, and never raise; the command line's
## BIOS options must hold for one run only, and a BIOS mode that needs a
## file must fall back to HLE when there is none.

import std/[os, tables, tempfiles, options]
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
    a.speed_mode == b.speed_mode and a.frame_size == b.frame_size

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

echo "Two windows: each save keeps the other window's changes"
block:
  # Two dingbat processes read the file at start; each save used to write
  # its whole, stale copy over the other's changes.
  let path = dir / "two.yml"
  save_config_file(new_config(), path)
  let a = load_config_file(path)
  let b = load_config_file(path)
  a.volume = 40
  save_config_file(a, path)
  b.keybindings[KP_8] = Input.START
  save_config_file(b, path)
  var back = load_config_file(path)
  check back.volume == 40, "A's volume survives B's save"
  check back.keybindings.getOrDefault(KP_8, Input.R) == Input.START, "B's binding is saved"
  # A saves again (its recents change): B's binding stays, A still has no
  # copy of it in memory.
  a.recents = @["/roms/x.gba"]
  save_config_file(a, path)
  back = load_config_file(path)
  check back.keybindings.getOrDefault(KP_8, Input.R) == Input.START, "B's binding survives A's next save"
  check back.recents == @["/roms/x.gba"] and back.volume == 40, "A's own changes are there"
  # A key both changed: the later save wins, as with one window.
  b.volume = 70
  save_config_file(b, path)
  check load_config_file(path).volume == 70, "the later change to one key wins"

echo "A damaged file is moved aside, never overwritten"
block:
  let path = dir / "bad.yml"
  const GARBAGE = "keybindings: [unclosed\n  volume: {\n"
  writeFile(path, GARBAGE)
  let cfg = load_config_file(path)
  check cfg.volume == 100 and cfg.notice.len > 0, "defaults, and a notice for the user"
  check not fileExists(path), "the damaged file is gone from the settings path"
  check fileExists(path & ".bad") and readFile(path & ".bad") == GARBAGE, "kept byte for byte as .bad"
  cfg.volume = 55
  save_config_file(cfg, path)
  check load_config_file(path).volume == 55, "the next save writes a good file"
  check readFile(path & ".bad") == GARBAGE, "and leaves the old one alone"
  # Damaged while running: the save moves it aside too, and a second damaged
  # file does not replace the first.
  writeFile(path, GARBAGE & "#2")
  cfg.notice = ""
  save_config_file(cfg, path)
  check load_config_file(path).volume == 55 and cfg.notice.len > 0, "a save over a damaged file says so"
  check readFile(path & ".bad2") == GARBAGE & "#2" and readFile(path & ".bad") == GARBAGE,
        "each damaged file keeps its own name"

echo "A settings folder that cannot be written"
block:
  # The parent is a plain file, so no folder can be created there (this
  # holds for any user, root included).
  let blocker = dir / "not_a_dir"
  writeFile(blocker, "")
  let path = blocker / "dingbat.yml"
  let cfg = new_config()
  var raised = false
  try:
    save_config_file(cfg, path)
  except CatchableError:
    raised = true
  check not raised, "save_config does not raise"
  check cfg.save_error.len > 0 and cfg.notice.len > 0, "the failure is kept and reported"
  cfg.notice = ""
  try:
    save_config_file(cfg, path)
  except CatchableError:
    raised = true
  check not raised and cfg.notice.len == 0, "reported once, not on every save"
  save_config_file(cfg, dir / "writable.yml")
  check cfg.save_error.len == 0, "a later good write clears it"
  save_config_file(cfg, path)
  check cfg.notice.len > 0, "and a new failure is reported again"

echo "Command-line BIOS options hold for one run"
block:
  let path = dir / "cli.yml"
  let bios = dir / "gba_bios.bin"
  writeFile(bios, newString(0x4000))
  let chosen = new_config()
  chosen.bios_path = bios
  chosen.use_hle = false                 # Settings: real BIOS, with the intro
  chosen.run_bios = true
  save_config_file(chosen, path)
  # `dingbat --hle game.gba`, and that run loads a ROM (which saves)
  let cfg = load_config_file(path)
  let boot = boot_settings(cfg, BootOverrides(use_hle: true))
  check boot.use_hle and not boot.run_bios, "--hle boots HLE without the intro"
  save_config_file(cfg, path)
  let next = load_config_file(path)
  check not next.use_hle and next.run_bios and next.bios_path == bios,
        "the next start still has the real BIOS the user chose"
  let skip = boot_settings(next, BootOverrides(run_bios: some(false)))
  check not skip.run_bios and not skip.use_hle, "--skip-bios skips a saved intro"
  check boot_settings(new_config(), BootOverrides(run_bios: some(true), bios_path: bios)).run_bios,
        "--run-bios with a BIOS argument runs the intro"
  let arg = boot_settings(new_config(), BootOverrides(bios_path: bios))
  check arg.bios_path == bios and not arg.use_hle, "a BIOS argument means the real BIOS"
  check describe(BootOverrides(use_hle: true, run_bios: some(false))) == "--hle, --skip-bios",
        "the Settings window names the overrides"

echo "Real BIOS or the intro without a BIOS file falls back to HLE"
block:
  let cfg = new_config()
  cfg.use_hle = false                     # "Real BIOS", no file set
  var boot = boot_settings(cfg, BootOverrides())
  check boot.use_hle and not boot.run_bios and boot.note.len > 0, "real BIOS, no file: HLE, and says why"
  cfg.use_hle = true
  cfg.run_bios = true                     # "Run BIOS intro", no file set
  boot = boot_settings(cfg, BootOverrides())
  check boot.use_hle and not boot.run_bios and boot.note.len > 0, "intro, no file: skipped, and says why"
  check boot.gb_run_bios, "the GB boot ROM setting is left alone"
  cfg.run_bios = false
  cfg.use_hle = false
  cfg.hle_after_bios = true               # "Real BIOS init, HLE SWI calls"
  cfg.bios_path = dir / "moved_away.bin"
  boot = boot_settings(cfg, BootOverrides())
  check boot.use_hle and boot.note.len > 0, "BIOS init + HLE, file missing: HLE"
  cfg.bios_path = dir / "gba_bios.bin"
  boot = boot_settings(cfg, BootOverrides())
  check not boot.use_hle and boot.hle_after_bios and boot.note.len == 0, "with the file: as configured"
  check boot_settings(new_config(), BootOverrides()).note.len == 0, "HLE with no file needs no note"

echo "Reset to Defaults resets every setting and keeps the user's data"
block:
  let cfg = new_config()
  cfg.explorer_dir = dir / "roms"
  cfg.recents = @[dir / "a.gba"]
  cfg.bios_path = dir / "gba_bios.bin"
  cfg.gb_bootrom_path = dir / "dmg_boot.bin"
  cfg.keybindings = homerow_keybindings()
  cfg.controller_bindings = {cint(0): Input.B}.toTable
  cfg.run_bios = true
  cfg.use_hle = false
  cfg.hle_after_bios = true
  cfg.gb_fifo = false
  cfg.gb_rumble = false
  cfg.volume = 12
  cfg.mute = true
  cfg.color_correction = false
  cfg.video_filter = vfGrid
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
  cfg.frame_size = 5
  cfg.reset_to_defaults()
  let want = new_config()
  want.explorer_dir = dir / "roms"
  want.recents = @[dir / "a.gba"]
  want.bios_path = dir / "gba_bios.bin"
  want.gb_bootrom_path = dir / "dmg_boot.bin"
  check cfg.fifo_interp and not cfg.speed_mode, "Audio interpolation back on, Speed mode off"
  check same_settings(cfg, want) and cfg.frame_size == want.frame_size,
        "every other setting is the default; paths and recents kept"

echo "Frame size is saved"
block:
  let path = dir / "frame.yml"
  let cfg = new_config()
  cfg.frame_size = 6
  save_config_file(cfg, path)
  check load_config_file(path).frame_size == 6, "6x comes back"
  writeFile(path, "---\nframe_size: 99\n")
  check load_config_file(path).frame_size == 8, "a hand-edited size is clamped"

removeDir(dir)

if failures > 0:
  echo failures, " check(s) failed"
  quit(1)
echo "ok"
