# No backup chip (included by gba.nim): writes to 0x0E000000-0x0FFFFFFF go
# nowhere and nothing is ever saved.

# Read value: Assumed 0xFF. The one cart known to have no chip (Top Gun:
# Combat Zones, storage_chip.nim find_storage_type) behaves the same whether
# this reads 0xFF, 0x00 or open bus, so no game pins it; measuring needs a
# chipless retail cart.
method `[]`*(st: NoBackup; address: uint32): uint8 = 0xFF'u8

method `[]=`*(st: NoBackup; address: uint32; value: uint8) = discard
