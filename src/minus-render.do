// Human-readable doof-- rendering for inspecting an already-built model.
import { MinusBlock, MinusFunction, MinusImport, MinusInstruction, MinusModule, MinusValue } from "./minus-ir"

function joined(values: string[], start: int = 0, stop: int = -1): string {
  let end = if stop < 0 then values.length else stop
  let output = ""
  for index of start..<end { output += (if index == start then "" else ", ") + values[index] }
  return output
}

function valueDeclaration(value: MinusValue): string => value.name + ":" + value.typeName

function blockParameters(block: MinusBlock): string {
  let values: string[] = []
  for parameter of block.params { values.push(valueDeclaration(parameter)) }
  return if values.length == 0 then "" else "(" + joined(values) + ")"
}

function renderedResult(instruction: MinusInstruction): string {
  if instruction.result == none { return "" }
  return valueDeclaration(instruction.result!) + " = "
}

function target(name: string, args: string[], start: int, stop: int): string => name + "(" + joined(args, start, stop) + ")"

function renderBranch(args: string[]): string {
  let split = -1
  for index of 0..<args.length { if args[index] == "|" { split = index; break } }
  if split < 0 || split + 1 >= args.length { return "branch " + joined(args) }
  first := target(args[1], args, 2, split)
  second := target(args[split + 1], args, split + 2, args.length)
  return "branch " + args[0] + " " + first + " " + second
}

function renderInstruction(instruction: MinusInstruction): string {
  args := instruction.args
  prefix := renderedResult(instruction)
  op := instruction.op
  if op == "const" { return prefix + "const " + joined(args) }
  if ["add", "sub", "mul", "div", "eq", "lt"].contains(op) { return prefix + op + " " + joined(args) }
  if op == "new" { return prefix + "new " + args[0] + "(" + joined(args, 1) + ")" }
  if op == "get" { return prefix + "get " + args[0] + "." + args[1] }
  if op == "set" { return "set " + args[0] + "." + args[1] + " = " + args[2] }
  if op == "call" { return prefix + "call " + args[0] + "(" + joined(args, 1) + ")" }
  if op == "call-method" { return prefix + "call " + args[0] + "." + args[1] + "(" + joined(args, 2) + ")" }
  if ["as", "box", "copy", "convert"].contains(op) { return prefix + op + " " + joined(args) }
  if op == "is" || op == "cast" { return prefix + op + " " + args[0] + " " + args[1] }
  if op == "jump" { return "jump " + target(args[0], args, 1, args.length) }
  if op == "branch" { return renderBranch(args) }
  if op == "return" { return "return" + (if args.length == 0 then "" else " " + args[0]) }
  if op == "panic" { return "panic" }
  return prefix + op + " " + joined(args)
}

function renderFunction(function_: MinusFunction): string {
  let params: string[] = []
  for parameter of function_.params { params.push(valueDeclaration(parameter)) }
  let output = (if function_.exported then "export " else "") + "func " + function_.name + "(" + joined(params) + ") -> " + function_.result + "\n"
  for block of function_.blocks {
    output += "block " + block.name + blockParameters(block) + "\n"
    for instruction of block.instructions { output += renderInstruction(instruction) + "\n" }
  }
  return output + "end\n"
}

function renderImport(import_: MinusImport): string {
  let params: string[] = []
  for parameter of import_.params { params.push(valueDeclaration(parameter)) }
  return "import func " + import_.name + "(" + joined(params) + ") -> " + import_.result + " from " + import_.importModule + " as " + import_.importName + "\n"
}

/** Render a MinusModule as readable doof-- text for debugging or snapshots. */
export function renderDoofMinus(module_: MinusModule): string {
  let output = ""
  for class_ of module_.classes {
    output += "class " + class_.name
    if class_.interfaces.length > 0 { output += " implements " + joined(class_.interfaces) }
    output += "\n"
    if class_.finalizer != "" { output += "destructor " + class_.finalizer + "\n" }
    for field of class_.fields {
      output += "field " + (if field.mutable then "let " else "") + field.name + ":" + field.typeName + "\n"
    }
    output += "end\n"
  }
  for interface_ of module_.interfaces {
    output += "interface " + interface_.name + "\n"
    for field of interface_.fields {
      output += "field " + (if field.mutable then "let " else "") + field.name + ":" + field.typeName + "\n"
    }
    for method of interface_.methods {
      output += "method " + method.name + "(" + joined(method.params) + ") -> " + method.result + "\n"
    }
    output += "end\n"
  }
  for import_ of module_.imports { output += renderImport(import_) }
  for function_ of module_.functions { output += renderFunction(function_) }
  return output
}
