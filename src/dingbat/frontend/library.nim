## The desktop's library: every game opened here, for the home screen's
## grid (library_view.nim draws it). No SDL, ImGui or GL, so
## tests/desktop_library_test.nim runs it headless.
##
## Kept in `library.json` beside dingbat.yml, not in it: `recents` (eight,
## File > Open Recent) stays as it is, so a build without the library reads
## and writes the same settings file, and the library takes in whatever
## recents such a build wrote. The grid's "Last played" order is the recents
## first, as listed, then the rest by when they were last opened.
##
## Names and sorting follow the web's home screen (web/index.js
## displayName, cartLabelFor, libFold, sortRoms, systemOf).

import std/[algorithm, json, os, strutils, times]
import ../common/atomicfile
import persist

const
  LIBRARY_MAX* = 1000   ## games kept; the oldest played go first
  SORTS* = ["recent", "alpha", "system"]

type
  LibGame* = object
    path*:     string  ## what load_rom opens (a zip: the zip)
    rom*:      string  ## the ROM's file name (a zip's: the ROM inside); "" not known
    system*:   string  ## "GBA", "GBC", "GB", "DS"; "" not known
    identity*: string  ## the ROM identity its slot files are named by (8 hex digits); "" not known
    played*:   int64   ## Unix seconds it was last opened; 0 = never here (taken from recents)

  Library* = object
    games*: seq[LibGame]
    sort*:  string     ## one of SORTS

proc find_game*(lib: Library; path: string): int =
  for i, g in lib.games:
    if g.path == path: return i
  -1

proc system_of*(name: string): string =
  ## By extension, as the web's systemOf (".sgb" carts are Game Boy ones).
  case name.splitFile().ext.toLowerAscii()
  of ".gba": "GBA"
  of ".nds": "DS"
  of ".gbc", ".cgb": "GBC"
  of ".gb", ".sgb": "GB"
  else: ""

proc display_name*(g: LibGame): string =
  ## The tile's name: the file's, less its extension (a zip's own name, the
  ## file the player knows).
  let name = g.path.extractFilename()
  let stem = name.splitFile().name
  if stem.len > 0: stem else: name

# ──────────────────────────── The file ────────────────────────────

proc parse_library*(text: string): Library =
  ## Whatever parses; anything else is dropped rather than failing the lot.
  result.sort = "recent"
  var j: JsonNode
  try: j = parseJson(text)
  except CatchableError: return
  if j.kind != JObject: return
  if j.hasKey("sort") and j["sort"].kind == JString and j["sort"].getStr() in SORTS:
    result.sort = j["sort"].getStr()
  if not j.hasKey("games") or j["games"].kind != JArray: return
  for e in j["games"]:
    if e.kind != JObject or not e.hasKey("path") or e["path"].kind != JString: continue
    let path = e["path"].getStr()
    if path.len == 0 or result.find_game(path) >= 0: continue
    var g = LibGame(path: path)
    if e.hasKey("rom") and e["rom"].kind == JString: g.rom = e["rom"].getStr()
    if e.hasKey("system") and e["system"].kind == JString: g.system = e["system"].getStr()
    if e.hasKey("identity") and e["identity"].kind == JString:
      g.identity = e["identity"].getStr()
    if e.hasKey("played") and e["played"].kind == JInt: g.played = e["played"].getBiggestInt()
    result.games.add g

proc library_json*(lib: Library): string =
  var games = newJArray()
  for g in lib.games:
    games.add %*{"path": g.path, "rom": g.rom, "system": g.system,
                 "identity": g.identity, "played": g.played}
  pretty(%*{"version": 1, "sort": lib.sort, "games": games}) & "\n"

proc merge_recents*(lib: var Library; recents: seq[string];
                    probe: proc(path: string): LibGame = nil): bool =
  ## Takes in recents the library does not hold yet (the first run, or a
  ## build without the library since), described by `probe` (nil: by the
  ## file's name). True when it added any.
  for r in recents:
    if r.len > 0 and lib.find_game(r) < 0:
      lib.games.add(if probe != nil: probe(r)
                    else: LibGame(path: r, rom: r.extractFilename(),
                                  system: system_of(r)))
      result = true

proc read_library*(path: string; recents: seq[string];
                   probe: proc(path: string): LibGame = nil):
                  tuple[lib: Library; added: bool] =
  ## The file (a new library when there is none) with the recents it lacks;
  ## `added` when it took any in, so the file wants writing.
  result.lib.sort = "recent"
  if fileExists(path):
    try: result.lib = parse_library(readFile(path))
    except CatchableError: discard
  result.added = result.lib.merge_recents(recents, probe)

proc write_library*(lib: Library; path: string): string =
  ## "" when it landed, else why not (the library in memory stays).
  try:
    createDir(path.parentDir)
    write_file_atomic(path, library_json(lib), sync = false)
    ""
  except CatchableError as e:
    e.msg

proc note_played*(lib: var Library; g: LibGame; now = getTime().toUnix()) =
  ## A game just opened: its entry, new or refreshed, played now. Past
  ## LIBRARY_MAX the longest unplayed goes.
  var e = g
  e.played = now
  let i = lib.find_game(g.path)
  if i >= 0: lib.games.delete(i)
  lib.games.insert(e, 0)
  if lib.games.len > LIBRARY_MAX:
    var oldest = 0
    for k, x in lib.games:
      if x.played < lib.games[oldest].played: oldest = k
    lib.games.delete(oldest)

proc remove*(lib: var Library; path: string) =
  let i = lib.find_game(path)
  if i >= 0: lib.games.delete(i)

# ──────────────────────────── Order and search ────────────────────────────

const SYSTEM_ORDER = ["GBA", "GBC", "GB", "DS"]

proc system_rank(s: string): int =
  let i = SYSTEM_ORDER.find(s)
  if i >= 0: i else: SYSTEM_ORDER.len

proc shown*(lib: Library; recents: seq[string]; ds_beta: bool): seq[LibGame] =
  ## The grid's games in the library's sort; DS games only with DS Beta on.
  for g in lib.games:
    if g.system == "DS" and not ds_beta: continue
    result.add g
  case lib.sort
  of "alpha":
    result.sort(proc(a, b: LibGame): int =
      cmp(a.display_name.toLowerAscii(), b.display_name.toLowerAscii()))
  of "system":
    result.sort(proc(a, b: LibGame): int =
      result = cmp(system_rank(a.system), system_rank(b.system))
      if result == 0:
        result = cmp(a.display_name.toLowerAscii(), b.display_name.toLowerAscii()))
  else:
    # The recents as listed, then the rest by when they were last opened.
    proc rank(g: LibGame): int =
      let i = recents.find(g.path)
      if i >= 0: i else: recents.len
    result.sort(proc(a, b: LibGame): int =
      result = cmp(rank(a), rank(b))
      if result == 0: result = cmp(b.played, a.played))

proc lib_fold*(s: string): string =
  ## Lowercase letters and digits only: "Fire-Red" is "firered".
  for c in s.toLowerAscii():
    if c in {'a'..'z', '0'..'9'}: result.add c

proc subsequence(needle, hay: string): bool =
  var i = 0
  for c in hay:
    if i < needle.len and c == needle[i]: inc i
  i == needle.len

proc word_matches(word, folded: string): bool =
  folded.contains(word) or (word.len >= 3 and subsequence(word, folded))

proc search_match*(query, name: string): bool =
  ## Every word of the query somewhere in the name, in any order; a word of
  ## three or more letters also matches as letters in order ("pkmn"). Two
  ## words typed apart also match as one ("fire red").
  let folded = lib_fold(name)
  var words: seq[string]
  for w in query.splitWhitespace():
    let f = lib_fold(w)
    if f.len > 0: words.add f
  if words.len == 0: return true
  var all = true
  for w in words:
    if not word_matches(w, folded): all = false
  if all: return true
  words.len > 1 and word_matches(words.join(""), folded)

# ──────────────────────────── The cartridge's label ────────────────────────────

proc cart_title(name: string): string =
  ## The name less its dump tags: "0412 - Metroid Fusion (U) [!]" is
  ## "Metroid Fusion", "Legend of Zelda, The" is "The Legend of Zelda".
  var s = name.splitFile().name
  if s.len == 0: s = name
  var t = ""
  var depth = 0
  for c in s:
    if c in {'(', '['}: inc depth
    elif c in {')', ']'} and depth > 0: dec depth
    elif depth == 0: t.add c
  s = t
  # "0412 - " release numbers
  var i = 0
  while i < s.len and s[i] == ' ': inc i
  var d = i
  while d < s.len and s[d].isDigit: inc d
  if d - i in 3 .. 5:
    var k = d
    while k < s.len and s[k] == ' ': inc k
    if k < s.len and s[k] == '-':
      inc k
      while k < s.len and s[k] == ' ': inc k
      s = s[k .. ^1]
  let comma = s.find(',')
  if comma > 0:
    let rest = s[comma + 1 .. ^1].strip(trailing = false)
    for art in ["The", "A", "An"]:
      if rest.len >= art.len and rest[0 ..< art.len].cmpIgnoreCase(art) == 0 and
         (rest.len == art.len or not rest[art.len].isAlphaNumeric):
        s = rest[0 ..< art.len] & " " & s[0 ..< comma] & rest[art.len .. ^1]
        break
  result = s.replace('_', ' ').splitWhitespace().join(" ")
  if result.len == 0: result = name

proc cart_label*(name: string): string =
  ## Two initials and a sequel's number ("Wario Land 3" is "WL3"), or one
  ## word's first two letters ("Tetris" is "Te"): the mark on a picture-less
  ## tile's cartridge.
  let bare = cart_title(name).replace("'", "")
  var src = bare
  if ' ' notin bare and '_' notin bare:
    # One run with no spaces splits where its capitals and digits start
    src = ""
    for k, c in bare:
      if k > 0 and ((c.isUpperAscii and bare[k - 1].isLowerAscii) or
                    (c.isDigit and bare[k - 1].isAlphaAscii)):
        src.add ' '
      src.add c
  var words: seq[string]
  var cur = ""
  for c in src:
    if c in {' ', '\t', '-', ':', '.', ',', '&', '!', '_'}:
      if cur.len > 0: words.add cur
      cur = ""
    else: cur.add c
  if cur.len > 0: words.add cur
  const roman = [("ii", "2"), ("iii", "3"), ("iv", "4"), ("vi", "6"),
                 ("vii", "7"), ("viii", "8"), ("ix", "9")]
  var num = ""
  for k in 1 ..< words.len:
    let w = words[k].toLowerAscii()
    if w.len in 1 .. 3 and w.allCharsInSet(Digits):
      num = w
    else:
      for (r, v) in roman:
        if w == r: num = v
    if num.len > 0:
      words.delete(k)
      break
  const small = ["the", "a", "an", "of", "and", "version", "edition"]
  var sig: seq[string]
  for w in words:
    if w.toLowerAscii() notin small: sig.add w
  if sig.len == 0: sig = words
  if sig.len == 0: return ""
  if sig.len == 1:
    let w = sig[0]
    result = $w[0].toUpperAscii()
    if w.len > 1: result.add w[1].toLowerAscii()
    return result & num
  $sig[0][0].toUpperAscii() & $sig[1][0].toUpperAscii() & num

# ──────────────────────────── Pictures ────────────────────────────
#
# A tile's picture is the newest of: the game's last screen (written when it
# is left: another game opened, or dingbat quit), and its save-state slots'
# thumbnails. Never anything fetched.

proc picture_name*(rom: string; identity: uint32): string =
  ## Named as the game's Quick slot is (persist.state_file_name).
  state_file_name(rom, identity, 0).changeFileExt(".png")

proc picture_files*(g: LibGame; pictures_dir, states_dir: string): seq[string] =
  ## Where a picture of the game could be. With no identity known (a game
  ## taken in from recents), any slot of a ROM of that file name.
  if g.rom.len == 0: return
  if g.identity.len == 8:
    try:
      let id = uint32(parseHexInt(g.identity))
      result.add pictures_dir / picture_name(g.rom, id)
      for slot in 0 ..< 9:
        result.add states_dir / state_file_name(g.rom, id, slot)
      return
    except ValueError: discard
  for slot in 0 ..< 9:
    result.add states_dir / legacy_state_file_name(g.rom, slot)
  # By prefix, not a glob: dump tags like "[!]" are glob syntax
  let prefix = g.rom & "-"
  if dirExists(states_dir):
    for kind, f in walkDir(states_dir):
      let name = f.extractFilename()
      if kind == pcFile and name.startsWith(prefix) and name.endsWith(".state"):
        result.add f

proc newest_picture*(g: LibGame; pictures_dir, states_dir: string):
                    tuple[path: string; time: Time] =
  ## The newest file picture_files names that is there; ("", 0) for none.
  for f in picture_files(g, pictures_dir, states_dir):
    try:
      let t = getLastModificationTime(f)
      if result.path.len == 0 or t > result.time: result = (f, t)
    except OSError: discard

# ──────────────────────────── The grid ────────────────────────────

type GridLayout* = object
  ## In the web's CSS px (the caller scales): how many columns, each tile's
  ## width, and the width the head and the bar are ruled to.
  cols*:   int
  track*:  float32
  width*:  float32   ## the block: head, bar and grid, centred
  grid_w*: float32   ## the tiles' own row, centred under the head

const
  LIB_GAP* = 10'f32
  LIB_PAD* = 24'f32
  LIB_MAX_W = 1400'f32

proc grid_layout*(viewport_w: float32; n: int; pad = LIB_PAD): GridLayout =
  ## web/styles.css "#home-inner": 1 to 6 columns by the window's width; a
  ## library short of a row draws only its own columns, and at least a floor
  ## wide, so the head is ruled over its own tiles.
  let vw = viewport_w
  let cols = if vw < 360: 1 elif vw < 640: 2 elif vw < 900: 3
             elif vw < 1150: 4 elif vw < 1400: 5 else: 6
  let w = max(1'f32, min(LIB_MAX_W, vw - 2 * pad))
  let tile = (w - float32(cols - 1) * LIB_GAP) / float32(cols)
  let fit = if n >= 1 and n < cols and (n == 1 or vw >= 760): n else: cols
  var floor = 460'f32
  var tile_max = 300'f32
  if vw >= 760 and n == 2: (floor, tile_max) = (min(w, 780'f32), 520'f32)
  if vw >= 760 and n == 3: (floor, tile_max) = (min(w, 1000'f32), 520'f32)
  let width = min(w, max(floor, float32(fit) * tile + float32(fit - 1) * LIB_GAP))
  let track = min(tile_max, (width - float32(fit - 1) * LIB_GAP) / float32(fit))
  GridLayout(cols: fit, track: track, width: width,
             grid_w: float32(fit) * track + float32(fit - 1) * LIB_GAP)
