## ARM946E-S system control coprocessor (CP15): control register, TCM
## regions, protection unit and cache registers. The TCM settings feed the
## ARM9 bus's map (bus9.nim); the cache tags and the protection unit's
## access rights live in timing.nim (cache timing, aborts) -- see
## docs/nds/spec.md.

type
  Cp15* = object
    control*: uint32          ## c1,c0,0
    dtcm_reg*: uint32         ## c9,c1,0
    itcm_reg*: uint32         ## c9,c1,1
    dtcm_base*: uint32
    dtcm_size*: uint32        ## virtual size (mirroring window), bytes
    itcm_size*: uint32        ## virtual size from base 0, bytes
    dtcm_enabled*, itcm_enabled*: bool   ## control bits 16 / 18
    dtcm_load_mode*, itcm_load_mode*: bool  ## bits 17 / 19: writes only
    prot_regions*: array[8, uint32]      ## c6,c0..c7
    dcache_cfg*, icache_cfg*, wbuf_cfg*: uint32
    data_perm*, code_perm*: uint32       ## c5,c0,2 / c5,c0,3: 4 bits per region
    dcache_lock*, icache_lock*: uint32
    trace_pid*: uint32        ## c13,c0,1 / c13,c1,1: plain R/W (libnds keeps
                              ## its IRQ mask here across handlers)
    halt_request*: bool       ## c7,c0,4 / c7,c8,2: wait for interrupt

const
  CP15_ID* = 0x41059461'u32
  CP15_CACHE_TYPE* = 0x0F0D2112'u32
  CP15_TCM_SIZE* = 0x00140180'u32
  CP15_CONTROL_FIXED* = 0x00000078'u32  ## bits 3-6 read as one

proc tcm_size_of(reg: uint32): uint32 =
  ## Region register size field: 512 shl n bytes (n = bits 1-5).
  let n = (reg shr 1) and 0x1F
  if n < 3: 4096'u32 else: 512'u32 shl n

proc update_tcm(c: var Cp15) =
  c.dtcm_base = c.dtcm_reg and 0xFFFF_F000'u32
  c.dtcm_size = tcm_size_of(c.dtcm_reg)
  c.itcm_size = tcm_size_of(c.itcm_reg)
  c.dtcm_enabled = (c.control and (1'u32 shl 16)) != 0
  c.dtcm_load_mode = (c.control and (1'u32 shl 17)) != 0
  c.itcm_enabled = (c.control and (1'u32 shl 18)) != 0
  c.itcm_load_mode = (c.control and (1'u32 shl 19)) != 0

proc reset*(c: var Cp15) =
  c = Cp15()
  c.control = 0x00012078'u32   ## reset value: DTCM on, everything else off
  c.update_tcm()

proc vector_base*(c: Cp15): uint32 =
  if (c.control and (1'u32 shl 13)) != 0: 0xFFFF0000'u32 else: 0

proc ap_compact(ext: uint32): uint32 =
  ## c5,c0,0/1 view of the extended permissions: the low 2 bits of each
  ## region's 4-bit field (GBATEK "CP15 Protection Unit").
  for i in 0'u32 .. 7:
    result = result or (((ext shr (i * 4)) and 3) shl (i * 2))

proc ap_extend(compact: uint32): uint32 =
  for i in 0'u32 .. 7:
    result = result or (((compact shr (i * 2)) and 3) shl (i * 4))

proc read*(c: Cp15; op1, cn, cm, op2: uint32): uint32 =
  case cn
  of 0:
    case op2
    of 1: CP15_CACHE_TYPE
    of 2: CP15_TCM_SIZE
    else: CP15_ID
  of 1: c.control
  of 2: (if op2 == 1: c.icache_cfg else: c.dcache_cfg)
  of 3: c.wbuf_cfg
  of 5:
    case op2
    of 0: ap_compact(c.data_perm)
    of 1: ap_compact(c.code_perm)
    of 2: c.data_perm
    else: c.code_perm
  of 6: c.prot_regions[cm and 7]
  of 9:
    if cm == 1: (if op2 == 1: c.itcm_reg else: c.dtcm_reg)
    else: (if op2 == 1: c.icache_lock else: c.dcache_lock)
  of 13: (if op2 == 1: c.trace_pid else: 0'u32)   # c13,c0,0 FCSE PID reads 0
  else: 0

proc write*(c: var Cp15; op1, cn, cm, op2, v: uint32) =
  ## Returns nothing; callers re-read the TCM fields afterwards.
  case cn
  of 1:
    c.control = (c.control and not 0x000FF085'u32) or (v and 0x000FF085'u32) or
                CP15_CONTROL_FIXED
  of 2: (if op2 == 1: c.icache_cfg = v else: c.dcache_cfg = v)
  of 3: c.wbuf_cfg = v
  of 5:
    case op2
    of 0: c.data_perm = ap_extend(v)
    of 1: c.code_perm = ap_extend(v)
    of 2: c.data_perm = v
    else: c.code_perm = v
  of 6: c.prot_regions[cm and 7] = v
  of 7:
    if (cm == 0 and op2 == 4) or (cm == 8 and op2 == 2): c.halt_request = true
    # cache maintenance: nothing to do without a cache model
  of 9:
    if cm == 1:
      if op2 == 1: c.itcm_reg = v and 0x3E'u32   # ITCM base is fixed at 0
      else: c.dtcm_reg = v and 0xFFFF_F03E'u32
    else:
      if op2 == 1: c.icache_lock = v else: c.dcache_lock = v
  of 13:
    if op2 == 1: c.trace_pid = v
  else: discard
  c.update_tcm()
