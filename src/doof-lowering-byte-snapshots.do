import { createMinusFunction } from "./minus-build"
// Byte snapshots are required by the std/fs readonly output contract.
import { MinusModule, MinusFunction, MinusValue, MinusBlock, MinusInstruction } from "./minus-ir"

export function injectByteArraySnapshots(module_: MinusModule, arrayClass: string): none {
  for method of ["cloneReadonly", "cloneMutable"] {
    module_.functions.push(createMinusFunction{
      name: arrayClass + "." + method,
      params: [MinusValue { name: "%self", typeName: arrayClass }], result: arrayClass,
      blocks: [MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%source", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%source"] },
        MinusInstruction { op: "array-alloc", result: MinusValue { name: "%data", typeName: "int" }, args: ["%length", "byte"] },
        MinusInstruction { op: "new", result: MinusValue { name: "%snapshot", typeName: arrayClass }, args: [arrayClass, "%data"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "array-copy", args: ["%data", "%zero", "%source", "%zero", "%length", "byte"] },
        MinusInstruction { op: "return", args: ["%snapshot"] },
      ] }],
    })
  }
}
