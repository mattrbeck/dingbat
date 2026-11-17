## The desktop library (src/dingbat/frontend/library.nim), headless: its
## file, the recents it takes in, the grid's order, search and filters, the
## cartridge marks and the grid's sizes, held to the web home screen's
## (web/index.js cartLabelFor, libSearchMatch, sortRoms; web/styles.css
## "#home-inner").

import std/[math, os, strutils, tempfiles, times]
import dingbat/frontend/library
import dingbat/frontend/persist

var failures = 0

proc check(cond: bool; msg: string) =
  if not cond:
    inc failures
    echo "  FAIL  ", msg

proc paths(games: seq[LibGame]): seq[string] =
  for g in games: result.add g.path

block the_file:
  var lib = Library(sort: "alpha")
  lib.note_played(LibGame(path: "/g/a.gba", rom: "a.gba", system: "GBA",
                          identity: "0000ABCD"), now = 10)
  lib.note_played(LibGame(path: "/g/b.zip", rom: "b.gbc", system: "GBC"), now = 20)
  let back = parse_library(library_json(lib))
  check back.sort == "alpha", "sort kept"
  check back.games == lib.games, "games kept: " & $back.games
  check parse_library("not json").games.len == 0, "garbage reads as empty"
  check parse_library("""{"games": [{"path": 3}, {"path": "/x.gb"}, {"path": "/x.gb"}],
                          "sort": "sideways"}""").games.paths == @["/x.gb"],
        "bad and repeated entries dropped"
  check parse_library("""{"sort": "sideways"}""").sort == "recent", "unknown sort"

block recents_taken_in:
  # A build without the library wrote these
  var lib: Library
  lib.note_played(LibGame(path: "/g/old.gba"), now = 5)
  check lib.merge_recents(@["/g/new.gb", "/g/old.gba", "/g/z.zip"]), "added some"
  check lib.games.paths == @["/g/old.gba", "/g/new.gb", "/g/z.zip"], $lib.games.paths
  check lib.games[1].system == "GB" and lib.games[1].rom == "new.gb", "described by name"
  check lib.games[2].system == "", "a zip is not known by its name"
  check not lib.merge_recents(@["/g/new.gb"]), "nothing new"
  let probed = proc(p: string): LibGame = LibGame(path: p, rom: "in.gbc", system: "GBC")
  check lib.merge_recents(@["/g/y.zip"], probed) and lib.games[^1].rom == "in.gbc",
        "the probe describes it"

block order:
  var lib: Library
  lib.note_played(LibGame(path: "/a.gba", system: "GBA"), now = 1)
  lib.note_played(LibGame(path: "/b.gb", system: "GB"), now = 3)
  lib.note_played(LibGame(path: "/c.nds", system: "DS"), now = 2)
  lib.note_played(LibGame(path: "/d.gbc", system: "GBC"), now = 4)
  # Last played: the recents as listed, then by when last opened
  check lib.shown(@["/a.gba"], ds_beta = true).paths ==
        @["/a.gba", "/d.gbc", "/b.gb", "/c.nds"], $lib.shown(@["/a.gba"], true).paths
  check lib.shown(@[], ds_beta = false).paths == @["/d.gbc", "/b.gb", "/a.gba"],
        "no DS game without DS Beta"
  lib.sort = "alpha"
  check lib.shown(@[], true).paths == @["/a.gba", "/b.gb", "/c.nds", "/d.gbc"], "A-Z"
  lib.sort = "system"
  check lib.shown(@[], true).paths == @["/a.gba", "/d.gbc", "/b.gb", "/c.nds"], "System"
  lib.remove("/b.gb")
  check lib.find_game("/b.gb") < 0, "removed"

block cap:
  var lib: Library
  for i in 0 ..< LIBRARY_MAX + 3:
    lib.note_played(LibGame(path: "/g" & $i), now = int64(i + 1))
  check lib.games.len == LIBRARY_MAX, "capped"
  check lib.find_game("/g0") < 0 and lib.find_game("/g" & $(LIBRARY_MAX + 2)) == 0,
        "the longest unplayed went"

block names:
  check LibGame(path: "/r/Pokemon - FireRed (USA).gba").display_name ==
        "Pokemon - FireRed (USA)", "the file's name less its extension"
  check LibGame(path: "/r/Game.zip").display_name == "Game", "a zip's own name"
  check system_of("x.CGB") == "GBC" and system_of("x.sgb") == "GB" and
        system_of("x.nds") == "DS" and system_of("x.bin") == "", "systems"

block cartridge_marks:
  # web/index.js cartLabelFor's own examples
  for (name, mark) in [("0412 - Metroid Fusion (U) [!].gba", "MF"),
                       ("Legend of Zelda, The - The Minish Cap (U).gba", "LZ"),
                       ("GoodboyGalaxy.gba", "GG"), ("advance_wars_2.gba", "AW2"),
                       ("Final Fantasy VI Advance (J).gba", "FF6"), ("TETRIS.gb", "Te"),
                       ("Wario Land 3", "WL3"), ("Kirby's Dream Land", "KD"),
                       ("Mega Man X", "MM")]:
    check cart_label(name) == mark, name & ": " & cart_label(name) & ", want " & mark

block search:
  check search_match("fire red", "Pokemon - FireRed Version"), "two words as one"
  check search_match("firered", "Pokemon - Fire Red"), "one word over two"
  check search_match("pkmn", "Pokemon"), "letters in order"
  check not search_match("ar", "Pokemon Crystal"), "short words exact"
  check search_match("", "anything"), "nothing typed"
  check search_match("red poke", "Pokemon FireRed"), "any order"

block grid:
  proc near(a, b: float32): bool = abs(a - b) < 0.6
  # Measured on the web page at these widths
  var l = grid_layout(1280, 3)
  check l.cols == 3 and near(l.width, 1000) and near(l.track, 326.7), $l
  l = grid_layout(1280, 10)
  check l.cols == 5 and near(l.track, 238.4) and near(l.width, 1232), $l
  l = grid_layout(1600, 10)
  check l.cols == 6 and near(l.track, 225), $l
  l = grid_layout(720, 10)
  check l.cols == 3 and near(l.track, (672 - 20) / 3), $l
  l = grid_layout(1280, 1)
  check l.cols == 1 and near(l.track, 300) and near(l.width, 460), "one game: " & $l
  l = grid_layout(700, 2)
  check l.cols == 3, "two games under 760px keep the row's columns: " & $l
  l = grid_layout(240, 4, pad = 16)
  check l.cols == 1 and near(l.track, 208), "a small window: " & $l
  # Under a hero (web body.home-card): one or two tiles take the hero's
  # floor, and a phone keeps two columns for one
  l = grid_layout(1280, 1, under_hero = true)
  check l.cols == 1 and near(l.track, 300) and near(l.width, 860), "hero, one: " & $l
  l = grid_layout(1280, 2, under_hero = true)
  check l.cols == 2 and near(l.track, 425) and near(l.width, 860), "hero, two: " & $l
  l = grid_layout(1280, 3, under_hero = true)
  check near(l.width, 1000), "hero, three: as without: " & $l
  l = grid_layout(700, 1, under_hero = true)
  check l.cols == 3, "hero, one, a phone's width: the row's columns: " & $l

block hero:
  var lib: Library
  lib.note_played(LibGame(path: "/a.gba", system: "GBA"), now = 1)
  lib.note_played(LibGame(path: "/b.nds", system: "DS"), now = 2)
  lib.note_played(LibGame(path: "/c.gb", system: "GB"), now = 3)
  check lib.hero_of(@[], ds_beta = true).path == "", "nothing played here: no hero"
  check lib.hero_of(@["/a.gba"], true).path == "/a.gba",
        "the game played here, not the library's newest"
  check lib.hero_of(@["/b.nds", "/a.gba"], true).path == "/b.nds", "the latest played here"
  check lib.hero_of(@["/b.nds", "/a.gba"], false).path == "/a.gba", "no DS game without DS Beta"
  check lib.hero_of(@["/gone.gba"], true).path == "", "one removed since: none"

block relink:
  var lib: Library
  lib.note_played(LibGame(path: "/old/A.gba", rom: "A.gba", system: "GBA",
                          identity: "0000ABCD"), now = 5)
  lib.note_played(LibGame(path: "/new/A2.gba", rom: "A2.gba", system: "GBA"), now = 9)
  lib.note_played(LibGame(path: "/x.gb", rom: "x.gb", system: "GB"), now = 7)
  lib.relink("/old/A.gba", LibGame(path: "/new/A2.gba", rom: "A2.gba", system: "GBA",
                                   identity: "0000ABCD"))
  check lib.games.paths == @["/x.gb", "/new/A2.gba"], "one tile for the file: " & $lib.games.paths
  let e = lib.games[lib.find_game("/new/A2.gba")]
  check e.played == 5 and e.rom == "A2.gba" and e.identity == "0000ABCD",
        "the old entry's, at the new file: " & $e
  lib.relink("/nope", LibGame(path: "/y.gb"))
  check lib.games.len == 2, "no such entry: nothing"
  check session_file_name("/r/Game.gba", 0xABCD'u32) == "Game.gba-0000ABCD.session.state",
        "the session's file"
  check session_file_name("/r/Game.gba", 1) != state_file_name("/r/Game.gba", 1, 0),
        "never a slot's"

block pictures:
  let dir = createTempDir("dingbat_library_", "")
  defer: removeDir(dir)
  let pics = dir / "pictures"
  let states = dir / "states"
  createDir(pics)
  createDir(states)
  let id = 0x1234ABCD'u32
  let g = LibGame(path: "/r/Game [!].gb", rom: "Game [!].gb", identity: id.toHex(8))
  check newest_picture(g, pics, states).path == "", "none yet"
  let slot = states / state_file_name(g.rom, id, 3)
  writeFile(slot, "s")
  setLastModificationTime(slot, fromUnix(1000))
  check newest_picture(g, pics, states).path == slot, "a slot's thumbnail"
  let last = pics / picture_name(g.rom, id)
  writeFile(last, "p")
  setLastModificationTime(last, fromUnix(2000))
  check newest_picture(g, pics, states).path == last, "the newer last screen"
  setLastModificationTime(slot, fromUnix(3000))
  check newest_picture(g, pics, states).path == slot, "a newer save state"
  # Another game's slot of the same name and a different identity
  writeFile(states / state_file_name(g.rom, 7, 0), "x")
  check newest_picture(g, pics, states).path == slot, "never another game's"
  # Identity not known (taken in from recents): any slot of that file name,
  # brackets and all
  let unknown = LibGame(path: g.path, rom: g.rom)
  check unknown.picture_files(pics, states).len >= 2, "found by name"

if failures > 0:
  echo failures, " failed"
  quit(1)
echo "ok"
