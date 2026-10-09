import { createMinusFunction, instruction, value } from "./minus-build"
// Native whitespace trimming uses exactly space and ASCII codes 9 through 13.
import { STRING_CLASS } from "./doof-lowering-constants"
import { MinusModule, MinusFunction, MinusBlock, MinusValue, MinusInstruction } from "./minus-ir"

export function injectStringWhitespace(module_: MinusModule): none {
  module_.functions.push(createMinusFunction{
    name: "__doof_string_is_whitespace", params: [value("%character", "char")], result: "bool",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        instruction("convert", ["%character"], "%code", "int"),
        instruction("const", ["32"], "%space", "int"),
        instruction("const", ["9"], "%first", "int"),
        instruction("const", ["13"], "%last", "int"),
        instruction("eq", ["%code", "%space"], "%isSpace", "bool"),
        instruction("branch", ["%isSpace", "yes", "|", "lower"]),
      ] },
      MinusBlock { name: "lower", instructions: [
        instruction("lt", ["%code", "%first"], "%below", "bool"),
        instruction("branch", ["%below", "no", "|", "upper"]),
      ] },
      MinusBlock { name: "upper", instructions: [
        instruction("lt", ["%last", "%code"], "%above", "bool"),
        instruction("branch", ["%above", "no", "|", "yes"]),
      ] },
      MinusBlock { name: "yes", instructions: [instruction("const", ["true"], "%yes", "bool"), instruction("return", ["%yes"])] },
      MinusBlock { name: "no", instructions: [instruction("const", ["false"], "%no", "bool"), instruction("return", ["%no"])] },
    ],
  })
}

export function injectStringTrimming(module_: MinusModule, method: string): none {
  let params = [value("%self", STRING_CLASS)]
  if method == "trimEnd" {
    // The explicit flag distinguishes omitted whitespace from an explicit NUL.
    params.push(value("%suffix", "char"))
    params.push(value("%whitespace", "bool"))
  }
  let entry = [
    instruction("const", ["0"], "%zero", "int"),
    instruction("const", ["1"], "%one", "int"),
    instruction("call-method", ["%self", "length"], "%length", "int"),
  ]
  entry.push(instruction("jump", if method == "trimEnd" then ["endScan", "%zero", "%length"] else ["startScan", "%zero"]))
  let blocks = [MinusBlock { name: "entry", instructions: entry }]
  if method != "trimEnd" {
    blocks.push(MinusBlock { name: "startScan", params: [value("%start", "int")], instructions: [
      instruction("lt", ["%start", "%length"], "%hasStart", "bool"),
      instruction("branch", ["%hasStart", "startCheck", "%start", "|", "slice", "%start", "%length"]),
    ] })
    let check = [
      instruction("call-method", ["%self", "get", "%startCursor"], "%startCharacter", "char"),
      instruction("call", ["__doof_string_is_whitespace", "%startCharacter"], "%trimStartCharacter", "bool"),
    ]
    check.push(instruction("branch", ["%trimStartCharacter", "startNext", "%startCursor", "|", if method == "trim" then "endScan" else "slice", "%startCursor", "%length"]))
    blocks.push(MinusBlock { name: "startCheck", params: [value("%startCursor", "int")], instructions: check })
    blocks.push(MinusBlock { name: "startNext", params: [value("%startPrevious", "int")], instructions: [
      instruction("add", ["%startPrevious", "%one"], "%startAfter", "int"),
      instruction("jump", ["startScan", "%startAfter"]),
    ] })
  }
  if method != "trimStart" {
    blocks.push(MinusBlock { name: "endScan", params: [value("%endStart", "int"), value("%end", "int")], instructions: [
      instruction("lt", ["%endStart", "%end"], "%hasEnd", "bool"),
      instruction("branch", ["%hasEnd", "endCheck", "%endStart", "%end", "|", "slice", "%endStart", "%end"]),
    ] })
    let check = [
      instruction("sub", ["%endCursor", "%one"], "%lastIndex", "int"),
      instruction("call-method", ["%self", "get", "%lastIndex"], "%endCharacter", "char"),
    ]
    if method == "trimEnd" {
      check.push(instruction("branch", ["%whitespace", "endWhitespace", "%checkStart", "%endCursor", "%lastIndex", "%endCharacter", "|", "endSuffix", "%checkStart", "%endCursor", "%lastIndex", "%endCharacter"]))
      for kind of ["Whitespace", "Suffix"] {
        let comparison = if kind == "Whitespace" then instruction("call", ["__doof_string_is_whitespace", "%character" + kind], "%matches" + kind, "bool") else instruction("eq", ["%character" + kind, "%suffix"], "%matches" + kind, "bool")
        blocks.push(MinusBlock { name: "end" + kind, params: [value("%start" + kind, "int"), value("%end" + kind, "int"), value("%index" + kind, "int"), value("%character" + kind, "char")], instructions: [
          comparison,
          instruction("branch", ["%matches" + kind, "endScan", "%start" + kind, "%index" + kind, "|", "slice", "%start" + kind, "%end" + kind]),
        ] })
      }
    } else {
      check.push(instruction("call", ["__doof_string_is_whitespace", "%endCharacter"], "%trimEndCharacter", "bool"))
      check.push(instruction("branch", ["%trimEndCharacter", "endScan", "%checkStart", "%lastIndex", "|", "slice", "%checkStart", "%endCursor"]))
    }
    blocks.push(MinusBlock { name: "endCheck", params: [value("%checkStart", "int"), value("%endCursor", "int")], instructions: check })
  }
  blocks.push(MinusBlock { name: "slice", params: [value("%sliceStart", "int"), value("%sliceEnd", "int")], instructions: [
    instruction("call-method", ["%self", "substring", "%sliceStart", "%sliceEnd"], "%answer", STRING_CLASS),
    instruction("return", ["%answer"]),
  ] })
  module_.functions.push(createMinusFunction{ name: STRING_CLASS + "." + method, params, result: STRING_CLASS, blocks })
}
