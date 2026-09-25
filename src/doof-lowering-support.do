// Shared lowering context, names, type mappings, and instruction helpers.
import {
  PrimitiveType, ClassType, EnumType, InterfaceType, ArrayResolvedType, SerialValueResolvedType, NoneType,
  UnionResolvedType, ResultResolvedType, SuccessResolvedType, FailureResolvedType, ResolvedType, FunctionType,
} from "doof/src/semantic"
import { EnumDeclaration, Expression, IfStatement, IfBranch, FunctionDeclaration } from "doof/src/ast"
import { MinusModule, MinusInterface, MinusMethod, MinusValue, MinusBlock, MinusInstruction } from "./minus-ir"
import { BYTE_ARRAY_CLASS, CHAR_ARRAY_CLASS, STRING_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS, ARRAY_CLASS_PREFIX, arrayClassName } from "./doof-lowering-constants"

export class SourceBinding {
  name: string
  typeName: string
  valueName: string
  parameter: bool = false
  mutable: bool = false
  boxedTypeName: string = ""
}

export class FunctionLowering {
  blocks: MinusBlock[] = []
  let currentBlock: MinusBlock
  bindings: SourceBinding[] = []
  interfaceNames: string[] = []
  let nextValue: int = 0
  let nextBlock: int = 0
  let failed: string = ""
  let terminated: bool = false
  let sourcePath: string = ""
  let module_: MinusModule | none = none
  let closureIndex: int = 0
  let closurePrefix: string = ""
  let currentLine: int = 0
  enumDeclarations: EnumDeclaration[] = []
  enumModules: string[] = []
}

export function qualifiedName(modulePath: string, name: string): string {
  // Decimal character codes make this encoding injective across logical paths.
  let result = "m"
  for index of 0..<modulePath.length { result = result + "_" + string(int(modulePath[index])) }
  return result + "_" + name
}

export function atLine(line: int, message: string): string => "line " + string(line) + ": " + message

export function enumVariantValue(declarations: EnumDeclaration[], modules: string[], modulePath: string, enumName: string, variantName: string): int | none {
  for index of 0..<declarations.length {
    declaration := declarations[index]
    if modules[index] != modulePath || declaration.name != enumName { continue }
    for variant of declaration.variants {
      if variant.name == variantName { return variant.resolvedIntValue }
    }
  }
  return none
}

export function resolvedName(type_: ResolvedType): string {
  case type_ {
    primitive: PrimitiveType -> { return if primitive.name == "string" then STRING_CLASS else primitive.name }
    class_: ClassType -> { return qualifiedName(class_.symbol.module, class_.name) }
    enum_: EnumType -> { return qualifiedName(enum_.symbol.module, enum_.name) }
    interface_: InterfaceType -> { return qualifiedName(interface_.symbol.module, interface_.name) }
    function_: FunctionType -> { return closureInterfaceName(function_) }
    array: ArrayResolvedType -> {
      elementType := resolvedName(array.elementType)
      if elementType == "byte" { return BYTE_ARRAY_CLASS }
      if elementType == "char" { return CHAR_ARRAY_CLASS }
      if elementType == "" || elementType == "none" { return "" }
      return arrayClassName(elementType)
    }
    _: SerialValueResolvedType -> { return "any" }
    _: ResultResolvedType -> { return "any" }
    _: SuccessResolvedType -> { return RESULT_SUCCESS_CLASS }
    _: FailureResolvedType -> { return RESULT_FAILURE_CLASS }
    union_: UnionResolvedType -> {
      for member of union_.types { if !supportedUnionMember(member) { return "" } }
      return "any"
    }
    _: NoneType -> { return "none" }
    _ -> { return "" }
  }
}

export function closureInterfaceName(function_: FunctionType): string {
  let name = "__closure_" + closureTypeLabel(function_.returnType)
  for parameter of function_.params { name = name + "_" + closureTypeLabel(parameter.type_) }
  return name
}

export function closureTypeLabel(type_: ResolvedType): string {
  case type_ {
    primitive: PrimitiveType -> { if primitive.name == "string" { return "string" } }
    _ -> { }
  }
  return resolvedName(type_)
}

export function supportedUnionMember(type_: ResolvedType): bool {
  case type_ {
    primitive: PrimitiveType -> { return ["bool", "char", "byte", "short", "int", "long", "float", "double", "string"].contains(primitive.name) }
    _: ClassType -> { return true }
    _: EnumType -> { return true }
    _: SerialValueResolvedType -> { return true }
    _: NoneType -> { return true }
    union_: UnionResolvedType -> {
      for member of union_.types { if !supportedUnionMember(member) { return false } }
      return true
    }
    _ -> { return false }
  }
}

export function annotationName(type_: ResolvedType | none): string {
  if type_ == none { return "none" }
  return resolvedName(type_!)
}

export function typeFromValue(value: Expression): string {
  if value.resolvedType == none { return "" }
  return resolvedName(value.resolvedType!)
}

export function declarationType(type_: ResolvedType | none, fallback: string): string {
  if type_ != none { return resolvedName(type_!) }
  return fallback
}

export function findBinding(context: FunctionLowering, name: string): SourceBinding | none {
  let found: SourceBinding | none = none
  for binding of context.bindings { if binding.name == name { found = binding } }
  return found
}

export function latestLocals(context: FunctionLowering): SourceBinding[] {
  let result: SourceBinding[] = []
  let names: string[] = []
  for binding of context.bindings {
    if binding.parameter || names.contains(binding.name) { continue }
    names.push(binding.name)
    current := findBinding(context, binding.name)
    if current != none { result.push(current!) }
  }
  return result
}

export function bindingValues(context: FunctionLowering, bindings: SourceBinding[]): string[] {
  let result: string[] = []
  for binding of bindings {
    current := findBinding(context, binding.name)
    result.push(if current == none then binding.valueName else current!.valueName)
  }
  return result
}

export function result(context: FunctionLowering, op: string, args: string[], typeName: string): string {
  name := "%v" + string(context.nextValue)
  context.nextValue = context.nextValue + 1
  context.currentBlock.instructions.push(MinusInstruction {
    op, result: MinusValue { name, typeName }, args, line: context.currentLine, sourcePath: context.sourcePath,
  })
  return name
}

export function effect(context: FunctionLowering, op: string, args: string[]): none {
  context.currentBlock.instructions.push(MinusInstruction { op, args, line: context.currentLine, sourcePath: context.sourcePath })
}

export function blockContext(parent: FunctionLowering, locals: SourceBinding[], id: int, suffix: string, name: string): FunctionLowering {
  let params: MinusValue[] = []
  let child = FunctionLowering { currentBlock: MinusBlock { name, line: 0 } }
  for binding of parent.bindings { child.bindings.push(binding) }
  for interfaceName of parent.interfaceNames { child.interfaceNames.push(interfaceName) }
  child.nextValue = parent.nextValue
  child.nextBlock = parent.nextBlock
  for index of 0..<locals.length {
    valueName := "%b" + string(id) + suffix + string(index)
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    params.push(MinusValue { name: valueName, typeName: storageType })
    child.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
  }
  child.sourcePath = parent.sourcePath
  child.module_ = parent.module_
  child.closureIndex = parent.closureIndex
  child.closurePrefix = parent.closurePrefix
  for declaration of parent.enumDeclarations { child.enumDeclarations.push(declaration) }
  for modulePath of parent.enumModules { child.enumModules.push(modulePath) }
  child.currentBlock = MinusBlock { name, params, line: 0, sourcePath: parent.sourcePath }
  child.blocks.push(child.currentBlock)
  return child
}

export function concatValues(prefix: string[], suffix: string[]): string[] {
  let result: string[] = []
  for value of prefix { result.push(value) }
  for value of suffix { result.push(value) }
  return result
}

export function appendContext(parent: FunctionLowering, child: FunctionLowering): none {
  for block of child.blocks { parent.blocks.push(block) }
  parent.currentBlock = child.currentBlock
  if child.nextValue > parent.nextValue { parent.nextValue = child.nextValue }
  if child.nextBlock > parent.nextBlock { parent.nextBlock = child.nextBlock }
  if child.closureIndex > parent.closureIndex { parent.closureIndex = child.closureIndex }
}

export function nestedElseIf(statement: IfStatement, index: int): IfStatement {
  branch := statement.elseIfs[index]
  let remaining: IfBranch[] = []
  for next of (index + 1)..<statement.elseIfs.length { remaining.push(statement.elseIfs[next]) }
  return IfStatement {
    kind: "if-statement",
    condition: branch.condition,
    body: branch.body,
    elseIfs: remaining,
    else_: statement.else_,
    span: branch.span,
  }
}

export function functionResultType(fn: FunctionDeclaration): ResolvedType | none {
  if fn.resolvedType == none { return none }
  case fn.resolvedType! {
    function_: FunctionType -> { return function_.returnType }
    _ -> { return none }
  }
}

export function registerClosureType(module_: MinusModule, type_: ResolvedType | none, line: int, sourcePath: string): none {
  if type_ == none { return }
  case type_! {
    function_: FunctionType -> {
      registerClosureType(module_, function_.returnType, line, sourcePath)
      for parameter of function_.params { registerClosureType(module_, parameter.type_, line, sourcePath) }
      name := closureInterfaceName(function_)
      for existing of module_.interfaces { if existing.name == name { return } }
      let params: string[] = []
      for parameter of function_.params { params.push(resolvedName(parameter.type_)) }
      module_.interfaces.push(MinusInterface {
        name, line, sourcePath,
        methods: [MinusMethod { name: "invoke", params, result: resolvedName(function_.returnType), line, sourcePath }],
      })
    }
    array: ArrayResolvedType -> { registerClosureType(module_, array.elementType, line, sourcePath) }
    _ -> { }
  }
}
