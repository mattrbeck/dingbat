import std/[os, json, tables, strutils]
import yaml/tojson
import input

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

const CONFIG_DIR  = "~/.config/dingbat"
const CONFIG_FILE = CONFIG_DIR & "/dingbat.yml"

# Default keybindings: SDL keycode → Input
# Matches Crystal defaults (config.cr): E=UP, D=DOWN, S=LEFT, F=RIGHT, K=A, J=B,
#   L=SELECT, SEMICOLON=START, W=L, R=R
proc default_keybindings*(): Table[cint, Input] =
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
  Config* = ref object
    explorer_dir*:      string
    keybindings*:       Table[cint, Input]
    recents*:           seq[string]
    run_bios*:          bool
    bios_path*:         string   # GBA BIOS path
    headless*:          bool
    gb_bootrom_path*:   string   # GB/GBC boot ROM path
    gb_fifo*:           bool     # use FIFO PPU renderer (default true)
    use_hle*:           bool     # use HLE BIOS for SWI calls

proc new_config*(): Config =
  Config(
    explorer_dir:    getCurrentDir(),
    keybindings:     default_keybindings(),
    recents:         @[],
    run_bios:        false,
    bios_path:       "",
    headless:        false,
    gb_bootrom_path: "",
    gb_fifo:         true,
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
  # bios path is nested under "gba" key to match Crystal's config structure
  if j.hasKey("gba") and j["gba"].kind == JObject:
    let gba = j["gba"]
    if gba.hasKey("bios") and gba["bios"].kind == JString:
      cfg.bios_path = gba["bios"].getStr("")
  if j.hasKey("gb") and j["gb"].kind == JObject:
    let gb = j["gb"]
    if gb.hasKey("bootrom") and gb["bootrom"].kind == JString:
      cfg.gb_bootrom_path = gb["bootrom"].getStr("")
    if gb.hasKey("fifo") and gb["fifo"].kind == JBool:
      cfg.gb_fifo = gb["fifo"].getBool(true)
  if j.hasKey("keybindings") and j["keybindings"].kind == JObject:
    cfg.keybindings = initTable[cint, Input]()
    for k, v in j["keybindings"].pairs:
      try:
        let keycode   = key_name_to_code(k)
        let input_val = input_from_name(v.getStr())
        if keycode >= 0:
          cfg.keybindings[keycode] = input_val
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
  lines.add("recents:")
  for r in cfg.recents:
    lines.add("- " & yaml_str(r))
  lines.add("run_bios: " & $cfg.run_bios)
  lines.add("gba:")
  if cfg.bios_path.len > 0:
    lines.add("  bios: " & yaml_str(cfg.bios_path))
  else:
    lines.add("  bios:")
  lines.add("gb:")
  if cfg.gb_bootrom_path.len > 0:
    lines.add("  bootrom: " & yaml_str(cfg.gb_bootrom_path))
  else:
    lines.add("  bootrom:")
  lines.add("  fifo: " & $cfg.gb_fifo)
  writeFile(path, lines.join("\n") & "\n")
