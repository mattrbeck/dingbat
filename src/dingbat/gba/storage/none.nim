# No backup chip (included by gba.nim): writes to 0x0E000000-0x0FFFFFFF go
# nowhere and nothing is ever saved.

# Read value: Assumed 0xFF. The one cart known to have no chip (storage.nim)
# behaves identically whether this area reads 0xFF, 0x00 or open bus, so no
# game pins it; measuring it needs a chipless retail cart in the slot.
method `[]`*(st: NoBackup; address: uint32): uint8 = 0xFF'u8

method `[]=`*(st: NoBackup; address: uint32; value: uint8) = discard
