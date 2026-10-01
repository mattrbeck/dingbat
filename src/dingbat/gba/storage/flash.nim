# Flash storage implementation (included by gba.nim)

proc new_flash*(flash_type: StorageType): Flash =
  let mem_size = storage_bytes(flash_type)
  result = Flash(
    flash_type: flash_type,
    state: {fsReady},
    bank: 0,
  )
  result.memory = newSeq[byte](mem_size)
  for i in 0 ..< result.memory.len:
    result.memory[i] = 0xFF
  result.id = flash_id(flash_type)

method `[]`*(fl: Flash; address: uint32): uint8 =
  flash_read(fl.memory, fl.state, fl.bank, fl.id, address)

method `[]=`*(fl: Flash; address: uint32; value: uint8) =
  # the command state machine is shared with the DS slot-2 cart (storage_chip.nim)
  if flash_write(fl.memory, fl.state, fl.bank, fl.flash_type, address, value):
    fl.dirty = true
