import { createMinusFunction } from "./minus-build"
// Source array pop wraps the transferring IR operation in the native Result API.
import { MinusModule, MinusFunction, MinusBlock, MinusInstruction, MinusValue } from "./minus-ir"
import { STRING_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS } from "./doof-lowering-constants"

export function injectArrayPop(module_: MinusModule, arrayClass: string, elementType: string): none {
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".pop", params: [MinusValue { name: "%self", typeName: arrayClass }], result: "any",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%data"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "lt", result: MinusValue { name: "%has", typeName: "bool" }, args: ["%zero", "%length"] },
        MinusInstruction { op: "branch", args: ["%has", "remove", "|", "empty"] },
      ] },
      MinusBlock { name: "remove", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%storage", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-pop", result: MinusValue { name: "%item", typeName: elementType }, args: ["%storage"] },
        MinusInstruction { op: if elementType == "any" then "copy" else "box", result: MinusValue { name: "%payload", typeName: "any" }, args: ["%item"] },
        MinusInstruction { op: "new", result: MinusValue { name: "%success", typeName: RESULT_SUCCESS_CLASS }, args: [RESULT_SUCCESS_CLASS, "%payload"] },
        MinusInstruction { op: "box", result: MinusValue { name: "%result", typeName: "any" }, args: ["%success"] },
        MinusInstruction { op: "return", args: ["%result"] },
      ] },
      MinusBlock { name: "empty", instructions: [
        MinusInstruction { op: "string-const", result: MinusValue { name: "%message", typeName: STRING_CLASS }, args: ["Attempted to pop from empty array"] },
        MinusInstruction { op: "box", result: MinusValue { name: "%error", typeName: "any" }, args: ["%message"] },
        MinusInstruction { op: "new", result: MinusValue { name: "%failure", typeName: RESULT_FAILURE_CLASS }, args: [RESULT_FAILURE_CLASS, "%error"] },
        MinusInstruction { op: "box", result: MinusValue { name: "%failed", typeName: "any" }, args: ["%failure"] },
        MinusInstruction { op: "return", args: ["%failed"] },
      ] },
    ],
  })
}
