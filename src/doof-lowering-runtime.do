// Runtime classes synthesized by source lowering for strings, arrays, and results.
import {
  BYTE_ARRAY_CLASS, BYTE_ARRAY_DESTRUCTOR, CHAR_ARRAY_CLASS, CHAR_ARRAY_DESTRUCTOR,
  STRING_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS, ARRAY_CLASS_PREFIX,
  arrayClassName, arrayElementFromClassName, isArrayClass,
} from "./doof-lowering-constants"
import { MinusBlock, MinusClass, MinusField, MinusFunction, MinusInstruction, MinusModule, MinusValue } from "./minus-ir"

export function moduleUsesArrayClass(module_: MinusModule, arrayClass: string): bool {
  for class_ of module_.classes {
    for field of class_.fields { if field.typeName == arrayClass { return true } }
  }
  for interface_ of module_.interfaces {
    for field of interface_.fields { if field.typeName == arrayClass { return true } }
    for method of interface_.methods {
      if method.result == arrayClass || method.params.contains(arrayClass) { return true }
    }
  }
  for import_ of module_.imports {
    if import_.result == arrayClass { return true }
    for parameter of import_.params { if parameter.typeName == arrayClass { return true } }
  }
  for function_ of module_.functions {
    if function_.result == arrayClass { return true }
    for parameter of function_.params { if parameter.typeName == arrayClass { return true } }
    for block of function_.blocks {
      for parameter of block.params { if parameter.typeName == arrayClass { return true } }
      for instruction of block.instructions {
        if instruction.result != none && instruction.result!.typeName == arrayClass { return true }
      }
    }
  }
  return false
}

function functionUsesType(function_: MinusFunction, typeName: string): bool {
  if function_.result == typeName { return true }
  for parameter of function_.params { if parameter.typeName == typeName { return true } }
  for block of function_.blocks {
    for parameter of block.params { if parameter.typeName == typeName { return true } }
    for instruction of block.instructions {
      if instruction.result != none && instruction.result!.typeName == typeName { return true }
      for argument of instruction.args { if argument == typeName { return true } }
    }
  }
  return false
}

function hasClass(module_: MinusModule, name: string): bool {
  for class_ of module_.classes { if class_.name == name { return true } }
  return false
}

export function injectResultClassesIfUsed(module_: MinusModule): none {
  let successUsed = false
  let failureUsed = false
  for function_ of module_.functions {
    if functionUsesType(function_, RESULT_SUCCESS_CLASS) { successUsed = true }
    if functionUsesType(function_, RESULT_FAILURE_CLASS) { failureUsed = true }
  }
  if successUsed && !hasClass(module_, RESULT_SUCCESS_CLASS) {
    module_.classes.push(MinusClass {
      name: RESULT_SUCCESS_CLASS,
      fields: [MinusField { name: "value", typeName: "any" }],
    })
  }
  if failureUsed && !hasClass(module_, RESULT_FAILURE_CLASS) {
    module_.classes.push(MinusClass {
      name: RESULT_FAILURE_CLASS,
      fields: [MinusField { name: "error", typeName: "any" }],
    })
  }
}

function injectArrayImplementation(module_: MinusModule, arrayClass: string, elementType: string, destructorName: string): none {
  let class_ = MinusClass { name: arrayClass, finalizer: destructorName }
  class_.fields.push(MinusField { name: "data", typeName: "int" })
  module_.classes.push(class_)
  module_.functions.push(MinusFunction {
    name: destructorName,
    params: [MinusValue { name: "%self", typeName: arrayClass }],
    result: "none",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-free", args: ["%data", elementType] },
      MinusInstruction { op: "return" },
    ] }],
  })
  module_.functions.push(MinusFunction {
    name: arrayClass + ".get",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%index", typeName: "int" }],
    result: elementType,
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-get", result: MinusValue { name: "%value", typeName: elementType }, args: ["%data", "%index"] },
      MinusInstruction { op: "return", args: ["%value"] },
    ] }],
  })
  module_.functions.push(MinusFunction {
    name: arrayClass + ".set",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%index", typeName: "int" }, MinusValue { name: "%value", typeName: elementType }],
    result: elementType,
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-set", args: ["%data", "%index", "%value"] },
      MinusInstruction { op: "return", args: ["%value"] },
    ] }],
  })
  module_.functions.push(MinusFunction {
    name: arrayClass + ".length",
    params: [MinusValue { name: "%self", typeName: arrayClass }],
    result: "int",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%data"] },
      MinusInstruction { op: "return", args: ["%length"] },
    ] }],
  })
}

export function injectArrayClassRecursively(module_: MinusModule, arrayClass: string, injected: string[]): none {
  if injected.contains(arrayClass) { return }
  elementType := if arrayClass == BYTE_ARRAY_CLASS then "byte" else if arrayClass == CHAR_ARRAY_CLASS then "char" else arrayElementFromClassName(arrayClass)
  if elementType == "" { return }
  if elementType == STRING_CLASS {
    let hasStringClass = false
    for class_ of module_.classes { if class_.name == STRING_CLASS { hasStringClass = true } }
    if !hasStringClass { injectStringImplementation(module_) }
  }
  if isArrayClass(elementType) {
    injectArrayClassRecursively(module_, elementType, injected)
  }
  if arrayClass == BYTE_ARRAY_CLASS {
    injectArrayImplementation(module_, arrayClass, "byte", BYTE_ARRAY_DESTRUCTOR)
  } else if arrayClass == CHAR_ARRAY_CLASS {
    injectArrayImplementation(module_, arrayClass, "char", CHAR_ARRAY_DESTRUCTOR)
  } else {
    injectArrayImplementation(module_, arrayClass, elementType, arrayClass + ".destroy")
  }
  injected.push(arrayClass)
}

function addArrayType(types: string[], typeName: string): none {
  if typeName.startsWith(ARRAY_CLASS_PREFIX + "_") && !types.contains(typeName) { types.push(typeName) }
}

export function usedArrayTypes(module_: MinusModule): string[] {
  let types: string[] = []
  for class_ of module_.classes { for field of class_.fields { addArrayType(types, field.typeName) } }
  for interface_ of module_.interfaces {
    for field of interface_.fields { addArrayType(types, field.typeName) }
    for method of interface_.methods { addArrayType(types, method.result); for parameter of method.params { addArrayType(types, parameter) } }
  }
  for import_ of module_.imports {
    addArrayType(types, import_.result)
    for parameter of import_.params { addArrayType(types, parameter.typeName) }
  }
  for function_ of module_.functions {
    addArrayType(types, function_.result)
    for parameter of function_.params { addArrayType(types, parameter.typeName) }
    for block of function_.blocks {
      for parameter of block.params { addArrayType(types, parameter.typeName) }
      for instruction of block.instructions { if instruction.result != none { addArrayType(types, instruction.result!.typeName) } }
    }
  }
  return types
}

function moduleUsesStringMethod(module_: MinusModule, methodName: string): bool {
  for function_ of module_.functions {
    for block of function_.blocks {
      for instruction of block.instructions {
        if instruction.op != "call-method" || instruction.args.length < 2 || instruction.args[1] != methodName { continue }
        receiver := instruction.args[0]
        for parameter of function_.params { if parameter.name == receiver && parameter.typeName == STRING_CLASS { return true } }
        for innerBlock of function_.blocks {
          for parameter of innerBlock.params { if parameter.name == receiver && parameter.typeName == STRING_CLASS { return true } }
          for candidate of innerBlock.instructions {
            if candidate.result != none && candidate.result!.name == receiver && candidate.result!.typeName == STRING_CLASS { return true }
          }
        }
      }
    }
  }
  return false
}

export function injectStringImplementation(module_: MinusModule): none {
  module_.classes.push(MinusClass {
    name: STRING_CLASS,
    fields: [MinusField { name: "chars", typeName: CHAR_ARRAY_CLASS }],
  })
  module_.functions.push(MinusFunction {
    name: STRING_CLASS + ".get",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%index", typeName: "int" }],
    result: "char",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
      MinusInstruction { op: "call-method", result: MinusValue { name: "%value", typeName: "char" }, args: ["%chars", "get", "%index"] },
      MinusInstruction { op: "return", args: ["%value"] },
    ] }],
  })
  module_.functions.push(MinusFunction {
    name: STRING_CLASS + ".length",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }],
    result: "int",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
      MinusInstruction { op: "call-method", result: MinusValue { name: "%length", typeName: "int" }, args: ["%chars", "length"] },
      MinusInstruction { op: "return", args: ["%length"] },
    ] }],
  })
  if moduleUsesStringMethod(module_, "compare") { module_.functions.push(MinusFunction {
    name: STRING_CLASS + ".compare",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%other", typeName: STRING_CLASS }],
    result: "int",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%left", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%right", typeName: CHAR_ARRAY_CLASS }, args: ["%other", "chars"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%leftLength", typeName: "int" }, args: ["%left", "length"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%rightLength", typeName: "int" }, args: ["%right", "length"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "jump", args: ["loop", "%zero"] },
      ] },
      MinusBlock { name: "loop", params: [MinusValue { name: "%index", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%leftHas", typeName: "bool" }, args: ["%index", "%leftLength"] },
        MinusInstruction { op: "branch", args: ["%leftHas", "rightCheck", "%index", "|", "leftEnded", "%index"] },
      ] },
      MinusBlock { name: "leftEnded", params: [MinusValue { name: "%endIndex", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%rightHasAtEnd", typeName: "bool" }, args: ["%endIndex", "%rightLength"] },
        MinusInstruction { op: "branch", args: ["%rightHasAtEnd", "less", "|", "equal"] },
      ] },
      MinusBlock { name: "rightCheck", params: [MinusValue { name: "%index2", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%rightHas", typeName: "bool" }, args: ["%index2", "%rightLength"] },
        MinusInstruction { op: "branch", args: ["%rightHas", "compareChar", "%index2", "|", "greater"] },
      ] },
      MinusBlock { name: "compareChar", params: [MinusValue { name: "%index3", typeName: "int" }], instructions: [
        MinusInstruction { op: "call-method", result: MinusValue { name: "%leftChar", typeName: "char" }, args: ["%left", "get", "%index3"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%rightChar", typeName: "char" }, args: ["%right", "get", "%index3"] },
        MinusInstruction { op: "eq", result: MinusValue { name: "%same", typeName: "bool" }, args: ["%leftChar", "%rightChar"] },
        MinusInstruction { op: "branch", args: ["%same", "advance", "%index3", "|", "different", "%leftChar", "%rightChar"] },
      ] },
      MinusBlock { name: "advance", params: [MinusValue { name: "%index4", typeName: "int" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%one", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%next", typeName: "int" }, args: ["%index4", "%one"] },
        MinusInstruction { op: "jump", args: ["loop", "%next"] },
      ] },
      MinusBlock { name: "different", params: [MinusValue { name: "%leftValue", typeName: "char" }, MinusValue { name: "%rightValue", typeName: "char" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%isLess", typeName: "bool" }, args: ["%leftValue", "%rightValue"] },
        MinusInstruction { op: "branch", args: ["%isLess", "less", "|", "greater"] },
      ] },
      MinusBlock { name: "less", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%lessResult", typeName: "int" }, args: ["-1"] }, MinusInstruction { op: "return", args: ["%lessResult"] }] },
      MinusBlock { name: "equal", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%equalResult", typeName: "int" }, args: ["0"] }, MinusInstruction { op: "return", args: ["%equalResult"] }] },
      MinusBlock { name: "greater", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%greaterResult", typeName: "int" }, args: ["1"] }, MinusInstruction { op: "return", args: ["%greaterResult"] }] },
    ],
  }) }
  if moduleUsesStringMethod(module_, "indexOf") { module_.functions.push(MinusFunction {
    name: STRING_CLASS + ".indexOf",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%needle", typeName: STRING_CLASS }],
    result: "int",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%needleChars", typeName: CHAR_ARRAY_CLASS }, args: ["%needle", "chars"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%length", typeName: "int" }, args: ["%chars", "length"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%needleLength", typeName: "int" }, args: ["%needleChars", "length"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "jump", args: ["outer", "%zero"] },
      ] },
      MinusBlock { name: "outer", params: [MinusValue { name: "%start", typeName: "int" }], instructions: [
        MinusInstruction { op: "sub", result: MinusValue { name: "%lastStart", typeName: "int" }, args: ["%length", "%needleLength"] },
        MinusInstruction { op: "lt", result: MinusValue { name: "%tooFar", typeName: "bool" }, args: ["%lastStart", "%start"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%false", typeName: "bool" }, args: ["false"] },
        MinusInstruction { op: "eq", result: MinusValue { name: "%inRange", typeName: "bool" }, args: ["%tooFar", "%false"] },
        MinusInstruction { op: "branch", args: ["%inRange", "inner", "%start", "%zero", "|", "missing"] },
      ] },
      MinusBlock { name: "inner", params: [MinusValue { name: "%start2", typeName: "int" }, MinusValue { name: "%offset", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%hasNeedleChar", typeName: "bool" }, args: ["%offset", "%needleLength"] },
        MinusInstruction { op: "branch", args: ["%hasNeedleChar", "check", "%start2", "%offset", "|", "found", "%start2"] },
      ] },
      MinusBlock { name: "check", params: [MinusValue { name: "%start3", typeName: "int" }, MinusValue { name: "%offset2", typeName: "int" }], instructions: [
        MinusInstruction { op: "add", result: MinusValue { name: "%hayIndex", typeName: "int" }, args: ["%start3", "%offset2"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%character", typeName: "char" }, args: ["%chars", "get", "%hayIndex"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%needleCharacter", typeName: "char" }, args: ["%needleChars", "get", "%offset2"] },
        MinusInstruction { op: "eq", result: MinusValue { name: "%matches", typeName: "bool" }, args: ["%character", "%needleCharacter"] },
        MinusInstruction { op: "branch", args: ["%matches", "advance", "%start3", "%offset2", "|", "nextStart", "%start3"] },
      ] },
      MinusBlock { name: "advance", params: [MinusValue { name: "%start4", typeName: "int" }, MinusValue { name: "%offset3", typeName: "int" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%one", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%nextOffset", typeName: "int" }, args: ["%offset3", "%one"] },
        MinusInstruction { op: "jump", args: ["inner", "%start4", "%nextOffset"] },
      ] },
      MinusBlock { name: "nextStart", params: [MinusValue { name: "%failedStart", typeName: "int" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%one", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%after", typeName: "int" }, args: ["%failedStart", "%one"] },
        MinusInstruction { op: "jump", args: ["outer", "%after"] },
      ] },
      MinusBlock { name: "found", params: [MinusValue { name: "%position", typeName: "int" }], instructions: [MinusInstruction { op: "return", args: ["%position"] }] },
      MinusBlock { name: "missing", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%notFound", typeName: "int" }, args: ["-1"] }, MinusInstruction { op: "return", args: ["%notFound"] }] },
    ],
  }) }
}

