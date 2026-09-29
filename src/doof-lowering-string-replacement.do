import { createMinusFunction } from "./minus-build"
// Replacement scans the original text twice and allocates the result once.
// Empty searches are a no-op, matching the native runtime; matches never overlap
// and inserted text is not searched again.
import { STRING_CLASS, CHAR_ARRAY_CLASS } from "./doof-lowering-constants"
import { MinusModule, MinusFunction, MinusBlock, MinusValue, MinusInstruction } from "./minus-ir"

function value(name: string, typeName: string): MinusValue => MinusValue { name, typeName }
function instruction(op: string, args: string[], name: string = "", typeName: string = "none"): MinusInstruction => MinusInstruction { op, args, result: if name == "" then none else value(name, typeName) }

export function injectStringReplacement(module_: MinusModule): none {
  let overflowInstructions: MinusInstruction[] = []
  if module_.recoverPanics {
    overflowInstructions.push(instruction("string-const", ["String replacement exceeds the array length limit"], "%overflowMessage", STRING_CLASS))
  }
  overflowInstructions.push(instruction("panic", if module_.recoverPanics then ["%overflowMessage"] else []))
  module_.functions.push(createMinusFunction{
    name: "__doof_string_matches_at",
    params: [value("%text", STRING_CLASS), value("%search", STRING_CLASS), value("%start", "int"), value("%width", "int")], result: "bool",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        instruction("const", ["0"], "%zero", "int"),
        instruction("const", ["1"], "%one", "int"),
        instruction("jump", ["loop", "%zero"]),
      ] },
      MinusBlock { name: "loop", params: [value("%offset", "int")], instructions: [
        instruction("lt", ["%offset", "%width"], "%more", "bool"),
        instruction("branch", ["%more", "compare", "%offset", "|", "found"]),
      ] },
      MinusBlock { name: "compare", params: [value("%cursor", "int")], instructions: [
        instruction("add", ["%start", "%cursor"], "%index", "int"),
        instruction("call-method", ["%text", "get", "%index"], "%actual", "char"),
        instruction("call-method", ["%search", "get", "%cursor"], "%expected", "char"),
        instruction("eq", ["%actual", "%expected"], "%same", "bool"),
        instruction("branch", ["%same", "advance", "%cursor", "|", "missing"]),
      ] },
      MinusBlock { name: "advance", params: [value("%previous", "int")], instructions: [
        instruction("add", ["%previous", "%one"], "%next", "int"),
        instruction("jump", ["loop", "%next"]),
      ] },
      MinusBlock { name: "found", instructions: [instruction("const", ["true"], "%yes", "bool"), instruction("return", ["%yes"])] },
      MinusBlock { name: "missing", instructions: [instruction("const", ["false"], "%no", "bool"), instruction("return", ["%no"])] },
    ],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".replaceAll",
    params: [value("%self", STRING_CLASS), value("%search", STRING_CLASS), value("%replacement", STRING_CLASS)], result: STRING_CLASS,
    blocks: [
      MinusBlock { name: "entry", instructions: [
        instruction("const", ["0"], "%zero", "int"),
        instruction("const", ["1"], "%one", "int"),
        instruction("call-method", ["%self", "length"], "%length", "int"),
        instruction("call-method", ["%search", "length"], "%width", "int"),
        instruction("call-method", ["%replacement", "length"], "%replacementLength", "int"),
        instruction("sub", ["%length", "%width"], "%last", "int"),
        instruction("eq", ["%width", "%zero"], "%empty", "bool"),
        instruction("branch", ["%empty", "unchanged", "|", "count", "%zero", "%zero"]),
      ] },
      MinusBlock { name: "unchanged", instructions: [instruction("return", ["%self"])] },
      MinusBlock { name: "count", params: [value("%position", "int"), value("%count", "int")], instructions: [
        instruction("lt", ["%last", "%position"], "%past", "bool"),
        instruction("branch", ["%past", "size", "%count", "|", "countMatch", "%position", "%count"]),
      ] },
      MinusBlock { name: "countMatch", params: [value("%matchPosition", "int"), value("%matchCount", "int")], instructions: [
        instruction("call", ["__doof_string_matches_at", "%self", "%search", "%matchPosition", "%width"], "%matches", "bool"),
        instruction("branch", ["%matches", "countFound", "%matchPosition", "%matchCount", "|", "countNext", "%matchPosition", "%matchCount"]),
      ] },
      MinusBlock { name: "countFound", params: [value("%foundPosition", "int"), value("%foundCount", "int")], instructions: [
        instruction("add", ["%foundPosition", "%width"], "%afterMatch", "int"),
        instruction("add", ["%foundCount", "%one"], "%moreMatches", "int"),
        instruction("jump", ["count", "%afterMatch", "%moreMatches"]),
      ] },
      MinusBlock { name: "countNext", params: [value("%nextPosition", "int"), value("%nextCount", "int")], instructions: [
        instruction("add", ["%nextPosition", "%one"], "%afterCharacter", "int"),
        instruction("jump", ["count", "%afterCharacter", "%nextCount"]),
      ] },
      MinusBlock { name: "size", params: [value("%matchesCount", "int")], instructions: [
        instruction("eq", ["%matchesCount", "%zero"], "%noMatches", "bool"),
        instruction("branch", ["%noMatches", "unchanged", "|", "measure", "%matchesCount"]),
      ] },
      MinusBlock { name: "measure", params: [value("%totalMatches", "int")], instructions: [
        // Widen before multiplying: the signed array bound must not wrap.
        instruction("sub", ["%replacementLength", "%width"], "%delta", "int"),
        instruction("convert", ["%delta"], "%wideDelta", "long"),
        instruction("convert", ["%totalMatches"], "%wideCount", "long"),
        instruction("convert", ["%length"], "%wideLength", "long"),
        instruction("mul", ["%wideDelta", "%wideCount"], "%growth", "long"),
        instruction("add", ["%wideLength", "%growth"], "%total", "long"),
        instruction("const", ["2147483647"], "%maximum", "long"),
        instruction("lt", ["%maximum", "%total"], "%overflow", "bool"),
        instruction("branch", ["%overflow", "tooLarge", "|", "allocate", "%total"]),
      ] },
      MinusBlock { name: "tooLarge", instructions: overflowInstructions },
      MinusBlock { name: "allocate", params: [value("%allocationLength", "long")], instructions: [
        instruction("convert", ["%allocationLength"], "%outputLength", "int"),
        instruction("array-alloc", ["%outputLength", "char"], "%data", "int"),
        // Give raw storage an owner before any copying call can panic.
        instruction("new", [CHAR_ARRAY_CLASS, "%data"], "%chars", CHAR_ARRAY_CLASS),
        instruction("jump", ["copy", "%zero", "%zero"]),
      ] },
      MinusBlock { name: "copy", params: [value("%sourceIndex", "int"), value("%outputIndex", "int")], instructions: [
        instruction("lt", ["%sourceIndex", "%length"], "%hasCharacter", "bool"),
        instruction("branch", ["%hasCharacter", "copyCheck", "%sourceIndex", "%outputIndex", "|", "finish"]),
      ] },
      MinusBlock { name: "copyCheck", params: [value("%checkSource", "int"), value("%checkOutput", "int")], instructions: [
        instruction("lt", ["%last", "%checkSource"], "%pastLast", "bool"),
        instruction("branch", ["%pastLast", "copyCharacter", "%checkSource", "%checkOutput", "|", "copyMatch", "%checkSource", "%checkOutput"]),
      ] },
      MinusBlock { name: "copyMatch", params: [value("%candidateSource", "int"), value("%candidateOutput", "int")], instructions: [
        instruction("call", ["__doof_string_matches_at", "%self", "%search", "%candidateSource", "%width"], "%copyMatches", "bool"),
        instruction("branch", ["%copyMatches", "replacement", "%candidateSource", "%candidateOutput", "%zero", "|", "copyCharacter", "%candidateSource", "%candidateOutput"]),
      ] },
      MinusBlock { name: "copyCharacter", params: [value("%characterSource", "int"), value("%characterOutput", "int")], instructions: [
        instruction("call-method", ["%self", "get", "%characterSource"], "%character", "char"),
        instruction("array-set", ["%data", "%characterOutput", "%character"]),
        instruction("add", ["%characterSource", "%one"], "%followingSource", "int"),
        instruction("add", ["%characterOutput", "%one"], "%followingOutput", "int"),
        instruction("jump", ["copy", "%followingSource", "%followingOutput"]),
      ] },
      MinusBlock { name: "replacement", params: [value("%replacementSource", "int"), value("%replacementOutput", "int"), value("%offset", "int")], instructions: [
        instruction("lt", ["%offset", "%replacementLength"], "%hasReplacement", "bool"),
        instruction("branch", ["%hasReplacement", "copyReplacement", "%replacementSource", "%replacementOutput", "%offset", "|", "replaced", "%replacementSource", "%replacementOutput"]),
      ] },
      MinusBlock { name: "copyReplacement", params: [value("%insertSource", "int"), value("%insertOutput", "int"), value("%insertOffset", "int")], instructions: [
        instruction("call-method", ["%replacement", "get", "%insertOffset"], "%insertCharacter", "char"),
        instruction("array-set", ["%data", "%insertOutput", "%insertCharacter"]),
        instruction("add", ["%insertOffset", "%one"], "%nextOffset", "int"),
        instruction("add", ["%insertOutput", "%one"], "%nextOutput", "int"),
        instruction("jump", ["replacement", "%insertSource", "%nextOutput", "%nextOffset"]),
      ] },
      MinusBlock { name: "replaced", params: [value("%replacedSource", "int"), value("%replacedOutput", "int")], instructions: [
        instruction("add", ["%replacedSource", "%width"], "%nextSource", "int"),
        instruction("jump", ["copy", "%nextSource", "%replacedOutput"]),
      ] },
      MinusBlock { name: "finish", instructions: [
        instruction("new", [STRING_CLASS, "%chars"], "%answer", STRING_CLASS),
        instruction("return", ["%answer"]),
      ] },
    ],
  })
}
