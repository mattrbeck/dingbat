## The Settings window as data. config_editor.nim describes its tabs once
## (rows, their values as edited, what is greyed out or hidden) and two
## windows draw that: Dear ImGui's (imgui_settings.nim) on Windows and Linux,
## and a native window on macOS (mac_settings.nim). Both change the edit
## through ConfigEditor's `set_value` and `activate`; Apply, Revert, OK and the
## questions on closing stay the editor's.
## No SDL, ImGui or GL, so tests build it headless.

type
  SettingId* = enum
    siNone
    # Video
    siFilter, siPreserveAspect, siLcdResponse, siSgbEnable, siSgbBorder, siNdsHd
    # BIOS
    siGbaBios, siRunBios, siBiosMode, siNdsBios9, siNdsBios7, siNdsFirmware
    # General, Controller
    siDsBeta, siRumble, siLibraryOpen
    # Bindings: `arg` is the Input's ordinal, or DS_ARG + the DsInput's
    siKeyPreset, siKeyBinding, siPadDefaults, siPadBinding

  RowKind* = enum
    rkLabel      ## `title` (and `help`); `rows` below it, indented
    rkToggle     ## a checkbox: `on`
    rkChoice     ## radio buttons: `options` / `values`, the chosen `value`
    rkPath       ## a file's path (`text`, `hint`, `valid`) and Browse
    rkNote       ## greyed text; "\n" breaks a line in the ImGui window
    rkText       ## plain text
    rkSeparator
    rkFold       ## `rows` under a folded header (macOS shows them open)
    rkPreset     ## a pick-list whose choice acts, `hint` its prompt
    rkBinding    ## a binding's button (`text`, its key) beside `title`;
                 ## `on` while it waits for a key or button
    rkButton

  SettingRow* = object
    kind*:     RowKind
    id*:       SettingId
    arg*:      int
    title*, help*, hint*, text*: string
    on*:       bool
    value*:    int
    options*:  seq[string]
    values*:   seq[int]
    option_on*: seq[bool]   ## per option: can be chosen
    inline*:   bool         ## rkChoice: options on one line
    enabled*:  bool
    shown*:    bool         ## false: kept in place, not drawn
    valid*:    bool         ## rkPath: empty or an existing file
    width*:    float32      ## ImGui: the field or button width (0: natural)
    label_col*: float32     ## ImGui rkPath: the help marker's column (0: after the title)
    rows*:     seq[SettingRow]

  SettingsTab* = object
    title*: string
    rows*:  seq[SettingRow]

const DS_ARG* = 100

proc row(kind: RowKind; id = siNone; title = ""; help = ""): SettingRow =
  SettingRow(kind: kind, id: id, title: title, help: help, enabled: true,
             shown: true, valid: true)

proc label*(title: string; help = ""; rows: seq[SettingRow] = @[]): SettingRow =
  result = row(rkLabel, title = title, help = help)
  result.rows = rows

proc group*(rows: seq[SettingRow]): SettingRow =
  ## Rows indented under the one before, with no title of their own
  label("", rows = rows)

proc toggle*(id: SettingId; title: string; on: bool; help = "";
             enabled = true): SettingRow =
  result = row(rkToggle, id, title, help)
  result.on = on
  result.enabled = enabled

proc choice*(id: SettingId; options: openArray[string]; values: openArray[int];
             value: int; inline = false; option_on: openArray[bool] = []): SettingRow =
  result = row(rkChoice, id)
  result.options = @options
  result.values = @values
  result.value = value
  result.inline = inline
  result.option_on = @option_on
  while result.option_on.len < result.options.len: result.option_on.add true

proc path*(id: SettingId; title, text, hint: string; valid: bool; help = "";
           width = 0'f32; label_col = 0'f32): SettingRow =
  result = row(rkPath, id, title, help)
  result.text = text
  result.hint = hint
  result.valid = valid
  result.width = width
  result.label_col = label_col

proc note*(text: string; shown = true): SettingRow =
  result = row(rkNote)
  result.text = text
  result.shown = shown

proc text*(text: string): SettingRow =
  result = row(rkText)
  result.text = text

proc separator*(): SettingRow = row(rkSeparator)

proc fold*(title: string; rows: seq[SettingRow]): SettingRow =
  result = row(rkFold, title = title)
  result.rows = rows

proc preset*(id: SettingId; title, hint: string; options: openArray[string]): SettingRow =
  result = row(rkPreset, id, title)
  result.hint = hint
  result.options = @options

proc binding*(id: SettingId; arg: int; title, key: string; capturing: bool;
              width: float32): SettingRow =
  result = row(rkBinding, id, title)
  result.arg = arg
  result.text = key
  result.on = capturing
  result.width = width

proc button*(id: SettingId; title: string): SettingRow = row(rkButton, id, title)

proc signature*(rows: seq[SettingRow]): string =
  ## The rows' shape: kinds, ids and option counts, not values or text. A
  ## window rebuilds a tab when it changes and updates it in place otherwise.
  for r in rows:
    result.add $ord(r.kind) & ":" & $ord(r.id) & ":" & $r.arg & ":" &
               $r.options.len & "("
    result.add signature(r.rows)
    result.add ")"

proc find*(rows: seq[SettingRow]; id: SettingId; arg = 0;
           found: var SettingRow): bool =
  ## The first row of `id` (and `arg`), searching nested rows too.
  for r in rows:
    if r.id == id and r.arg == arg and id != siNone:
      found = r
      return true
    if find(r.rows, id, arg, found): return true
  false
