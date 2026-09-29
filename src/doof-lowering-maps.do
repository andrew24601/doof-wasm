import { createMinusFunction } from "./minus-build"
// Compiler cache maps share the owned, chunk-backed array runtime. Lookup is
// linear and compares string contents; updating an entry preserves its key.
import { MinusModule, MinusClass, MinusField, MinusFunction, MinusBlock, MinusInstruction, MinusValue } from "./minus-ir"
import { STRING_BOOL_MAP_CLASS, STRING_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS, arrayClassName } from "./doof-lowering-constants"

function value(name: string, typeName: string): MinusValue => MinusValue { name, typeName }
function instruction(op: string, args: string[], name: string = "", typeName: string = "none"): MinusInstruction => MinusInstruction { op, args, result: if name == "" then none else value(name, typeName) }

export function injectStringBoolMap(module_: MinusModule): none {
  keysType := arrayClassName(STRING_CLASS)
  valuesType := arrayClassName("bool")
  module_.classes.push(MinusClass {
    name: STRING_BOOL_MAP_CLASS,
    fields: [MinusField { name: "keys", typeName: keysType }, MinusField { name: "values", typeName: valuesType }],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_BOOL_MAP_CLASS + ".find", params: [value("%self", STRING_BOOL_MAP_CLASS), value("%key", STRING_CLASS)], result: "int",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        instruction("get", ["%self", "keys"], "%keys", keysType),
        instruction("call-method", ["%keys", "length"], "%length", "int"),
        instruction("const", ["0"], "%zero", "int"),
        instruction("jump", ["loop", "%zero"]),
      ] },
      MinusBlock { name: "loop", params: [value("%index", "int")], instructions: [
        instruction("lt", ["%index", "%length"], "%more", "bool"),
        instruction("branch", ["%more", "compare", "%index", "|", "missing"]),
      ] },
      MinusBlock { name: "compare", params: [value("%cursor", "int")], instructions: [
        instruction("call-method", ["%keys", "get", "%cursor"], "%stored", STRING_CLASS),
        instruction("call-method", ["%stored", "compare", "%key"], "%comparison", "int"),
        instruction("eq", ["%comparison", "%zero"], "%same", "bool"),
        instruction("branch", ["%same", "found", "%cursor", "|", "advance", "%cursor"]),
      ] },
      MinusBlock { name: "advance", params: [value("%previous", "int")], instructions: [
        instruction("const", ["1"], "%one", "int"),
        instruction("add", ["%previous", "%one"], "%next", "int"),
        instruction("jump", ["loop", "%next"]),
      ] },
      MinusBlock { name: "found", params: [value("%at", "int")], instructions: [instruction("return", ["%at"])] },
      MinusBlock { name: "missing", instructions: [
        instruction("const", ["-1"], "%absent", "int"),
        instruction("return", ["%absent"]),
      ] },
    ],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_BOOL_MAP_CLASS + ".has", params: [value("%self", STRING_BOOL_MAP_CLASS), value("%key", STRING_CLASS)], result: "bool",
    blocks: [MinusBlock { name: "entry", instructions: [
      instruction("call-method", ["%self", "find", "%key"], "%index", "int"),
      instruction("const", ["-1"], "%absent", "int"),
      instruction("lt", ["%absent", "%index"], "%present", "bool"),
      instruction("return", ["%present"]),
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_BOOL_MAP_CLASS + ".get", params: [value("%self", STRING_BOOL_MAP_CLASS), value("%key", STRING_CLASS)], result: "any",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        instruction("call-method", ["%self", "find", "%key"], "%index", "int"),
        instruction("const", ["-1"], "%absent", "int"),
        instruction("lt", ["%absent", "%index"], "%present", "bool"),
        instruction("branch", ["%present", "found", "%index", "|", "missing"]),
      ] },
      MinusBlock { name: "found", params: [value("%at", "int")], instructions: [
        instruction("get", ["%self", "values"], "%values", valuesType),
        instruction("call-method", ["%values", "get", "%at"], "%item", "bool"),
        instruction("box", ["%item"], "%payload", "any"),
        instruction("new", [RESULT_SUCCESS_CLASS, "%payload"], "%success", RESULT_SUCCESS_CLASS),
        instruction("box", ["%success"], "%result", "any"),
        instruction("return", ["%result"]),
      ] },
      MinusBlock { name: "missing", instructions: [
        instruction("string-const", ["Map key not found"], "%message", STRING_CLASS),
        instruction("box", ["%message"], "%error", "any"),
        instruction("new", [RESULT_FAILURE_CLASS, "%error"], "%failure", RESULT_FAILURE_CLASS),
        instruction("box", ["%failure"], "%failed", "any"),
        instruction("return", ["%failed"]),
      ] },
    ],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_BOOL_MAP_CLASS + ".set", params: [value("%self", STRING_BOOL_MAP_CLASS), value("%key", STRING_CLASS), value("%item", "bool")], result: "none",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        instruction("call-method", ["%self", "find", "%key"], "%index", "int"),
        instruction("get", ["%self", "values"], "%values", valuesType),
        instruction("const", ["-1"], "%absent", "int"),
        instruction("lt", ["%absent", "%index"], "%present", "bool"),
        instruction("branch", ["%present", "replace", "%index", "|", "insert"]),
      ] },
      MinusBlock { name: "replace", params: [value("%at", "int")], instructions: [
        instruction("call-method", ["%values", "set", "%at", "%item"], "%replaced", "bool"),
        instruction("return", []),
      ] },
      MinusBlock { name: "insert", instructions: [
        instruction("get", ["%self", "keys"], "%keys", keysType),
        instruction("call-method", ["%keys", "push", "%key"], "%insertedKey"),
        instruction("call-method", ["%values", "push", "%item"], "%insertedValue"),
        instruction("return", []),
      ] },
    ],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_BOOL_MAP_CLASS + ".size", params: [value("%self", STRING_BOOL_MAP_CLASS)], result: "int",
    blocks: [MinusBlock { name: "entry", instructions: [
      instruction("get", ["%self", "keys"], "%keys", keysType),
      instruction("call-method", ["%keys", "length"], "%length", "int"),
      instruction("return", ["%length"]),
    ] }],
  })
}
