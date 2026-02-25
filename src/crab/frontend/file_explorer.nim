import std/[os, algorithm, strutils]
import imguin/[cimgui, impl_opengl, impl_sdl2]
import ../common/config

type
  FileEntry = object
    name:      string
    is_file:   bool
    extension: string
    hidden:    bool

  FileExplorer* = ref object
    cfg*:          Config
    entries:       seq[FileEntry]
    selected_idx:  int
    show_hidden:   bool
    open*:         bool

proc gather_entries(fe: FileExplorer) =
  fe.entries.setLen(0)
  try:
    for kind, path in walkDir(fe.cfg.explorer_dir):
      let name = extractFilename(path)
      let is_file = kind == pcFile
      let dot_pos = name.rfind('.')
      let ext = if dot_pos > 0 and dot_pos < name.len - 1: name[dot_pos + 1 .. ^1] else: ""
      let hidden = name.startsWith('.')
      fe.entries.add(FileEntry(name: name, is_file: is_file, extension: ext, hidden: hidden))
  except:
    discard
  # Add parent dir entry
  fe.entries.add(FileEntry(name: "..", is_file: false, extension: "", hidden: false))
  # Sort: dirs first, then alpha
  fe.entries.sort(proc(a, b: FileEntry): int =
    if a.is_file and not b.is_file: 1
    elif not a.is_file and b.is_file: -1
    else: cmp(a.name, b.name))

proc new_file_explorer*(cfg: Config): FileExplorer =
  result = FileExplorer(cfg: cfg, selected_idx: 0)
  result.gather_entries()

proc close*(fe: FileExplorer) =
  fe.open = false
  igCloseCurrentPopup()

proc render*(fe: FileExplorer; name: string; open_popup: bool;
             extensions: openArray[string]; handler: proc(path: string)) =
  if open_popup:
    fe.open = true
    igOpenPopup_Str(cstring(name), 0)

  var center = ImVec2(x: 0, y: 0)
  let vp = igGetMainViewport()
  if vp != nil:
    ImGuiViewport_GetCenter(addr center, vp)
  igSetNextWindowPos(center, cint(ImGui_Cond_Appearing),
                     ImVec2(x: 0.5'f32, y: 0.5'f32))

  if igBeginPopupModal(cstring(name), nil, cint(ImGui_WindowFlags_AlwaysAutoResize)):
    # Breadcrumb navigation
    let sep = $DirSep
    var parts = fe.cfg.explorer_dir.split(sep)
    # Remove empty parts from root /
    var parts_clean: seq[string] = @[]
    for p in parts:
      if p.len > 0: parts_clean.add(p)

    var first = true
    var so_far = ""
    for idx, part in parts_clean:
      if not first: igSameLine(0, -1)
      first = false
      when defined(windows):
        so_far = if idx == 0: part else: so_far & sep & part
      else:
        so_far = "/" & parts_clean[0 .. idx].join("/")
      let target = so_far
      if igButton(cstring(part), ImVec2(x: 0, y: 0)):
        fe.cfg.explorer_dir = normalizedPath(target)
        save_config(fe.cfg)
        fe.gather_entries()

    # File list
    var disp_size = ImVec2(x: 800, y: 600)
    let vp2 = igGetMainViewport()
    if vp2 != nil:
      disp_size = vp2[].Size
    let width  = min(disp_size.x - 40, 600'f32)
    let height = min(disp_size.y - 40, 16'f32 * igGetTextLineHeightWithSpacing())

    var navigate_to = ""
    if igBeginListBox("##files", ImVec2(x: width, y: height)):
      for idx, entry in fe.entries:
        if entry.hidden and not fe.show_hidden: continue
        if entry.is_file and extensions.len > 0:
          var ok = false
          for ext in extensions:
            if entry.extension == ext: ok = true; break
          if not ok: continue
        let is_selected = idx == fe.selected_idx
        let label = if entry.is_file: "[F] " & entry.name
                    else: "[D] " & entry.name & "/"
        if igSelectable_Bool(cstring(label), is_selected,
                             cint(ImGui_SelectableFlags_AllowDoubleClick),
                             ImVec2(x: 0, y: 0)):
          if entry.is_file:
            fe.selected_idx = idx
            if igIsMouseDoubleClicked_Nil(0):
              let path = fe.cfg.explorer_dir / entry.name
              handler(path)
              fe.close()
          elif igIsMouseDoubleClicked_Nil(0):
            navigate_to = if entry.name == "..":
              parentDir(fe.cfg.explorer_dir)
            else:
              fe.cfg.explorer_dir / entry.name
        if is_selected:
          igSetItemDefaultFocus()
      igEndListBox()
    if navigate_to.len > 0:
      fe.cfg.explorer_dir = normalizedPath(navigate_to)
      save_config(fe.cfg)
      fe.gather_entries()
      fe.selected_idx = 0

    # Bottom buttons
    igBeginGroup()
    if igButton("Open", ImVec2(x: 0, y: 0)):
      if fe.selected_idx < fe.entries.len and fe.entries[fe.selected_idx].is_file:
        let path = fe.cfg.explorer_dir / fe.entries[fe.selected_idx].name
        handler(path)
        fe.close()
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2(x: 0, y: 0)):
      fe.close()
    igSameLine(0, 10)
    discard igCheckbox("Show hidden files?", addr fe.show_hidden)
    igEndGroup()

    igEndPopup()
