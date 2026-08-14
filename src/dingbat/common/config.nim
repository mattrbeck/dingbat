import std/[os, json, tables, strutils]
import yaml/tojson
import input
import lcd_response

# Keycode name ↔ SDL keycode integer table, mirroring Crystal's LibSDL::Keycode
# enum (ysbaddaden/sdl.cr keycode.cr) so that config files are compatible.
# Crystal serialises enum members by their lowercased name, e.g. SEMICOLON → "semicolon".
# SDL's own SDL_GetKeyFromName / SDL_GetScancodeName do NOT produce these word-form names
# for printable-character keys (they return the raw character, e.g. ";"), so we maintain
# the table ourselves.
const SDLK_SCANCODE_MASK = cint(1 shl 30)

# Scancode values (from ysbaddaden/sdl.cr scancode.cr) used for scancode-masked keycodes.
const SC_CAPSLOCK    = cint(57)
const SC_F1          = cint(58);  const SC_F2  = cint(59);  const SC_F3  = cint(60)
const SC_F4          = cint(61);  const SC_F5  = cint(62);  const SC_F6  = cint(63)
const SC_F7          = cint(64);  const SC_F8  = cint(65);  const SC_F9  = cint(66)
const SC_F10         = cint(67);  const SC_F11 = cint(68);  const SC_F12 = cint(69)
const SC_PRINTSCREEN = cint(70);  const SC_SCROLLLOCK = cint(71); const SC_PAUSE = cint(72)
const SC_INSERT      = cint(73);  const SC_HOME = cint(74); const SC_PAGEUP = cint(75)
const SC_END         = cint(77);  const SC_PAGEDOWN = cint(78)
const SC_RIGHT       = cint(79);  const SC_LEFT = cint(80); const SC_DOWN = cint(81)
const SC_UP          = cint(82)
const SC_LCTRL = cint(224); const SC_LSHIFT = cint(225); const SC_LALT = cint(226)
const SC_LGUI  = cint(227); const SC_RCTRL  = cint(228); const SC_RSHIFT = cint(229)
const SC_RALT  = cint(230); const SC_RGUI   = cint(231)

const KEYCODE_TABLE = [
  # Printable / ASCII keycodes
  ("backspace",    cint(8)),
  ("tab",          cint(9)),
  ("return",       cint(13)),
  ("escape",       cint(27)),
  ("space",        cint(32)),
  ("exclaim",      cint(33)),
  ("quotedbl",     cint(34)),
  ("hash",         cint(35)),
  ("percent",      cint(37)),
  ("dollar",       cint(38)),   # Crystal has DOLLAR=38 (typo; '&'=38 too)
  ("ampersand",    cint(38)),
  ("quote",        cint(39)),
  ("leftparen",    cint(40)),
  ("rightparen",   cint(41)),
  ("asterisk",     cint(42)),
  ("plus",         cint(43)),
  ("comma",        cint(44)),
  ("minus",        cint(45)),
  ("period",       cint(46)),
  ("slash",        cint(47)),
  ("key_0",        cint(48)),
  ("key_1",        cint(49)),
  ("key_2",        cint(50)),
  ("key_3",        cint(51)),
  ("key_4",        cint(52)),
  ("key_5",        cint(53)),
  ("key_6",        cint(54)),
  ("key_7",        cint(55)),
  ("key_8",        cint(56)),
  ("key_9",        cint(57)),
  ("colon",        cint(58)),
  ("semicolon",    cint(59)),
  ("less",         cint(60)),
  ("equals",       cint(61)),
  ("greater",      cint(62)),
  ("question",     cint(63)),
  ("at",           cint(64)),
  ("leftbracket",  cint(91)),
  ("backslash",    cint(92)),
  ("rightbracket", cint(93)),
  ("caret",        cint(94)),
  ("underscore",   cint(95)),
  ("backquote",    cint(96)),
  ("a", cint(97)),  ("b", cint(98)),  ("c", cint(99)),  ("d", cint(100)),
  ("e", cint(101)), ("f", cint(102)), ("g", cint(103)), ("h", cint(104)),
  ("i", cint(105)), ("j", cint(106)), ("k", cint(107)), ("l", cint(108)),
  ("m", cint(109)), ("n", cint(110)), ("o", cint(111)), ("p", cint(112)),
  ("q", cint(113)), ("r", cint(114)), ("s", cint(115)), ("t", cint(116)),
  ("u", cint(117)), ("v", cint(118)), ("w", cint(119)), ("x", cint(120)),
  ("y", cint(121)), ("z", cint(122)),
  ("delete",       cint(127)),
  # Scancode-masked keycodes
  ("capslock",     SC_CAPSLOCK    or SDLK_SCANCODE_MASK),
  ("f1",           SC_F1          or SDLK_SCANCODE_MASK),
  ("f2",           SC_F2          or SDLK_SCANCODE_MASK),
  ("f3",           SC_F3          or SDLK_SCANCODE_MASK),
  ("f4",           SC_F4          or SDLK_SCANCODE_MASK),
  ("f5",           SC_F5          or SDLK_SCANCODE_MASK),
  ("f6",           SC_F6          or SDLK_SCANCODE_MASK),
  ("f7",           SC_F7          or SDLK_SCANCODE_MASK),
  ("f8",           SC_F8          or SDLK_SCANCODE_MASK),
  ("f9",           SC_F9          or SDLK_SCANCODE_MASK),
  ("f10",          SC_F10         or SDLK_SCANCODE_MASK),
  ("f11",          SC_F11         or SDLK_SCANCODE_MASK),
  ("f12",          SC_F12         or SDLK_SCANCODE_MASK),
  ("printscreen",  SC_PRINTSCREEN or SDLK_SCANCODE_MASK),
  ("scrolllock",   SC_SCROLLLOCK  or SDLK_SCANCODE_MASK),
  ("pause",        SC_PAUSE       or SDLK_SCANCODE_MASK),
  ("insert",       SC_INSERT      or SDLK_SCANCODE_MASK),
  ("home",         SC_HOME        or SDLK_SCANCODE_MASK),
  ("pageup",       SC_PAGEUP      or SDLK_SCANCODE_MASK),
  ("end",          SC_END         or SDLK_SCANCODE_MASK),
  ("pagedown",     SC_PAGEDOWN    or SDLK_SCANCODE_MASK),
  ("right",        SC_RIGHT       or SDLK_SCANCODE_MASK),
  ("left",         SC_LEFT        or SDLK_SCANCODE_MASK),
  ("down",         SC_DOWN        or SDLK_SCANCODE_MASK),
  ("up",           SC_UP          or SDLK_SCANCODE_MASK),
  ("lctrl",        SC_LCTRL       or SDLK_SCANCODE_MASK),
  ("lshift",       SC_LSHIFT      or SDLK_SCANCODE_MASK),
  ("lalt",         SC_LALT        or SDLK_SCANCODE_MASK),
  ("lgui",         SC_LGUI        or SDLK_SCANCODE_MASK),
  ("rctrl",        SC_RCTRL       or SDLK_SCANCODE_MASK),
  ("rshift",       SC_RSHIFT      or SDLK_SCANCODE_MASK),
  ("ralt",         SC_RALT        or SDLK_SCANCODE_MASK),
  ("rgui",         SC_RGUI        or SDLK_SCANCODE_MASK),
]

proc build_name_to_code(): Table[string, cint] =
  for (name, code) in KEYCODE_TABLE: result[name] = code

proc build_code_to_name(): Table[cint, string] =
  # Iterate in reverse so the first entry for a given code wins
  # (handles the DOLLAR/AMPERSAND duplicate at keycode 38).
  for i in countdown(KEYCODE_TABLE.high, 0):
    let (name, code) = KEYCODE_TABLE[i]
    result[code] = name

let NAME_TO_CODE = build_name_to_code()
let CODE_TO_NAME = build_code_to_name()

proc key_name_to_code(name: string): cint =
  NAME_TO_CODE.getOrDefault(toLowerAscii(name), cint(-1))

proc key_code_to_name(code: cint): string =
  CODE_TO_NAME.getOrDefault(code, "")

proc input_from_name(name: string): Input =
  ## Parse a lowercase input name to the Input enum (e.g. "start" → START).
  case toLowerAscii(name)
  of "up":     Input.UP
  of "down":   Input.DOWN
  of "left":   Input.LEFT
  of "right":  Input.RIGHT
  of "a":      Input.A
  of "b":      Input.B
  of "select": Input.SELECT
  of "start":  Input.START
  of "l":      Input.L
  of "r":      Input.R
  else:        raise newException(ValueError, "Unknown input: " & name)

# Controller button names, indexed by SDL_GameControllerButton ordinal.
# These match SDL_GameControllerGetStringForButton / FromString exactly, but
# are kept as a table so config.nim stays SDL-free (the wasm build must not
# link SDL's controller API).
const CONTROLLER_BUTTON_NAMES = [
  "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick",
  "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright",
]

proc controller_button_name*(button: cint): string =
  if button >= 0 and button < cint(CONTROLLER_BUTTON_NAMES.len):
    CONTROLLER_BUTTON_NAMES[button]
  else:
    ""

proc controller_button_from_name*(name: string): cint =
  let lowered = toLowerAscii(name)
  for i, n in CONTROLLER_BUTTON_NAMES:
    if n == lowered: return cint(i)
  cint(-1)

# Default controller bindings, by SDL_GameControllerButton ordinal.
# X/Y intentionally duplicate A/B (GBA-style face buttons on a 4-button pad).
const DEFAULT_CONTROLLER_MAPPING = [
  (cint(0),  Input.A),       # a
  (cint(1),  Input.B),       # b
  (cint(2),  Input.A),       # x
  (cint(3),  Input.B),       # y
  (cint(4),  Input.SELECT),  # back
  (cint(6),  Input.START),   # start
  (cint(9),  Input.L),       # leftshoulder
  (cint(10), Input.R),       # rightshoulder
  (cint(11), Input.UP),      # dpup
  (cint(12), Input.DOWN),    # dpdown
  (cint(13), Input.LEFT),    # dpleft
  (cint(14), Input.RIGHT),   # dpright
]

static:
  # Every emulated input must be reachable and no button may be bound twice
  var covered: set[Input]
  for (btn, inp) in DEFAULT_CONTROLLER_MAPPING:
    covered.incl(inp)
    assert CONTROLLER_BUTTON_NAMES[btn] != "", "unnamed controller button"
  for inp in Input:
    assert inp in covered, "default controller mapping misses an Input"
  for i in 0 ..< DEFAULT_CONTROLLER_MAPPING.len:
    for j in (i + 1) ..< DEFAULT_CONTROLLER_MAPPING.len:
      assert DEFAULT_CONTROLLER_MAPPING[i][0] != DEFAULT_CONTROLLER_MAPPING[j][0],
             "controller button bound twice in default mapping"

proc default_controller_bindings*(): Table[cint, Input] =
  result = initTable[cint, Input]()
  for (btn, inp) in DEFAULT_CONTROLLER_MAPPING:
    result[btn] = inp

# Windows: %APPDATA%\dingbat (the native location); elsewhere: ~/.config/dingbat
let CONFIG_DIR  = when defined(windows): getConfigDir() / "dingbat"
                  else: "~/.config/dingbat"
let CONFIG_FILE = CONFIG_DIR / "dingbat.yml"

proc config_dir*(): string =
  ## The per-user config/data directory (tilde expanded)
  expandTilde(CONFIG_DIR)

# Default keybindings: SDL keycode → Input (mgba-style)
# Arrow keys=D-pad, Z=A, X=B, Backspace=SELECT, Return=START, A=L, S=R
proc default_keybindings*(): Table[cint, Input] =
  result = initTable[cint, Input]()
  result[key_name_to_code("up")]        = Input.UP
  result[key_name_to_code("down")]      = Input.DOWN
  result[key_name_to_code("left")]      = Input.LEFT
  result[key_name_to_code("right")]     = Input.RIGHT
  result[key_name_to_code("z")]         = Input.A
  result[key_name_to_code("x")]         = Input.B
  result[key_name_to_code("backspace")] = Input.SELECT
  result[key_name_to_code("return")]    = Input.START
  result[key_name_to_code("a")]         = Input.L
  result[key_name_to_code("s")]         = Input.R

proc homerow_keybindings*(): Table[cint, Input] =
  result = initTable[cint, Input]()
  result[key_name_to_code("e")]         = Input.UP
  result[key_name_to_code("d")]         = Input.DOWN
  result[key_name_to_code("s")]         = Input.LEFT
  result[key_name_to_code("f")]         = Input.RIGHT
  result[key_name_to_code("k")]         = Input.A
  result[key_name_to_code("j")]         = Input.B
  result[key_name_to_code("l")]         = Input.SELECT
  result[key_name_to_code("semicolon")] = Input.START
  result[key_name_to_code("w")]         = Input.L
  result[key_name_to_code("r")]         = Input.R

type
  VideoFilter* = enum
    ## GPU upscale filter for the game view (both front-ends). Stored by its
    ## string value in the config so new filters can be appended without
    ## churning saved files.
    vfNone = "none"
    vfHq4x = "hq4x"
    vfXbr  = "xbr"
    vfXbrz = "xbrz"
    # Screen-structure looks, in the same selector as the smoothing filters:
    # every option is a way to draw the picture and exactly one can be active,
    # which is what retired the separate Scanlines toggle (it used to be
    # suspended whenever a smoothing filter was on — the selector makes that
    # exclusivity structural). The LCD grid is that toggle's successor: seams
    # on both axes, the way the real panels look, instead of CRT-style rows.
    # They are NOT filter_mode values in the shader; the frontends translate
    # them to their own uniforms.
    vfGrid     = "grid"
    vfSubpixel = "rgb"

  Config* = ref object
    explorer_dir*:      string
    keybindings*:       Table[cint, Input]
    controller_bindings*: Table[cint, Input]  # SDL_GameControllerButton ordinal → Input
    recents*:           seq[string]
    run_bios*:          bool
    bios_path*:         string   # GBA BIOS path
    headless*:          bool
    gb_bootrom_path*:   string   # GB/GBC boot ROM path
    gb_fifo*:           bool     # use FIFO PPU renderer (default true)
    gb_rumble*:         bool     # controller rumble + screen shake on rumble carts
                                 # (GB MBC5 and GBA GPIO; "gb_" kept for config-file compat)
    use_hle*:           bool     # use HLE BIOS for SWI calls
    hle_after_bios*:    bool     # run real BIOS for init, then use HLE for SWI calls
    volume*:            int      # master volume 0..100
    mute*:              bool     # mute audio output
    color_correction*:  bool     # GBA LCD color-correction shader (default on)
    video_filter*:      VideoFilter  # GPU filter/screen look (VideoFilter)
    lcd_response*:      bool     # panel-response model; the panel follows the machine
    preserve_aspect*:   bool     # letterbox instead of stretching to the window
    # Super Game Boy. sgb_enable is OFF by default: a fresh install plays
    # monochrome carts as a Game Boy, which is what they look like everywhere
    # else, and SGB is something you go and turn on. sgb_border defaults ON
    # because it is not a second opt-in -- once you have asked for the adapter,
    # the border is most of what it does.
    sgb_enable*:        bool     # run SGB-flagged DMG carts as a Super Game Boy
    sgb_border*:        bool     # composite the cart's SGB border (256x224)
    rewind*:            bool     # keep rewind history (hold ` to rewind)
    pitch_correct_ff*:  bool     # WSOLA pitch-preserving 2x fast-forward (off = octave-up)
    audio_lowpass*:     bool     # analog-output low-pass on the GBA mix (cap/speaker smoothing)
    # GBA DirectSound FIFO interpolation (true-phase cubic). ON by default:
    # strictly removes reconstruction noise, touches nothing musical. OFF is
    # the hardware-accurate mode — bit-true DAC output including its grit.
    fifo_interp*:       bool
    mp2k_hle*:          bool     # experimental MP2K sound-engine HLE (auto-engages on detection)
    # Speed mode for low-end devices: GBA frameskip + 2x emulated-CPU
    # underclock, GB scanline renderer at next load. Deliberately less
    # accurate/compatible; other expensive niceties are suspended while on.
    speed_mode*:        bool

proc new_config*(): Config =
  Config(
    explorer_dir:    getCurrentDir(),
    keybindings:     default_keybindings(),
    controller_bindings: default_controller_bindings(),
    recents:         @[],
    run_bios:        false,
    use_hle:         true,   # fresh configs have no BIOS file → HLE
    bios_path:       "",
    headless:        false,
    gb_bootrom_path: "",
    gb_fifo:         true,
    gb_rumble:       true,
    volume:          100,
    mute:            false,
    color_correction: true,
    video_filter:    vfNone,
    lcd_response:    false,
    preserve_aspect: true,
    sgb_enable:      false,
    sgb_border:      true,
    rewind:          true,
    pitch_correct_ff: false,
    audio_lowpass:   false,
    fifo_interp:     true,
    mp2k_hle:        false,
    speed_mode:      false,
  )

proc parse_config(j: JsonNode): Config =
  var cfg = new_config()
  if j.hasKey("explorer_dir") and j["explorer_dir"].kind == JString:
    cfg.explorer_dir = j["explorer_dir"].getStr(getCurrentDir())
  if j.hasKey("recents") and j["recents"].kind == JArray:
    for r in j["recents"]:
      if r.kind == JString: cfg.recents.add(r.getStr())
  if j.hasKey("run_bios"):
    cfg.run_bios = j["run_bios"].getBool(false)
  if j.hasKey("volume") and j["volume"].kind == JInt:
    cfg.volume = clamp(j["volume"].getInt(100), 0, 100)
  if j.hasKey("mute"):
    cfg.mute = j["mute"].getBool(false)
  if j.hasKey("color_correction"):
    cfg.color_correction = j["color_correction"].getBool(true)
  if j.hasKey("video_filter") and j["video_filter"].kind == JString:
    try:
      cfg.video_filter = parseEnum[VideoFilter](j["video_filter"].getStr("none"))
    except ValueError:
      cfg.video_filter = vfNone
  if j.hasKey("scanlines"):
    # Scanlines grew into the LCD grid. A config that had the old toggle on
    # becomes that Filter choice — unless it ALSO named a smoothing filter,
    # which the old UI made win by suspending scanlines, so the filter keeps
    # winning here. (A briefly-stored video_filter of "scanlines" fails
    # parseEnum above and lands on vfNone, where this migration catches a
    # still-set legacy toggle; that transitional value never shipped.)
    if j["scanlines"].getBool(false) and cfg.video_filter == vfNone:
      cfg.video_filter = vfGrid
  if j.hasKey("lcd_response"):
    # Two generations of stored value land here. The key held a panel name
    # while the setting was a six-way picker (off/auto/dmg/cgb/agb/ags), and
    # holds a bool now that it is a switch; parse_enabled maps every one of
    # the old names on without changing what anybody asked for.
    cfg.lcd_response =
      if j["lcd_response"].kind == JString:
        parse_enabled(j["lcd_response"].getStr("off"))
      else:
        j["lcd_response"].getBool(false)
  elif j.hasKey("frame_blend"):
    # Migration: the old interframe blend became the LCD response model, and
    # anyone who had it on wanted panel ghosting — give them the panel their
    # machine shipped with rather than silently turning the feature off.
    cfg.lcd_response = j["frame_blend"].getBool(false)
  if j.hasKey("preserve_aspect"):
    cfg.preserve_aspect = j["preserve_aspect"].getBool(true)
  if j.hasKey("rewind"):
    cfg.rewind = j["rewind"].getBool(true)
  if j.hasKey("pitch_correct_ff"):
    cfg.pitch_correct_ff = j["pitch_correct_ff"].getBool(false)
  if j.hasKey("audio_lowpass"):
    cfg.audio_lowpass = j["audio_lowpass"].getBool(false)
  if j.hasKey("fifo_interp"):
    cfg.fifo_interp = j["fifo_interp"].getBool(true)
  if j.hasKey("mp2k_hle"):
    cfg.mp2k_hle = j["mp2k_hle"].getBool(false)
  if j.hasKey("speed_mode"):
    cfg.speed_mode = j["speed_mode"].getBool(false)
  # bios path is nested under "gba" key to match Crystal's config structure
  var hle_key_present = false
  if j.hasKey("gba") and j["gba"].kind == JObject:
    let gba = j["gba"]
    if gba.hasKey("bios") and gba["bios"].kind == JString:
      cfg.bios_path = gba["bios"].getStr("")
    if gba.hasKey("hle"):
      hle_key_present = true
      cfg.use_hle = gba["hle"].getBool(false)
    if gba.hasKey("hle_after_bios"):
      cfg.hle_after_bios = gba["hle_after_bios"].getBool(false)
  if not hle_key_present:
    # Legacy configs predate the persisted SWI mode: keep the old behavior
    # of defaulting to HLE exactly when no BIOS file is configured
    cfg.use_hle = cfg.bios_path.len == 0
  if j.hasKey("gb") and j["gb"].kind == JObject:
    let gb = j["gb"]
    if gb.hasKey("bootrom") and gb["bootrom"].kind == JString:
      cfg.gb_bootrom_path = gb["bootrom"].getStr("")
    if gb.hasKey("fifo") and gb["fifo"].kind == JBool:
      cfg.gb_fifo = gb["fifo"].getBool(true)
    if gb.hasKey("rumble") and gb["rumble"].kind == JBool:
      cfg.gb_rumble = gb["rumble"].getBool(true)
    # No key -> the new_config default, which is OFF. An existing config
    # predating this feature therefore does NOT silently gain it.
    if gb.hasKey("sgb") and gb["sgb"].kind == JBool:
      cfg.sgb_enable = gb["sgb"].getBool(false)
    if gb.hasKey("sgb_border") and gb["sgb_border"].kind == JBool:
      cfg.sgb_border = gb["sgb_border"].getBool(true)
  if j.hasKey("keybindings") and j["keybindings"].kind == JObject:
    cfg.keybindings = initTable[cint, Input]()
    for k, v in j["keybindings"].pairs:
      try:
        let keycode   = key_name_to_code(k)
        let input_val = input_from_name(v.getStr())
        if keycode >= 0:
          cfg.keybindings[keycode] = input_val
      except: discard
  if j.hasKey("controller_bindings") and j["controller_bindings"].kind == JObject:
    cfg.controller_bindings = initTable[cint, Input]()
    for k, v in j["controller_bindings"].pairs:
      try:
        let button    = controller_button_from_name(k)
        let input_val = input_from_name(v.getStr())
        if button >= 0:
          cfg.controller_bindings[button] = input_val
      except: discard
  result = cfg

proc load_config*(): Config =
  let path = expandTilde(CONFIG_FILE)
  if not fileExists(path):
    return new_config()
  try:
    let docs = loadToJson(readFile(path))
    if docs.len == 0 or docs[0].kind != JObject:
      return new_config()
    return parse_config(docs[0])
  except:
    return new_config()

# Produce a YAML string value: quote if the value contains special chars or
# is empty, so it round-trips cleanly through Crystal's YAML parser.
proc yaml_str(s: string): string =
  if s.len == 0:
    return "''"
  # Characters that require quoting in YAML
  const special = {'{', '}', '[', ']', ',', '#', '&', '*', '?', '|',
                   '-', '<', '>', '=', '!', '%', '@', '`', '\'', '\"', ':'}
  var needs_quote = false
  for c in s:
    if c in special or c == '\n' or c == '\r':
      needs_quote = true
      break
  if needs_quote:
    result = "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
  else:
    result = s

proc save_config*(cfg: Config) =
  let path = expandTilde(CONFIG_FILE)
  createDir(expandTilde(CONFIG_DIR))
  var lines: seq[string]
  lines.add("---")
  lines.add("explorer_dir: " & yaml_str(cfg.explorer_dir))
  lines.add("keybindings:")
  for k, v in cfg.keybindings.pairs:
    lines.add("  " & key_code_to_name(k) & ": " & toLowerAscii($v))
  lines.add("controller_bindings:")
  for k, v in cfg.controller_bindings.pairs:
    let name = controller_button_name(k)
    if name.len > 0:
      lines.add("  " & name & ": " & toLowerAscii($v))
  lines.add("recents:")
  for r in cfg.recents:
    lines.add("- " & yaml_str(r))
  lines.add("run_bios: " & $cfg.run_bios)
  lines.add("volume: " & $cfg.volume)
  lines.add("mute: " & $cfg.mute)
  lines.add("color_correction: " & $cfg.color_correction)
  lines.add("video_filter: " & $cfg.video_filter)
  lines.add("lcd_response: " & $cfg.lcd_response)
  lines.add("preserve_aspect: " & $cfg.preserve_aspect)
  lines.add("rewind: " & $cfg.rewind)
  lines.add("pitch_correct_ff: " & $cfg.pitch_correct_ff)
  lines.add("audio_lowpass: " & $cfg.audio_lowpass)
  lines.add("fifo_interp: " & $cfg.fifo_interp)
  lines.add("mp2k_hle: " & $cfg.mp2k_hle)
  lines.add("speed_mode: " & $cfg.speed_mode)
  lines.add("gba:")
  if cfg.bios_path.len > 0:
    lines.add("  bios: " & yaml_str(cfg.bios_path))
  else:
    lines.add("  bios:")
  lines.add("  hle: " & $cfg.use_hle)
  lines.add("  hle_after_bios: " & $cfg.hle_after_bios)
  lines.add("gb:")
  if cfg.gb_bootrom_path.len > 0:
    lines.add("  bootrom: " & yaml_str(cfg.gb_bootrom_path))
  else:
    lines.add("  bootrom:")
  lines.add("  fifo: " & $cfg.gb_fifo)
  lines.add("  rumble: " & $cfg.gb_rumble)
  lines.add("  sgb: " & $cfg.sgb_enable)
  lines.add("  sgb_border: " & $cfg.sgb_border)
  writeFile(path, lines.join("\n") & "\n")
