// Shared lowering context, names, type mappings, and instruction helpers.
import {
  PrimitiveType, ClassType, EnumType, InterfaceType, ArrayResolvedType, MapResolvedType, SerialValueResolvedType, NoneType,
  UnionResolvedType, ResultResolvedType, SuccessResolvedType, FailureResolvedType, ResolvedType, FunctionType, PromiseType,
} from "doof/src/semantic"
import { ClassDeclaration, EnumDeclaration, Expression, IfStatement, IfBranch, FunctionDeclaration } from "doof/src/ast"
import { MinusModule, MinusInterface, MinusMethod, MinusValue, MinusBlock, MinusInstruction, MinusNameIndex, createMinusNameIndex, lookupMinusName, insertMinusName } from "./minus-ir"
import { WasmLoweringOptions } from "./doof-lowering-options"
import { BYTE_ARRAY_CLASS, CHAR_ARRAY_CLASS, STRING_CLASS, STRING_BOOL_MAP_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS, ARRAY_CLASS_PREFIX, arrayClassName } from "./doof-lowering-constants"

export class SourceBinding {
  name: string
  typeName: string
  valueName: string
  parameter: bool = false
  mutable: bool = false
  boxedTypeName: string = ""
  // Stable declaration identity for versions carried to an enclosing loop.
  // Synthesized bindings use unique names and keep the default sentinel.
  origin: int = -1
}

export class SourceConstant {
  name: string
  modulePath: string
  value: Expression
  typeName: string = ""
}

export class LoopTarget {
  breakName: string
  continueName: string
  locals: SourceBinding[]
  label: string | none = none
  parent: LoopTarget | none = none
  scopeDepth: int = 0
}

export class YieldTarget {
  joinName: string
  typeName: string
  locals: SourceBinding[]
  scopeDepth: int = 0
}

// Owned by one lowering invocation; never retained across compilations.
export class SourceNameCache {
  paths: MinusNameIndex = createMinusNameIndex(128)
  prefixes: string[] = []
}

export class FunctionLowering {
  let names: SourceNameCache | none = none
  let options: WasmLoweringOptions = WasmLoweringOptions {}
  let completionType: string = ""
  constants: SourceConstant[] = []
  expandingConstants: string[] = []
  let loopTarget: LoopTarget | none = none
  let yieldTarget: YieldTarget | none = none
  scopedValues: MinusValue[] = []

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
  classDeclarations: ClassDeclaration[] = []
}

export function staticFunctionName(className: string, method: string): string {
  return "__doof_static_" + string(className.length) + "_" + className + "_" + method
}

export function qualifiedName(modulePath: string, name: string, names: SourceNameCache | none = none): string {
  if names != none {
    index := lookupMinusName(names!.paths, modulePath)
    if index >= 0 { return names!.prefixes[index] + name }
  }
  // Decimal character codes make this encoding injective across logical paths.
  let result = "m"
  for index of 0..<modulePath.length { result = result + "_" + string(int(modulePath[index])) }
  prefix := result + "_"
  if names != none {
    _ := insertMinusName(names!.paths, modulePath)
    names!.prefixes.push(prefix)
  }
  return prefix + name
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

export function resolvedName(type_: ResolvedType, names: SourceNameCache | none = none): string {
  case type_ {
    primitive: PrimitiveType -> { return if primitive.name == "string" then STRING_CLASS else primitive.name }
    class_: ClassType -> { return qualifiedName(class_.symbol.module, if class_.symbol.originalName == "" then class_.symbol.name else class_.symbol.originalName, names) }
    enum_: EnumType -> { return qualifiedName(enum_.symbol.module, enum_.name, names) }
    interface_: InterfaceType -> { return qualifiedName(interface_.symbol.module, interface_.name, names) }
    function_: FunctionType -> { return closureInterfaceName(function_, names) }
    _: PromiseType -> { return "__doof_promise" }
    map: MapResolvedType -> {
      if resolvedName(map.keyType, names) == STRING_CLASS && resolvedName(map.valueType, names) == "bool" { return STRING_BOOL_MAP_CLASS }
      return ""
    }
    array: ArrayResolvedType -> {
      elementType := resolvedName(array.elementType, names)
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
      for member of union_.types { if !supportedUnionMember(member, names) { return "" } }
      return "any"
    }
    _: NoneType -> { return "none" }
    _ -> { return "" }
  }
}

export function closureInterfaceName(function_: FunctionType, names: SourceNameCache | none = none): string {
  let name = "__closure_" + closureTypeLabel(function_.returnType, names)
  for parameter of function_.params { name = name + "_" + closureTypeLabel(parameter.type_, names) }
  return name
}

function closureTypeLabel(type_: ResolvedType, names: SourceNameCache | none = none): string {
  case type_ {
    primitive: PrimitiveType -> { if primitive.name == "string" { return "string" } }
    _ -> { }
  }
  return resolvedName(type_, names)
}

function supportedUnionMember(type_: ResolvedType, names: SourceNameCache | none = none): bool {
  case type_ {
    primitive: PrimitiveType -> { return ["bool", "char", "byte", "int", "long", "float", "double", "string"].contains(primitive.name) }
    _: ClassType -> { return true }
    result_: ResultResolvedType -> { return supportedUnionMember(result_.valueType, names) && supportedUnionMember(result_.errorType, names) }
    success: SuccessResolvedType -> { return supportedUnionMember(success.valueType, names) }
    failure: FailureResolvedType -> { return supportedUnionMember(failure.errorType, names) }
    _: EnumType -> { return true }
    _: SerialValueResolvedType -> { return true }
    map: MapResolvedType -> { return resolvedName(map, names) != "" }
    array: ArrayResolvedType -> { return resolvedName(array, names) != "" }
    _: NoneType -> { return true }
    union_: UnionResolvedType -> {
      for member of union_.types { if !supportedUnionMember(member, names) { return false } }
      return true
    }
    _ -> { return false }
  }
}

export function annotationName(type_: ResolvedType | none, names: SourceNameCache | none = none): string {
  if type_ == none { return "none" }
  return resolvedName(type_!, names)
}

export function typeFromValue(value: Expression, names: SourceNameCache | none = none): string {
  if value.resolvedType == none { return "" }
  return resolvedName(value.resolvedType!, names)
}

export function declarationType(type_: ResolvedType | none, fallback: string, names: SourceNameCache | none = none): string {
  if type_ != none { return resolvedName(type_!, names) }
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
    if binding.parameter || !binding.mutable || names.contains(binding.name) { continue }
    names.push(binding.name)
    current := findBinding(context, binding.name)
    if current != none && current!.mutable { result.push(current!) }
  }
  return result
}

export function bindingValues(context: FunctionLowering, bindings: SourceBinding[]): string[] {
  let result: string[] = []
  for binding of bindings {
    let current: SourceBinding | none = none
    for candidate of context.bindings {
      if candidate.name == binding.name && candidate.origin == binding.origin { current = candidate }
    }
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
  child.names = parent.names
  child.options = parent.options
  child.completionType = parent.completionType
  for binding of parent.bindings { child.bindings.push(binding) }
  for interfaceName of parent.interfaceNames { child.interfaceNames.push(interfaceName) }
  child.nextValue = parent.nextValue
  child.nextBlock = parent.nextBlock
  for index of 0..<locals.length {
    valueName := "%b" + string(id) + suffix + string(index)
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    params.push(MinusValue { name: valueName, typeName: storageType })
    child.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName, mutable: locals[index].mutable, origin: locals[index].origin, boxedTypeName: locals[index].boxedTypeName })
  }
  for constant of parent.constants { child.constants.push(constant) }
  for name of parent.expandingConstants { child.expandingConstants.push(name) }
  child.loopTarget = parent.loopTarget
  child.yieldTarget = parent.yieldTarget
  for value of parent.scopedValues { child.scopedValues.push(value) }
  child.sourcePath = parent.sourcePath
  child.module_ = parent.module_
  child.closureIndex = parent.closureIndex
  child.closurePrefix = parent.closurePrefix
  for declaration of parent.enumDeclarations { child.enumDeclarations.push(declaration) }
  for modulePath of parent.enumModules { child.enumModules.push(modulePath) }
  for declaration of parent.classDeclarations { child.classDeclarations.push(declaration) }
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

export function registerClosureType(module_: MinusModule, type_: ResolvedType | none, line: int, sourcePath: string, names: SourceNameCache | none = none): none {
  if type_ == none { return }
  case type_! {
    function_: FunctionType -> {
      registerClosureType(module_, function_.returnType, line, sourcePath, names)
      for parameter of function_.params { registerClosureType(module_, parameter.type_, line, sourcePath, names) }
      name := closureInterfaceName(function_, names)
      for existing of module_.interfaces { if existing.name == name { return } }
      let params: string[] = []
      for parameter of function_.params { params.push(resolvedName(parameter.type_, names)) }
      module_.interfaces.push(MinusInterface {
        name, line, sourcePath,
        methods: [MinusMethod { name: "invoke", params, result: resolvedName(function_.returnType, names), line, sourcePath }],
      })
    }
    array: ArrayResolvedType -> { registerClosureType(module_, array.elementType, line, sourcePath, names) }
    _ -> { }
  }
}
