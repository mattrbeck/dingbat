# GB Joypad (included by gb.nim)

proc joypad_lines*(j: GbJoypad): uint8 =
  ## The four input pins as they actually read: a bit is 0 while a key of a
  ## selected group holds its line low. Both groups can be selected at once,
  ## in which case either key pulls the shared line down.
  let pressed =
    (if (j.down  and j.direction_keys) or (j.start   and j.button_keys): 0x08'u8 else: 0'u8) or
    (if (j.up    and j.direction_keys) or (j.jselect and j.button_keys): 0x04'u8 else: 0'u8) or
    (if (j.left  and j.direction_keys) or (j.b       and j.button_keys): 0x02'u8 else: 0'u8) or
    (if (j.right and j.direction_keys) or (j.a       and j.button_keys): 0x01'u8 else: 0'u8)
  (not pressed) and 0x0F'u8

proc new_gb_joypad*(): GbJoypad =
  # Nothing selected and nothing held, so every line idles high.
  GbJoypad(prev_lines: 0x0F)

proc joypad_sync*(j: GbJoypad) =
  ## Re-seed the edge detector without raising an interrupt (state loads).
  j.prev_lines = joypad_lines(j)

proc joypad_update*(j: GbJoypad; gb: GB) =
  ## Raise the joypad interrupt on a high-to-low transition of any input line.
  ## Selecting a group whose keys are already held is such a transition, so
  ## this runs after writes to P1 as well as after key changes.
  let now = joypad_lines(j)
  if (j.prev_lines and not now and 0x0F'u8) != 0:
    gb.interrupts.joypad_interrupt = true
  j.prev_lines = now

proc joypad_read*(j: GbJoypad; gb: GB): uint8 =
  # Bits 6-7 are unused and read high; bits 4-5 read back the selection.
  result = 0xC0'u8 or
    (if j.button_keys:    0'u8 else: 0x20'u8) or
    (if j.direction_keys: 0'u8 else: 0x10'u8) or
    joypad_lines(j)
  # SGB multiplayer: with both groups deselected the low nibble is the joypad
  # ID of the current player, 0xF..0xC for players 1..4 (Pan Docs, "Reading
  # Multiple Controllers"); one-player mode pins cur_player at 0.
  if gb.sgb != nil and not j.button_keys and not j.direction_keys:
    result = (result and 0xF0'u8) or (0x0F'u8 - gb.sgb.cur_player)

proc joypad_write*(j: GbJoypad; gb: GB; val: uint8) =
  j.button_keys    = ((val shr 5) and 0x1) == 0
  j.direction_keys = ((val shr 4) and 0x1) == 0
  # The SGB command-packet stream rides on the same two select lines without
  # disturbing the joypad (Pan Docs, "Command Packet Transfers").
  if gb.sgb != nil: sgb_p1_write(gb, val)
  joypad_update(j, gb)

proc handle_input*(j: GbJoypad; gb: GB; inp: Input; pressed: bool) =
  case inp
  of Input.UP:     j.up     = pressed
  of Input.DOWN:   j.down   = pressed
  of Input.LEFT:   j.left   = pressed
  of Input.RIGHT:  j.right  = pressed
  of Input.A:      j.a      = pressed
  of Input.B:      j.b      = pressed
  of Input.SELECT: j.jselect = pressed
  of Input.START:  j.start  = pressed
  else: discard
  joypad_update(j, gb)
