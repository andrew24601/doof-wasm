// Carry expression temporaries across source-generated control-flow edges.
import { MinusFunction, MinusBlock, MinusValue } from "./minus-ir"

class BlockValues {
  defined: string[] = []
  required: string[] = []
}

function add(values: string[], name: string): bool {
  if values.contains(name) { return false }
  values.push(name)
  return true
}

function blockIndex(function_: MinusFunction, name: string): int {
  for index of 0..<function_.blocks.length { if function_.blocks[index].name == name { return index } }
  return -1
}

function targets(block: MinusBlock): string[] {
  last := block.instructions[block.instructions.length - 1]
  if last.op == "jump" { return [last.args[0]] }
  if last.op == "branch" {
    for index of 0..<last.args.length { if last.args[index] == "|" { return [last.args[1], last.args[index + 1]] } }
  }
  return []
}

function valueType(function_: MinusFunction, name: string): string {
  for block of function_.blocks {
    for value of block.params { if value.name == name { return value.typeName } }
    for instruction of block.instructions {
      if instruction.result != none && instruction.result!.name == name { return instruction.result!.typeName }
    }
  }
  return ""
}

function carriedName(index: int, name: string): string => "%carry" + string(index) + "_" + name.substring(1)

/** Source expressions may split blocks after evaluating an owner or argument.
 * Preserve those SSA values explicitly, just as source bindings are carried.
 * Function parameters are visible in every block and need no extra arguments.
 */
export function carryExpressionValues(function_: MinusFunction): none {
  let parameters: string[] = []
  for parameter of function_.params { parameters.push(parameter.name) }
  let values: BlockValues[] = []
  for block of function_.blocks {
    let info = BlockValues {}
    for parameter of block.params { info.defined.push(parameter.name) }
    for instruction of block.instructions {
      if instruction.result != none { info.defined.push(instruction.result!.name) }
    }
    for instruction of block.instructions {
      if instruction.op == "const" || instruction.op == "string-const" { continue }
      for argument of instruction.args {
        if argument.startsWith("%") && !parameters.contains(argument) && !info.defined.contains(argument) { _ := add(info.required, argument) }
      }
    }
    values.push(info)
  }
  let changed = true
  while changed {
    changed = false
    for index of 0..<function_.blocks.length {
      for target of targets(function_.blocks[index]) {
        successor := blockIndex(function_, target)
        if successor < 0 { continue }
        for name of values[successor].required {
          if !parameters.contains(name) && !values[index].defined.contains(name) {
            if add(values[index].required, name) { changed = true }
          }
        }
      }
    }
  }
  // Resolve types before introducing new parameters or renaming operands.
  let types: string[][] = []
  for info of values {
    let requiredTypes: string[] = []
    for name of info.required { requiredTypes.push(valueType(function_, name)) }
    types.push(requiredTypes)
  }
  for index of 0..<function_.blocks.length {
    block := function_.blocks[index]
    for offset of 0..<values[index].required.length {
      name := values[index].required[offset]
      block.params.push(MinusValue { name: carriedName(index, name), typeName: types[index][offset] })
    }
    last := block.instructions[block.instructions.length - 1]
    if last.op == "jump" {
      successor := blockIndex(function_, last.args[0])
      if successor >= 0 { for name of values[successor].required { last.args.push(name) } }
    } else if last.op == "branch" {
      let separator = -1
      for offset of 0..<last.args.length { if last.args[offset] == "|" { separator = offset } }
      yes := blockIndex(function_, last.args[1])
      no := blockIndex(function_, last.args[separator + 1])
      let arguments: string[] = []
      for offset of 0..<separator { arguments.push(last.args[offset]) }
      if yes >= 0 { for name of values[yes].required { arguments.push(name) } }
      for offset of separator..<last.args.length { arguments.push(last.args[offset]) }
      if no >= 0 { for name of values[no].required { arguments.push(name) } }
      while last.args.length > 0 { _ := try! last.args.pop() }
      for argument of arguments { last.args.push(argument) }
    }
    for instruction of block.instructions {
      if instruction.op == "const" || instruction.op == "string-const" { continue }
      for offset of 0..<instruction.args.length {
        name := instruction.args[offset]
        if values[index].required.contains(name) { instruction.args[offset] = carriedName(index, name) }
      }
    }
  }
}
