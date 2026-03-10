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
    visible*:   bool

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
  help_marker("A BIOS is embedded and used by default. You can optionally provide your own.")
  igSameLine(0, -1)
  let valid = b.buf_valid
  if not valid:
    igPushStyleColor_Vec4(cint(ImGui_Col_Text), RED_TEXT_COL)
  discard igInputTextWithHint("##gba_bios",
    "optional (leave empty for embedded BIOS)",
    cast[cstring](addr b.bios_buf[0]), BUF_SIZE.csize_t, 0, nil, nil)
  b.buf_valid = b.is_buf_valid()
  if not valid:
    igPopStyleColor(1)
  igSameLine(0, -1)
  let browse = igButton("Browse##gba_bios", ImVec2(x: 0, y: 0))

  igIndent(106)
  discard igCheckbox("Run BIOS intro", addr b.run_bios)
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

proc apply*(b: BiosSelection) =
  b.cfg.bios_path = b.bios_buf_str()
  b.cfg.run_bios  = b.run_bios
