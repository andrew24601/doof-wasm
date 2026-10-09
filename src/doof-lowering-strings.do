import { createMinusFunction, instruction, value } from "./minus-build"
import { minusBlocks } from "./minus-control-flow"
// Synthesized string construction used by compiler diagnostics and source tokenization.
import { STRING_CLASS, CHAR_ARRAY_CLASS, arrayClassName } from "./doof-lowering-constants"
import { MinusModule, MinusFunction, MinusBlock, MinusValue, MinusInstruction } from "./minus-ir"
import { MinusValues, minusValues, minusValueId, minusOperandPositions } from "./minus-analysis"

function uses(module_: MinusModule, target: string): bool {
  for fn of module_.functions {
    for block of minusBlocks(fn) {
      for instruction_ of block.instructions {
        if instruction_.op == "call" && instruction_.args[0] == target { return true }
        if instruction_.op == "call-method" && instruction_.args[1] == target { return true }
      }
    }
  }
  return false
}

export function injectStringConstruction(module_: MinusModule): none {
  if uses(module_, "concat") {
    module_.functions.push(createMinusFunction{
      name: STRING_CLASS + ".concat", params: [value("%self", STRING_CLASS), value("%other", STRING_CLASS)], result: STRING_CLASS,
      blocks: [
        MinusBlock { name: "entry", instructions: [
          instruction("get", ["%self", "chars"], "%leftChars", CHAR_ARRAY_CLASS),
          instruction("get", ["%other", "chars"], "%rightChars", CHAR_ARRAY_CLASS),
          instruction("get", ["%leftChars", "data"], "%leftData", "int"),
          instruction("get", ["%rightChars", "data"], "%rightData", "int"),
          instruction("array-length", ["%leftData"], "%left", "int"),
          instruction("array-length", ["%rightData"], "%right", "int"),
          instruction("const", ["0"], "%zero", "int"),
          instruction("eq", ["%left", "%zero"], "%leftEmpty", "bool"),
          instruction("branch", ["%leftEmpty", "other", "|", "rightCheck"]),
        ] },
        MinusBlock { name: "other", instructions: [instruction("return", ["%other"])] },
        MinusBlock { name: "rightCheck", instructions: [
          instruction("eq", ["%right", "%zero"], "%rightEmpty", "bool"),
          instruction("branch", ["%rightEmpty", "self", "|", "size"]),
        ] },
        MinusBlock { name: "self", instructions: [instruction("return", ["%self"])] },
        MinusBlock { name: "size", instructions: [
          instruction("add", ["%left", "%right"], "%total", "int"),
          instruction("lt", ["%total", "%zero"], "%overflow", "bool"),
          instruction("branch", ["%overflow", "overflow", "|", "allocate"]),
        ] },
        MinusBlock { name: "overflow", instructions: [instruction("panic", [])] },
        MinusBlock { name: "allocate", instructions: [
          instruction("array-alloc", ["%total", "char"], "%data", "int"),
          instruction("array-copy", ["%data", "%zero", "%leftData", "%zero", "%left", "char"]),
          instruction("array-copy", ["%data", "%left", "%rightData", "%zero", "%right", "char"]),
          instruction("new", [CHAR_ARRAY_CLASS, "%data"], "%chars", CHAR_ARRAY_CLASS),
          instruction("new", [STRING_CLASS, "%chars"], "%answer", STRING_CLASS),
          instruction("return", ["%answer"]),
        ] },
      ],
    })
  }
  if uses(module_, "split") {
    module_.functions.push(createMinusFunction{
      name: STRING_CLASS + ".split", params: [value("%self", STRING_CLASS), value("%separator", STRING_CLASS)], result: arrayClassName(STRING_CLASS),
      blocks: [
      MinusBlock { name: "entry", params: [], instructions: [
        instruction("const", ["0"], "%zero", "int"),
        instruction("const", ["1"], "%one", "int"),
        instruction("call-method", ["%self", "length"], "%length", "int"),
        instruction("call-method", ["%separator", "length"], "%width", "int"),
        instruction("array-alloc", ["%zero", STRING_CLASS], "%storage", "int"),
        instruction("new", [arrayClassName(STRING_CLASS), "%storage"], "%parts", arrayClassName(STRING_CLASS)),
        instruction("eq", ["%width", "%zero"], "%empty", "bool"),
        instruction("branch", ["%empty", "characters", "%zero", "%length", "%one", "%parts", "|", "scan", "%zero", "%zero", "%length", "%one", "%parts", "%width", "%zero"])
      ] },
      MinusBlock { name: "characters", params: [value("%ci", "int"), value("%length_characters", "int"), value("%one_characters", "int"), value("%parts_characters", arrayClassName(STRING_CLASS))], instructions: [
        instruction("lt", ["%ci", "%length_characters"], "%hasChar", "bool"),
        instruction("branch", ["%hasChar", "character", "%ci", "%length_characters", "%one_characters", "%parts_characters", "|", "done", "%parts_characters"])
      ] },
      MinusBlock { name: "character", params: [value("%cp", "int"), value("%length_character", "int"), value("%one_character", "int"), value("%parts_character", arrayClassName(STRING_CLASS))], instructions: [
        instruction("add", ["%cp", "%one_character"], "%cn", "int"),
        instruction("call-method", ["%self", "substring", "%cp", "%cn"], "%single", STRING_CLASS),
        instruction("call-method", ["%parts_character", "push", "%single"], "%ignoredChar", "none"),
        instruction("jump", ["characters", "%cn", "%length_character", "%one_character", "%parts_character"])
      ] },
      MinusBlock { name: "scan", params: [value("%start", "int"), value("%position", "int"), value("%length_scan", "int"), value("%one_scan", "int"), value("%parts_scan", arrayClassName(STRING_CLASS)), value("%width_scan", "int"), value("%zero_scan", "int")], instructions: [
        instruction("sub", ["%length_scan", "%width_scan"], "%last", "int"),
        instruction("lt", ["%last", "%position"], "%past", "bool"),
        instruction("branch", ["%past", "tail", "%start", "%length_scan", "%parts_scan", "|", "match", "%start", "%position", "%zero_scan", "%length_scan", "%one_scan", "%parts_scan", "%width_scan", "%zero_scan"])
      ] },
      MinusBlock { name: "match", params: [value("%ms", "int"), value("%mp", "int"), value("%offset", "int"), value("%length_match", "int"), value("%one_match", "int"), value("%parts_match", arrayClassName(STRING_CLASS)), value("%width_match", "int"), value("%zero_match", "int")], instructions: [
        instruction("lt", ["%offset", "%width_match"], "%more", "bool"),
        instruction("branch", ["%more", "check", "%ms", "%mp", "%offset", "%length_match", "%one_match", "%parts_match", "%width_match", "%zero_match", "|", "found", "%ms", "%mp", "%length_match", "%one_match", "%parts_match", "%width_match", "%zero_match"])
      ] },
      MinusBlock { name: "check", params: [value("%cs", "int"), value("%pos", "int"), value("%off", "int"), value("%length_check", "int"), value("%one_check", "int"), value("%parts_check", arrayClassName(STRING_CLASS)), value("%width_check", "int"), value("%zero_check", "int")], instructions: [
        instruction("add", ["%pos", "%off"], "%index", "int"),
        instruction("call-method", ["%self", "get", "%index"], "%actual", "char"),
        instruction("call-method", ["%separator", "get", "%off"], "%expected", "char"),
        instruction("eq", ["%actual", "%expected"], "%same", "bool"),
        instruction("branch", ["%same", "advance", "%cs", "%pos", "%off", "%length_check", "%one_check", "%parts_check", "%width_check", "%zero_check", "|", "next", "%cs", "%pos", "%length_check", "%one_check", "%parts_check", "%width_check", "%zero_check"])
      ] },
      MinusBlock { name: "advance", params: [value("%as", "int"), value("%ap", "int"), value("%ao", "int"), value("%length_advance", "int"), value("%one_advance", "int"), value("%parts_advance", arrayClassName(STRING_CLASS)), value("%width_advance", "int"), value("%zero_advance", "int")], instructions: [
        instruction("add", ["%ao", "%one_advance"], "%an", "int"),
        instruction("jump", ["match", "%as", "%ap", "%an", "%length_advance", "%one_advance", "%parts_advance", "%width_advance", "%zero_advance"])
      ] },
      MinusBlock { name: "next", params: [value("%ns", "int"), value("%np", "int"), value("%length_next", "int"), value("%one_next", "int"), value("%parts_next", arrayClassName(STRING_CLASS)), value("%width_next", "int"), value("%zero_next", "int")], instructions: [
        instruction("add", ["%np", "%one_next"], "%nn", "int"),
        instruction("jump", ["scan", "%ns", "%nn", "%length_next", "%one_next", "%parts_next", "%width_next", "%zero_next"])
      ] },
      MinusBlock { name: "found", params: [value("%fs", "int"), value("%fp", "int"), value("%length_found", "int"), value("%one_found", "int"), value("%parts_found", arrayClassName(STRING_CLASS)), value("%width_found", "int"), value("%zero_found", "int")], instructions: [
        instruction("call-method", ["%self", "substring", "%fs", "%fp"], "%part", STRING_CLASS),
        instruction("call-method", ["%parts_found", "push", "%part"], "%ignored", "none"),
        instruction("add", ["%fp", "%width_found"], "%following", "int"),
        instruction("jump", ["scan", "%following", "%following", "%length_found", "%one_found", "%parts_found", "%width_found", "%zero_found"])
      ] },
      MinusBlock { name: "tail", params: [value("%ts", "int"), value("%length_tail", "int"), value("%parts_tail", arrayClassName(STRING_CLASS))], instructions: [
        instruction("call-method", ["%self", "substring", "%ts", "%length_tail"], "%lastPart", STRING_CLASS),
        instruction("call-method", ["%parts_tail", "push", "%lastPart"], "%ignoredTail", "none"),
        instruction("jump", ["done", "%parts_tail"])
      ] },
      MinusBlock { name: "done", params: [value("%parts_done", arrayClassName(STRING_CLASS))], instructions: [
        instruction("return", ["%parts_done"])
      ] }
      ],
    })
  }
  if uses(module_, "__doof_format_long") {
    module_.functions.push(createMinusFunction{
      name: "__doof_format_long", params: [value("%input", "long")], result: STRING_CLASS,
      blocks: [
      MinusBlock { name: "entry", params: [], instructions: [
        instruction("const", ["0"], "%zero", "long"),
        instruction("const", ["10"], "%ten", "long"),
        instruction("const", ["0"], "%intZero", "int"),
        instruction("const", ["1"], "%one", "int"),
        instruction("lt", ["%input", "%zero"], "%negative", "bool"),
        instruction("array-alloc", ["%intZero", "char"], "%raw", "int"),
        instruction("new", [CHAR_ARRAY_CLASS, "%raw"], "%digits", CHAR_ARRAY_CLASS),
        instruction("string-const", ["0123456789"], "%alphabet", STRING_CLASS),
        instruction("branch", ["%negative", "digits", "%input", "%alphabet", "%digits", "%intZero", "%negative", "%one", "%ten", "%zero", "|", "negate", "%alphabet", "%digits", "%intZero", "%negative", "%one", "%ten", "%zero"])
      ] },
      MinusBlock { name: "negate", params: [value("%alphabet_negate", STRING_CLASS), value("%digits_negate", CHAR_ARRAY_CLASS), value("%intZero_negate", "int"), value("%negative_negate", "bool"), value("%one_negate", "int"), value("%ten_negate", "long"), value("%zero_negate", "long")], instructions: [
        instruction("sub", ["%zero_negate", "%input"], "%negated", "long"),
        instruction("jump", ["digits", "%negated", "%alphabet_negate", "%digits_negate", "%intZero_negate", "%negative_negate", "%one_negate", "%ten_negate", "%zero_negate"])
      ] },
      MinusBlock { name: "digits", params: [value("%remaining", "long"), value("%alphabet_digits", STRING_CLASS), value("%digits_digits", CHAR_ARRAY_CLASS), value("%intZero_digits", "int"), value("%negative_digits", "bool"), value("%one_digits", "int"), value("%ten_digits", "long"), value("%zero_digits", "long")], instructions: [
        instruction("rem", ["%remaining", "%ten_digits"], "%negativeDigit", "long"),
        instruction("sub", ["%zero_digits", "%negativeDigit"], "%digitLong", "long"),
        instruction("convert", ["%digitLong"], "%digit", "int"),
        instruction("call-method", ["%alphabet_digits", "get", "%digit"], "%character", "char"),
        instruction("call-method", ["%digits_digits", "push", "%character"], "%unused", "none"),
        instruction("div", ["%remaining", "%ten_digits"], "%quotient", "long"),
        instruction("eq", ["%quotient", "%zero_digits"], "%finished", "bool"),
        instruction("branch", ["%finished", "sign", "%digits_digits", "%intZero_digits", "%negative_digits", "%one_digits", "|", "digits", "%quotient", "%alphabet_digits", "%digits_digits", "%intZero_digits", "%negative_digits", "%one_digits", "%ten_digits", "%zero_digits"])
      ] },
      MinusBlock { name: "sign", params: [value("%digits_sign", CHAR_ARRAY_CLASS), value("%intZero_sign", "int"), value("%negative_sign", "bool"), value("%one_sign", "int")], instructions: [
        instruction("branch", ["%negative_sign", "minus", "%digits_sign", "%intZero_sign", "%one_sign", "|", "prepare", "%digits_sign", "%intZero_sign", "%one_sign"])
      ] },
      MinusBlock { name: "minus", params: [value("%digits_minus", CHAR_ARRAY_CLASS), value("%intZero_minus", "int"), value("%one_minus", "int")], instructions: [
        instruction("const", ["45"], "%minus", "char"),
        instruction("call-method", ["%digits_minus", "push", "%minus"], "%unusedSign", "none"),
        instruction("jump", ["prepare", "%digits_minus", "%intZero_minus", "%one_minus"])
      ] },
      MinusBlock { name: "prepare", params: [value("%digits_prepare", CHAR_ARRAY_CLASS), value("%intZero_prepare", "int"), value("%one_prepare", "int")], instructions: [
        instruction("call-method", ["%digits_prepare", "length"], "%count", "int"),
        instruction("array-alloc", ["%count", "char"], "%output", "int"),
        instruction("jump", ["reverse", "%intZero_prepare", "%count", "%digits_prepare", "%one_prepare", "%output"])
      ] },
      MinusBlock { name: "reverse", params: [value("%index", "int"), value("%count_reverse", "int"), value("%digits_reverse", CHAR_ARRAY_CLASS), value("%one_reverse", "int"), value("%output_reverse", "int")], instructions: [
        instruction("lt", ["%index", "%count_reverse"], "%more", "bool"),
        instruction("branch", ["%more", "copy", "%index", "%count_reverse", "%digits_reverse", "%one_reverse", "%output_reverse", "|", "done", "%output_reverse"])
      ] },
      MinusBlock { name: "copy", params: [value("%at", "int"), value("%count_copy", "int"), value("%digits_copy", CHAR_ARRAY_CLASS), value("%one_copy", "int"), value("%output_copy", "int")], instructions: [
        instruction("sub", ["%count_copy", "%at"], "%back", "int"),
        instruction("sub", ["%back", "%one_copy"], "%source", "int"),
        instruction("call-method", ["%digits_copy", "get", "%source"], "%c", "char"),
        instruction("array-set", ["%output_copy", "%at", "%c"]),
        instruction("add", ["%at", "%one_copy"], "%next", "int"),
        instruction("jump", ["reverse", "%next", "%count_copy", "%digits_copy", "%one_copy", "%output_copy"])
      ] },
      MinusBlock { name: "done", params: [value("%output_done", "int")], instructions: [
        instruction("new", [CHAR_ARRAY_CLASS, "%output_done"], "%chars", CHAR_ARRAY_CLASS),
        instruction("new", [STRING_CLASS, "%chars"], "%answer", STRING_CLASS),
        instruction("return", ["%answer"])
      ] }
      ],
    })
  }
  if uses(module_, "__doof_format_char") {
    module_.functions.push(createMinusFunction{
      name: "__doof_format_char", params: [value("%input", "char")], result: STRING_CLASS,
      blocks: [
      MinusBlock { name: "entry", params: [], instructions: [
        instruction("const", ["1"], "%one", "int"),
        instruction("const", ["0"], "%zero", "int"),
        instruction("array-alloc", ["%one", "char"], "%data", "int"),
        instruction("array-set", ["%data", "%zero", "%input"]),
        instruction("new", [CHAR_ARRAY_CLASS, "%data"], "%chars", CHAR_ARRAY_CLASS),
        instruction("new", [STRING_CLASS, "%chars"], "%answer", STRING_CLASS),
        instruction("return", ["%answer"])
      ] }
      ],
    })
  }
}

// Concatenation chains such as `a + b + c` or an interpolated string lower to
// nested two-part concats, each allocating and copying a temporary. Merge a
// concat whose left or right operand is a single-use concat result from the
// same block, then build all parts with one allocation. Chains longer than
// MAX_CONCAT_PARTS are split into successive groups.
readonly MAX_CONCAT_PARTS = 8

export function flattenStringConcats(module_: MinusModule): none {
  let arities: int[] = []
  for function_ of module_.functions {
    if function_.name.startsWith(STRING_CLASS + ".concat") { continue }
    table := minusValues(function_)
    let uses: int[] = []
    for _ of table.values { uses.push(0) }
    blocks := minusBlocks(function_)
    for block_ of blocks {
      for instruction_ of block_.instructions {
        for operand of minusOperandPositions(instruction_) { uses[minusValueId(table, instruction_.args[operand])] += 1 }
      }
    }
    for block_ of blocks { flattenBlock(block_, table, uses, arities) }
  }
  for arity of arities { module_.functions.push(concatFunction(arity)) }
}

function flattenBlock(block_: MinusBlock, table: MinusValues, uses: int[], arities: int[]): none {
  let concats: int[] = []
  let any = false
  for index of 0..<block_.instructions.length {
    instruction_ := block_.instructions[index]
    isConcat := instruction_.op == "call-method" && instruction_.args.length == 3 && instruction_.args[1] == "concat"
      && instruction_.result != none && instruction_.result!.typeName == STRING_CLASS
      && table.values[minusValueId(table, instruction_.args[0])].typeName == STRING_CLASS
      && table.values[minusValueId(table, instruction_.args[2])].typeName == STRING_CLASS
    concats.push(if isConcat then 1 else 0)
    if isConcat { any = true }
  }
  if !any { return }
  // parts[i]: operand names for concat i; absorbed[i]: merged into a later one.
  let parts: string[][] = []
  let absorbed: bool[] = []
  let names: string[] = []
  for index of 0..<block_.instructions.length {
    parts.push([]); absorbed.push(false)
    instruction_ := block_.instructions[index]
    names.push(if instruction_.result != none then instruction_.result!.name else "")
  }
  for index of 0..<block_.instructions.length {
    if concats[index] == 0 { continue }
    instruction_ := block_.instructions[index]
    for operand of [instruction_.args[0], instruction_.args[2]] {
      let source = -1
      if uses[minusValueId(table, operand)] == 1 {
        let cursor = index - 1
        while cursor >= 0 {
          if names[cursor] == operand { source = cursor; break }
          cursor -= 1
        }
      }
      if source >= 0 && concats[source] == 1 && !absorbed[source] {
        absorbed[source] = true
        for part of parts[source] { parts[index].push(part) }
      } else { parts[index].push(operand) }
    }
  }
  let rebuilt: MinusInstruction[] = []
  for index of 0..<block_.instructions.length {
    instruction_ := block_.instructions[index]
    if concats[index] == 0 || parts[index].length <= 2 {
      if !absorbed[index] { rebuilt.push(instruction_) }
      continue
    }
    if absorbed[index] { continue }
    // Group long chains; each group's result becomes the next group's first part.
    let pending = parts[index]
    let group = 0
    while pending.length > 0 {
      let take = if pending.length > MAX_CONCAT_PARTS then MAX_CONCAT_PARTS else pending.length
      let chunk: string[] = []
      for position of 0..<take { chunk.push(pending[position]) }
      let rest: string[] = []
      for position of take..<pending.length { rest.push(pending[position]) }
      final := rest.length == 0
      target := if final then instruction_.result!.name else instruction_.result!.name + "_concat" + string(group)
      if chunk.length == 1 {
        rebuilt.push(MinusInstruction { op: "copy", result: MinusValue { name: target, typeName: STRING_CLASS }, args: [chunk[0]], line: instruction_.line, sourcePath: instruction_.sourcePath })
      } else if chunk.length == 2 {
        rebuilt.push(MinusInstruction { op: "call-method", result: MinusValue { name: target, typeName: STRING_CLASS }, args: [chunk[0], "concat", chunk[1]], line: instruction_.line, sourcePath: instruction_.sourcePath })
      } else {
        let args = [chunk[0], "concat" + string(chunk.length)]
        for position of 1..<chunk.length { args.push(chunk[position]) }
        rebuilt.push(MinusInstruction { op: "call-method", result: MinusValue { name: target, typeName: STRING_CLASS }, args, line: instruction_.line, sourcePath: instruction_.sourcePath })
        if !arities.contains(chunk.length) { arities.push(chunk.length) }
      }
      if final { break }
      pending = [target]
      for part of rest { pending.push(part) }
      group += 1
    }
  }
  while block_.instructions.length > 0 { _ := block_.instructions.pop()! }
  for instruction_ of rebuilt { block_.instructions.push(instruction_) }
}

// __doof_string.concatN(self, p1, ...): one allocation for all parts.
function concatFunction(arity: int): MinusFunction {
  let params = [value("%self", STRING_CLASS)]
  for index of 1..<arity { params.push(value("%part" + string(index), STRING_CLASS)) }
  let entry: MinusInstruction[] = [instruction("const", ["0"], "%zero", "int")]
  let total = "%zero"
  for index of 0..<arity {
    name := if index == 0 then "%self" else "%part" + string(index)
    entry.push(instruction("get", [name, "chars"], "%chars" + string(index), CHAR_ARRAY_CLASS))
    entry.push(instruction("get", ["%chars" + string(index), "data"], "%data" + string(index), "int"))
    entry.push(instruction("array-length", ["%data" + string(index)], "%length" + string(index), "int"))
    entry.push(instruction("add", [total, "%length" + string(index)], "%total" + string(index), "int"))
    total = "%total" + string(index)
  }
  // Each length is non-negative, so a negative running total means overflow.
  let checks: MinusBlock[] = []
  entry.push(instruction("lt", ["%total1", "%zero"], "%overflow1", "bool"))
  entry.push(instruction("branch", ["%overflow1", "overflow", "|", if arity > 2 then "check2" else "allocate"]))
  for index of 2..<arity {
    next := if index + 1 < arity then "check" + string(index + 1) else "allocate"
    checks.push(MinusBlock { name: "check" + string(index), instructions: [
      instruction("lt", ["%total" + string(index), "%zero"], "%overflow" + string(index), "bool"),
      instruction("branch", ["%overflow" + string(index), "overflow", "|", next]),
    ] })
  }
  let copies: MinusInstruction[] = [instruction("array-alloc", [total, "char"], "%data", "int")]
  let offset = "%zero"
  for index of 0..<arity {
    copies.push(instruction("array-copy", ["%data", offset, "%data" + string(index), "%zero", "%length" + string(index), "char"]))
    offset = "%total" + string(index)
  }
  copies.push(instruction("new", [CHAR_ARRAY_CLASS, "%data"], "%chars", CHAR_ARRAY_CLASS))
  copies.push(instruction("new", [STRING_CLASS, "%chars"], "%answer", STRING_CLASS))
  copies.push(instruction("return", ["%answer"]))
  let blocks = [MinusBlock { name: "entry", instructions: entry }]
  for check of checks { blocks.push(check) }
  blocks.push(MinusBlock { name: "overflow", instructions: [instruction("panic", [])] })
  blocks.push(MinusBlock { name: "allocate", instructions: copies })
  return createMinusFunction{ name: STRING_CLASS + ".concat" + string(arity), params, result: STRING_CLASS, blocks }
}
