# No backup chip (included by gba.nim): writes to 0x0E000000-0x0FFFFFFF go
# nowhere and nothing is ever saved.

# Read value: Assumed 0xFF; no known game depends on it (measuring needs a
# chipless retail cart).
method `[]`*(st: NoBackup; address: uint32): uint8 = 0xFF'u8

method `[]=`*(st: NoBackup; address: uint32; value: uint8) = discard
