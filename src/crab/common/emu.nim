type
  EmuObj* = object of RootObj
  Emu* = ref EmuObj

method run_until_frame*(emu: Emu) {.base.} = discard
method toggle_sync*(emu: Emu) {.base.} = discard
