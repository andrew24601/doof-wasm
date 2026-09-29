import { createMinusFunction } from "./minus-build"
// Synchronous promises are a compiler-bootstrap compatibility representation.
import { MinusModule, MinusClass, MinusField, MinusFunction, MinusBlock, MinusInstruction, MinusValue } from "./minus-ir"
import { STRING_CLASS, RESULT_FAILURE_CLASS, arrayClassName } from "./doof-lowering-constants"

export function injectSynchronousPromises(module_: MinusModule): none {
  module_.classes.push(MinusClass { name: "__doof_promise", fields: [MinusField { name: "completion", typeName: "any" }] })
  module_.functions.push(createMinusFunction{
    name: "__doof_promise.get", params: [MinusValue { name: "%self", typeName: "__doof_promise" }], result: "any",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%completion", typeName: "any" }, args: ["%self", "completion"] },
      MinusInstruction { op: "return", args: ["%completion"] },
    ] }],
  })
  // All jobs are settled, so consume in insertion order. Copy the tail into
  // owned storage, update the existing array wrapper, then free the old data.
  arrayClass := arrayClassName("__doof_promise")
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".takeFirstCompleted", params: [MinusValue { name: "%self", typeName: arrayClass }], result: "any",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%source", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%source"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "lt", result: MinusValue { name: "%has", typeName: "bool" }, args: ["%zero", "%length"] },
        MinusInstruction { op: "branch", args: ["%has", "prepare", "%length", "|", "empty"] },
      ] },
      MinusBlock { name: "empty", instructions: [
        MinusInstruction { op: "string-const", result: MinusValue { name: "%message", typeName: STRING_CLASS }, args: ["takeFirstCompleted called on an empty array"] },
        MinusInstruction { op: "box", result: MinusValue { name: "%error", typeName: "any" }, args: ["%message"] },
        MinusInstruction { op: "new", result: MinusValue { name: "%failure", typeName: RESULT_FAILURE_CLASS }, args: [RESULT_FAILURE_CLASS, "%error"] },
        MinusInstruction { op: "box", result: MinusValue { name: "%failed", typeName: "any" }, args: ["%failure"] },
        MinusInstruction { op: "return", args: ["%failed"] },
      ] },
      MinusBlock { name: "prepare", params: [MinusValue { name: "%count", typeName: "int" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%first", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%one", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "sub", result: MinusValue { name: "%newLength", typeName: "int" }, args: ["%count", "%one"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%old", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-get", result: MinusValue { name: "%promise", typeName: "__doof_promise" }, args: ["%old", "%first"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%ready", typeName: "any" }, args: ["%promise", "completion"] },
        MinusInstruction { op: "array-alloc", result: MinusValue { name: "%new", typeName: "int" }, args: ["%newLength", "__doof_promise"] },
        MinusInstruction { op: "jump", args: ["loop", "%new", "%first", "%newLength", "%ready"] },
      ] },
      MinusBlock { name: "loop", params: [MinusValue { name: "%data", typeName: "int" }, MinusValue { name: "%index", typeName: "int" }, MinusValue { name: "%limit", typeName: "int" }, MinusValue { name: "%completion", typeName: "any" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%more", typeName: "bool" }, args: ["%index", "%limit"] },
        MinusInstruction { op: "branch", args: ["%more", "copy", "%data", "%index", "%limit", "%completion", "|", "done", "%data", "%completion"] },
      ] },
      MinusBlock { name: "copy", params: [MinusValue { name: "%copyData", typeName: "int" }, MinusValue { name: "%cursor", typeName: "int" }, MinusValue { name: "%copyLimit", typeName: "int" }, MinusValue { name: "%copyCompletion", typeName: "any" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%step", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%next", typeName: "int" }, args: ["%cursor", "%step"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%copySource", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-get", result: MinusValue { name: "%item", typeName: "__doof_promise" }, args: ["%copySource", "%next"] },
        MinusInstruction { op: "array-set", args: ["%copyData", "%cursor", "%item"] },
        MinusInstruction { op: "jump", args: ["loop", "%copyData", "%next", "%copyLimit", "%copyCompletion"] },
      ] },
      MinusBlock { name: "done", params: [MinusValue { name: "%doneData", typeName: "int" }, MinusValue { name: "%doneCompletion", typeName: "any" }], instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%oldData", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "set", args: ["%self", "data", "%doneData"] },
        MinusInstruction { op: "array-free", args: ["%oldData", "__doof_promise"] },
        MinusInstruction { op: "return", args: ["%doneCompletion"] },
      ] },
    ],
  })
}
