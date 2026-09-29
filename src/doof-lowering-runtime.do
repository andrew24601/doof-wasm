import { createMinusFunction } from "./minus-build"
import { minusBlocks } from "./minus-control-flow"
// Runtime classes synthesized by source lowering for strings, arrays, and results.
import { injectStringConstruction } from "./doof-lowering-strings"
import { injectStringReplacement } from "./doof-lowering-string-replacement"
import { injectStringWhitespace, injectStringTrimming } from "./doof-lowering-string-trimming"
import { injectByteArraySnapshots } from "./doof-lowering-byte-snapshots"
import { injectArrayPop } from "./doof-lowering-array-methods"
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
    for block of minusBlocks(function_) {
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
  for block of minusBlocks(function_) {
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
    if function_.capturePanics { failureUsed = true }
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
  class_.fields.push(MinusField { name: "data", typeName: "int", mutable: true })
  module_.classes.push(class_)
  if elementType == "byte" { injectByteArraySnapshots(module_, arrayClass) }
  module_.functions.push(createMinusFunction{
    name: destructorName,
    params: [MinusValue { name: "%self", typeName: arrayClass }],
    result: "none",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-free", args: ["%data", elementType] },
      MinusInstruction { op: "return" },
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".get",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%index", typeName: "int" }],
    result: elementType,
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-get", result: MinusValue { name: "%value", typeName: elementType }, args: ["%data", "%index"] },
      MinusInstruction { op: "return", args: ["%value"] },
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".set",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%index", typeName: "int" }, MinusValue { name: "%value", typeName: elementType }],
    result: elementType,
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-set", args: ["%data", "%index", "%value"] },
      MinusInstruction { op: "return", args: ["%value"] },
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".length",
    params: [MinusValue { name: "%self", typeName: arrayClass }],
    result: "int",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%data"] },
      MinusInstruction { op: "return", args: ["%length"] },
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".push",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%value", typeName: elementType }],
    result: "none",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-push", result: MinusValue { name: "%grown", typeName: "int" }, args: ["%data", "%value"] },
      MinusInstruction { op: "set", args: ["%self", "data", "%grown"] },
      MinusInstruction { op: "return" },
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".reserve",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%capacity", typeName: "int" }],
    result: "none",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-reserve", result: MinusValue { name: "%grown", typeName: "int" }, args: ["%data", "%capacity", elementType] },
      MinusInstruction { op: "set", args: ["%self", "data", "%grown"] },
      MinusInstruction { op: "return" },
    ] }],
  })
  if moduleUsesStringMethod(module_, "pop", arrayClass) { injectArrayPop(module_, arrayClass, elementType) }
  let compareInstructions: MinusInstruction[] = [
    MinusInstruction { op: "get", result: MinusValue { name: "%compareData", typeName: "int" }, args: ["%self", "data"] },
    MinusInstruction { op: "array-get", result: MinusValue { name: "%item", typeName: elementType }, args: ["%compareData", "%cursor"] },
  ]
  if elementType == STRING_CLASS {
    compareInstructions.push(MinusInstruction { op: "call-method", result: MinusValue { name: "%same", typeName: "bool" }, args: ["%item", "equals", "%value"] })
  } else {
    compareInstructions.push(MinusInstruction { op: "eq", result: MinusValue { name: "%same", typeName: "bool" }, args: ["%item", "%value"] })
  }
  compareInstructions.push(MinusInstruction { op: "branch", args: ["%same", "found", "|", "advance", "%cursor"] })
  module_.functions.push(createMinusFunction{
    name: arrayClass + ".contains",
    params: [MinusValue { name: "%self", typeName: arrayClass }, MinusValue { name: "%value", typeName: elementType }],
    result: "bool",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "jump", args: ["loop", "%zero"] },
      ] },
      MinusBlock { name: "loop", params: [MinusValue { name: "%index", typeName: "int" }], instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
        MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%data"] },
        MinusInstruction { op: "lt", result: MinusValue { name: "%has", typeName: "bool" }, args: ["%index", "%length"] },
        MinusInstruction { op: "branch", args: ["%has", "compare", "%index", "|", "missing"] },
      ] },
      MinusBlock { name: "compare", params: [MinusValue { name: "%cursor", typeName: "int" }], instructions: compareInstructions },
      MinusBlock { name: "advance", params: [MinusValue { name: "%advanceIndex", typeName: "int" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%one", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%next", typeName: "int" }, args: ["%advanceIndex", "%one"] },
        MinusInstruction { op: "jump", args: ["loop", "%next"] },
      ] },
      MinusBlock { name: "found", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%yes", typeName: "bool" }, args: ["true"] }, MinusInstruction { op: "return", args: ["%yes"] }] },
      MinusBlock { name: "missing", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%no", typeName: "bool" }, args: ["false"] }, MinusInstruction { op: "return", args: ["%no"] }] },
    ],
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
    for block of minusBlocks(function_) {
      for parameter of block.params { addArrayType(types, parameter.typeName) }
      for instruction of block.instructions { if instruction.result != none { addArrayType(types, instruction.result!.typeName) } }
    }
  }
  return types
}

function moduleUsesStringMethod(module_: MinusModule, methodName: string, receiverType: string = STRING_CLASS): bool {
  for function_ of module_.functions {
    for block of minusBlocks(function_) {
      for instruction of block.instructions {
        if instruction.op != "call-method" || instruction.args.length < 2 || instruction.args[1] != methodName { continue }
        receiver := instruction.args[0]
        for parameter of function_.params { if parameter.name == receiver && parameter.typeName == receiverType { return true } }
        for innerBlock of minusBlocks(function_) {
          for parameter of innerBlock.params { if parameter.name == receiver && parameter.typeName == receiverType { return true } }
          for candidate of innerBlock.instructions {
            if candidate.result != none && candidate.result!.name == receiver && candidate.result!.typeName == receiverType { return true }
          }
        }
      }
    }
  }
  return false
}

export function moduleUsesArrayPop(module_: MinusModule): bool {
  if moduleUsesStringMethod(module_, "pop", BYTE_ARRAY_CLASS) || moduleUsesStringMethod(module_, "pop", CHAR_ARRAY_CLASS) { return true }
  for arrayClass of usedArrayTypes(module_) { if moduleUsesStringMethod(module_, "pop", arrayClass) { return true } }
  return false
}

function arraysNeedStringComparison(module_: MinusModule): bool {
  for arrayClass of usedArrayTypes(module_) {
    let element = arrayElementFromClassName(arrayClass)
    while isArrayClass(element) { element = arrayElementFromClassName(element) }
    if element == STRING_CLASS || element == "any" { return true }
  }
  return false
}

export function injectStringImplementation(module_: MinusModule): none {
  injectStringConstruction(module_)
  if moduleUsesStringMethod(module_, "replaceAll") { injectStringReplacement(module_) }
  if moduleUsesStringMethod(module_, "trim") || moduleUsesStringMethod(module_, "trimStart") || moduleUsesStringMethod(module_, "trimEnd") {
    injectStringWhitespace(module_)
    for method of ["trim", "trimStart", "trimEnd"] {
      if moduleUsesStringMethod(module_, method) { injectStringTrimming(module_, method) }
    }
  }
  module_.classes.push(MinusClass {
    name: STRING_CLASS,
    fields: [MinusField { name: "chars", typeName: CHAR_ARRAY_CLASS }],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".get",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%index", typeName: "int" }],
    result: "char",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
      MinusInstruction { op: "call-method", result: MinusValue { name: "%value", typeName: "char" }, args: ["%chars", "get", "%index"] },
      MinusInstruction { op: "return", args: ["%value"] },
    ] }],
  })
  module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".length",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }],
    result: "int",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
      MinusInstruction { op: "call-method", result: MinusValue { name: "%length", typeName: "int" }, args: ["%chars", "length"] },
      MinusInstruction { op: "return", args: ["%length"] },
    ] }],
  })
  if moduleUsesStringMethod(module_, "compare") || arraysNeedStringComparison(module_) || moduleUsesArrayClass(module_, "any") { module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".compare",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%other", typeName: STRING_CLASS }],
    result: "int",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%compareLeft", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
      MinusInstruction { op: "get", result: MinusValue { name: "%compareRight", typeName: CHAR_ARRAY_CLASS }, args: ["%other", "chars"] },
      MinusInstruction { op: "get", result: MinusValue { name: "%leftData", typeName: "int" }, args: ["%compareLeft", "data"] },
      MinusInstruction { op: "get", result: MinusValue { name: "%rightData", typeName: "int" }, args: ["%compareRight", "data"] },
      MinusInstruction { op: "array-compare", result: MinusValue { name: "%compared", typeName: "int" }, args: ["%leftData", "%rightData"] },
      MinusInstruction { op: "return", args: ["%compared"] },
    ] }],
  }) }
  if moduleUsesStringMethod(module_, "equals") || arraysNeedStringComparison(module_) { module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".equals",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%other", typeName: STRING_CLASS }],
    result: "bool",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%equalLeft", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
      MinusInstruction { op: "get", result: MinusValue { name: "%equalRight", typeName: CHAR_ARRAY_CLASS }, args: ["%other", "chars"] },
      MinusInstruction { op: "get", result: MinusValue { name: "%equalLeftData", typeName: "int" }, args: ["%equalLeft", "data"] },
      MinusInstruction { op: "get", result: MinusValue { name: "%equalRightData", typeName: "int" }, args: ["%equalRight", "data"] },
      MinusInstruction { op: "array-equal", result: MinusValue { name: "%equal", typeName: "bool" }, args: ["%equalLeftData", "%equalRightData"] },
      MinusInstruction { op: "return", args: ["%equal"] },
    ] }],
  }) }
  let usesIndexOf = moduleUsesStringMethod(module_, "indexOf") || moduleUsesStringMethod(module_, "startsWith") || moduleUsesStringMethod(module_, "contains")
  if usesIndexOf { module_.functions.push(createMinusFunction{
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
        MinusInstruction { op: "const", result: MinusValue { name: "%startOne", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%after", typeName: "int" }, args: ["%failedStart", "%startOne"] },
        MinusInstruction { op: "jump", args: ["outer", "%after"] },
      ] },
      MinusBlock { name: "found", params: [MinusValue { name: "%position", typeName: "int" }], instructions: [MinusInstruction { op: "return", args: ["%position"] }] },
      MinusBlock { name: "missing", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%notFound", typeName: "int" }, args: ["-1"] }, MinusInstruction { op: "return", args: ["%notFound"] }] },
    ],
  }) }
  for methodName of ["startsWith", "contains"] {
    if !moduleUsesStringMethod(module_, methodName) { continue }
    let resultValue = if methodName == "startsWith" then "%isPrefix" else "%isPresent"
    module_.functions.push(createMinusFunction{
      name: STRING_CLASS + "." + methodName,
      params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%needle", typeName: STRING_CLASS }],
      result: "bool",
      blocks: [MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "call-method", result: MinusValue { name: "%position", typeName: "int" }, args: ["%self", "indexOf", "%needle"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%expected", typeName: "int" }, args: [if methodName == "startsWith" then "0" else "-1"] },
        MinusInstruction { op: if methodName == "startsWith" then "eq" else "lt", result: MinusValue { name: resultValue, typeName: "bool" }, args: if methodName == "startsWith" then ["%position", "%expected"] else ["%expected", "%position"] },
        MinusInstruction { op: "return", args: [resultValue] },
      ] }],
    })
  }
  if moduleUsesStringMethod(module_, "endsWith") { module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".endsWith",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%suffix", typeName: STRING_CLASS }],
    result: "bool",
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%suffixChars", typeName: CHAR_ARRAY_CLASS }, args: ["%suffix", "chars"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%length", typeName: "int" }, args: ["%chars", "length"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%suffixLength", typeName: "int" }, args: ["%suffixChars", "length"] },
        MinusInstruction { op: "lt", result: MinusValue { name: "%tooLong", typeName: "bool" }, args: ["%length", "%suffixLength"] },
        MinusInstruction { op: "branch", args: ["%tooLong", "no", "|", "begin"] },
      ] },
      MinusBlock { name: "begin", instructions: [
        MinusInstruction { op: "sub", result: MinusValue { name: "%offset", typeName: "int" }, args: ["%length", "%suffixLength"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "jump", args: ["loop", "%zero"] },
      ] },
      MinusBlock { name: "loop", params: [MinusValue { name: "%index", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%more", typeName: "bool" }, args: ["%index", "%suffixLength"] },
        MinusInstruction { op: "branch", args: ["%more", "check", "%index", "|", "yes"] },
      ] },
      MinusBlock { name: "check", params: [MinusValue { name: "%index2", typeName: "int" }], instructions: [
        MinusInstruction { op: "add", result: MinusValue { name: "%at", typeName: "int" }, args: ["%offset", "%index2"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%actual", typeName: "char" }, args: ["%chars", "get", "%at"] },
        MinusInstruction { op: "call-method", result: MinusValue { name: "%expected", typeName: "char" }, args: ["%suffixChars", "get", "%index2"] },
        MinusInstruction { op: "eq", result: MinusValue { name: "%same", typeName: "bool" }, args: ["%actual", "%expected"] },
        MinusInstruction { op: "branch", args: ["%same", "advance", "%index2", "|", "no"] },
      ] },
      MinusBlock { name: "advance", params: [MinusValue { name: "%index3", typeName: "int" }], instructions: [
        MinusInstruction { op: "const", result: MinusValue { name: "%one", typeName: "int" }, args: ["1"] },
        MinusInstruction { op: "add", result: MinusValue { name: "%next", typeName: "int" }, args: ["%index3", "%one"] },
        MinusInstruction { op: "jump", args: ["loop", "%next"] },
      ] },
      MinusBlock { name: "yes", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%true", typeName: "bool" }, args: ["true"] }, MinusInstruction { op: "return", args: ["%true"] }] },
      MinusBlock { name: "no", instructions: [MinusInstruction { op: "const", result: MinusValue { name: "%false", typeName: "bool" }, args: ["false"] }, MinusInstruction { op: "return", args: ["%false"] }] },
    ],
  }) }
  if moduleUsesStringMethod(module_, "substring") { module_.functions.push(createMinusFunction{
    name: STRING_CLASS + ".substring",
    params: [MinusValue { name: "%self", typeName: STRING_CLASS }, MinusValue { name: "%start", typeName: "int" }, MinusValue { name: "%end", typeName: "int" }],
    result: STRING_CLASS,
    blocks: [
      MinusBlock { name: "entry", instructions: [
        MinusInstruction { op: "get", result: MinusValue { name: "%chars", typeName: CHAR_ARRAY_CLASS }, args: ["%self", "chars"] },
        MinusInstruction { op: "get", result: MinusValue { name: "%source", typeName: "int" }, args: ["%chars", "data"] },
        MinusInstruction { op: "array-length", result: MinusValue { name: "%length", typeName: "int" }, args: ["%source"] },
        MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: "int" }, args: ["0"] },
        MinusInstruction { op: "lt", result: MinusValue { name: "%negative", typeName: "bool" }, args: ["%start", "%zero"] },
        MinusInstruction { op: "branch", args: ["%negative", "begin", "%zero", "|", "begin", "%start"] },
      ] },
      MinusBlock { name: "begin", params: [MinusValue { name: "%begin", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%past", typeName: "bool" }, args: ["%length", "%end"] },
        MinusInstruction { op: "branch", args: ["%past", "range", "%length", "|", "range", "%end"] },
      ] },
      MinusBlock { name: "range", params: [MinusValue { name: "%limit", typeName: "int" }], instructions: [
        MinusInstruction { op: "lt", result: MinusValue { name: "%nonempty", typeName: "bool" }, args: ["%begin", "%limit"] },
        MinusInstruction { op: "branch", args: ["%nonempty", "copy", "|", "empty"] },
      ] },
      MinusBlock { name: "copy", instructions: [
        MinusInstruction { op: "sub", result: MinusValue { name: "%sliceLength", typeName: "int" }, args: ["%limit", "%begin"] },
        MinusInstruction { op: "array-alloc", result: MinusValue { name: "%data", typeName: "int" }, args: ["%sliceLength", "char"] },
        MinusInstruction { op: "array-copy", args: ["%data", "%zero", "%source", "%begin", "%sliceLength", "char"] },
        MinusInstruction { op: "new", result: MinusValue { name: "%resultChars", typeName: CHAR_ARRAY_CLASS }, args: [CHAR_ARRAY_CLASS, "%data"] },
        MinusInstruction { op: "new", result: MinusValue { name: "%result", typeName: STRING_CLASS }, args: [STRING_CLASS, "%resultChars"] },
        MinusInstruction { op: "return", args: ["%result"] },
      ] },
      MinusBlock { name: "empty", instructions: [
        MinusInstruction { op: "string-const", result: MinusValue { name: "%empty", typeName: STRING_CLASS }, args: [""] },
        MinusInstruction { op: "return", args: ["%empty"] },
      ] },
    ],
  }) }
}
