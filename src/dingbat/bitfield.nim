import macros

# Bitfield DSL after github.com/mattrbeck/bitfield; fields listed LSB first.
#
#   bitfield MyReg, uint32:
#     num mode, 5
#     bool thumb
#     num reserved, 20, read_only = true
#     bool overflow
#
# Generates a `value: T` object, inline getters/setters, and read_byte /
# write_byte (read_byte hides write_only fields, write_byte ignores read_only).

proc needsQuoting(s: string): bool =
  s in ["type", "end", "begin", "if", "for", "while", "var", "let",
        "const", "proc", "method", "template", "macro", "import",
        "from", "as", "export", "interface", "is", "of", "in", "not",
        "and", "or", "xor", "div", "mod", "shl", "shr", "addr", "ptr",
        "ref", "object", "tuple", "enum", "case", "when", "with",
        "out", "static", "nil", "return", "yield", "discard"]

proc makeIdent(name: string): NimNode =
  if needsQuoting(name):
    nnkAccQuoted.newTree(ident(name))
  else:
    ident(name)

macro bitfield*(typeName: untyped, baseType: untyped, body: untyped): untyped =
  result = newStmtList()
  var bitOffset = 0
  var readMask  = 0  # bits visible via read_byte  (all except write_only)
  var writeMask = 0  # bits writable via write_byte (all except read_only)

  result.add(nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      nnkPostfix.newTree(ident"*", typeName),
      newEmptyNode(),
      nnkObjectTy.newTree(
        newEmptyNode(),
        newEmptyNode(),
        nnkRecList.newTree(
          nnkIdentDefs.newTree(
            nnkPostfix.newTree(ident"*", ident"value"),
            baseType,
            newEmptyNode()
          )
        )
      )
    )
  ))

  for stmt in body:
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue

    let kindStr = stmt[0].strVal
    if kindStr notin ["bool", "num"]:
      continue

    let isBool = (kindStr == "bool")
    var numBits = 1
    var readOnly  = false
    var writeOnly = false

    # Field name; `:keyword` symbol syntax is accepted.
    let rawName = stmt[1]
    let fieldName: NimNode =
      if rawName.kind == nnkPrefix and rawName[0].strVal == ":":
        rawName[1]
      else:
        rawName

    var modStart = 2
    if not isBool and stmt.len > 2:
      if stmt[2].kind in {nnkIntLit, nnkInt64Lit}:
        numBits  = int(stmt[2].intVal)
        modStart = 3

    for i in modStart ..< stmt.len:
      let arg = stmt[i]
      if arg.kind in {nnkExprColonExpr, nnkExprEqExpr}:
        let modName = arg[0].strVal
        let modVal  = arg[1].strVal == "true"
        case modName
        of "read_only":  readOnly  = modVal
        of "write_only": writeOnly = modVal
        else: discard

    let offset  = newLit(bitOffset)
    let maskVal = (1 shl numBits) - 1
    let mask    = newLit(maskVal)
    let fieldBits = maskVal shl bitOffset
    if not readOnly:  writeMask = writeMask or fieldBits
    if not writeOnly: readMask  = readMask  or fieldBits
    bitOffset  += numBits

    # Getter (write_only fields still get one for internal use).
    let fn = makeIdent(fieldName.strVal)
    if isBool:
      result.add(quote do:
        proc `fn`*(self: `typeName`): bool {.inline.} =
          ((self.value shr `offset`) and 1) != 0
      )
    else:
      result.add(quote do:
        proc `fn`*(self: `typeName`): `baseType` {.inline.} =
          `baseType`((self.value shr `offset`) and `baseType`(`mask`))
      )

    if not readOnly:
      let setterName = makeIdent(fieldName.strVal & "=")
      if isBool:
        result.add(quote do:
          proc `setterName`*(self: var `typeName`, v: bool) {.inline.} =
            let m = `baseType`(1) shl `offset`
            self.value = (self.value and not m) or (`baseType`(ord(v)) shl `offset`)
        )
      else:
        result.add(quote do:
          proc `setterName`*(self: var `typeName`, v: `baseType`) {.inline.} =
            let m = `baseType`(`mask`)
            self.value = (self.value and not(m shl `offset`)) or ((v and m) shl `offset`)
        )

  let readMaskLit  = newLit(readMask)
  let writeMaskLit = newLit(writeMask)
  result.add(quote do:
    proc read_byte*(self: `typeName`, byte_num: uint32): uint8 {.inline.} =
      let shift = 8'u32 * byte_num
      uint8(self.value shr shift) and uint8((`readMaskLit` shr shift) and 0xFF)
    proc write_byte*(self: var `typeName`, byte_num: uint32, v: uint8) {.inline.} =
      let shift = 8'u32 * byte_num
      let byte_mask = uint8((`writeMaskLit` shr shift) and 0xFF)
      let m = not(`baseType`(0xFF'u32) shl shift)
      self.value = (self.value and m) or (`baseType`(v and byte_mask) shl shift)
  )
