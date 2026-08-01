type
  TestOutput* = ref object
    serial_buffer*: string
    sram_status*: uint8
    sram_text*: string
    mooneye_result*: int          # -1=running, 0=pass, 1=fail
    bb_breakpoint*: bool          # LD B,B ends the run whatever the registers hold
    mgba_debug_buffer*: array[256, uint8]
    mgba_debug_pos*: int
    mgba_debug_output*: string
    mgba_debug_enable*: uint16
    finished*: bool
    result_text*: string

proc new_test_output*(): TestOutput =
  TestOutput(mooneye_result: -1)
