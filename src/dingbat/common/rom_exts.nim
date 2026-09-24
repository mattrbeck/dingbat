## The file extensions each core's ROMs go by, for every frontend that picks
## a core by a file's name (the desktop's game_load.nim, the web's
## dingbat_wasm.nim; web/index.js keeps the same list for its file picker).
##
## `.cgb` and `.sgb` are names some ROM sets and homebrew give Color-only
## and Super Game Boy carts; the GB core reads the mode from the header,
## never the name. Not `.dmg`: on macOS that is a disk image, which would
## boot as a Game Boy cart full of noise.

const
  GB_ROM_EXTS* = [".gb", ".gbc", ".cgb", ".sgb"]
  ROM_EXTS* = [".gba", ".gb", ".gbc", ".cgb", ".sgb"]
