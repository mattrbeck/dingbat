import std/os
import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/config
import file_explorer
import util

const RED_TEXT_COL = ImVec4(x: 1.0'f32, y: 0.5'f32, z: 0.5'f32, w: 1.0'f32)
const BUF_SIZE     = 512

type
  BiosSelection* = ref object
    cfg*:       Config
    fe*:        FileExplorer
    bios_buf*:  array[BUF_SIZE, char]
    buf_valid*: bool
    run_bios*:  bool
    bios_mode*: cint   # 0 = HLE, 1 = real BIOS, 2 = real BIOS init + HLE SWIs
    visible*:   bool
    overrides*: string # command-line BIOS options in force this run (describe())

proc new_bios_selection*(cfg: Config; fe: FileExplorer): BiosSelection =
  BiosSelection(cfg: cfg, fe: fe, buf_valid: true)

proc bios_buf_str(b: BiosSelection): string =
  $cast[cstring](addr b.bios_buf[0])

proc is_buf_valid(b: BiosSelection): bool =
  let s = b.bios_buf_str()
  s.len == 0 or fileExists(s)

proc render*(b: BiosSelection) =
  igText("GBA BIOS:")
  igSameLine(0, -1)
  help_marker("Optional. Without a BIOS file, BIOS calls are answered by HLE " &
              "(a built-in reimplementation) and the intro is skipped.")
  igSameLine(0, -1)
  let valid = b.buf_valid
  if not valid:
    igPushStyleColor_Vec4(cint(ImGui_Col_Text), RED_TEXT_COL)
  discard igInputTextWithHint("##gba_bios",
    "optional (leave empty for HLE)",
    cast[cstring](addr b.bios_buf[0]), BUF_SIZE.csize_t, 0, nil, nil)
  b.buf_valid = b.is_buf_valid()
  if not valid:
    igPopStyleColor(1)
  igSameLine(0, -1)
  let browse = igButton("Browse##gba_bios", ImVec2(x: 0, y: 0))

  igIndent(106)
  # The intro and the real-BIOS modes need an image: without one the core
  # has only a stub that answers interrupts, and load_rom boots HLE instead.
  let have_file = gba_bios_file_ok(b.bios_buf_str())
  igBeginDisabled(not have_file)
  discard igCheckbox("Run BIOS intro", addr b.run_bios)
  igEndDisabled()

  igText("SWI handling:")
  igSameLine(0, -1)
  help_marker("How GBA BIOS calls are serviced. HLE needs no BIOS file; " &
              "the mode takes effect on the next ROM load.")
  discard igRadioButton_IntPtr("HLE (no BIOS file needed)", addr b.bios_mode, 0)
  igBeginDisabled(not have_file)
  discard igRadioButton_IntPtr("Real BIOS", addr b.bios_mode, 1)
  discard igRadioButton_IntPtr("Real BIOS init, HLE SWI calls", addr b.bios_mode, 2)
  igEndDisabled()
  if not have_file and (b.bios_mode != 0 or b.run_bios):
    igTextDisabled("No BIOS file: GBA games use HLE and skip the intro.")
  if b.overrides.len > 0:
    igTextDisabled("This run only, from the command line: %s", cstring(b.overrides))
  igUnindent(106)

  b.fe.render("GBA BIOS", browse, [], proc(path: string) =
    zeroMem(addr b.bios_buf[0], BUF_SIZE)
    let copy_len = min(path.len, BUF_SIZE - 1)
    copyMem(addr b.bios_buf[0], cstring(path), copy_len)
    b.buf_valid = b.is_buf_valid()
  )

proc reset*(b: BiosSelection) =
  zeroMem(addr b.bios_buf[0], BUF_SIZE)
  let s = b.cfg.bios_path
  if s.len > 0:
    let copy_len = min(s.len, BUF_SIZE - 1)
    copyMem(addr b.bios_buf[0], cstring(s), copy_len)
  b.buf_valid = b.is_buf_valid()
  b.run_bios  = b.cfg.run_bios
  b.bios_mode = if b.cfg.hle_after_bios: 2'i32
                elif b.cfg.use_hle: 0'i32
                else: 1'i32

proc apply*(b: BiosSelection) =
  b.cfg.bios_path      = b.bios_buf_str()
  b.cfg.run_bios       = b.run_bios
  b.cfg.use_hle        = b.bios_mode == 0
  b.cfg.hle_after_bios = b.bios_mode == 2
