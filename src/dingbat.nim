import std/[os, hashes, math, options, parseopt, strformat, strutils, tables, times, algorithm]
import sdl3
import imguin/cimgui
import stb_image/read as stbi
import stb_image/write as stbiw
import dingbat/common/config
import dingbat/common/atomicfile
import dingbat/common/lcd_response
import dingbat/common/input
import dingbat/common/rewind
import dingbat/gba/gba
import dingbat/gba/netlink
import dingbat/gb/gb
import dingbat/frontend/file_explorer
import dingbat/frontend/notice
import dingbat/frontend/config_editor
import dingbat/frontend/imgui_settings
import dingbat/frontend/keybindings_widget
import dingbat/frontend/controller_widget
import dingbat/frontend/held_input
import dingbat/frontend/gba_debug
import dingbat/frontend/gb_debug
import dingbat/frontend/cheats_widget
import dingbat/frontend/save_states_widget
import dingbat/frontend/link_cable
import dingbat/frontend/persist
import dingbat/frontend/game_load
import dingbat/frontend/game_lock
import dingbat/frontend/window_restore
import dingbat/frontend/nds_game
import dingbat/frontend/imgui_sdl3
from dingbat/frontend/presenter as pr import nil
import dingbat/frontend/util
import dingbat/frontend/ui_fonts
import dingbat/frontend/menu_model
import dingbat/frontend/imgui_menu
import dingbat/frontend/library
import dingbat/frontend/library_view
when defined(macosx):
  import dingbat/frontend/mac_menu
  import dingbat/frontend/mac_settings
  import dingbat/frontend/mac_alert
  import dingbat/frontend/mac_scroll
when defined(gui_driver):
  import dingbat/frontend/gui_driver
import dingbat/common/cheats
import dingbat/common/serialize
from dingbat/common/audio_out import audio_close
from dingbat/nds/savestate as nds_savestate import nil

const VERSION = "0.1.0"
const GBA_W   = 240
const GBA_H   = 160
const GB_W    = 160
const GB_H    = 144

# Mod key for keyboard shortcuts
when defined(macosx):
  const MOD_KEY_MASK = KMOD_GUI
  const MOD_KEY_STR  = "Cmd"
else:
  const MOD_KEY_MASK = KMOD_CTRL
  const MOD_KEY_STR  = "Ctrl"

const LOGO_PNG_DATA = staticRead("../.github/readme/dingbat.png")

const HELP_URL = "https://github.com/mattrbeck/dingbat/blob/main/docs/usage.md"

# macOS: dingbat's menus in the system menu bar (mac_menu.nim), not the
# window; DINGBAT_IMGUI_MENU=1 keeps the in-window ImGui bar instead.
var native_menu = false

# The sdl3 package types SDL_WINDOWPOS_CENTERED as uint; positions are cint
const WINDOW_CENTERED = cint(WINDOWPOS_CENTERED)

# ──────────────────────────── Helpers ────────────────────────────

proc print_help() =
  echo "dingbat - A GBA emulator"
  echo ""
  echo "Usage: dingbat [options] [BIOS] [ROM]"
  echo ""
  echo "Options:"
  echo "  -h, --help       Show this help message"
  echo "  --hle            Use HLE BIOS (no external BIOS file needed)"
  echo "  --hle-after-bios Run real BIOS for init, then use HLE for SWI calls"
  echo "  --run-bios       Run the BIOS intro"
  echo "  --skip-bios      Skip the BIOS intro"
  echo "  (BIOS options and a BIOS argument hold for this run; Settings keep theirs)"
  echo "  --version        Print version"
  echo ""
  echo "Network link (2-player, GBA only; the same game, or two that trade):"
  echo "  --listen PORT       Host the link on PORT (this side is unit 0)"
  echo "  --connect HOST:PORT Join a host's link (this side is unit 1)"
  echo "  --netlink-delay-ms N  Add N ms of send latency (network simulation)"
  echo "  --link-auto         Zero-config auto-pair on localhost (same as opening"
  echo "                      the Link Cable window)"
  echo "  Two windows on one computer can't open the same ROM file (they would"
  echo "  share its save): open a different game in each (Ruby and Sapphire),"
  echo "  or a copy of the ROM file under another name."
  echo ""
  echo "Verification:"
  echo "  --capture N:PATH    After N presented frames, write the back buffer"
  echo "                      (the real composited picture, letterbox excluded,"
  echo "                      in device pixels: 2x the window on a Retina display)"
  echo "                      to PATH as a PNG and exit"

proc load_logo_texture(): (uint64, int, int) =
  ## The bat as an ImGui image, drawn by the home screen at 2x, nearest
  var buf = newSeq[byte](LOGO_PNG_DATA.len)
  for i, c in LOGO_PNG_DATA: buf[i] = byte(c)
  var w, h, comp: int
  let pixels = stbi.loadFromMemory(buf, w, h, comp, stbi.RGBA)
  var tex: uint64
  pr.ui_texture(tex, unsafeAddr pixels[0], w, h, bgr555 = false, linear = false)
  (tex, w, h)

# --capture N:PATH. Reads the actual back buffer, so it proves the shader
# path rather than the core's buffers. -1 disables.
var capture_after = -1
var capture_path  = ""
var present_count = 0

# ──────────────────────────── App State ────────────────────────────

type EmuKind = enum ekNone, ekGBA, ekGB, ekNDS  # ekNDS: DS Beta only

type OpenHow = enum
  ## How a game is being opened (web launchRom's options)
  ohFile     ## a file handed in (Add a Game, a drop, the command line): from
             ## its save, the session offered after
  ohLibrary  ## a tile, Open Recent: the session or the save, as Settings says
  ohPlay     ## Play: from its save, nothing offered
  ohResume   ## the hero's Resume: the session

type AppState = ref object
  cfg:             Config
  cur_path:        string  # what load_rom last loaded (a zip: the zip); Reset reloads it
  gba_emu:         GBA
  gb_emu:          GB
  nds:             NdsGame   # a DS game (DS Beta; frontend/nds_game.nim)
  emu_kind:        EmuKind
  window:          Window
  io:              ptr ImGuiIO
  look:            pr.Look  # the game shader's inputs
  nds_tex_scale:   int      # a DS game's texture: 256x384 times this (HD 3D)
  # The SGB border layer is uploaded and sampled only while the cart runs
  # as a Super Game Boy and has transferred a border.
  border_shown:    bool     # what the last present decided; drives window sizing
  border_gen:      uint32   # last border generation uploaded to the texture
  logo_texture:    uint64   # an ImGui image (presenter.ui_texture)
  logo_w, logo_h:  int
  fe:              FileExplorer
  ce:              ConfigEditor
  dbg:             GbaDebug
  gb_dbg:          GbDebug
  cheats:          CheatsWidget
  save_states:     SaveStatesWidget
  state_slot_texs: array[NUM_SLOTS, uint64]  # thumbnails for the grid (0 = none)
  scale:           int
  running:         bool
  paused:          bool
  # Save states run only at frame boundaries: the main loop services these
  # right after run_until_frame.
  pending_save:    bool
  pending_load:    bool
  pending_step:    bool  # frame advance: run exactly one frame while paused
  # Set when a save state is refused; render_state_notice draws it.
  state_notice:      string
  state_notice_hint: string
  # Set when a ROM could not be loaded; render_load_notice draws it.
  load_notice:       string
  load_notice_hint:  string
  # This window's hold on its game's files: a second window fails to open it
  game_lock:       GameLock
  # Command-line BIOS choices: for this run only, never written to cfg
  boot_overrides:  BootOverrides
  # A battery save that can't be written; shown in the same modal once
  # state_notice is clear (poll_battery_notice).
  battery:           BatteryNotice
  rewind:          Rewind
  rewind_ds:       bool    # `rewind` is a DS game's ring (no keyframes)
  rewinding:       bool    # true while the rewind key is held
  last_rewind_pop: uint64
  # Active 2-player network link (nil = single-player). While set, the core
  # runs via netlink.step_frame (keeps the socket pumped and both sides in
  # sync); rewind, frame advance, turbo and state load are off (they desync).
  netlink:         NetLink
  # ImGui "Link Cable" window; pairing is non-blocking.
  link_window:     bool
  link_window_min_h: float32  # its content's height last frame
  link:            LinkCable  # pairing state (frontend/link_cable.nim)
  # Why the link failed while AppKit held the main loop; ended by the loop
  link_lost:       string
  fullscreen:      bool
  fs_track:        FullscreenTrack  # the window's real state (window_restore.nim)
  aspect:          float32  # the window's ratio lock as last set (0 = free)
  enable_overlay:  bool
  last_mouse_tick: uint64
  drag_hover:      bool  # a file is being dragged over the window
  # The home screen's games (frontend/library.nim) and its drawing
  library:         Library
  home:            LibraryView
  home_stale:      bool    # the library changed since the view last took it
  home_open:       string  # a game the home screen chose; the main loop opens it
  home_how:        OpenHow # and how
  offer_taken:     string  # the session offer's Resume, for the game it was made for
  played_here:     seq[string]  # library paths played in this run, latest first (the hero's)
  find_for:        string  # Find the File: the missing game's path, while its dialog is up
  find_request:    bool    # Find the File chosen: the ImGui explorer opens next frame
  open_rom_request: bool # Add a game chosen: the ImGui explorer opens next frame

var app: AppState

# Emulated-frames FPS (not the UI framerate), updated once a second
var emu_fps = 0.0

# LCD response (common/lcd_response.nim): presentation-only, safe to change
# live. Cell state is dropped on ROM load.
var lcd_resp: LcdResponse

# MBC5 rumble (GB cart types 0x1C-0x1E): update_rumble polls the motor into
# rumble_on each loop; render_game shakes the viewport, rumble_flip alternating
# the direction per present.
var rumble_on         = false
var rumble_flip       = false
var rumble_last_pulse = 0'u64

# Frame period in performance-counter ticks, which the frame scheduler paces
# by: GB/GBA 280896 cycles at 16.777216 MHz, or the DS's. Set in main; load_rom
# picks the core's.
var gbx_frame_ticks, nds_frame_ticks, frame_ticks: uint64

# ──────────────────────────── ROM Loading ────────────────────────────

proc flush_saves() =
  ## Call before a core is dropped (switch, Reset) and at quit. A failure is
  ## the core's to log and poll_battery_notice's to show.
  discard flush_batteries(app.gba_emu, app.gb_emu)
  if app.nds != nil: discard app.nds.flush()

proc apply_color_correction() =
  ## The correction models the GBA and GBC panels: never on a DS's own.
  app.look.color_correct = app.cfg.color_correction and app.emu_kind != ekNDS

# Black-and-white game palette: Night's, the web and iOS default (web
# GB_DEFAULT_SHADES), lightest first, 0xRRGGBB. The core's greys are codes.
const DMG_SHADES = [0xF7F3FF'u32, 0xC6B0FF'u32, 0xA26FCF'u32, 0x3A2463'u32]

proc dmg_shades_on(): bool =
  ## A black-and-white game, not under SGB colour (whose palettes' white and
  ## black are the grey codes too): web gbMonoPanel and !sgbActive.
  app.emu_kind == ekGB and app.gb_emu != nil and not app.gb_emu.cgb_enabled and
    not app.gb_emu.sgb_active()

proc dmg_shade_rgb(v: uint16): array[3, byte] =
  ## A grey code's palette colour; v must be one of DMG_COLORS (or an old
  ## state's OLD_DMG_COLORS).
  var s = dmg_shade(v)
  if s < 0: s = OLD_DMG_COLORS.find(v and 0x7FFF'u16)
  let c = DMG_SHADES[s]
  [byte(c shr 16), byte((c shr 8) and 0xFF), byte(c and 0xFF)]

proc sgb_border_active(): bool =
  ## The last condition keeps the window from resizing for a cart that
  ## colours its screen but ships no border art.
  app.emu_kind == ekGB and app.gb_emu != nil and
    app.cfg.sgb_enable and app.cfg.sgb_border and app.gb_emu.sgb_has_border()

proc output_size(): (int, int) =
  ## The picture's native size, which is what the window is sized from and
  ## what the aspect is preserved against. 256x224 only while a border is
  ## actually on screen.
  case app.emu_kind
  of ekGBA: (GBA_W, GBA_H)
  of ekGB:  (if sgb_border_active(): (SGB_BORDER_W, SGB_BORDER_H) else: (GB_W, GB_H))
  of ekNDS: (NDS_W, NDS_H)
  of ekNone: (GBA_W, GBA_H)

proc window_units(window: Window; s: int): float =
  ## Window units per native pixel at Frame size s: s times the UI scale,
  ## rounded to whole back-buffer pixels so every native pixel is the same
  ## size. Windows and X11 size windows in pixels, so the UI scale applies
  ## there (3x at 125% is 3.75x, made 4x). A fractional density (Wayland at
  ## 125%) is made whole the same way. On macOS, or Windows at 100%, this is s.
  var d = float(getWindowPixelDensity(window))
  if d <= 0: d = 1.0
  max(1.0, round(float(s) * float(ui_scale) * d)) / d

proc window_scale(): int =
  ## Frame size, except a DS picture takes the largest multiple that fits the
  ## screen's usable height, title bar allowed for.
  if app.emu_kind != ekNDS: return app.scale
  var r: Rect
  if not getDisplayUsableBounds(getDisplayForWindow(app.window), r):
    return app.scale
  result = app.scale
  while result > 1 and float(NDS_H) * window_units(app.window, result) +
                       40 * float(ui_scale) > float(r.h):
    dec result

proc wanted_aspect(): float32 =
  ## The width:height a resize keeps the window to: the picture's, so a drag
  ## never letterboxes it. Free (0) on the home screen, in fullscreen, and
  ## with Preserve aspect ratio off (the picture stretches to the window).
  let fs = app.fullscreen or (getWindowFlags(app.window) and WINDOW_FULLSCREEN) != 0
  if app.emu_kind == ekNone or fs or not app.cfg.preserve_aspect: return 0
  let (w, h) = output_size()
  float32(w) / float32(h)

proc sync_aspect() =
  ## Every loop iteration and before each resize. SDL fits the window to a
  ## new ratio at once, and every later size to it (a size of exactly that
  ## ratio is left as it is), so it is set before sizing for a new picture.
  let a = wanted_aspect()
  if a != app.aspect:
    app.aspect = a
    discard setWindowAspectRatio(app.window, a, a)
    when defined(macosx):
      if a == 0: mac_free_aspect(app.window)

proc set_window_to(w, h, s: int) =
  ## Size the window to s times a native w x h picture (window_units).
  sync_aspect()
  let k = window_units(app.window, s)
  discard setWindowSize(app.window, cint(round(float(w) * k)),
                        cint(round(float(h) * k)))

var ui_base_style: ImGuiStyle  # ImGui's dark style at 100%, scaled from afresh

proc display_ui_scale(window: Window): float32 =
  ## The display's content scale less the pixel density: Windows' 125%/150%,
  ## X11's Xft.dpi, and 1 on macOS or Wayland (density is the whole scale).
  ## DINGBAT_UI_SCALE=<x> overrides it.
  try:
    let forced = parseFloat(getEnv("DINGBAT_UI_SCALE", "0"))
    if forced > 0: return clamp(float32(forced), 0.5, 4)
  except ValueError: discard
  let d = getWindowPixelDensity(window)
  let s = getWindowDisplayScale(window)
  if d <= 0 or s <= 0: 1'f32 else: s / d

proc apply_ui_scale(s: float32) =
  ## Scale ImGui's style, fonts and ui_px sizes by s. Scaled from the 100%
  ## style each time, as ScaleAllSizes rounds down; ImGui rasterises the fonts
  ## at the scaled size.
  ui_scale = s
  let style = igGetStyle()
  style[] = ui_base_style
  ImGuiStyle_ScaleAllSizes(style, s)
  style.FontScaleDpi = s

proc setup_ui_style() =
  ## The fonts, and ImGui's dark style spaced for them: body text at the
  ## web's 14 px, controls a little roomier and rounder than ImGui's own
  load_ui_fonts(igGetIO_Nil().Fonts)
  echo "UI fonts: ", face_names.join(", ")
  igStyleColorsDark(nil)
  let st = igGetStyle()
  st.FontSizeBase = font_px(BODY_PX)
  st.WindowPadding = ImVec2(x: 12, y: 10)
  st.FramePadding = ImVec2(x: 6, y: 4)
  st.ItemSpacing = ImVec2(x: 8, y: 5)
  st.ItemInnerSpacing = ImVec2(x: 6, y: 4)
  st.WindowRounding = 8
  st.ChildRounding = 6
  st.PopupRounding = 6
  st.FrameRounding = 5
  st.GrabRounding = 4
  st.TabRounding = 5
  ui_base_style = st[]

proc resize_to_output() =
  ## Size the window to an integer multiple of the native picture. In
  ## fullscreen this is deferred to track_fullscreen.
  if app.fullscreen:
    app.fs_track.refit = true
    return
  let (w, h) = output_size()
  set_window_to(w, h, window_scale())

proc remember_fullscreen(on: bool) =
  ## Saved so the next start comes back this way (window_restore.nim).
  app.fullscreen = on
  if app.cfg.fullscreen != on:
    app.cfg.fullscreen = on
    save_config(app.cfg)

proc set_fullscreen(on: bool) =
  ## Menu and Cmd/Ctrl+F.
  remember_fullscreen(on)
  sync_aspect()   # free before going fullscreen
  discard setWindowFullscreen(app.window, on)

proc window_is_fullscreen(): bool =
  ## What the window really is, whoever put it there: SDL 3 also flags a
  ## macOS fullscreen Space entered from the green button or Ctrl+Cmd+F.
  (getWindowFlags(app.window) and WINDOW_FULLSCREEN) != 0

proc track_fullscreen() =
  ## On a window resize: adopt a fullscreen change the OS made, and apply a
  ## sizing deferred while fullscreen (a GB game loaded in fullscreen).
  let real = window_is_fullscreen()
  case app.fs_track.observe(real, app.fullscreen)
  of fcNone: discard
  of fcEntered, fcLeft:
    remember_fullscreen(real)
  if app.fs_track.take_refit(real): resize_to_output()

proc letterbox(ww, wh: cint): (int, int, int, int) =
  ## The letterboxed rect the picture fills in a ww x wh area, in that
  ## area's units. An SGB border switches the picture from 10:9 to 8:7
  ## mid-session, so one window must fit both.
  let (ow, oh) = output_size()
  if not app.cfg.preserve_aspect or ow <= 0 or oh <= 0:
    return (0, 0, int(ww), int(wh))
  let scale = min(float(ww) / float(ow), float(wh) / float(oh))
  let vw = int(float(ow) * scale)
  let vh = int(float(oh) * scale)
  ((int(ww) - vw) div 2, (int(wh) - vh) div 2, vw, vh)

proc game_viewport(): (int, int, int, int) =
  ## The rect the game quad is drawn into, in back-buffer pixels from the
  ## bottom left: twice the window's size on a Retina display
  ## (WINDOW_HIGH_PIXEL_DENSITY).
  var pw, ph: cint
  discard getWindowSizeInPixels(app.window, pw, ph)
  letterbox(pw, ph)

proc apply_panel_uniforms() =
  ## Depends only on the core kind: run on core (re)load, not per frame.
  let gbc = app.emu_kind == ekGB
  let ds = app.emu_kind == ekNDS
  app.look.panel_gbc = gbc
  app.look.tex_height = if gbc: float32(GB_H) elif ds: float32(NDS_H) else: float32(GBA_H)
  app.look.tex_width = if gbc: float32(GB_W) elif ds: float32(NDS_W) else: float32(GBA_W)

proc apply_master_volume() =
  # Nothing audible: the cores skip mixing (APU.silent) and queue zeros
  let silent = app.cfg.mute or app.cfg.volume <= 0
  if app.gba_emu != nil:
    app.gba_emu.apu.set_master_volume(app.cfg.volume, app.cfg.mute)
    app.gba_emu.set_audio_silent(silent)
  if app.gb_emu != nil:
    app.gb_emu.apu.set_master_volume(app.cfg.volume, app.cfg.mute)
    app.gb_emu.apu.silent = silent

proc apply_pitch_correct_ff() =
  if app.gba_emu != nil:
    app.gba_emu.apu.set_pitch_correct_ff(app.cfg.pitch_correct_ff)
  if app.gb_emu != nil:
    app.gb_emu.apu.set_pitch_correct_ff(app.cfg.pitch_correct_ff)

proc apply_audio_lowpass() =
  # Models the GBA's cap/speaker smoothing; GBA only (DirectSound imaging).
  if app.gba_emu != nil:
    app.gba_emu.apu.set_audio_lowpass(app.cfg.audio_lowpass)

proc apply_mp2k_hle() =
  # Free to arm: engages only when mp2k.nim detects the engine.
  if app.gba_emu != nil:
    app.gba_emu.mp2k_hle = app.cfg.mp2k_hle

proc apply_fifo_interp() =
  # DirectSound FIFO interpolation (cubic). Off is bit-true DAC output.
  if app.gba_emu != nil:
    app.gba_emu.apu.set_fifo_interp(app.cfg.fifo_interp)

proc current_cheat_engine(): CheatEngine
proc load_cheats()
proc on_cheats_changed()
proc save_state_slot(slot: int): bool
# Network link procs, defined below with the rest of the link code
proc teardown_netlink(why = "")
proc link_cancel_setup()
proc link_auto_stop()

# ──────────────────────────── Input log ────────────────────────────
# DINGBAT_INPUT_LOG=<path> records a GBA session's keypad as "<frame> <mask>"
# lines (KEYINPUT bit order, set before that frame runs) for tools/playtest to
# replay headless. State loads and rewinds break the timeline; the log says so.
# Every 60 frames a "hash" line holds the playtest framebuffer hash so a replay
# can check it is in step; F9 writes a "mark". The RTC is frozen at the
# playtest epoch while recording.

const INPUT_LOG_RTC_EPOCH = 1136073600'i64   # tools/playtest DEFAULT_RTC

var input_log: system.File
var input_log_open = false
var input_log_frame = 0
var input_log_mask = 0

proc input_log_start(rom_path: string) =
  let path = getEnv("DINGBAT_INPUT_LOG")
  if path.len == 0: return
  if input_log_open: input_log.close()
  # append: every ROM load (including a reset) starts a new session in the file
  input_log_open = open(input_log, path, fmAppend)
  if not input_log_open:
    echo "input log: cannot write ", path
    return
  input_log.writeLine "session " & $getTime().toUnix
  input_log.writeLine "rom " & rom_path
  let g = app.gba_emu
  input_log.writeLine &"bios run_bios={g.run_bios} use_hle={g.use_hle} hle_after_bios={g.hle_after_bios}"
  app.gba_emu.enable_deterministic_rtc(INPUT_LOG_RTC_EPOCH)
  input_log.writeLine &"rtc {INPUT_LOG_RTC_EPOCH}"
  input_log.flushFile()
  input_log_frame = 0
  input_log_mask = 0
  echo "input log: recording to ", path

proc input_log_fb_hash(): uint64 =
  ## FNV-1a over the 15-bit pixels, as tools/playtest/drivers hash them
  result = 0xcbf29ce484222325'u64
  for p in app.gba_emu.ppu.framebuffer:
    result = (result xor uint64(p and 0x7FFF)) * 0x100000001b3'u64

proc input_log_frame_start() =
  if not input_log_open: return
  if input_log_frame mod 60 == 0 and input_log_frame > 0:
    input_log.writeLine &"hash {input_log_frame} {input_log_fb_hash().toHex}"
  let mask = int(not toU16(app.gba_emu.keypad.keyinput) and 0x03FF'u16)
  if mask != input_log_mask:
    input_log.writeLine &"{input_log_frame} {mask}"
    input_log.flushFile()
    input_log_mask = mask
  inc input_log_frame

proc input_log_event(what: string) =
  if not input_log_open: return
  input_log.writeLine &"desync {input_log_frame} {what}"
  input_log.flushFile()

proc input_log_mark() =
  if not input_log_open: return
  input_log.writeLine &"mark {input_log_frame}"
  input_log.flushFile()
  echo "input log: mark at frame ", input_log_frame

proc input_log_close() =
  if not input_log_open: return
  input_log.writeLine &"end {input_log_frame}"
  input_log.close()
  input_log_open = false

proc new_core_takes_held_input()  # defined below, with the controllers
proc store_last_screen()          # defined below, with the library
proc save_session()               # defined below, with Close Game
proc record_played(g: LibGame)

proc load_notice(text, hint: string) =
  echo text, (if hint.len > 0: " (" & hint & ")" else: "")
  app.load_notice = text
  app.load_notice_hint = hint

proc nds_paths(): NdsPaths =
  ## The DS dumps from Settings > BIOS, and the one firmware flash every DS
  ## game shares
  NdsPaths(bios9: app.cfg.nds_bios9_path, bios7: app.cfg.nds_bios7_path,
           firmware: app.cfg.nds_firmware_path,
           flash: config_dir() / "nds" / "flash.bin")

proc states_dir(): string = config_dir() / "states"

proc load_rom(path: string; keep_ds = false) =
  ## Every failure leaves the running game (or the home screen) as it was and
  ## says why. A DS game loads only with DS Beta on (`keep_ds`: a Reset of
  ## the DS game running, whatever the setting says now). The outgoing game
  ## leaves its session, as Close Game does (web loadRom).
  if not fileExists(path):
    load_notice(&"{path.extractFilename()} isn't there any more.", path)
    return
  let ds_beta = app.cfg.ds_beta or keep_ds
  # Zips: load the first ROM inside; recents keep the zip path itself
  var rom_path = path
  if path.splitFile().ext.toLowerAscii() == ".zip":
    rom_path = if ds_beta: extract_zip_rom(config_dir() / "zip-cache", path, ROM_EXTS_DS)
               else: extract_zip_rom(config_dir() / "zip-cache", path)
    if rom_path == "":
      let systems = if ds_beta: "Game Boy, GBA or DS" else: "Game Boy or GBA"
      load_notice(&"No {systems} ROM could be read from {path.extractFilename()}.", "")
      return
  let as_ds = ds_beta and is_nds_file(rom_path)
  # Before the new core reads the .sav: a Reset reloads the same file
  flush_saves()
  # A game another dingbat window has open fails before its .sav is read; a
  # Reset keeps this window's own lock
  let lock_dir = config_dir() / "locks"
  var claim: GameLock
  if not app.game_lock.claim_files(lock_dir, rom_path, claim):
    let (text, hint) = refusal_notice(rfFiles, path.extractFilename(),
                                      rom_path.extractFilename())
    load_notice(text, hint)
    return
  # The new core is built and checked before anything of the old one goes
  var built: BuiltCore
  var built_ds: BuiltNds
  if as_ds:
    built_ds = build_nds(rom_path, nds_paths())
    if built_ds.error.len > 0:
      claim.abandon()
      load_notice(built_ds.error, built_ds.detail)
      return
  else:
    let boot = boot_settings(app.cfg, app.boot_overrides)
    if boot.note.len > 0 and not is_gb_rom(rom_path): echo boot.note
    built = build_core(rom_path, CoreOptions(
      gb_bootrom: app.cfg.gb_bootrom_path,
      headless: app.cfg.headless, gb_run_bios: boot.gb_run_bios,
      sgb: app.cfg.sgb_enable, bios_path: boot.bios_path,
      run_bios: boot.run_bios, use_hle: boot.use_hle,
      hle_after_bios: boot.hle_after_bios))
    if built.error.len > 0:
      claim.abandon()
      load_notice(built.error, built.detail)
      return
  # A copy of this game under the same file name shares its save-state slots
  let identity = if as_ds: built_ds.game.state_identity()
                 elif built.gb != nil: built.gb.state_rom_identity()
                 else: built.gba.state_rom_identity()
  if not app.game_lock.claim_states(lock_dir, rom_path, identity, claim):
    claim.abandon()
    let (text, hint) = refusal_notice(rfStates, path.extractFilename(),
                                      rom_path.extractFilename())
    load_notice(text, hint)
    return
  # The link (or a pending setup) belongs to the outgoing core: left up, it
  # keeps driving that core unseen, and a late peer binds to whatever is
  # loaded then, a GB game included
  if app.netlink == nil and app.link.setup != lsNone:
    app.link.status = "Link ended: another game was loaded."
  link_auto_stop()
  link_cancel_setup()
  teardown_netlink("another game was loaded")
  # A Quick Save pending in this batch of input is the outgoing game's: save
  # it now. With the link gone the core is at a frame boundary (teardown
  # finishes a torn frame).
  if app.pending_save:
    app.pending_save = false
    if not save_state_slot(0):
      app.state_notice = QUICK_SAVE_FAILED
      app.state_notice_hint = last_state_error
  # What that finished frame wrote goes too
  flush_saves()
  # The library keeps the outgoing game's last screen, and where it was left
  store_last_screen()
  save_session()
  dismiss_game_toasts()
  # The old game's files are written out; its locks go to the new game
  app.game_lock.commit(claim)
  let was_ds = app.emu_kind == ekNDS
  if as_ds:
    app.nds = built_ds.game
    app.nds.set_hd(app.cfg.nds_hd)
    app.gba_emu = nil
    app.gb_emu = nil
    app.emu_kind = ekNDS
    app.border_shown = false
    app.nds.open_audio()
    set_window_to(NDS_W, NDS_H, window_scale())
    app.dbg = nil
    app.gb_dbg = nil
    # The cheat window edits GB/GBA codes; a DS game has none to take
    app.cheats.window = false
  elif built.gb != nil:
    app.nds = nil
    app.gb_emu = built.gb
    app.gba_emu = nil
    app.emu_kind = ekGB
    app.border_shown = false
    app.border_gen = 0
    set_window_to(GB_W, GB_H, app.scale)
    app.dbg = nil
    app.gb_dbg = new_gb_debug(app.gb_emu)
  else:
    app.nds = nil
    app.gba_emu = built.gba
    input_log_start(rom_path)
    app.gb_emu = nil
    app.emu_kind = ekGBA
    app.border_shown = false
    set_window_to(GBA_W, GBA_H, app.scale)
    app.dbg = new_gba_debug(app.gba_emu)
    app.gb_dbg = nil
  app.cheats.attach(current_cheat_engine(),
                    if app.emu_kind == ekGBA: cpGBA else: cpGB)
  app.cheats.on_change = on_cheats_changed
  load_cheats()
  apply_master_volume()
  apply_pitch_correct_ff()
  apply_audio_lowpass()
  apply_fifo_interp()
  apply_mp2k_hle()
  apply_panel_uniforms()
  if was_ds or as_ds:
    apply_color_correction()
    frame_ticks = if as_ds: nds_frame_ticks else: gbx_frame_ticks
  lcd_resp.reset()  # fresh core: don't ghost the previous game's frame
  # A DS payload is ~6 MB: its ring keeps no keyframes (each a 2 MB zlib, a
  # stall every few seconds), as on the web; same 64 MB cap
  if as_ds:
    app.rewind = new_rewind(REWIND_CAP_BYTES, key_every = 0)
    app.rewind_ds = true
  elif app.rewind_ds:
    app.rewind = new_rewind()
    app.rewind_ds = false
  else:
    app.rewind.clear()
  app.rewinding = false
  let (tw, th) = if app.emu_kind == ekGBA: (GBA_W, GBA_H)
                 elif app.emu_kind == ekNDS: (NDS_W, NDS_H)
                 else: (GB_W, GB_H)
  pr.game_alloc(tw, th)
  app.nds_tex_scale = 1   # a DS game's HD size is taken at its first present
  app.cur_path = path
  var recs = app.cfg.recents
  let idx = recs.find(path)
  if idx >= 0: recs.delete(idx)
  recs.insert(path, 0)
  while recs.len > 8: recs.setLen(8)
  app.cfg.recents = recs
  save_config(app.cfg)
  let rom_name = rom_path.extractFilename()
  var system = if as_ds: "DS" else: system_of(rom_name)
  if system.len == 0: system = if app.emu_kind == ekGB: "GB" else: "GBA"
  record_played(LibGame(path: path, rom: rom_name, system: system,
                        identity: identity.toHex(8)))
  when defined(macosx):
    if native_menu:
      mac_note_recent(path)
      mac_set_document(app.window, path)
      mac_menu_refresh()
  discard setWindowPosition(app.window, WINDOW_CENTERED, WINDOW_CENTERED)
  app.paused = false
  app.pending_save = false
  app.pending_load = false
  # An open Save States window re-reads the new game's slots before acting
  # (mark_stale also drops the old game's notice)
  app.save_states.mark_stale()
  new_core_takes_held_input()

proc reset_game() =
  ## Reload the file the running game was loaded from.
  if app.cur_path.len > 0: load_rom(app.cur_path, keep_ds = app.emu_kind == ekNDS)

# ──────────────────────────── Save States ────────────────────────────

proc current_rom_path(): string =
  case app.emu_kind
  of ekGBA: (if app.gba_emu != nil: app.gba_emu.rom_path else: "")
  of ekGB:  (if app.gb_emu != nil: app.gb_emu.rom_path else: "")
  of ekNDS: (if app.nds != nil: app.nds.rom_path else: "")
  of ekNone: ""

# ──────────────────────────── Cheats ────────────────────────────

proc cheat_file_path(): string =
  ## Sidecar cheat list, next to the ROM (mirrors the .sav convention).
  let rp = current_rom_path()
  if rp.len == 0: return ""
  rp.changeFileExt(".cht")

proc current_cheat_engine(): CheatEngine =
  case app.emu_kind
  of ekGBA: (if app.gba_emu != nil: app.gba_emu.cheats else: nil)
  of ekGB:  (if app.gb_emu != nil: app.gb_emu.cheats else: nil)
  of ekNDS, ekNone: nil   # no DS cheats on the desktop yet

proc refresh_cheat_rom_patches() =
  case app.emu_kind
  of ekGBA: (if app.gba_emu != nil: app.gba_emu.refresh_cheat_rom_patches())
  of ekGB:  (if app.gb_emu != nil: app.gb_emu.refresh_cheat_rom_patches())
  of ekNDS, ekNone: discard

proc save_cheats() =
  let eng = current_cheat_engine()
  let path = cheat_file_path()
  if eng == nil or path.len == 0: return
  try:
    if eng.cheats.len == 0:
      if fileExists(path): removeFile(path)
    else:
      write_file_atomic(path, eng.serialize())
  except CatchableError as e:
    echo "cheats: could not save ", path, ": ", e.msg

proc load_cheats() =
  ## Read the sidecar (if any) into the live engine and apply ROM patches.
  let eng = current_cheat_engine()
  let path = cheat_file_path()
  if eng == nil or path.len == 0 or not fileExists(path): return
  try:
    eng.deserialize(readFile(path))
    refresh_cheat_rom_patches()
  except CatchableError as e:
    echo "cheats: could not load ", path, ": ", e.msg

proc on_cheats_changed() =
  ## Called by the widget after any edit: re-apply ROM patches, then persist.
  refresh_cheat_rom_patches()
  save_cheats()

proc state_identity(): uint32 =
  case app.emu_kind
  of ekGBA: app.gba_emu.state_rom_identity()
  of ekGB:  app.gb_emu.state_rom_identity()
  of ekNDS: app.nds.state_identity()
  of ekNone: 0'u32

proc state_prior_identity(): uint32 =
  ## What the previous slot names used (persist.nim state_read_path).
  case app.emu_kind
  of ekGBA: app.gba_emu.state_prior_rom_identity()
  of ekGB:  app.gb_emu.state_prior_rom_identity()
  of ekNDS: app.nds.state_identity()   # no older DS slot names
  of ekNone: 0'u32

proc state_is_ours(data: string): bool =
  ## An older slot file name (ROM name alone, or with the 1 MB identity) is
  ## this game's only if the state says so.
  case app.emu_kind
  of ekGBA: app.gba_emu.state_is_for(data)
  of ekGB:  app.gb_emu.state_is_for(data)
  of ekNDS: app.nds.state_is_for(data)
  of ekNone: false

proc state_file_path(slot = 0): string =
  ## Named by ROM file name and identity (persist.nim), so same-named games
  ## keep their own slots. Slot 0 is the Quick slot.
  let rom = current_rom_path()
  if rom.len == 0: return ""
  states_dir() / state_file_name(rom, state_identity(), slot)

proc state_slot_read_path(slot = 0): string =
  ## Where a slot is read from: its own file, else an older build's for this
  ## game (read only; the next Save writes the new name).
  let rom = current_rom_path()
  if rom.len == 0: return ""
  state_read_path(states_dir(), rom, state_identity(), slot, state_is_ours,
                  state_prior_identity())

proc save_state_slot(slot: int): bool =
  ## Synchronous save of a numbered slot (with a thumbnail). Callers must be at
  ## a frame boundary — true during process_pending_state and render_imgui.
  let path = state_file_path(slot)
  if path.len == 0: return false
  result = case app.emu_kind
    of ekGBA: app.gba_emu.save_state(path, thumbnail = true)
    of ekGB:  app.gb_emu.save_state(path, thumbnail = true)
    of ekNDS: app.nds.save_state_file(path)
    of ekNone: false
  if result: echo "State saved: ", path

proc load_state_at(path: string): bool =
  # Loading into a linked core would desync the two games. Checked here so
  # every caller (menu, hotkey, Save States window, Resume) gets it.
  if app.netlink != nil:
    last_state_error = ""
    return false
  if path.len == 0: return false
  result = case app.emu_kind
    of ekGBA: app.gba_emu.load_state(path)
    of ekGB:  app.gb_emu.load_state(path)
    of ekNDS: app.nds.load_state_file(path)
    of ekNone: false
  if result:
    echo "State loaded: ", path
    input_log_event("state_load")
    # The ring holds the timeline the load replaced (the web drops it too).
    app.rewind.clear()

proc load_state_slot(slot: int): bool = load_state_at(state_slot_read_path(slot))

proc state_reject_sentence(): string =
  ## One sentence per StateRejectKind, saying what to do about it; never raw
  ## exception text, never two causes on one message.
  if app.netlink != nil:
    return "Save states can't be loaded while the link cable is connected. " &
           "Disconnect first."
  case last_state_reject_kind
  of srkNotAState:
    "That file isn't a dingbat save state."
  of srkWrongCore:
    if app.emu_kind == ekNDS:
      "That save state is for another system: only a DS state loads into a DS game."
    else:
      "That save state is for the other system: a Game Boy state can't load " &
      "into a GBA game, or the reverse."
  of srkWrongRom:
    "That save state belongs to a different game. Load the game it was made " &
    "in, then try again."
  of srkTooNew:
    "That save state was made by a newer version of dingbat than this one. " &
    "Update dingbat and try again."
  of srkTruncated:
    "That save state file is incomplete: the copy or download was cut short."
  of srkCorrupt:
    "That save state is damaged and can't be loaded. The game is still " &
    "running and nothing was changed."
  of srkNoFile:
    # The common one: Quick Load before any Quick Save. Not "damaged".
    "There's no save state in that slot yet."
  of srkIncompatible:
    "That save state was made by another version of dingbat's DS core, or " &
    "with a different BIOS, and can't be loaded here."
  of srkNone:
    "That save state couldn't be loaded."

proc delete_state_slot(slot: int) =
  let rom = current_rom_path()
  if rom.len == 0: return
  for path in state_delete_paths(states_dir(), rom, state_identity(), slot,
                                 state_is_ours, state_prior_identity()):
    try:
      removeFile(path)
      echo "State deleted: ", path
    except CatchableError:
      echo "Delete state failed: ", getCurrentExceptionMsg()

proc refresh_state_slots() =
  ## Decode each slot's thumbnail into a texture for the Save States
  ## widget. Called on window open and after a save, never on the hot path.
  let w = app.save_states
  w.have_rom = app.emu_kind != ekNone
  for i in 0 ..< NUM_SLOTS:
    let path = state_slot_read_path(i)
    if path.len == 0 or not fileExists(path):
      w.set_slot(i, used = false, label = "", tex = 0, tw = 0, th = 0)
      continue
    var label = ""
    try:
      label = getFileInfo(path).lastWriteTime.local.format("MM-dd  HH:mm")
    except CatchableError: discard
    var data = ""
    try: data = readFile(path)
    except CatchableError: discard
    var (tw, th, pixels) = parse_state_thumbnail(data)
    # A black-and-white game's slot in its shade palette, as on screen; an
    # old state's trailer holds the amber four, read the same way.
    if pixels.len > 0 and dmg_shades_on():
      let px = cast[ptr UncheckedArray[uint16]](addr pixels[0])
      for i in 0 ..< pixels.len div 2:
        let v = px[i] and 0x7FFF'u16
        if dmg_shade(v) >= 0 or v in OLD_DMG_COLORS:
          let c = dmg_shade_rgb(v)
          px[i] = (px[i] and 0x8000'u16) or (uint16(c[2] shr 3) shl 10) or
                  (uint16(c[1] shr 3) shl 5) or uint16(c[0] shr 3)
    if pixels.len > 0:
      pr.ui_texture(app.state_slot_texs[i], addr pixels[0], tw, th,
                    bgr555 = true, linear = true)
      w.set_slot(i, used = true, label = label,
                 tex = app.state_slot_texs[i],
                 tw = float32(tw), th = float32(th))
    else:
      # A state without a thumbnail: selectable, no preview.
      w.set_slot(i, used = true, label = label, tex = 0, tw = 0, th = 0)

proc process_pending_state() =
  ## Runs only between frames (after run_until_frame, or while paused), so
  ## the core is at a frame boundary. Quick Save/Load act on slot 0.
  if app.pending_save:
    app.pending_save = false
    if not save_state_slot(0):
      # The write goes to a temp file first, so the slot is as it was.
      app.state_notice = QUICK_SAVE_FAILED
      app.state_notice_hint = last_state_error
    # An open Save States window is showing slot 1 stale now — refresh it
    app.save_states.mark_stale()
  if app.pending_load:
    app.pending_load = false
    if not load_state_slot(0):
      app.state_notice = state_reject_sentence()
      app.state_notice_hint = last_state_error

# ──────────────────────────── The session ────────────────────────────
# Leaving a game (Close Game, another game or a Reset, quitting) takes a
# session snapshot, a save state outside the slots (persist.nim
# session_file_name), after the battery is written, with that battery's
# signature beside it (web `saveSig`). Resume boots the game and loads it,
# so the game is exactly where it was left. A session counts only while the
# battery on disk is that one: once the game has saved since, it would put
# the older save back, so it is never resumed or offered (web
# resumeSessionFor).

proc session_path(): string =
  let rom = current_rom_path()
  if rom.len == 0: "" else: states_dir() / session_file_name(rom, state_identity())

proc session_path_of(g: LibGame): string =
  ## Where a library game's session is; "" for a game not known well enough
  if g.rom.len == 0 or g.identity.len != 8: return ""
  try: states_dir() / session_file_name(g.rom, uint32(parseHexInt(g.identity)))
  except ValueError: ""

proc state_hash(): string =
  ## The running game's whole state, for the GUI driver's tests to compare a
  ## session put back against the one taken
  let payload = case app.emu_kind
    of ekGBA: app.gba_emu.state_payload()
    of ekGB: app.gb_emu.state_payload()
    of ekNDS: app.nds.rewind_payload()
    of ekNone: ""
  fnv1a(payload).toHex(8)

proc battery_path(): string =
  ## The running game's battery file
  case app.emu_kind
  of ekGBA: app.gba_emu.storage.save_path
  of ekGB: app.gb_emu.cartridge.sav_path
  of ekNDS: app.nds.save_path
  of ekNone: ""

proc save_session() =
  ## At a frame boundary, the battery written. A session that cannot be
  ## taken goes: an older one would put back a moment from before this play.
  ## None in a link (frame-synced, as the web's).
  let path = session_path()
  if path.len == 0 or app.netlink != nil: return
  let sig = battery_signature(battery_path())
  var ok = false
  if sig.len > 0:
    ok = case app.emu_kind
      of ekGBA: app.gba_emu.save_state(path, thumbnail = true)
      of ekGB: app.gb_emu.save_state(path, thumbnail = true)
      of ekNDS: app.nds.save_state_file(path)
      of ekNone: false
  if ok:
    try:
      write_file_atomic(session_battery_name(path), sig & "\n")
      echo "Session saved: ", path
      when defined(gui_driver): echo "session hash ", state_hash()
      return
    except CatchableError as e: last_state_error = e.msg
  echo "Session not saved: ", last_state_error
  discard tryRemoveFile(path)
  discard tryRemoveFile(session_battery_name(path))

# ──────────────────────────── Screenshots ────────────────────────────

proc bgr555_to_rgb(px: uint16; correct, gbc: bool): array[3, byte] =
  ## BGR555 to 8-bit RGB. `correct` mirrors FRAG_SRC's colour correction
  ## (AGB model, or CGB with `gbc`) so the PNG matches the screen.
  let r5 = float64(px and 0x1F) / 31.0
  let g5 = float64((px shr 5) and 0x1F) / 31.0
  let b5 = float64((px shr 10) and 0x1F) / 31.0
  if correct and gbc:
    const lum = 0.94
    let r = pow(r5, 2.2) * lum
    let g = pow(g5, 2.2) * lum
    let b = pow(b5, 2.2) * lum
    let mixed = [0.82 * r + 0.240 * g - 0.060 * b,
                 0.125 * r + 0.665 * g + 0.210 * b,
                 0.195 * r + 0.075 * g + 0.730 * b]
    for i in 0 .. 2:
      result[i] = byte(min(255.0, round(pow(max(0.0, min(1.0, mixed[i])), 1.0 / 2.2) * 255.0)))
  elif correct:
    let r = pow(r5, 4.0)
    let g = pow(g5, 4.0)
    let b = pow(b5, 4.0)
    let mixed = [(  0.0 * b +  50.0 * g + 240.0 * r) / 255.0,
                 ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
                 (220.0 * b +  10.0 * g +  50.0 * r) / 255.0]
    for i in 0 .. 2:
      result[i] = byte(min(255.0, round(pow(mixed[i], 1.0 / 2.2) * 255.0)))
  else:
    result[0] = byte(round(r5 * 255.0))
    result[1] = byte(round(g5 * 255.0))
    result[2] = byte(round(b5 * 255.0))

proc screen_rgb(hd = true): (int, int, seq[byte]) =
  ## The frame as shown, 8-bit RGB, colour-corrected when the setting is on.
  ## A DS game's both screens, HD 3D's size only with `hd`.
  if app.emu_kind == ekNone: return (0, 0, @[])
  let border = sgb_border_active()
  let (w, h) = if app.emu_kind == ekNDS:
                 (if hd: app.nds.screen_size() else: (NDS_W, NDS_H))
               else: output_size()
  let correct = app.cfg.color_correction
  let gbc = app.emu_kind == ekGB
  var rgb = newSeq[byte](w * h * 3)
  let shades = dmg_shades_on()
  template put(i: int; v: uint16; corr: bool) =
    let c = if shades and dmg_shade(v) >= 0: dmg_shade_rgb(v)
            else: bgr555_to_rgb(v, corr, gbc)
    rgb[i * 3 + 0] = c[0]
    rgb[i * 3 + 1] = c[1]
    rgb[i * 3 + 2] = c[2]
  template convert(fb: untyped) =
    for i in 0 ..< w * h: put(i, fb[i], correct)
  if border:
    # The shader's composite: backdrop, Game Boy window at (48, 40), opaque
    # border on top. The border is SNES art: no LCD colour correction.
    let s = app.gb_emu
    let bp = cast[ptr UncheckedArray[uint16]](s.sgb_border_ptr())
    let backdrop = s.sgb_backdrop()
    for i in 0 ..< w * h: put(i, backdrop, false)
    for y in 0 ..< GB_H:
      for x in 0 ..< GB_W:
        put((y + 40) * w + (x + 48), s.ppu.framebuffer[y * GB_W + x], correct)
    for i in 0 ..< w * h:
      if (bp[i] and 0x8000'u16) != 0: put(i, bp[i] and 0x7FFF'u16, false)
  else:
    case app.emu_kind
    of ekGBA: convert(app.gba_emu.ppu.framebuffer)
    of ekGB:  convert(app.gb_emu.ppu.framebuffer)
    of ekNDS:
      # Both screens, top above bottom; the DS's own LCDs, so no correction
      var pic: seq[uint16]
      app.nds.compose(pic, hd = hd)
      for i in 0 ..< w * h: put(i, pic[i], false)
    of ekNone: discard
  (w, h, rgb)

proc save_screenshot() =
  ## Write the current frame to config_dir/screenshots/<rom>-<timestamp>.png,
  ## colour-corrected when the setting is on so it matches the screen.
  let (w, h, rgb) = screen_rgb()
  if rgb.len == 0: return
  let dir = config_dir() / "screenshots"
  try:
    createDir(dir)
  except OSError as e:
    echo "Screenshot failed (mkdir): ", e.msg; return
  let rom  = current_rom_path().extractFilename()
  let base = if rom.len > 0: rom.changeFileExt("") else: "screenshot"
  let path = dir / (base & "-" & now().format("yyyyMMdd-HHmmss") & ".png")
  if stbiw.writePNG(path, w, h, 3, rgb):
    echo "Screenshot saved: ", path
  else:
    echo "Screenshot failed: ", path

# ──────────────────────────── The library (home screen) ────────────────────────────

proc library_file(): string = config_dir() / "library.json"
proc pictures_dir(): string = config_dir() / "pictures"

proc probe_game(path: string): LibGame =
  ## A game the library takes in from recents, described without opening
  ## it: a zip by the ROM inside
  result = LibGame(path: path, rom: path.extractFilename(), system: system_of(path))
  if path.splitFile().ext.toLowerAscii() == ".zip":
    let inner = zip_rom_name(config_dir() / "zip-cache", path)
    if inner.len > 0:
      result.rom = inner
      result.system = system_of(inner)
  elif result.system.len == 0 and is_nds_file(path):
    result.system = "DS"

proc save_library() =
  let err = app.library.write_library(library_file())
  if err.len > 0: echo "library: could not save ", library_file(), ": ", err

proc reload_library() =
  ## From the file: another dingbat window may have opened a game since
  let (lib, added) = read_library(library_file(), app.cfg.recents, probe_game)
  app.library = lib
  if added: save_library()
  app.home_stale = true

proc record_played(g: LibGame) =
  app.library = read_library(library_file(), @[]).lib
  app.library.note_played(g)
  save_library()
  let i = app.played_here.find(g.path)
  if i >= 0: app.played_here.delete(i)
  app.played_here.insert(g.path, 0)
  app.home_stale = true

proc remove_from_library(path: string) =
  ## The tile's Remove from Library: from the recents too, or the next
  ## start would take it back in
  app.library = read_library(library_file(), @[]).lib
  app.library.remove(path)
  save_library()
  let i = app.cfg.recents.find(path)
  if i >= 0:
    app.cfg.recents.delete(i)
    save_config(app.cfg)
  app.home_stale = true

proc set_library_sort(sort: string) =
  app.library = read_library(library_file(), app.cfg.recents, probe_game).lib
  app.library.sort = sort
  save_library()
  app.home_stale = true

proc store_last_screen() =
  ## The picture the library shows for the game being left (web
  ## `frame:<game>`): its screen as shown, unless that is all one colour (a
  ## boot's white, a fade), which would stand for nothing.
  let rom = current_rom_path()
  if app.emu_kind == ekNone or rom.len == 0: return
  let (w, h, rgb) = screen_rgb(hd = false)
  if rgb.len < 3: return
  var one_colour = true
  for i in countup(3, rgb.len - 3, 3):
    if rgb[i] != rgb[0] or rgb[i + 1] != rgb[1] or rgb[i + 2] != rgb[2]:
      one_colour = false
      break
  if one_colour: return
  let path = pictures_dir() / picture_name(rom.extractFilename(), state_identity())
  let tmp = path & ".tmp"
  try:
    createDir(pictures_dir())
    if stbiw.writePNG(tmp, w, h, 3, rgb): moveFile(tmp, path)
  except CatchableError as e:
    echo "library: could not store the last screen: ", e.msg

proc load_library_picture(path: string; g: LibGame): Picture =
  ## A tile's picture as RGBA: a last screen (PNG), or a slot's thumbnail,
  ## a black-and-white game's in its shade palette as on screen
  if path.endsWith(".png"):
    try:
      var w, h, comp: int
      let px = stbi.load(path, w, h, comp, stbi.RGBA)
      return Picture(w: w, h: h, rgba: px)
    except CatchableError:
      return
  var data = ""
  try: data = readFile(path)
  except CatchableError: return
  let (tw, th, pixels) = parse_state_thumbnail(data)
  if pixels.len == 0: return
  result = Picture(w: tw, h: th, rgba: newSeq[byte](tw * th * 4))
  let px = cast[ptr UncheckedArray[uint16]](unsafeAddr pixels[0])
  let mono = g.system == "GB"
  for i in 0 ..< tw * th:
    let v = px[i] and 0x7FFF'u16
    let c = if mono and (dmg_shade(v) >= 0 or v in OLD_DMG_COLORS): dmg_shade_rgb(v)
            else: bgr555_to_rgb(v, false, false)
    result.rgba[i * 4] = c[0]
    result.rgba[i * 4 + 1] = c[1]
    result.rgba[i * 4 + 2] = c[2]
    result.rgba[i * 4 + 3] = 255

proc rom_file_identity(rom_path: string): uint32 =
  ## What the cores name a ROM's slot files by, from the file alone: the
  ## whole file's FNV-1a (GB and GBA: state_rom_identity), or a DS game's
  ## header and ARM9 start (nds savestate rom_identity). Raises on a read.
  let data = readFile(rom_path)
  if is_nds_file(rom_path):
    nds_savestate.rom_identity(toOpenArrayByte(data, 0, data.high))
  else: fnv1a(data)

proc rom_file_of(path, rom: string): string =
  ## Where a library game's ROM is read from, its battery beside it: the
  ## file, or a zip's copy in its cache folder
  if path.splitFile().ext.toLowerAscii() == ".zip" and rom.len > 0:
    zip_cache_dir(config_dir() / "zip-cache", path) / rom
  else: path

proc library_session_ok(session: string; g: LibGame): bool =
  session_counts(session, rom_file_of(g.path, g.rom).changeFileExt(".sav"))

proc copy_if_missing(src, dst: string) =
  ## Never over a file already there: that one is the newer game's
  if src == dst or not fileExists(src) or fileExists(dst): return
  try:
    createDir(dst.parentDir)
    copyFile(src, dst)
    echo "Kept for the game's new file: ", dst
  except CatchableError as e:
    echo "Couldn't copy ", src, ": ", e.msg

proc relink_game(old, chosen: string) =
  ## Find the File: the missing game is the chosen file now, if it is the
  ## same game (the library's ROM identity). Its slots, session and picture
  ## are named by ROM file name and identity, and its battery and cheats sit
  ## beside the ROM: under a new name or folder they are copied across,
  ## never over files already there. Another game is refused and changes
  ## nothing.
  app.library = read_library(library_file(), @[]).lib
  let i = app.library.find_game(old)
  if i < 0: return
  let entry = app.library.games[i]
  let name = chosen.extractFilename()
  if not (is_rom_file(chosen) or (app.cfg.ds_beta and is_nds_file(chosen))):
    load_notice(&"{name} isn't a game dingbat can open.", chosen)
    return
  var rom_path = chosen
  if chosen.splitFile().ext.toLowerAscii() == ".zip":
    rom_path = if app.cfg.ds_beta: extract_zip_rom(config_dir() / "zip-cache", chosen, ROM_EXTS_DS)
               else: extract_zip_rom(config_dir() / "zip-cache", chosen)
    if rom_path.len == 0:
      load_notice(&"No game could be read from {name}.", "")
      return
  var identity: uint32
  try: identity = rom_file_identity(rom_path)
  except CatchableError as e:
    load_notice(&"Couldn't read {name}.", e.msg)
    return
  if entry.identity.len == 8 and entry.identity.toUpperAscii() != identity.toHex(8):
    load_notice(&"{name} is a different game from {entry.display_name}, so it " &
                "wasn't put in its place.",
                &"{entry.display_name} keeps its saves and save states for when its " &
                "own file is found. To play this one, add it as a game of its own.")
    return
  let rom = rom_path.extractFilename()
  if entry.rom.len > 0 and entry.rom != rom:
    for slot in 0 ..< NUM_SLOTS:
      copy_if_missing(states_dir() / state_file_name(entry.rom, identity, slot),
                      states_dir() / state_file_name(rom, identity, slot))
    let session = session_file_name(entry.rom, identity)
    copy_if_missing(states_dir() / session, states_dir() / session_file_name(rom, identity))
    copy_if_missing(states_dir() / session_battery_name(session),
                    states_dir() / session_battery_name(session_file_name(rom, identity)))
    copy_if_missing(pictures_dir() / picture_name(entry.rom, identity),
                    pictures_dir() / picture_name(rom, identity))
  # Where the old file's battery was: beside it, or a zip's cache folder
  let old_rom = rom_file_of(old, entry.rom)
  for ext in [".sav", ".cht"]:
    copy_if_missing(old_rom.changeFileExt(ext), rom_path.changeFileExt(ext))
  var system = if is_nds_file(rom_path): "DS" else: system_of(rom)
  if system.len == 0: system = entry.system
  app.library.relink(old, LibGame(path: chosen, rom: rom, system: system,
                                  identity: identity.toHex(8)))
  save_library()
  let r = app.cfg.recents.find(old)
  if r >= 0:
    if chosen in app.cfg.recents: app.cfg.recents.delete(r)
    else: app.cfg.recents[r] = chosen
    save_config(app.cfg)
  let p = app.played_here.find(old)
  if p >= 0: app.played_here[p] = chosen
  echo "Found ", entry.display_name, ": ", chosen
  app.home_stale = true

proc take_find_for(): string =
  ## The game Find the File was for, once: a copy, never app.find_for itself
  ## (a string parameter aliases what it is passed)
  result = move app.find_for
  app.find_for = ""

proc find_file(path: string) =
  ## The missing game's Find the File: a file dialog, in its old folder when
  ## that is still there
  app.find_for = path
  let dir = path.parentDir
  when defined(macosx):
    if native_menu:
      mac_open_panel(app.window,
                     if app.cfg.ds_beta: ROM_DIALOG_EXTS_DS else: ROM_DIALOG_EXTS,
                     if dirExists(dir): dir else: app.cfg.explorer_dir, purpose = "find",
                     message = "Where is " & LibGame(path: path).display_name & " now?")
      return
  app.fe.show_dir(dir)
  app.find_request = true

proc make_home_texture(p: Picture): uint64 =
  pr.ui_texture(result, unsafeAddr p.rgba[0], p.w, p.h, bgr555 = false,
                linear = true, mipmaps = true)

proc free_home_texture(t: uint64) =
  var tex = t
  pr.ui_texture_free(tex)

proc open_game(path: string; how: OpenHow) =
  ## For the main loop, which opens it between frames (`take_open`)
  app.home_open = path
  app.home_how = how

proc home_view(): LibraryView =
  ## Made the first time the home screen draws: a game opened from the
  ## command line never reads the library
  if app.home == nil:
    let v = new_library_view()
    v.logo_tex = app.logo_texture
    v.logo_w = float32(app.logo_w)
    v.logo_h = float32(app.logo_h)
    v.pictures_dir = pictures_dir()
    v.states_dir = states_dir()
    v.load_picture = load_library_picture
    v.make_texture = make_home_texture
    v.free_texture = free_home_texture
    v.on_open = proc(path: string) = open_game(path, ohLibrary)
    v.on_play = proc(path: string) = open_game(path, ohPlay)
    v.on_resume = proc(path: string) = open_game(path, ohResume)
    v.session_ok = library_session_ok
    v.on_find = find_file
    v.on_add = proc() = push_cmd(mcOpenRom)
    v.on_remove = remove_from_library
    v.on_sort = set_library_sort
    app.home = v
    reload_library()
  if app.home_stale or app.home.ds_beta != app.cfg.ds_beta:
    app.home.ds_beta = app.cfg.ds_beta
    app.home.sort = app.library.sort
    app.home.set_games(app.library.shown(app.cfg.recents, app.cfg.ds_beta))
    app.home_stale = false
  let hero = app.library.hero_of(app.played_here, app.cfg.ds_beta)
  app.home.set_hero(hero, session_path_of(hero))
  app.home

# ──────────────────────────── Close Game and Resume ────────────────────────────

proc close_game() =
  ## Back to the home screen, the game heading it (web hero, closed): its
  ## battery written, its session taken, its last screen kept, then the core
  ## gone. A battery that cannot be written keeps the game open: closing
  ## would lose what was saved in it.
  if app.emu_kind == ekNone: return
  # The link ends politely, as on loading another game
  if app.netlink == nil and app.link.setup != lsNone:
    app.link.status = "Link ended: the game was closed."
  link_auto_stop()
  link_cancel_setup()
  teardown_netlink("the game was closed")
  if app.pending_save:
    app.pending_save = false
    if not save_state_slot(0):
      app.state_notice = QUICK_SAVE_FAILED
      app.state_notice_hint = last_state_error
  app.pending_load = false
  app.pending_step = false
  app.rewinding = false
  let (save_file, err) =
    case app.emu_kind
    of ekGBA: (app.gba_emu.storage.save_path, flush_batteries(app.gba_emu, nil))
    of ekGB: (app.gb_emu.cartridge.sav_path, flush_batteries(nil, app.gb_emu))
    of ekNDS: (app.nds.save_path, app.nds.flush())
    of ekNone: ("", "")
  if err.len > 0:
    app.battery.text = CLOSE_BATTERY_FAILED & "\n\n" & save_file
    app.battery.hint = err
    return
  save_session()
  store_last_screen()
  dismiss_game_toasts()
  input_log_close()
  app.gba_emu = nil
  app.gb_emu = nil
  app.nds = nil
  app.emu_kind = ekNone
  audio_close()
  app.dbg = nil
  app.gb_dbg = nil
  # Its windows: the cheats and slots were the game's, the link needs one
  app.cheats.attach(nil, cpGBA)
  app.cheats.window = false
  app.save_states.window = false
  app.save_states.mark_stale()
  app.link_window = false
  app.game_lock.release()
  app.cur_path = ""
  app.paused = false
  app.rewind.clear()
  app.border_shown = false
  lcd_resp.reset()
  frame_ticks = gbx_frame_ticks
  apply_color_correction()
  when defined(macosx):
    if native_menu:
      mac_set_document(app.window, "")
      mac_menu_refresh()
  discard setWindowTitle(app.window, "dingbat")
  app.home_stale = true
  echo "Game closed"

proc resume_game(path: string; quiet = false) =
  ## Boot the game and put its session back before its first frame, where
  ## it still counts against the battery the boot just read. Without one
  ## the game is booted from its save: `quiet` (a tile) just that, as the
  ## web's tile; else (the hero's Resume, which showed only while it
  ## counted) saying so. A session refused (another version, damaged) leaves
  ## the game booted from its save and says why.
  load_rom(path)
  if app.emu_kind == ekNone or app.cur_path != path: return
  let session = session_path()
  if not session_counts(session, battery_path()):
    if not quiet: show_toast("The game has saved since — starting from that save")
    return
  if load_state_at(session):
    echo "Session resumed: ", session
    when defined(gui_driver): echo "resumed hash ", state_hash()
  else:
    app.state_notice = state_reject_sentence()
    app.state_notice_hint = last_state_error

proc offer_session() =
  ## After a boot from the save: the session, offered for a while, where it
  ## still counts (web offerAutoResume, "Last session saved 5m ago")
  let session = session_path()
  if app.emu_kind == ekNone or app.netlink != nil or
     not session_counts(session, battery_path()): return
  let rom = app.cur_path
  show_offer("Last session saved " & session_age(session), "Resume",
             proc() = app.offer_taken = rom)

proc take_offer(rom: string) =
  ## The offer's Resume, between frames: still the game, and the battery as
  ## it has it now still the session's (it may have saved since the offer)
  if app.emu_kind == ekNone or app.cur_path != rom or app.netlink != nil: return
  flush_saves()
  let session = session_path()
  if not session_counts(session, battery_path()):
    show_toast("The game has saved since — that session is gone")
    return
  if load_state_at(session):
    echo "Session resumed: ", session
    when defined(gui_driver): echo "resumed hash ", state_hash()
    show_toast("Resumed")
  else:
    app.state_notice = state_reject_sentence()
    app.state_notice_hint = last_state_error

proc open_file(path: string) =
  ## A file handed in: from its save, the session offered (web handleRomFile)
  load_rom(path)
  if app.cur_path == path: offer_session()

proc take_open() =
  ## What the home screen, a recent or the offer chose, between frames
  if app.offer_taken.len > 0:
    take_offer(move app.offer_taken)
    app.offer_taken = ""
  if app.home_open.len == 0: return
  let path = move app.home_open
  app.home_open = ""
  case app.home_how
  of ohFile: open_file(path)
  of ohPlay: load_rom(path)
  of ohResume: resume_game(path)
  of ohLibrary:
    if app.cfg.library_resume: resume_game(path, quiet = true)
    else: open_file(path)

# ──────────────────────────── Rendering ────────────────────────────

proc upload_frame(fb: ptr uint16; w, h: int) =
  ## Upload the frame through the LCD response model. The model advances once
  ## per uploaded frame (emulated time), so settling is independent of the
  ## display's refresh rate.
  let src = cast[ptr UncheckedArray[uint16]](fb)
  let gb = app.emu_kind == ekGB and app.gb_emu != nil
  # The GBA color-correction shader linearizes with lcdGamma 4.0, so while it
  # is on, the AGB table must be built for that chain (see set_panel).
  lcd_resp.set_panel(app.cfg.lcd_response.resolve(
    gba = app.emu_kind == ekGBA,
    cgb = gb and app.gb_emu.cgb_enabled,
    sgb = gb and app.gb_emu.sgb_active()),
    display_gamma = if app.emu_kind == ekGBA and app.cfg.color_correction: 4.0
                    else: 0.0)
  let upload = cast[pointer](lcd_resp.apply(src, w * h))
  pr.game_upload(0, w, h, upload)

when defined(gputime) and defined(macosx):
  {.error: "-d:gputime times OpenGL, which macOS does not draw with".}
when defined(gputime):
  # Diagnostic, off by default (-d:gputime): GL_TIME_ELAPSED around the game
  # quad, to measure upscale filters at a real window size. Prints median/p90
  # GPU ms every 2 s. Windows and Linux (OpenGL).
  import imguin/glad/gl
  var gpuq: array[8, GLuint]
  var gpuq_init = false
  var gpuq_slot = 0
  var gpu_samples: seq[float]
  var gpu_last_report = getTime()
  var gpu_sweep_step = 0

  proc gpu_begin() =
    if not gpuq_init:
      glGenQueries(GLsizei(gpuq.len), addr gpuq[0])
      gpuq_init = true
    else:
      # harvest the slot we are about to reuse (8 frames of latency)
      var avail: GLint
      glGetQueryObjectiv(gpuq[gpuq_slot], GL_QUERY_RESULT_AVAILABLE, addr avail)
      if avail != 0:
        var ns: GLuint64
        glGetQueryObjectui64v(gpuq[gpuq_slot], GL_QUERY_RESULT, addr ns)
        gpu_samples.add(float(ns) / 1e6)
    glBeginQuery(GL_TIME_ELAPSED, gpuq[gpuq_slot])

  proc gpu_end() =
    glEndQuery(GL_TIME_ELAPSED)
    gpuq_slot = (gpuq_slot + 1) mod gpuq.len
    let now = getTime()
    if (now - gpu_last_report).inMilliseconds >= 2000 and gpu_samples.len > 8:
      gpu_last_report = now
      var v = gpu_samples
      v.sort()
      var w, h: cint
      discard getWindowSizeInPixels(app.window, w, h)
      echo "GPUTIME viewport=", w, "x", h,
           " filter=", $app.cfg.video_filter,
           " colorcorrect=", app.cfg.color_correction,
           " lcdresponse=", $app.cfg.lcd_response,
           " n=", v.len,
           " median_ms=", formatFloat(v[v.len div 2], ffDecimal, 4),
           " p90_ms=", formatFloat(v[(v.len * 9) div 10], ffDecimal, 4),
           " emu_fps=", formatFloat(emu_fps, ffDecimal, 1)
      gpu_samples.setLen(0)
      # DINGBAT_GPUTIME_SWEEP=1 steps through the present-path settings, one
      # per report.
      if getEnv("DINGBAT_GPUTIME_SWEEP") == "1":
        gpu_sweep_step.inc
        case gpu_sweep_step
        of 1: app.cfg.video_filter = vfNone
        of 2: app.cfg.video_filter = vfHq4x
        of 3: app.cfg.video_filter = vfXbr
        of 4: app.cfg.video_filter = vfGrid
        of 5: app.cfg.video_filter = vfSubpixel
        of 6: app.cfg.video_filter = vfNone;   app.cfg.color_correction = false
        of 7: app.cfg.color_correction = true; app.cfg.lcd_response = true
        of 8: app.cfg.lcd_response = false
        else: echo "GPUTIME sweep done"; app.running = false

# A GBA frame changed since the last upload. Unpaced (fast-forward, turbo),
# a changed frame may go unpresented and the next static one would keep the
# old texture on screen
var gba_changed_unuploaded = false

proc note_gba_frame() =
  ## After a GBA frame has run outside a present.
  if not app.gba_emu.ppu.frame_static: gba_changed_unuploaded = true

proc render_game() =
  if app.emu_kind != ekNone:
    # Pushed every present: Settings' Apply has no callback into this module.
    # filter_mode carries only the smoothing filters; grid and subpixel are
    # separate stages.
    let vf = app.cfg.video_filter
    app.look.lcd_grid = vf == vfGrid
    app.look.subpixel = vf == vfSubpixel
    app.look.filter_mode = if vf in {vfHq4x, vfXbr}: ord(vf) else: 0
    app.look.dmg_remap = dmg_shades_on()
    for i, c in DMG_SHADES:
      app.look.dmg_pal[i * 3] = float32(c shr 16) / 255
      app.look.dmg_pal[i * 3 + 1] = float32((c shr 8) and 0xFF) / 255
      app.look.dmg_pal[i * 3 + 2] = float32(c and 0xFF) / 255
  var (vx, vy, vw, vh) = game_viewport()
  case app.emu_kind
  of ekGBA:
    if app.gba_emu == nil: return
    app.look.sgb_border = false
    app.look.scan_height = float32(GBA_H)
    app.look.scan_width = float32(GBA_W)
    # The LCD model needs static frames too, or a settling cell freezes
    if app.cfg.lcd_response or gba_changed_unuploaded or not app.gba_emu.ppu.frame_static:
      upload_frame(addr app.gba_emu.ppu.framebuffer[0], GBA_W, GBA_H)
      gba_changed_unuploaded = false
    when defined(gputime): gpu_begin()
    pr.draw_game(vx, vy, vw, vh, app.look)
    when defined(gputime): gpu_end()
  of ekGB:
    if app.gb_emu == nil: return
    let border = sgb_border_active()
    app.look.sgb_border = border
    # The scanline pitch follows the OUTPUT (224 rows with a border), not the
    # Game Boy texture.
    app.look.scan_height = if border: float32(SGB_BORDER_H) else: float32(GB_H)
    app.look.scan_width = if border: float32(SGB_BORDER_W) else: float32(GB_W)
    if border:
      let bd = app.gb_emu.sgb_backdrop()
      app.look.sgb_backdrop = [float32(float(bd and 0x1F) / 31.0),
                               float32(float((bd shr 5) and 0x1F) / 31.0),
                               float32(float((bd shr 10) and 0x1F) / 31.0)]
      let gen = app.gb_emu.sgb_border_gen()
      if gen != app.border_gen:
        app.border_gen = gen
        pr.border_upload(app.gb_emu.sgb_border_ptr())
    # A border appearing or going changes the picture's size: resize once,
    # on the edge.
    if border != app.border_shown:
      app.border_shown = border
      resize_to_output()
      (vx, vy, vw, vh) = game_viewport()
    upload_frame(addr app.gb_emu.ppu.framebuffer[0], GB_W, GB_H)
    if rumble_on:
      # ±1 window-unit viewport jitter (pixel density and UI scale applied),
      # alternating per present; ImGui renders unshaken.
      rumble_flip = not rumble_flip
      let px = int(max(1.0, round(getWindowPixelDensity(app.window) * ui_scale)))
      let off = if rumble_flip: px else: -px
      pr.draw_game(vx + off, vy - off, vw, vh, app.look)
    else:
      pr.draw_game(vx, vy, vw, vh, app.look)
  of ekNDS:
    if app.nds == nil: return
    app.look.sgb_border = false
    app.look.scan_height = float32(NDS_H)
    app.look.scan_width = float32(NDS_W)
    # HD 3D follows the setting live. The texture is 256k x 384k at scale k;
    # window, viewport and scan_* stay at 1x: HD only sharpens.
    app.nds.set_hd(app.cfg.nds_hd)
    let (tw, th) = app.nds.screen_size()
    if app.nds.hd_scale != app.nds_tex_scale:
      app.nds_tex_scale = app.nds.hd_scale
      pr.game_alloc(tw, th)
      app.look.tex_width = float32(tw)
      app.look.tex_height = float32(th)
    # Top screen above bottom. No LCD response model: it models GB/GBA panels.
    pr.game_upload(0, tw, th div 2, app.nds.top_screen())
    pr.game_upload(th div 2, tw, th div 2, app.nds.bottom_screen())
    pr.draw_game(vx, vy, vw, vh, app.look)
  of ekNone: discard   # the home screen is ImGui's (library_view.nim)

proc show_menu_bar(): bool =
  ## The in-window bar: on the home screen, and over a game while the mouse
  ## is in the window and has moved in the last 3 s (the cursor hides with
  ## it). Never beside the macOS menu bar, though the cursor still hides.
  if app.emu_kind == ekNone: return not native_menu
  var focused    = getMouseFocus() == app.window
  when defined(gui_driver):
    focused = focused or gui_driver.mouse_in
  let mouse_idle = getTicks() - app.last_mouse_tick > 3000'u64
  result = focused and not mouse_idle
  discard (if result: showCursor() else: hideCursor())
  if native_menu: result = false

proc render_link_window()  # defined below, near the network-link procs

proc poll_battery_notice() =
  ## Once per loop: feed the core's battery-write failures to `app.battery`.
  var none = false
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil:
      let st = app.gba_emu.storage
      app.battery.poll(st.save_path, st.save_error, st.save_error_new)
  of ekGB:
    if app.gb_emu != nil:
      let cart = app.gb_emu.cartridge
      app.battery.poll(cart.sav_path, cart.save_error, cart.save_error_new)
  of ekNDS:
    if app.nds != nil:
      app.battery.poll(app.nds.save_path, app.nds.save_error, app.nds.save_error_new)
  of ekNone: app.battery.poll("", "", none)

proc render_state_notice() =
  ## A save state failed. Modal: it always follows a user action.
  render_notice("State##notice", app.state_notice, app.state_notice_hint)

proc render_load_notice() =
  ## A ROM that could not be loaded. After the other notices, never over one:
  ## two modals opened at the same level replace each other every frame.
  if app.state_notice.len > 0 or app.cfg.notice.len > 0: return
  render_notice("Couldn't open the game##notice", app.load_notice, app.load_notice_hint)

proc render_config_notice() =
  ## The settings file was moved aside or could not be written (config.nim).
  ## Never over the state notice.
  if app.state_notice.len > 0: return
  var no_hint = ""
  render_notice("Settings##notice", app.cfg.notice, no_hint)

proc render_battery_notice() =
  ## The battery save can't be written (persist.nim BatteryNotice). Unbidden,
  ## so it waits for the other notices.
  if app.state_notice.len > 0 or app.cfg.notice.len > 0 or
     app.load_notice.len > 0: return
  render_notice("Save file##battery", app.battery.text, app.battery.hint)

when defined(macosx):
  proc mac_notices() =
    ## With the macOS menu bar the notices are alerts on the game's window
    ## (mac_alert.nim), one at a time in render_*_notice's order; OK clears
    ## the notice as the modal's does.
    case mac_alert_take_ok()
    of "State":
      app.state_notice = ""
      app.state_notice_hint = ""
    of "Settings": app.cfg.notice = ""
    of "Game":
      app.load_notice = ""
      app.load_notice_hint = ""
    of "Save file": app.battery.dismiss()
    else: discard
    if app.state_notice.len > 0:
      mac_alert_show(app.window, "State", app.state_notice, app.state_notice_hint)
    elif app.cfg.notice.len > 0:
      mac_alert_show(app.window, "Settings", app.cfg.notice, "")
    elif app.load_notice.len > 0:
      mac_alert_show(app.window, "Game", app.load_notice, app.load_notice_hint)
    elif app.battery.text.len > 0:
      mac_alert_show(app.window, "Save file", app.battery.text, app.battery.hint)
    else:
      mac_alert_show(app.window, "", "", "")

# ──────────────────────────── Menus ────────────────────────────

proc menu_state(cmd: MenuCmd; arg: int): MenuState =
  ## Whether an item can be chosen now, and whether it is ticked: for both
  ## menu bars, the shortcut keys, and AppKit's check before a shortcut fires.
  let game = app.emu_kind != ekNone
  let unlinked = app.netlink == nil
  let gba = app.emu_kind == ekGBA and app.gba_emu != nil
  let gb = app.emu_kind == ekGB and app.gb_emu != nil
  let nds = app.emu_kind == ekNDS and app.nds != nil
  case cmd
  of mcNone, mcOpenRom, mcOpenRecent, mcClearRecents, mcSettings, mcQuit,
     mcHelp, mcReset, mcVolume, mcVolumeDone: (true, false)
  of mcCloseGame: (game, false)
  # The game window's ImGui field being typed in (the Cheats code, the Link
  # Cable address)
  of mcUndo, mcRedo, mcCut, mcCopy, mcPaste, mcSelectAll:
    (app.io != nil and app.io[].WantTextInput, false)
  of mcRecentMenu: (app.cfg.recents.len > 0, false)
  of mcChannelsMenu: (gba or gb, false)
  of mcQuickSave, mcSaveStates, mcScreenshot: (game, false)
  # Loading a save state mid-link would desync the pair
  of mcQuickLoad: (game and unlinked, false)
  of mcPause: (true, app.paused)
  # Frame advance too
  of mcFrameAdvance: (app.paused and game and unlinked, false)
  of mcRewind: (true, app.cfg.rewind)
  # Off while a GBA is linked (it would run ahead of the peer)
  of mcTurbo:
    if gba: (unlinked, app.gba_emu.apu.turbo)
    elif gb: (true, app.gb_emu.apu.turbo)
    elif nds: (true, app.nds.turbo)
    else: (false, false)
  of mcFastForward:
    if gba: (unlinked, not app.gba_emu.apu.sync)
    elif gb: (true, not app.gb_emu.apu.sync)
    elif nds: (true, not app.nds.sync)
    else: (false, false)
  of mcCloseLid: (nds, nds and app.nds.lid_closed)
  of mcCheats: (app.emu_kind in {ekGBA, ekGB}, app.cheats.window)
  of mcLinkCable: (app.emu_kind == ekGBA, app.link_window)
  of mcMute: (true, app.cfg.mute)
  of mcPitchCorrect: (true, app.cfg.pitch_correct_ff)
  of mcAudioInterp: (app.emu_kind == ekGBA, app.cfg.fifo_interp)
  of mcAnalogFilter: (app.emu_kind == ekGBA, app.cfg.audio_lowpass)
  of mcMp2kHle: (true, app.cfg.mp2k_hle)
  # Models of the GBA and GBC panels: not a DS's
  of mcColorCorrection: (app.emu_kind != ekNDS, app.cfg.color_correction)
  of mcChannel:
    if gba and arg in 0 .. 5: (true, app.gba_emu.apu.channel_mask[arg])
    elif gb and arg in 0 .. 3: (true, app.gb_emu.apu.channel_mask[arg])
    else: (false, false)
  of mcFrameSize: (true, arg == app.scale)
  of mcFullscreen: (true, app.fullscreen)
  of mcOverlay: (true, app.enable_overlay)
  of mcGbaDebug: (app.dbg != nil, app.dbg != nil and app.dbg.window_flag(arg)[])
  of mcGbDebug: (app.gb_dbg != nil, app.gb_dbg != nil and app.gb_dbg.window_flag(arg)[])

proc open_rom_dialog() =
  when defined(macosx):
    if native_menu:
      mac_open_panel(app.window,
                     if app.cfg.ds_beta: ROM_DIALOG_EXTS_DS else: ROM_DIALOG_EXTS,
                     app.cfg.explorer_dir)
      return
  app.open_rom_request = true

proc run_menu(cmd: MenuCmd; arg: int) =
  ## A chosen item (or its shortcut key), run by the main loop.
  if not menu_state(cmd, arg).enabled: return
  # 2x Speed stays audio-paced; Fast Forward == not sync (uncapped). Enabling
  # either clears the other (fast forward would dominate 2x).
  template turbo(x: untyped) =
    x.turbo = not x.turbo
    if x.turbo: x.sync = true
  template fast_forward(x: untyped) =
    x.sync = not x.sync
    if not x.sync: x.turbo = false
  template toggle_saved(field: untyped; apply: untyped) =
    app.cfg.field = not app.cfg.field
    apply
    save_config(app.cfg)
  case cmd
  of mcNone, mcRecentMenu, mcChannelsMenu: discard
  of mcOpenRom: open_rom_dialog()
  of mcOpenRecent:
    if arg in 0 ..< app.cfg.recents.len: open_game(app.cfg.recents[arg], ohLibrary)
  of mcClearRecents:
    app.cfg.recents.setLen(0)
    save_config(app.cfg)
    when defined(macosx):
      if native_menu: mac_clear_recents()
  of mcQuickSave: app.pending_save = true
  of mcQuickLoad: app.pending_load = true
  of mcSaveStates: app.save_states.window = true
  of mcScreenshot: save_screenshot()
  of mcCloseGame:
    # Settings (or a panel) in front: Cmd+W is its close, as in any Mac app
    when defined(macosx):
      if native_menu and mac_close_key_window(): return
    close_game()
  of mcSettings:
    when defined(macosx):
      if app.ce.native:
        mac_settings_show()
        return
    app.ce.open = true
  of mcUndo, mcRedo, mcCut, mcCopy, mcPaste, mcSelectAll:
    # The field's own shortcut, as ImGui reads it (Cmd: io.ConfigMacOSXBehaviors)
    let key = case cmd
              of mcUndo, mcRedo: ImGui_Key_Z
              of mcCut: ImGui_Key_X
              of mcCopy: ImGui_Key_C
              of mcPaste: ImGui_Key_V
              else: ImGui_Key_A
    var mods = @[ImGui_Mod_Super]
    if cmd == mcRedo: mods.add ImGui_Mod_Shift
    for m in mods: ImGuiIO_AddKeyEvent(app.io, m, true)
    ImGuiIO_AddKeyEvent(app.io, key, true)
    ImGuiIO_AddKeyEvent(app.io, key, false)
    for m in mods: ImGuiIO_AddKeyEvent(app.io, m, false)
  of mcQuit: app.running = false
  of mcHelp: discard openURL(HELP_URL)
  of mcReset: reset_game()
  of mcPause: app.paused = not app.paused
  of mcFrameAdvance: app.pending_step = true
  of mcRewind:
    app.cfg.rewind = not app.cfg.rewind
    if not app.cfg.rewind: app.rewind.clear()  # free the history
    save_config(app.cfg)
  of mcTurbo:
    case app.emu_kind
    of ekGBA: turbo(app.gba_emu.apu)
    of ekGB: turbo(app.gb_emu.apu)
    of ekNDS: turbo(app.nds)
    of ekNone: discard
  of mcFastForward:
    case app.emu_kind
    of ekGBA: fast_forward(app.gba_emu.apu)
    of ekGB: fast_forward(app.gb_emu.apu)
    of ekNDS: fast_forward(app.nds)
    of ekNone: discard
  # The hinge: closed, a game typically sleeps until it opens
  of mcCloseLid: app.nds.set_lid(not app.nds.lid_closed)
  of mcCheats: app.cheats.window = not app.cheats.window
  of mcLinkCable: app.link_window = not app.link_window
  of mcVolume, mcVolumeDone:
    app.cfg.volume = clamp(arg, 0, 100)
    apply_master_volume()
    # Persist once the slider is let go, not every step of the drag
    if cmd == mcVolumeDone: save_config(app.cfg)
  of mcMute: toggle_saved(mute, apply_master_volume())
  # WSOLA time-stretch keeps 2x audio at normal pitch
  of mcPitchCorrect: toggle_saved(pitch_correct_ff, apply_pitch_correct_ff())
  # ON: reconstructs the waveform between FIFO samples. OFF: bit-true GBA
  # DAC output, grit included.
  of mcAudioInterp: toggle_saved(fifo_interp, apply_fifo_interp())
  # Pair with interpolation off for the closest real-hardware sound
  of mcAnalogFilter: toggle_saved(audio_lowpass, apply_audio_lowpass())
  # When engaged (per-game detection), supersedes interpolation for the
  # music stream
  of mcMp2kHle: toggle_saved(mp2k_hle, apply_mp2k_hle())
  of mcColorCorrection: toggle_saved(color_correction, apply_color_correction())
  of mcChannel:
    if app.emu_kind == ekGBA:
      app.gba_emu.apu.channel_mask[arg] = not app.gba_emu.apu.channel_mask[arg]
    else:
      app.gb_emu.apu.channel_mask[arg] = not app.gb_emu.apu.channel_mask[arg]
  of mcFrameSize:
    app.scale = arg
    app.cfg.frame_size = arg
    if app.emu_kind != ekNone: resize_to_output()
    save_config(app.cfg)
  of mcFullscreen: set_fullscreen(not app.fullscreen)
  of mcOverlay: app.enable_overlay = not app.enable_overlay
  of mcGbaDebug:
    let f = app.dbg.window_flag(arg)
    f[] = not f[]
  of mcGbDebug:
    let f = app.gb_dbg.window_flag(arg)
    f[] = not f[]

proc menu_bar(native: bool): seq[MenuItem] =
  ## Both bars' menus. The macOS bar (`native`) adds the app, Window and Help
  ## menus, moves Settings and Quit into the app menu, and shows file names
  ## in Open Recent, as Mac apps do. Titles spell "..." (mac_menu.m draws it
  ## as one "…", and `menu pick` paths name it so).
  var recent: seq[MenuItem]
  for i, r in app.cfg.recents:
    recent.add action(if native: extractFilename(r) else: r, mcOpenRecent, i)
  recent.add separator()
  recent.add action(if native: "Clear Menu" else: "Clear", mcClearRecents)
  # One name for it everywhere, the home screen's button's and the web's
  var file = @[
    action(if native: "Add a Game..." else: "Add a game", mcOpenRom,
           key = if native: "o" else: ""),
    submenu(if native: "Open Recent" else: "Recent", recent, mcRecentMenu),
    separator(),
    action("Quick Save", mcQuickSave, key = "s"),
    action("Quick Load", mcQuickLoad, key = "l"),
    action("Save States...", mcSaveStates),
    (if native: action("Screenshot", mcScreenshot, shown = skF12)
     else: action("Screenshot  F12", mcScreenshot)),
    separator()]
  # Cmd/Ctrl+W closes the game; with none, on macOS, it closes the window
  if native:
    if app.emu_kind != ekNone:
      file.add action("Close Game", mcCloseGame, key = "w")
      file.add system("Close Window", "performClose:", key = "w", shift = true)
    else:
      file.add system("Close Window", "performClose:", key = "w")
  else:
    file.add action("Close Game", mcCloseGame, key = "w")
    file.add action("Settings", mcSettings)
    file.add separator()
    file.add action("Exit", mcQuit, key = "q")

  var emu = @[
    action("Reset", mcReset, key = "r"),
    action("Pause", mcPause, key = "p"),
    action("Frame Advance", mcFrameAdvance, key = "n"),
    action("Rewind (hold `)", mcRewind)]
  if (app.emu_kind == ekGBA and app.gba_emu != nil) or
     (app.emu_kind == ekGB and app.gb_emu != nil) or
     (app.emu_kind == ekNDS and app.nds != nil):
    emu.add action("2x Speed", mcTurbo, hint = "Shift+Tab", shown = skShiftTab)
    emu.add action("Fast Forward", mcFastForward, hint = "Tab", shown = skTab)
  if app.emu_kind == ekNDS and app.nds != nil:
    emu.add separator()
    emu.add action("Close Lid", mcCloseLid)
  emu.add separator()
  emu.add action("Cheats", mcCheats)
  emu.add action("Link Cable...", mcLinkCable)

  var channels: seq[MenuItem]
  if app.emu_kind == ekGBA and app.gba_emu != nil:
    for i, n in ["PSG1", "PSG2", "PSG3", "PSG4", "DMA-A", "DMA-B"]:
      channels.add action(n, mcChannel, i, hint = $(i + 1))
  elif app.emu_kind == ekGB and app.gb_emu != nil:
    for i, n in ["Pulse 1", "Pulse 2", "Wave", "Noise"]:
      channels.add action(n, mcChannel, i, hint = $(i + 1))
  var sizes: seq[MenuItem]
  for s in 1 .. 8: sizes.add action($s & "x", mcFrameSize, s)
  sizes.add separator()
  sizes.add action("Fullscreen", mcFullscreen, key = "f")
  let av = @[
    slider("Volume", mcVolume, mcVolumeDone, app.cfg.volume, 0, 100),
    action("Mute", mcMute),
    action("Pitch-correct fast-forward", mcPitchCorrect),
    action("Audio interpolation", mcAudioInterp),
    action("Analog filter", mcAnalogFilter),
    action("Enhanced music synthesis (HLE)", mcMp2kHle),
    separator(),
    action("LCD Color Correction", mcColorCorrection),
    submenu("Channels", channels, mcChannelsMenu),
    separator(),
    submenu("Frame size", sizes)]

  var debug = @[action("Overlay", mcOverlay), separator()]
  if app.dbg != nil:
    for i, t in GBA_DEBUG_WINDOWS: debug.add action(t, mcGbaDebug, i)
  if app.gb_dbg != nil:
    for i, t in GB_DEBUG_WINDOWS: debug.add action(t, mcGbDebug, i)

  if native:
    result.add submenu("dingbat", @[
      system("About dingbat", "about"),
      separator(),
      action("Settings...", mcSettings, key = ","),
      separator(),
      system("Services", "services"),
      separator(),
      system("Hide dingbat", "hide:", key = "h"),
      system("Hide Others", "hideOtherApplications:", key = "h", alt = true),
      system("Show All", "unhideAllApplications:"),
      separator(),
      action("Quit dingbat", mcQuit, key = "q")])
  result.add submenu("File", file)
  if native:
    result.add submenu("Edit", @[
      edit("Undo", mcUndo, "undo:", "z"),
      edit("Redo", mcRedo, "redo:", "z", shift = true),
      separator(),
      edit("Cut", mcCut, "cut:", "x"),
      edit("Copy", mcCopy, "copy:", "c"),
      edit("Paste", mcPaste, "paste:", "v"),
      edit("Select All", mcSelectAll, "selectAll:", "a")])
  result.add submenu("Emulation", emu)
  result.add submenu("Audio/Video", av)
  result.add submenu("Debug", debug)
  if native:
    result.add submenu("Window", @[
      system("Minimize", "performMiniaturize:", key = "m"),
      system("Zoom", "performZoom:"),
      separator(),
      system("Bring All to Front", "arrangeInFront:")])
    result.add submenu("Help", @[action("dingbat Help", mcHelp)])
  result.apply_state(menu_state)

proc run_menu_cmds() =
  ## Items chosen since the last iteration, and the Open panel's choice.
  for (cmd, arg) in take_cmds(): run_menu(cmd, arg)
  when defined(macosx):
    let (purpose, path) = mac_take_opened()
    if path.len > 0:
      app.cfg.explorer_dir = parentDir(path)  # the panel opens there next time
      if purpose == "find": relink_game(take_find_for(), path)
      else: open_game(path, ohFile)
    elif purpose == "find": app.find_for = ""

var frames_run = 0  # frames emulated (the GUI driver's `link`)
var imgui_skipped = false  # the last render_imgui returned before igNewFrame

proc render_imgui() =
  # Skip the ImGui pass when no UI is visible: uncapped, the empty
  # NewFrame/Render pair costs real throughput. The home screen always renders.
  let menu_visible = show_menu_bar()
  if app.emu_kind != ekNone and not app.paused and not app.rewinding and
     not menu_visible and not app.enable_overlay and
     not app.fe.open and not (app.ce.open and not app.ce.native) and
     (app.dbg == nil or not app.dbg.any_window_open) and
     (app.gb_dbg == nil or not app.gb_dbg.any_window_open) and
     not app.link_window and not app.cheats.window and
     not app.save_states.window and not app.drag_hover and
     not app.open_rom_request and not app.find_request and not toasts_up() and
     # A notice must still draw with the menu bar idle-hidden (Quick Load
     # key); with the macOS menu bar it is an alert (mac_notices)
     (native_menu or app.state_notice.len == 0 and app.cfg.notice.len == 0 and
      app.load_notice.len == 0 and app.battery.text.len == 0):
    # Only igNewFrame drains ImGui's input queue, a few events a frame, so a
    # long keyboard-only session would leave a backlog the menu waits behind.
    # Drop it, and clear held keys (a release may be among what is dropped).
    # Nothing shows, so nothing captures: the flags igNewFrame set while a
    # modal or field was up would otherwise keep keys from the game.
    if app.io != nil:
      if not imgui_skipped:
        ImGuiIO_ClearInputKeys(app.io)
        ImGuiIO_ClearInputMouse(app.io)
      ImGuiIO_ClearEventsQueue(app.io)
      app.io[].WantCaptureKeyboard = false
      app.io[].WantCaptureMouse = false
      app.io[].WantTextInput = false
    imgui_skipped = true
    return
  imgui_skipped = false

  pr.imgui_new_frame()
  ImGui_ImplSDL3_NewFrame()
  igNewFrame()

  var overlay_h: cfloat = ui_px(10)

  if menu_visible:
    overlay_h += render_menu_bar(menu_bar(native = false), MOD_KEY_STR)

  # Under every window, so drawn first
  if app.emu_kind == ekNone:
    home_view().draw(if app.cfg.ds_beta: ".gba, .gb, .gbc, .nds or a .zip"
                     else: ".gba, .gb, .gbc or a .zip")

  app.fe.render("ROM", app.open_rom_request,
                if app.cfg.ds_beta: ROM_DIALOG_EXTS_DS else: ROM_DIALOG_EXTS,
                proc(path: string) = open_game(path, ohFile))
  app.open_rom_request = false
  app.fe.render("Find the File", app.find_request,
                if app.cfg.ds_beta: ROM_DIALOG_EXTS_DS else: ROM_DIALOG_EXTS,
                proc(path: string) = relink_game(take_find_for(), path))
  app.find_request = false

  if not native_menu:   # else alerts (mac_notices)
    render_state_notice()
    render_config_notice()
    render_load_notice()
    render_battery_notice()

  app.ce.render()

  if app.enable_overlay:
    igSetNextWindowPos(ImVec2(x: ui_px(10), y: overlay_h), cint(ImGui_Cond_Always),
                       ImVec2(x: 0, y: 0))
    igSetNextWindowBgAlpha(0.5'f32)
    let ov_flags = cint(ImGui_WindowFlags_NoDecoration) or
                   cint(ImGui_WindowFlags_NoMove) or
                   cint(ImGui_WindowFlags_NoSavedSettings)
    if igBegin("##overlay", addr app.enable_overlay, ov_flags):
      push_font(fMono, MONO_PX)   # its numbers lined up
      let fps = app.io[].Framerate
      igText("UI FPS:     %.1f", fps)
      igText("Frame time: %.3f ms", 1000.0'f32 / fps)
      igText("Emulation:  %.1f fps", cfloat(emu_fps))
      if app.emu_kind == ekGBA and app.gba_emu != nil and
         app.gba_emu.apu != nil:
        # GB's APU has no queued-bytes getter, so this is GBA-only
        igText("Audio queue: %u bytes", cuint(app.gba_emu.apu.audio_queued_bytes()))
      if app.cfg.rewind and app.emu_kind != ekNone:
        igText("Rewind: %d snapshots, %.1f MB", cint(app.rewind.len),
               cdouble(app.rewind.mem_used()) / (1024.0 * 1024.0))
      igSeparator()
      for line in pr.info(): igTextUnformatted(cstring(line), nil)
      igPopFont()
    igEnd()

  if app.dbg != nil:
    app.dbg.render_windows()
  if app.gb_dbg != nil:
    app.gb_dbg.render_windows()
  app.cheats.render()
  # load_state_slot fails while linked; the window says so up front.
  app.save_states.load_blocked =
    if app.netlink != nil: "Loading is paused while linked." else: ""
  app.save_states.render()

  render_link_window()

  let rom_types = if app.cfg.ds_beta: ".gba, .gb, .gbc, .nds, .zip"
                  else: ".gba, .gb, .gbc, .zip"
  # A file dragged over the window: say what letting go does. SDL reports
  # the hover on macOS, X11 and Wayland; Windows only reports the drop.
  if app.drag_hover:
    let vp = igGetMainViewport()
    if vp != nil:
      igSetNextWindowPos(vp[].Pos, cint(ImGui_Cond_Always), ImVec2(x: 0, y: 0))
      igSetNextWindowSize(vp[].Size, cint(ImGui_Cond_Always))
      igSetNextWindowBgAlpha(0.85'f32)
      let drop_flags = cint(ImGui_WindowFlags_NoDecoration) or
                       cint(ImGui_WindowFlags_NoMove) or
                       cint(ImGui_WindowFlags_NoInputs) or
                       cint(ImGui_WindowFlags_NoSavedSettings)
      if igBegin("##drop_target", nil, drop_flags):
        # A drop zone's outline, inset from the window's edges
        let inset = ui_px(16)
        let (p0, p1) = (ImVec2(x: vp[].Pos.x + inset, y: vp[].Pos.y + inset),
                        ImVec2(x: vp[].Pos.x + vp[].Size.x - inset,
                               y: vp[].Pos.y + vp[].Size.y - inset))
        let dl = igGetWindowDrawList()
        let (rounding, thick) = (ui_px(12), ui_px(3))
        when compiles(ImDrawList_AddRect(dl, p0, p1, 0x99FFFFFF'u32, rounding, 0, thick)):
          ImDrawList_AddRect(dl, p0, p1, 0x99FFFFFF'u32, rounding, 0, thick)
        else:
          ImDrawList_AddRect(dl, p0, p1, 0x99FFFFFF'u32, rounding, thick, 0)
        let title = "Release to load"
        push_font(fBold, 28)
        let t_size = calc_text_size(title)
        let t_h = igGetTextLineHeightWithSpacing()
        igPopFont()
        let d_size = calc_text_size(rom_types)
        let top = (vp[].Size.y - t_h - d_size.y) * 0.5'f32
        igSetCursorPos(ImVec2(x: (vp[].Size.x - t_size.x) * 0.5'f32, y: top))
        with_font(fBold, 28):
          igTextUnformatted(cstring(title), nil)
        igSetCursorPos(ImVec2(x: (vp[].Size.x - d_size.x) * 0.5'f32, y: top + t_h))
        igTextDisabled(cstring(rom_types))
      igEnd()

  # Without it a paused game with the menu bar hidden looks frozen
  if (app.paused or app.rewinding) and app.emu_kind != ekNone:
    let vp = igGetMainViewport()
    if vp != nil:
      let (vpos, vsize) = (vp[].Pos, vp[].Size)
      igSetNextWindowPos(ImVec2(x: vpos.x + vsize.x - ui_px(10),
                                y: vpos.y + overlay_h + ui_px(4)),
                         cint(ImGui_Cond_Always), ImVec2(x: 1.0, y: 0.0))
      igSetNextWindowBgAlpha(0.5'f32)
      let badge_flags = cint(ImGui_WindowFlags_NoDecoration) or
                        cint(ImGui_WindowFlags_NoMove) or
                        cint(ImGui_WindowFlags_NoInputs) or
                        cint(ImGui_WindowFlags_NoSavedSettings)
      if igBegin("##paused_badge", nil, badge_flags):
        igText(if app.rewinding: cstring"<< Rewinding" else: cstring"Paused")
      igEnd()

  draw_toasts()
  igRender()
  pr.imgui_render(igGetDrawData())

# ──────────────────────────── Controllers ────────────────────────────

# Open gamepads by joystick instance id. SDL emits EVENT_GAMEPAD_ADDED for
# pads attached at init, so hotplug covers startup. Every pad is player 1.
var controllers: Table[JoystickID, Gamepad]

# Left-stick-as-dpad and right-trigger fast-forward thresholds (not rebindable)
const STICK_DEADZONE     = 8000'i16
const TRIGGER_THRESHOLD  = 8000'i16

# What the keyboard, each pad and each pad's stick hold, merged for the core
# (frontend/held_input.nim)
var held: HeldInput

# What a key binds to the DS's X and Y outside a DS game: nothing
var no_ds_keys: Table[cint, DsInput]

proc emu_pad_input(inp: Input; pressed: bool) =
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil: app.gba_emu.handle_input(inp, pressed)
  of ekGB:
    if app.gb_emu != nil: app.gb_emu.handle_input(inp, pressed)
  of ekNDS:
    if app.nds != nil: app.nds.press(inp, pressed)
  of ekNone: discard

proc push_held_input() =
  ## Tell the core what changed in the merged held state
  let (pressed, released) = held.take_changes()
  for inp in released: emu_pad_input(inp, false)
  for inp in pressed: emu_pad_input(inp, true)
  if app.emu_kind == ekNDS and app.nds != nil:
    let (ds_pressed, ds_released) = held.take_ds_changes()
    for inp in ds_released: app.nds.press(inp, false)
    for inp in ds_pressed: app.nds.press(inp, true)

proc apply_trigger() =
  ## The right trigger's fast forward, onto the running core's speed toggles
  template onto(apu: untyped) =
    var speed = Speed(sync: apu.sync, turbo: apu.turbo)
    held.apply_trigger(speed, linked = app.netlink != nil)
    apu.sync = speed.sync
    apu.turbo = speed.turbo
  case app.emu_kind
  of ekGBA:
    if app.gba_emu != nil: onto(app.gba_emu.apu)
  of ekGB:
    if app.gb_emu != nil: onto(app.gb_emu.apu)
  of ekNDS:
    if app.nds != nil: onto(app.nds)
  of ekNone: discard

proc new_core_takes_held_input() =
  ## A fresh core holds nothing: press what the player still holds, and
  ## fast-forward again under a trigger still pulled
  held.core_replaced()
  push_held_input()
  apply_trigger()

proc update_rumble() =
  ## 80 ms effects re-triggered every 50 ms make a continuous buzz; an
  ## explicit stop on the off edge keeps short pulses crisp.
  let was_on = rumble_on
  let motor_on =
    case app.emu_kind
    of ekGB:  app.gb_emu != nil and app.gb_emu.cartridge.mbc_rumble()
    of ekGBA: app.gba_emu != nil and app.gba_emu.bus.gpio.gpio_rumble()
    of ekNDS, ekNone: false
  rumble_on = app.cfg.gb_rumble and not app.paused and motor_on
  if rumble_on:
    let now = getTicks()
    if now - rumble_last_pulse >= 50:
      rumble_last_pulse = now
      for pad in controllers.values:
        # 0.6 strong (low-freq) / 0.4 weak (high-freq), matching the web UI
        discard pad.rumbleGamepad(0x9999'u16, 0x6666'u16, 80)
  elif was_on:
    for pad in controllers.values:
      discard pad.rumbleGamepad(0, 0, 0)

# ──────────────────────────── Input ────────────────────────────

proc open_dropped(path: string) =
  ## A file dropped on the window: a ROM or a zip loads (a DS game too with
  ## DS Beta on), anything else is ignored
  if is_rom_file(path) or (app.cfg.ds_beta and is_nds_file(path)):
    open_game(path, ohFile)

proc nds_view_top_left(): (int, int, int, int) =
  ## The picture's rect in window units, top-left origin, for the stylus
  ## (game_viewport's is GL's: bottom-up, in pixels).
  var ww, wh: cint
  discard getWindowSize(app.window, ww, wh)
  let (vx, vy, vw, vh) = letterbox(ww, wh)
  (int(vx), int(wh) - int(vy) - int(vh), int(vw), int(vh))

proc settings_capturing_keys(): bool =
  ## A Keybindings capture takes this window's keys. The native Settings
  ## window takes its own while it has the keyboard (mac_settings.m).
  result = app.ce.capturing_keys()
  when defined(macosx):
    if app.ce.native and mac_settings_has_keyboard(): result = false

proc handle_input() =
  when defined(gui_driver):
    # A pushed drop event can't carry its path through SDL's event memory,
    # so the driver hands it over here.
    if gui_driver.dropped.len > 0:
      let path = gui_driver.dropped
      gui_driver.dropped = ""
      open_dropped(path)
  var evt: Event
  while pollEvent(evt):
    discard ImGui_ImplSDL3_ProcessEvent(addr evt)

    case evt.type
    of EVENT_KEY_DOWN, EVENT_KEY_UP:
      let pressed = evt.key.down
      let kev     = evt.key
      # The unmodified key: SDL 3's event keycode is shifted (Shift or Caps
      # Lock turn 'z' into 'Z'), which no binding names
      let sym     = if kev.scancode == SCANCODE_UNKNOWN: cint(kev.key)
                    else: cint(getKeyFromScancode(kev.scancode, 0, true))
      let mods    = uint32(kev.mod)

      # Releases are applied before any of these filters (held_input.nim)
      let route = held.route_key(app.cfg.keybindings, sym, pressed, kev.repeat,
                                 shortcut_mod = (mods and MOD_KEY_MASK) != 0,
                                 imgui_keyboard = app.io != nil and
                                                  app.io[].WantCaptureKeyboard,
                                 capturing = settings_capturing_keys(),
                                 ds_bindings = if app.emu_kind == ekNDS:
                                                 app.cfg.nds_keybindings
                                               else: no_ds_keys)
      push_held_input()
      case route
      of krNone: discard
      of krCapture:
        app.ce.keybindings.key_released(sym)
      of krShortcut:
        # The menus' own commands, guarded as their items are. On macOS the
        # menu bar takes Cmd shortcuts itself (mac_menu.nim).
        let cmd = case sym
                  of cint(SDLK_R): mcReset
                  of cint(SDLK_P): mcPause
                  of cint(SDLK_N): mcFrameAdvance
                  of cint(SDLK_S): mcQuickSave
                  of cint(SDLK_L): mcQuickLoad
                  of cint(SDLK_F): mcFullscreen
                  of cint(SDLK_W): mcCloseGame
                  of cint(SDLK_Q): mcQuit
                  else: mcNone
        if cmd != mcNone and not native_menu: run_menu(cmd, 0)
      of krMark:
        # input log: mark this screen as a checkpoint
        input_log_mark()
      of krScreenshot:
        save_screenshot()
      of krRewind:
        # Hold-to-rewind (off while linked: it desyncs)
        app.rewinding = pressed and app.cfg.rewind and
                        app.emu_kind != ekNone and app.netlink == nil
      of krFastForward:
        # Shift+Tab = 2x, Tab = unbounded; mutually exclusive
        template toggle(apu: untyped) =
          if (mods and KMOD_SHIFT) != 0:
            apu.turbo = not apu.turbo
            if apu.turbo: apu.sync = true
          else:
            apu.sync = not apu.sync
            if not apu.sync: apu.turbo = false
        # Off while linked (would run ahead of the peer)
        if app.emu_kind == ekGBA and app.gba_emu != nil and app.netlink == nil:
          toggle(app.gba_emu.apu)
        elif app.emu_kind == ekGB and app.gb_emu != nil:
          toggle(app.gb_emu.apu)
        elif app.emu_kind == ekNDS and app.nds != nil:
          toggle(app.nds)
      of krChannel:
        # Feedback is visible in the Audio/Video > Channels submenu
        let ch = int(sym) - int(SDLK_1)
        if app.emu_kind == ekGBA and app.gba_emu != nil:
          app.gba_emu.apu.channel_mask[ch] = not app.gba_emu.apu.channel_mask[ch]
        elif app.emu_kind == ekGB and app.gb_emu != nil and ch < 4:
          app.gb_emu.apu.channel_mask[ch] = not app.gb_emu.apu.channel_mask[ch]

    of EVENT_GAMEPAD_ADDED:
      let id = evt.gdevice.which
      if not controllers.hasKey(id):
        let pad = openGamepad(id)
        if pad != nil:
          controllers[id] = pad
          held.pad_added(int32(id))

    of EVENT_GAMEPAD_REMOVED:
      let id = evt.gdevice.which
      if controllers.hasKey(id):
        closeGamepad(controllers[id])
        controllers.del(id)
      # Unplugged mid-press: let go of what this pad held, and only that
      held.pad_removed(int32(id))
      push_held_input()
      apply_trigger()

    of EVENT_GAMEPAD_BUTTON_DOWN, EVENT_GAMEPAD_BUTTON_UP:
      let pressed = evt.gbutton.down
      let button  = cint(evt.gbutton.button)
      let pad     = int32(evt.gbutton.which)
      if pressed and app.emu_kind == ekNDS and
         app.cfg.nds_controller_bindings.hasKey(button):
        # A DS game's X or Y, ahead of the button's GB/GBA input
        held.pad_ds_button(pad, button,
                           app.cfg.nds_controller_bindings[button], true)
      else:
        let bound   = app.cfg.controller_bindings.hasKey(button)
        held.pad_button(pad, button, bound,
                        if bound: app.cfg.controller_bindings[button] else: Input.low,
                        pressed)
        if not pressed: held.pad_ds_button(pad, button, dsX, false)
      push_held_input()
      if not pressed and app.ce.capturing_buttons():
        app.ce.controller.button_released(button)

    of EVENT_GAMEPAD_AXIS_MOTION:
      let ax = evt.gaxis
      let pad = int32(ax.which)
      if ax.axis == uint8(GAMEPAD_AXIS_LEFTX):
        held.pad_stick(pad, Input.LEFT,  ax.value < -STICK_DEADZONE)
        held.pad_stick(pad, Input.RIGHT, ax.value > STICK_DEADZONE)
      elif ax.axis == uint8(GAMEPAD_AXIS_LEFTY):
        held.pad_stick(pad, Input.UP,   ax.value < -STICK_DEADZONE)
        held.pad_stick(pad, Input.DOWN, ax.value > STICK_DEADZONE)
      elif ax.axis == uint8(GAMEPAD_AXIS_RIGHT_TRIGGER):
        held.pad_trigger(pad, ax.value > TRIGGER_THRESHOLD)
      push_held_input()
      apply_trigger()

    of EVENT_WINDOW_RESIZED, EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      # Each present takes the back buffer's size afresh (pr.begin): a move
      # between 1x and Retina changes only that. ImGui follows by itself.
      if evt.type == EVENT_WINDOW_RESIZED: track_fullscreen()

    of EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
      # SDL keeps a Windows or X11 window's size in pixels, so rescale the
      # menus and resize the window for the new scale. On macOS the UI scale
      # stays 1 and nothing changes.
      let s = display_ui_scale(app.window)
      if s != ui_scale:
        apply_ui_scale(s)
        resize_to_output()

    of EVENT_WINDOW_ENTER_FULLSCREEN, EVENT_WINDOW_LEAVE_FULLSCREEN:
      # Sent once the transition is over (macOS animates Spaces)
      track_fullscreen()

    of EVENT_WINDOW_FOCUS_GAINED:
      # Back at the home screen: another window may have played since
      if app.emu_kind == ekNone and app.home != nil: reload_library()

    of EVENT_MOUSE_MOTION:
      app.last_mouse_tick = getTicks()
      # The stylus follows the mouse while down, clamped to the bottom screen
      if app.emu_kind == ekNDS and app.nds != nil and app.nds.stylus:
        let t = touch_point(int(evt.motion.x), int(evt.motion.y),
                            nds_view_top_left())
        app.nds.set_touch(t.x, t.y, true)

    of EVENT_MOUSE_BUTTON_DOWN:
      # Stylus: a left click on the bottom screen, not on ImGui
      if app.emu_kind == ekNDS and app.nds != nil and
         evt.button.button == BUTTON_LEFT and
         not (app.io != nil and app.io[].WantCaptureMouse):
        let t = touch_point(int(evt.button.x), int(evt.button.y),
                            nds_view_top_left())
        if t.bottom: app.nds.set_touch(t.x, t.y, true)

    of EVENT_MOUSE_BUTTON_UP:
      if app.emu_kind == ekNDS and app.nds != nil and app.nds.stylus and
         evt.button.button == BUTTON_LEFT:
        app.nds.lift_stylus()

    of EVENT_DROP_POSITION:
      app.drag_hover = true

    of EVENT_DROP_COMPLETE:   # dropped, or dragged back out
      app.drag_hover = false

    of EVENT_DROP_FILE:
      open_dropped($evt.drop.data)   # SDL owns the string

    of EVENT_QUIT:
      app.running = false

    else: discard
  when defined(macosx): mac_scroll_feed()

# ──────────────────────────── FPS Title ────────────────────────────

var fps_frames    = 0
var fps_us        = 0'i64
var fps_last_time = getTime()
var fps_second    = getTime().toUnix() mod 60

proc update_fps_title(emulated: bool) =
  # Count emulated frames only: the loop runs at the display's refresh rate
  if emulated: inc fps_frames
  let now = getTime()
  fps_us += (now - fps_last_time).inMicroseconds()
  fps_last_time = now
  let cur_sec = now.toUnix() mod 60
  if cur_sec != fps_second:
    let fps = if fps_us > 0: fps_frames.float * 1_000_000.0 / fps_us.float else: 0.0
    emu_fps = fps
    let title = if app.emu_kind == ekNone: "dingbat"
                elif app.paused: "dingbat - PAUSED"
                elif app.emu_kind == ekGBA and app.gba_emu != nil and
                     app.gba_emu.cpu.stopped: "dingbat - SLEEPING"
                elif app.emu_kind == ekNDS and app.nds != nil and
                     app.nds.asleep(): "dingbat - SLEEPING"
                else: fmt"dingbat - {fps:.1f} fps"
    discard setWindowTitle(app.window, cstring(title))
    fps_frames = 0
    fps_us     = 0
    fps_second = cur_sec

# ──────────────────────────── Network link ────────────────────────────

const LINK_FRAME_BUDGET_MS = 8
  ## How long a linked frame may wait on the peer per loop iteration (half a
  ## 60 Hz frame).

proc link_ready(): bool =
  app.emu_kind == ekGBA and app.gba_emu != nil

proc teardown_netlink(why = "") =
  ## Drop the link: BYE to the peer, close the socket, swap back the no-cable
  ## SIO driver so the game sees a clean unplug. `why` (empty for the user's
  ## Disconnect) is shown as "Link ended: ...". A core left mid-frame finishes
  ## that frame single-player: states assume a frame boundary and
  ## link_mid_frame no longer holds them back.
  let torn = app.netlink != nil and app.netlink.mid_frame
  app.link.teardown(app.netlink, why)
  if torn and app.gba_emu != nil:
    app.gba_emu.run_until_frame()
    note_gba_frame()

proc linked_now(nl: NetLink): bool =
  ## Bind a new link to the app; drops rewind history, which would desync.
  if nl == nil: return false
  app.netlink = nl
  app.link_lost = ""
  app.rewind.clear()
  app.rewinding = false
  true

proc establish_netlink(listen_port: int; connect_to: string; delay_ms: int) =
  ## `--listen PORT` hosts (unit 0), `--connect HOST:PORT` joins (unit 1), as
  ## the Link Cable window's Advanced does, with the window open. The loop
  ## services the wait (service_link_setup); the game runs single-player
  ## until a peer pairs.
  app.link.delay_ms = delay_ms
  if app.link.start_cli(listen_port, connect_to, link_ready()):
    app.link_window = true

proc link_cancel_setup() = app.link.cancel_setup()

proc link_auto_stop() = app.link.auto_stop()

proc service_link_setup() =
  ## Per iteration: poll the pending accept/connect so the UI never blocks
  ## while waiting for a peer; a paired socket becomes app.netlink.
  if app.netlink != nil: return
  let gba = if link_ready(): app.gba_emu else: nil
  discard linked_now(app.link.service_setup(gba, current_rom_path(),
                                            link_now_ms()))

proc service_netlink() =
  ## Linked and paused: keep reading the socket so the peer's BYE or loss is
  ## seen, and send our pause (CLOCK's paused bit: its stall clock stops, the
  ## link stays up).
  if app.netlink == nil: return
  try:
    if app.link_lost.len > 0:
      raise newException(NetLinkError, move app.link_lost)
    app.netlink.set_paused(app.paused)
    if app.paused: app.netlink.idle()
  except NetLinkError as e:
    echo "NETLINK: link lost: ", e.msg, " — continuing single-player"
    teardown_netlink(e.msg)
    return
  if app.netlink.peer_done:
    echo "NETLINK: peer disconnected — continuing single-player"
    teardown_netlink("your friend disconnected")

proc link_while_blocked() =
  ## AppKit holds the main loop (a menu open, a live resize): the game stops
  ## as for a pause, and the link goes on as a paused one does, answering
  ## and telling the peer. The loop resumes it (service_netlink). Called
  ## from inside SDL's event pump, where no link step is under way.
  if app.netlink == nil or app.link_lost.len > 0: return
  try:
    app.netlink.set_paused(true)
    app.netlink.idle()
  except NetLinkError as e:
    app.link_lost = e.msg

proc link_mid_frame(): bool =
  ## The linked core stopped inside a frame, parked on the peer: states wait.
  app.netlink != nil and app.netlink.mid_frame

proc render_link_advanced() =
  ## Manual Host/Join behind a collapsed "Advanced" header; either button
  ## first cancels auto-pairing.
  if igCollapsingHeader_TreeNodeFlags("Advanced", 0):
    igSetNextItemWidth(ui_px(120))
    discard igInputInt("Port", addr app.link.port, 1, 100, 0)
    igSeparator()
    igText("To host, share your address and port with a friend:")
    if igButton("Host game", ImVec2(x: 0, y: 0)):
      link_auto_stop(); link_cancel_setup(); app.link.start_host(link_ready())
    igSeparator()
    igText("To join, enter the host's address:")
    igSetNextItemWidth(ui_px(200))
    discard igInputTextWithHint("##link_host", "127.0.0.1",
      cast[cstring](addr app.link.host_buf[0]), csize_t(app.link.host_buf.len),
      0, nil, nil)
    igSameLine(0, -1)
    if igButton("Join game", ImVec2(x: 0, y: 0)):
      link_auto_stop(); link_cancel_setup(); app.link.start_join(link_ready())

proc render_link_window() =
  ## Opening it auto-pairs on localhost; manual Host/Join are under
  ## "Advanced".
  if not app.link_window: return
  igSetNextWindowSize(ImVec2(x: ui_px(340), y: 0), cint(ImGui_Cond_FirstUseEver))
  # Never shorter than last frame's content, whatever imgui.ini kept, so
  # nothing scrolls.
  if app.link_window_min_h > 0:
    igSetNextWindowSizeConstraints(ImVec2(x: 0, y: app.link_window_min_h),
                                   ImVec2(x: 1e9, y: 1e9), nil, nil)
  if igBegin("Link Cable", addr app.link_window,
             cint(ImGui_WindowFlags_NoCollapse)):
    if app.netlink != nil:
      igText("Paired successfully")
      igText("%s", cstring(app.link.status))
      if app.netlink.peer_paused:
        igText("Your friend has paused.")
      elif app.netlink.stalled:
        igText("Waiting for your friend...")
      igText("Rewind, turbo and save-state load are paused while linked.")
      if igButton("Disconnect", ImVec2(x: 0, y: 0)):
        teardown_netlink()
    elif not link_ready():
      igText("Load a GBA ROM, then reopen this window to link.")
    else:
      if app.link.auto:
        # An animated ellipsis so it's visibly working; auto stops on close.
        let dots = 1 + (int(getTicks() div 400) mod 3)
        igText("Waiting to pair%s", cstring(repeat('.', dots)))
        # load_rom fails on a ROM file another window has open (game_lock.nim)
        igTextWrapped("%s", cstring(LINK_SAME_MACHINE_HINT))
      elif app.link.setup == lsListening:
        igText("Hosting on port %d", cint(app.link.port))
        igText("Waiting for a friend to join...")
        igText("They pick Join and enter  your-ip : %d", cint(app.link.port))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      elif app.link.setup == lsConnecting:
        igText("Connecting to %s:%d...",
               cstring(app.link.join_host()), cint(app.link.port))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      elif app.link.setup == lsHandshake:
        igText("Connected. Waiting for your friend's game to answer")
        igText("(up to %d s)...", cint(app.link.hello_timeout_ms div 1000))
        if igButton("Cancel", ImVec2(x: 0, y: 0)): link_cancel_setup()
      else:
        igText("Two players, one emulated link cable, over the network.")
      igSeparator()
      render_link_advanced()
    if app.link.status.len > 0 and app.netlink == nil:
      igSeparator()
      igText("%s", cstring(app.link.status))
    # Content bottom (cursor sits one item spacing below the last item, title
    # bar included) plus padding.
    let style = igGetStyle()
    app.link_window_min_h = igGetCursorPosY() - style.ItemSpacing.y +
                            style.WindowPadding.y
  igEnd()

proc update_link_auto() =
  ## Opening the Link Cable window starts auto-pairing; closing it stops any
  ## pairing, auto or manual.
  app.link.update_auto(app.link_window, link_ready(), app.netlink != nil)

# ──────────────────────────── Main ────────────────────────────

proc main() =
  var rom_path     = ""
  var boot_ov: BootOverrides
  var listen_port    = 0
  var connect_to     = ""
  var netlink_delay  = 0
  var link_auto      = false
  var pos_args: seq[string]

  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":  print_help(); system.quit(0)
      of "version":    echo VERSION; system.quit(0)
      of "hle":            boot_ov.use_hle = true
      of "hle-after-bios": boot_ov.hle_after_bios = true
      of "run-bios":       boot_ov.run_bios = some(true)
      of "skip-bios":      boot_ov.run_bios = some(false)
      of "listen":
        # Accepts --listen:PORT or --listen PORT
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        listen_port = parseInt(v)
      of "connect":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        connect_to = v
      of "netlink-delay-ms":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        netlink_delay = parseInt(v)
      of "capture":
        let parts = p.val.split(':', 1)
        capture_after = parseInt(parts[0])
        capture_path  = if parts.len > 1: parts[1] else: "capture.png"
      of "link-auto":
        link_auto = true
      else: echo "Unknown option: --" & p.key; system.quit(1)
    of cmdArgument:
      pos_args.add(p.key)

  case pos_args.len
  of 0: discard
  of 1: rom_path  = pos_args[0]
  of 2: boot_ov.bios_path = pos_args[0]; rom_path = pos_args[1]
  else: echo "Too many arguments."; system.quit(1)

  # Command-line BIOS choices stay in app.boot_overrides, out of cfg, so
  # save_config never makes them permanent.
  let cfg = load_config()
  # Start fullscreen only if the platform restores windows; otherwise clear
  # the saved flag (as macOS discards window state at quit), so nothing stale
  # comes back when the system setting is turned on later.
  let start_fs = start_fullscreen(cfg.fullscreen, system_restores_windows())
  if cfg.fullscreen != start_fs:
    cfg.fullscreen = start_fs
    save_config(cfg)

  when defined(macosx):
    native_menu = getEnv("DINGBAT_IMGUI_MENU") != "1"
    # Fullscreen from Cmd+F (setWindowFullscreen) would otherwise hide the
    # menu bar for good; this keeps it at the top edge, as the green button does
    if native_menu:
      discard setHint("SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY", "1")
  if not sdl3.init(INIT_VIDEO or INIT_AUDIO or INIT_GAMEPAD):
    echo "SDL init failed: ", $getError(); system.quit(1)
  defer: sdl3.quit()

  if not pr.choose_backend():
    echo "No Metal device: dingbat draws with Metal on macOS"; system.quit(1)

  # Created hidden, then centred and shown: SDL_CreateWindow takes no position.
  # HIGH_PIXEL_DENSITY: on Retina (and Wayland, density = desktop scale) the
  # back buffer is device pixels, not 1x pixel-doubled by the compositor.
  # Window sizes, positions and the mouse stay in points; drawing and captures
  # use getWindowSizeInPixels. Windows and X11 windows are already in pixels (SDL 3
  # is per-monitor DPI aware), so the flag does nothing there; the display
  # scale becomes the UI scale (display_ui_scale), applied before showing.
  var hidden = false
  when defined(gui_driver):
    driver_init()
    hidden = driver_enabled()
  let window = createWindow("dingbat",
    cint(GBA_W * cfg.frame_size), cint(GBA_H * cfg.frame_size),
    pr.window_flags() or WINDOW_RESIZABLE or WINDOW_HIDDEN or
    WINDOW_HIGH_PIXEL_DENSITY or (if start_fs: WINDOW_FULLSCREEN else: 0'u64))
  if window == nil:
    echo "Failed to create window: ", $getError(); system.quit(1)
  defer: destroyWindow(window)
  ui_scale = display_ui_scale(window)
  if not start_fs:
    let k = window_units(window, cfg.frame_size)
    discard setWindowSize(window, cint(round(float(GBA_W) * k)),
                          cint(round(float(GBA_H) * k)))
  discard setWindowPosition(window, WINDOW_CENTERED, WINDOW_CENTERED)
  if not hidden: discard showWindow(window)

  # Reading the back buffer is set up front (a Metal layer must allow it)
  var readable = capture_after >= 0
  when defined(gui_driver): readable = true
  if not pr.init(window, readable): system.quit(1)
  defer: pr.shutdown()
  let (logo_tex, logo_w, logo_h) = load_logo_texture()

  discard igCreateContext(nil)
  setup_ui_style()
  apply_ui_scale(ui_scale)
  let io_ptr = igGetIO_Nil()
  # Retina needs nothing here: the SDL 3 backend sets
  # io.DisplayFramebufferScale each frame and ImGui 1.92 rasterises the font
  # at it. Windows/X11 scale goes through apply_ui_scale.
  pr.imgui_init(window)

  let fe = new_file_explorer(cfg)
  let ce = new_config_editor(cfg, fe)
  # "Reset to Defaults" changes settings no widget owns: push them live.
  ce.live_sync = proc() =
    apply_color_correction()
    apply_master_volume()
    apply_mp2k_hle()
    apply_fifo_interp()
    apply_pitch_correct_ff()
    apply_audio_lowpass()
    if app.scale != app.cfg.frame_size:
      app.scale = app.cfg.frame_size
      if app.emu_kind != ekNone: resize_to_output()

  app = AppState(
    cfg:             cfg,
    gba_emu:         nil,
    window:          window,
    io:              io_ptr,
    logo_texture:    logo_tex,
    logo_w:          logo_w,
    logo_h:          logo_h,
    home_stale:      true,
    fe:              fe,
    ce:              ce,
    cheats:          new_cheats_widget(),
    save_states:     new_save_states_widget(),
    dbg:             nil,
    scale:           (when defined(gputime): parseInt(getEnv("DINGBAT_SCALE", "3"))
                      else: cfg.frame_size),
    running:         true,
    paused:          false,
    fullscreen:      start_fs,
    enable_overlay:  false,
    last_mouse_tick: getTicks(),
    rewind:          new_rewind(),
    link:            init_link_cable(),
    boot_overrides:  boot_ov,
  )
  ce.bios.overrides = describe(boot_ov)
  # Started fullscreen, the window is at its 100% size: rescale on leaving.
  if start_fs and ui_scale != 1: app.fs_track.refit = true
  # Save/Load run synchronously: render_imgui is always at a frame boundary
  # (after process_pending_state).
  app.save_states.on_open = proc() = refresh_state_slots()
  app.save_states.on_save = proc(slot: int) =
    if not save_state_slot(slot):
      app.save_states.notice = SLOT_SAVE_FAILED
  app.save_states.on_load = proc(slot: int) =
    if not load_state_slot(slot):
      # Raw wording goes to the log only.
      app.save_states.notice = state_reject_sentence()
      if last_state_error.len > 0:
        echo "Slot load refused: ", last_state_error
  app.save_states.on_delete = proc(slot: int) = delete_state_slot(slot)
  when defined(gui_driver):
    gui_driver.home_dump = proc(): string =
      if app.home != nil and app.emu_kind == ekNone: app.home.dump() else: "none\n"
    gui_driver.link_state = proc(): string =
      let nl = app.netlink
      "linked=" & $ord(nl != nil) &
        " peer_paused=" & $ord(nl != nil and nl.peer_paused) &
        " frames=" & $frames_run
    gui_driver.explorer_dump = proc(): string = app.fe.dump()
    gui_driver.settings_dump = imgui_settings.dump
    gui_driver.toast_dump = library_view.toast_dump
    gui_driver.imgui_menu_dump = proc(): string =
      ## The in-window bar's menus as data: a title a line, indented under
      ## its menu, as the ImGui bar labels it ([off] greyed, [x] ticked)
      proc walk(items: seq[MenuItem]; depth: int; s: var string) =
        for it in items:
          if it.kind in {mkSystem, mkEdit}: continue
          s.add repeat("  ", depth)
          if it.kind == mkSeparator:
            s.add "---\n"
            continue
          s.add imgui_label(it, MOD_KEY_STR)
          if it.checked: s.add " [x]"
          if not it.enabled: s.add " [off]"
          s.add "\n"
          if it.kind == mkSubmenu: walk(it.items, depth + 1, s)
      walk(menu_bar(native = false), 0, result)
    gui_driver.app_cmd = proc(w: seq[string]) =
      case w[0]
      of "cmd": push_cmd(parseEnum[MenuCmd](w[1]), if w.len > 2: parseInt(w[2]) else: 0)
      of "tab": imgui_settings.tab_request = parseInt(w[1])
      else: raise newException(ValueError, "app cmd|tab")
  when defined(macosx):
    mac_while_blocked(link_while_blocked)
    mac_scroll_install(window)
    if native_menu:
      mac_menu_install(window, proc(): seq[MenuItem] = menu_bar(native = true),
                       menu_state, VERSION)
      # Settings in a native window too (DINGBAT_IMGUI_MENU=1 keeps ImGui's)
      var driven = false
      when defined(gui_driver): driven = driver_enabled()
      mac_settings_init(ce, driven)

  # The look starts all 0/false, so set the configured value now
  # (tex_height too: 0 would make the scanline fract() darken everything)
  apply_color_correction()
  apply_panel_uniforms()

  if listen_port > 0 and connect_to.len > 0:
    echo "Use either --listen or --connect, not both."; system.quit(1)

  if rom_path != "":
    if not fileExists(rom_path):
      echo "ROM file not found: ", rom_path; system.quit(1)
    if listen_port > 0 or connect_to.len > 0 or link_auto: load_rom(rom_path)
    else: open_file(rom_path)
    if listen_port > 0 or connect_to.len > 0:
      establish_netlink(listen_port, connect_to, netlink_delay)
    elif link_auto:
      # update_link_auto starts pairing on the window's open edge.
      if link_ready():
        app.link_window = true
      else:
        echo "NETLINK: --link-auto needs a GBA ROM; ignoring"
  elif listen_port > 0 or connect_to.len > 0:
    echo "NETLINK: --listen/--connect need a ROM path; ignoring"
  elif link_auto:
    echo "NETLINK: --link-auto needs a ROM path; ignoring"

  # The UI runs at the display's refresh rate, decoupled from emulation:
  #  - Emulation faster (fast forward): presents are skipped down to the
  #    display rate (upload + swap is ~1 ms per frame).
  #  - Emulation slower (60 fps on 120 Hz): pacing happens here, skipping
  #    emulation while audio is ahead, so the loop never blocks in the APU.
  var present_interval = 8'u64
  let display_mode = getDesktopDisplayMode(getPrimaryDisplay())
  if display_mode != nil and display_mode.refresh_rate > 0:
    present_interval = uint64(1000'f32 / display_mode.refresh_rate)
  var last_present = getTicks()
  # Normal play: fixed 16.743 ms wall-clock slot (280896 cycles / 16.777216
  # MHz, GB too); the audio queue is only a bounds check. Turbo and
  # fast-forward pace by audio.
  let sched_freq = getPerformanceFrequency()
  gbx_frame_ticks = sched_freq * 280896'u64 div 16777216'u64
  # A DS frame is a little shorter: 1120380 cycles at 67.027964 MHz
  nds_frame_ticks = sched_freq * uint64(NDS_FRAME_CYCLES) div uint64(NDS_MASTER_HZ)
  frame_ticks = if app.emu_kind == ekNDS: nds_frame_ticks else: gbx_frame_ticks
  var next_frame_due = getPerformanceCounter()
  # Within this of a slot the idle wait sleeps precisely, not in 1 ms steps
  # (which overshoot by a few ms)
  let precise_wait = sched_freq * 4 div 1000
  # A paced frame's swap is held to a steady offset from its release, so
  # varying emulation time does not move frames across refreshes. The offset
  # is the 90th percentile of the last two seconds' release-to-ready times; a
  # slower frame goes out as soon as it's ready.
  var frame_start: uint64
  var ready_ring: array[120, uint64]
  var ready_next = 0
  var present_hold = 0'u64
  proc hold_learn(ready: uint64) =
    ready_ring[ready_next] = ready
    ready_next = (ready_next + 1) mod ready_ring.len
    var sorted = ready_ring
    sorted.sort()
    present_hold = min(sorted[ready_ring.len * 9 div 10] + sched_freq div 4000,
                       frame_ticks div 2)

  var sched_refilling = true  # start with an empty queue: fill to target

  proc scheduler_frame_due(queued, low, target, high: uint32): bool =
    let now = getPerformanceCounter()
    if next_frame_due + frame_ticks < now:
      # Stalled: resync instead of bursting missed slots
      next_frame_due = now
    if queued > high: return false  # queue ran away: hold until it drains
    # Hysteresis: below `low`, burst until `target`. Stopping at `low` makes
    # the cadence follow audio drain granularity, not the wall clock.
    if queued < low: sched_refilling = true
    if sched_refilling:
      if queued < target: return true
      sched_refilling = false
    now >= next_frame_due

  proc scheduler_frame_ran() =
    # Clamp to one period from now: refill bursts must not bank future slots
    # (a burst/hold sawtooth)
    next_frame_due = min(next_frame_due + frame_ticks,
                         getPerformanceCounter() + frame_ticks)

  proc is_paced(): bool =
    ## True while emulation is meant to run at exactly hardware speed
    case app.emu_kind
    of ekGBA: app.gba_emu != nil and app.gba_emu.apu.sync and
              not app.gba_emu.apu.turbo
    of ekGB:  app.gb_emu != nil and app.gb_emu.apu.sync and
              not app.gb_emu.apu.turbo
    of ekNDS: app.nds != nil and app.nds.sync and not app.nds.turbo
    of ekNone: false

  proc gba_frame_due(): bool =
    let apu = app.gba_emu.apu
    if not apu.sync or apu.turbo: return not apu.audio_ahead()
    # s16 stereo is 4 B/frame: 1024/3072/8192 B ≈ 7.8/23.4/62.5 ms of audio
    scheduler_frame_due(apu.audio_queued_bytes(), 1024, 3072, 8192)

  proc gb_frame_due(): bool =
    let apu = app.gb_emu.apu
    if not apu.sync or apu.turbo: return not apu.audio_ahead()
    # f32 stereo is 8 B/frame: the same time bounds are 2048/6144/16384 B
    scheduler_frame_due(apu.audio_queued_bytes(), 2048, 6144, 16384)

  proc nds_frame_due(): bool =
    let g = app.nds
    if not g.sync or g.turbo: return not g.audio_ahead()
    # f32 stereo as the GB's, on the DS's own frame period
    scheduler_frame_due(g.audio_queued_bytes(), 2048, 6144, 16384)

  # DINGBAT_PACING_LOG=1: one line per second with emulated-frame counts and
  # audio queue depth bounds (qmin=0 would mean an underrun)
  let pacing_log = getEnv("DINGBAT_PACING_LOG").len > 0
  var pace_frames = 0
  var pace_total  = 0
  var pace_min_q  = uint32.high
  var pace_max_q  = 0'u32
  var pace_start  = 0'u64
  var pace_last   = 0'u64
  # DINGBAT_FRAME_TRACE=<path>: one CSV row per present, written at quit:
  # slot due, emulation start/end, swap issued/returned, on the glass
  # (performance-counter ticks; due is 0 for a present with no new frame,
  # shown 0 where unknown: OpenGL, or a hidden window)
  let trace_path = getEnv("DINGBAT_FRAME_TRACE")
  var trace: seq[array[7, uint64]]
  var trace_due, trace_end, trace_ready, trace_swap: uint64
  # DINGBAT_LATENCY_TEST=<trials>: inject an UP press where SDL keys are
  # applied; time until (a) the framebuffer differs and (b) that frame is
  # swapped. Needs a GBA ROM static until UP, responding next frame (tonc
  # m7_demo.gba).
  var lat_trials = 0
  try: lat_trials = parseInt(getEnv("DINGBAT_LATENCY_TEST", "0"))
  except ValueError: discard
  var lat_state = 0            # 0 settle, 1 awaiting fb change, 2 awaiting present
  var lat_settle = 0
  var lat_inject_at = 0'u64
  var lat_rng = 0x9E3779B97F4A7C15'u64
  var lat_t0, lat_t1: uint64
  var lat_base: uint32
  var lat_wait = 0
  var lat_change_ms: seq[float]
  var lat_present_ms: seq[float]
  let lat_freq = float(getPerformanceFrequency())
  proc lat_ms(a, b: uint64): float = float(b - a) * 1000.0 / lat_freq
  proc lat_fb_hash(): uint32 =
    result = 0x811C9DC5'u32
    for v in app.gba_emu.ppu.framebuffer:
      result = (result xor uint32(v and 0xFF)) * 0x01000193'u32
      result = (result xor uint32(v shr 8)) * 0x01000193'u32
  proc lat_stats(xs: seq[float]): (float, float, float) =
    var mn = xs[0]
    var mx = xs[0]
    var s  = 0.0
    for x in xs:
      mn = min(mn, x)
      mx = max(mx, x)
      s += x
    (mn, s / float(xs.len), mx)
  proc lat_poll_input() =
    # Timed from when the press was due, as a real key's wait would be
    if lat_trials > 0 and lat_state == 0 and lat_inject_at != 0 and
       app.gba_emu != nil and getPerformanceCounter() >= lat_inject_at:
      lat_t0 = lat_inject_at
      lat_inject_at = 0
      lat_settle = 0
      lat_base = lat_fb_hash()
      app.gba_emu.handle_input(UP, true)
      lat_wait = 0
      lat_state = 1
  if lat_trials > 0:
    echo "LATENCY: present_interval=", present_interval, " ms, ",
         "display refresh=", display_mode.refresh_rate, " Hz"
  while app.running:
    when defined(gui_driver): driver_poll(window)
    var emulated = false
    # Frame advance bypasses audio pacing: exactly one frame
    let stepping = app.paused and app.pending_step
    app.pending_step = false
    if app.rewinding and app.emu_kind != ekNone and app.netlink == nil:
      # ~30 pops/s of 10-frame snapshots ≈ 5x realtime. A snapshot restores
      # the framebuffer, so presenting shows the rewound frame.
      let now_r = getTicks()
      if now_r - app.last_rewind_pop >= 33:
        app.last_rewind_pop = now_r
        let snap = app.rewind.pop()
        if snap.len > 0:
          input_log_event("rewind")
          try:
            case app.emu_kind
            of ekGBA: app.gba_emu.apply_state_payload(snap)
            of ekGB:  app.gb_emu.apply_state_payload(snap)
            of ekNDS:
              if not app.nds.rewind_apply(snap):
                raise newException(CatchableError, last_state_error)
            of ekNone: discard
            emulated = true
          except CatchableError:
            echo "Rewind failed: ", getCurrentExceptionMsg()
            app.rewinding = false
    elif not app.paused or stepping:
      frame_start = getPerformanceCounter()
      case app.emu_kind
      of ekGBA:
        if app.gba_emu != nil and (stepping or gba_frame_due()):
          if app.netlink != nil:
            # Parked on the peer, it returns after LINK_FRAME_BUDGET_MS so
            # input and drawing go on; the frame resumes next iteration.
            try:
              emulated = app.netlink.step_frame_for(LINK_FRAME_BUDGET_MS)
            except NetLinkError as e:
              echo "NETLINK: link lost: ", e.msg, " — continuing single-player"
              teardown_netlink(e.msg)
          else:
            input_log_frame_start()
            app.gba_emu.run_until_frame()
            emulated = true
      of ekGB:
        if app.gb_emu != nil and (stepping or gb_frame_due()):
          app.gb_emu.run_until_frame()
          emulated = true
      of ekNDS:
        if app.nds != nil and (stepping or nds_frame_due()):
          app.nds.run_frame(app.cfg.volume, app.cfg.mute, app.cfg.pitch_correct_ff)
          emulated = true
      of ekNone: discard
      if emulated and is_paced():
        trace_due = next_frame_due
        if trace_path.len > 0: trace_end = getPerformanceCounter()
        scheduler_frame_ran()
      if emulated: inc frames_run
      if emulated and app.emu_kind == ekGBA and app.gba_emu != nil:
        note_gba_frame()
      if emulated and app.cfg.rewind and app.netlink == nil:
        case app.emu_kind
        of ekGBA:
          discard app.rewind.maybe_push(proc(): string = app.gba_emu.state_payload())
        of ekGB:
          discard app.rewind.maybe_push(proc(): string = app.gb_emu.state_payload())
        of ekNDS:
          # A DS switched off has nothing to come back to
          if not app.nds.powered_off():
            discard app.rewind.maybe_push(proc(): string = app.nds.rewind_payload())
        of ekNone: discard
    if lat_trials > 0 and app.emu_kind == ekGBA and app.gba_emu != nil and
       not app.paused:
      case lat_state
      of 0:
        if emulated:
          inc lat_settle
        if lat_settle >= 40:  # let the screen go static between trials
          # Random phase within the frame period, to sample the whole
          # arrival-time distribution
          if lat_inject_at == 0:
            lat_rng = lat_rng * 6364136223846793005'u64 + 1442695040888963407'u64
            lat_inject_at = getPerformanceCounter() +
                            (lat_rng shr 33) mod frame_ticks
      of 1:
        if emulated:
          if lat_fb_hash() != lat_base:
            lat_t1 = getPerformanceCounter()
            lat_state = 2
          else:
            inc lat_wait
            if lat_wait > 10:
              echo "LATENCY: no fb change within 10 frames — wrong ROM or key?"
              app.gba_emu.handle_input(UP, false)
              lat_state = 0
      else: discard
    # Linked: the socket is read even while paused, and BYE ends the link.
    service_netlink()
    # States run at a frame boundary (a core parked mid-frame on the peer
    # keeps them pending)
    if (app.pending_save or app.pending_load) and app.emu_kind != ekNone and
       not link_mid_frame():
      process_pending_state()
    poll_battery_notice()
    if pacing_log and app.emu_kind == ekGBA and app.gba_emu != nil and
       not app.paused:
      let q = app.gba_emu.apu.audio_queued_bytes()
      pace_min_q = min(pace_min_q, q)
      pace_max_q = max(pace_max_q, q)
      if emulated:
        if pace_start == 0:
          pace_start = getTicks()
          pace_last  = pace_start
        inc pace_frames
        inc pace_total
      if pace_start != 0:
        let t = getTicks()
        if t - pace_last >= 1000:
          let elapsed = float(t - pace_start) / 1000.0
          echo &"pacing t={elapsed:.2f}s frames_1s={pace_frames} " &
               &"total={pace_total} avg_fps={float(pace_total - 1)/elapsed:.4f} " &
               &"qmin={pace_min_q} qmax={pace_max_q}"
          pace_last = t
          pace_frames = 0
          pace_min_q = uint32.high
          pace_max_q = 0
    handle_input()
    lat_poll_input()
    run_menu_cmds()
    take_open()
    when defined(macosx):
      mac_settings_tick()
      if native_menu: mac_notices()
    sync_aspect()
    update_rumble()
    update_link_auto()
    service_link_setup()
    let now = getTicks()
    var presented = false
    # A paced frame presents immediately (waiting for the next slot adds up to
    # a display period of latency). The interval bounds the present rate under
    # turbo and refreshes the UI when nothing ran; while paced frames arrive
    # they refresh the UI, as an extra present would compete with their swap.
    let ui_interval = if is_paced() and not app.paused:
                        max(present_interval, 2 * frame_ticks * 1000 div sched_freq)
                      else: present_interval
    if (emulated and is_paced()) or now - last_present >= ui_interval:
      last_present = now
      # Black letterbox behind a game; the home screen's page behind it.
      if app.emu_kind == ekNone:
        let (r, g, b) = stage_rgb()
        pr.begin(window, r, g, b)
      else:
        pr.begin(window, 0'f32, 0'f32, 0'f32)
      render_game()
      inc present_count
      if capture_after >= 0 and present_count >= capture_after:
        let (cx, cy, cw, ch) = game_viewport()
        let pix = pr.read(cx, cy, cw, ch)
        if pix.len > 0 and stbiw.writePNG(capture_path, cw, ch, 3, pix):
          echo "capture written: ", capture_path, " ", cw, "x", ch
        else:
          echo "capture FAILED: ", capture_path
        app.running = false
      render_imgui()
      when defined(gui_driver): driver_frame(window)
      if emulated and is_paced() and not app.rewinding:
        let ready = getPerformanceCounter()
        if trace_path.len > 0: trace_ready = ready
        let present_at = frame_start + present_hold
        if ready < present_at:
          delayPrecise((present_at - ready) * 1_000_000_000'u64 div sched_freq)
        hold_learn(ready - frame_start)
      if trace_path.len > 0: trace_swap = getPerformanceCounter()
      let present_seq = pr.present(window)
      presented = true
      if trace_path.len > 0:
        trace.add([(if emulated: trace_due else: 0'u64), frame_start,
                   trace_end, trace_ready, trace_swap, getPerformanceCounter(),
                   present_seq])
      if lat_trials > 0 and lat_state == 2:
        let t2 = getPerformanceCounter()
        lat_change_ms.add(lat_ms(lat_t0, lat_t1))
        lat_present_ms.add(lat_ms(lat_t0, t2))
        echo &"LATENCY trial {lat_present_ms.len}: " &
             &"inject→fb-change {lat_ms(lat_t0, lat_t1):.2f} ms, " &
             &"inject→present {lat_ms(lat_t0, t2):.2f} ms"
        app.gba_emu.handle_input(UP, false)
        lat_state = 0
        if lat_present_ms.len >= lat_trials:
          let (c0, c1, c2) = lat_stats(lat_change_ms)
          let (p0, p1, p2) = lat_stats(lat_present_ms)
          echo &"LATENCY inject→fb-change ms: min {c0:.2f} avg {c1:.2f} max {c2:.2f}"
          echo &"LATENCY inject→present ms:  min {p0:.2f} avg {p1:.2f} max {p2:.2f}"
          app.running = false
    update_fps_title(emulated)
    if not emulated and not presented:
      # Idle without spinning. Close to a paced slot, wake on it exactly: a
      # late release moves the frame across a refresh (a repeat, then a
      # drop). Input is re-read on waking.
      let wait = next_frame_due - min(next_frame_due, getPerformanceCounter())
      if is_paced() and not app.paused and wait > 0 and wait <= precise_wait:
        delayPrecise(wait * 1_000_000_000'u64 div sched_freq)
        handle_input()
        lat_poll_input()
      else:
        delay(1)
  if trace_path.len > 0:
    var csv = &"# freq={getPerformanceFrequency()} " &
              &"frame_ticks={frame_ticks}\ndue,start,emulated,ready,swap,swapped,shown\n"
    for r in trace:
      var row = r
      row[6] = pr.shown_at(r[6], uint64(getPerformanceFrequency()))
      csv.add row.join(",") & "\n"
    writeFile(trace_path, csv)
  # The peer hears BYE instead of waiting out its timeout
  link_auto_stop()
  link_cancel_setup()
  teardown_netlink()
  store_last_screen()
  flush_saves()
  save_session()
  input_log_close()

main()
