# Keypad implementation (included by gba.nim)

proc new_keypad*(gba: GBA): Keypad =
  result = Keypad(gba: gba)
  result.keyinput = cast[KEYINPUT](0xFFFF'u16)
  result.keycnt   = cast[KEYCNT](0xFFFF'u16)

proc `[]`*(kp: Keypad; io_addr: uint32): uint8 =
  case io_addr
  of 0x130..0x131: read(kp.keyinput, io_addr and 1)
  of 0x132..0x133: read(kp.keycnt, io_addr and 1)
  else: raise newException(Exception, "Unreachable keypad read " & hex_str(uint32(io_addr)))

proc `[]=`*(kp: Keypad; io_addr: uint32; value: uint8) =
  discard  # TODO: stop mode via keycnt

proc handle_input*(kp: Keypad; input: Input; pressed: bool) =
  case input
  of UP:     kp.keyinput.up     = not pressed
  of DOWN:   kp.keyinput.down   = not pressed
  of LEFT:   kp.keyinput.left   = not pressed
  of RIGHT:  kp.keyinput.right  = not pressed
  of A:      kp.keyinput.a      = not pressed
  of B:      kp.keyinput.b      = not pressed
  of SELECT: kp.keyinput.select = not pressed
  of START:  kp.keyinput.start  = not pressed
  of L:      kp.keyinput.l      = not pressed
  of R:      kp.keyinput.r      = not pressed
