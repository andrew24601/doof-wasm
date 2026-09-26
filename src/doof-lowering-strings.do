// Synthesized string construction used by compiler diagnostics and source tokenization.
import { STRING_CLASS, CHAR_ARRAY_CLASS, arrayClassName } from "./doof-lowering-constants"
import { MinusModule, MinusFunction, MinusBlock, MinusValue, MinusInstruction } from "./minus-ir"

function value(name: string, typeName: string): MinusValue => MinusValue { name, typeName }
function instruction(op: string, args: string[], name: string = "", typeName: string = "none"): MinusInstruction => MinusInstruction { op, args, result: if name == "" then none else value(name, typeName) }

function uses(module_: MinusModule, target: string): bool {
  for fn of module_.functions {
    for block of fn.blocks {
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
    module_.functions.push(MinusFunction {
      name: STRING_CLASS + ".concat", params: [value("%self", STRING_CLASS), value("%other", STRING_CLASS)], result: STRING_CLASS,
      blocks: [
      MinusBlock { name: "entry", params: [], instructions: [
        instruction("call-method", ["%self", "length"], "%left", "int"),
        instruction("call-method", ["%other", "length"], "%right", "int"),
        instruction("add", ["%left", "%right"], "%total", "int"),
        instruction("const", ["0"], "%zero", "int"),
        instruction("lt", ["%total", "%zero"], "%overflow", "bool"),
        instruction("branch", ["%overflow", "overflow", "|", "allocate", "%left", "%right", "%total", "%zero"])
      ] },
      MinusBlock { name: "overflow", params: [], instructions: [
        instruction("panic", [])
      ] },
      MinusBlock { name: "allocate", params: [value("%left_allocate", "int"), value("%right_allocate", "int"), value("%total_allocate", "int"), value("%zero_allocate", "int")], instructions: [
        instruction("array-alloc", ["%total_allocate", "char"], "%data", "int"),
        instruction("jump", ["left", "%zero_allocate", "%data", "%left_allocate", "%right_allocate", "%zero_allocate"])
      ] },
      MinusBlock { name: "left", params: [value("%i", "int"), value("%data_left", "int"), value("%left_left", "int"), value("%right_left", "int"), value("%zero_left", "int")], instructions: [
        instruction("lt", ["%i", "%left_left"], "%more", "bool"),
        instruction("branch", ["%more", "copyLeft", "%i", "%data_left", "%left_left", "%right_left", "%zero_left", "|", "right", "%zero_left", "%data_left", "%left_left", "%right_left"])
      ] },
      MinusBlock { name: "copyLeft", params: [value("%li", "int"), value("%data_copyLeft", "int"), value("%left_copyLeft", "int"), value("%right_copyLeft", "int"), value("%zero_copyLeft", "int")], instructions: [
        instruction("call-method", ["%self", "get", "%li"], "%lc", "char"),
        instruction("array-set", ["%data_copyLeft", "%li", "%lc"]),
        instruction("const", ["1"], "%oneL", "int"),
        instruction("add", ["%li", "%oneL"], "%ln", "int"),
        instruction("jump", ["left", "%ln", "%data_copyLeft", "%left_copyLeft", "%right_copyLeft", "%zero_copyLeft"])
      ] },
      MinusBlock { name: "right", params: [value("%j", "int"), value("%data_right", "int"), value("%left_right", "int"), value("%right_right", "int")], instructions: [
        instruction("lt", ["%j", "%right_right"], "%moreR", "bool"),
        instruction("branch", ["%moreR", "copyRight", "%j", "%data_right", "%left_right", "%right_right", "|", "finish", "%data_right"])
      ] },
      MinusBlock { name: "copyRight", params: [value("%rj", "int"), value("%data_copyRight", "int"), value("%left_copyRight", "int"), value("%right_copyRight", "int")], instructions: [
        instruction("call-method", ["%other", "get", "%rj"], "%rc", "char"),
        instruction("add", ["%left_copyRight", "%rj"], "%at", "int"),
        instruction("array-set", ["%data_copyRight", "%at", "%rc"]),
        instruction("const", ["1"], "%oneR", "int"),
        instruction("add", ["%rj", "%oneR"], "%rn", "int"),
        instruction("jump", ["right", "%rn", "%data_copyRight", "%left_copyRight", "%right_copyRight"])
      ] },
      MinusBlock { name: "finish", params: [value("%data_finish", "int")], instructions: [
        instruction("new", [CHAR_ARRAY_CLASS, "%data_finish"], "%chars", CHAR_ARRAY_CLASS),
        instruction("new", [STRING_CLASS, "%chars"], "%answer", STRING_CLASS),
        instruction("return", ["%answer"])
      ] }
      ],
    })
  }
  if uses(module_, "split") {
    module_.functions.push(MinusFunction {
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
    module_.functions.push(MinusFunction {
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
    module_.functions.push(MinusFunction {
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
