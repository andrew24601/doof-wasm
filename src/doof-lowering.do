// Lower checked Doof AST nodes directly into the doof-- model.
import {
  PrimitiveType, ClassType, InterfaceType, ArrayResolvedType, SerialValueResolvedType, NoneType,
  UnionResolvedType, ResolvedType, FunctionType,
} from "doof/src/semantic"
import {
  Program, Statement, FunctionDeclaration, ClassDeclaration, InterfaceDeclaration,
  Expression, Block, ReturnStatement, ImmutableBinding, LetDeclaration,
  ReadonlyDeclaration, ExpressionStatement, IntLiteral, LongLiteral, FloatLiteral,
  DoubleLiteral, StringLiteral, CharLiteral, BoolLiteral, NoneLiteral, Identifier,
  BinaryExpression, UnaryExpression, AssignmentExpression, CallExpression, MemberExpression,
  ConstructExpression, ArrayLiteral, IndexExpression, AsExpression, ThisExpression, IfStatement, IfBranch,
  CaseStatement, TypePattern, ValuePattern, WildcardPattern, WhileStatement,
  ImportDeclaration, ExportList,
} from "doof/src/ast"
import {
  MinusModule, MinusClass, MinusField, MinusInterface, MinusMethod, MinusValue, MinusImport,
  MinusFunction, MinusBlock, MinusInstruction,
} from "./minus-ir"

readonly BYTE_ARRAY_CLASS = "__doof_array_byte"
readonly BYTE_ARRAY_DESTRUCTOR = "__doof_array_byte.destroy"
readonly CHAR_ARRAY_CLASS = "__doof_array_char"
readonly CHAR_ARRAY_DESTRUCTOR = "__doof_array_char.destroy"
readonly STRING_CLASS = "__doof_string"

class SourceBinding {
  name: string
  typeName: string
  valueName: string
  parameter: bool = false
}

class FunctionLowering {
  blocks: MinusBlock[] = []
  let currentBlock: MinusBlock
  bindings: SourceBinding[] = []
  interfaceNames: string[] = []
  let nextValue: int = 0
  let nextBlock: int = 0
  let failed: string = ""
  let terminated: bool = false
  let sourcePath: string = ""
  let currentLine: int = 0
}

function qualifiedName(modulePath: string, name: string): string {
  // Decimal character codes make this encoding injective across logical paths.
  let result = "m"
  for index of 0..<modulePath.length { result = result + "_" + string(int(modulePath[index])) }
  return result + "_" + name
}

function atLine(line: int, message: string): string => "line " + string(line) + ": " + message

function resolvedName(type_: ResolvedType): string {
  case type_ {
    primitive: PrimitiveType -> { return if primitive.name == "string" then STRING_CLASS else primitive.name }
    class_: ClassType -> { return qualifiedName(class_.symbol.module, class_.name) }
    interface_: InterfaceType -> { return qualifiedName(interface_.symbol.module, interface_.name) }
    array: ArrayResolvedType -> {
      case array.elementType {
        primitive: PrimitiveType -> {
          if primitive.name == "byte" { return BYTE_ARRAY_CLASS }
          if primitive.name == "char" { return CHAR_ARRAY_CLASS }
        }
        _ -> { }
      }
      return ""
    }
    _: SerialValueResolvedType -> { return "any" }
    union_: UnionResolvedType -> {
      for member of union_.types { if !supportedUnionMember(member) { return "" } }
      return "any"
    }
    _: NoneType -> { return "none" }
    _ -> { return "" }
  }
}

function supportedUnionMember(type_: ResolvedType): bool {
  case type_ {
    primitive: PrimitiveType -> { return ["bool", "char", "byte", "short", "int", "long", "float", "double", "string"].contains(primitive.name) }
    _: ClassType -> { return true }
    _: SerialValueResolvedType -> { return true }
    _: NoneType -> { return true }
    union_: UnionResolvedType -> {
      for member of union_.types { if !supportedUnionMember(member) { return false } }
      return true
    }
    _ -> { return false }
  }
}

function annotationName(type_: ResolvedType | none): string {
  if type_ == none { return "none" }
  return resolvedName(type_!)
}

function typeFromValue(value: Expression): string {
  if value.resolvedType == none { return "" }
  return resolvedName(value.resolvedType!)
}

function declarationType(type_: ResolvedType | none, fallback: string): string {
  if type_ != none { return resolvedName(type_!) }
  return fallback
}

function findBinding(context: FunctionLowering, name: string): SourceBinding | none {
  let found: SourceBinding | none = none
  for binding of context.bindings { if binding.name == name { found = binding } }
  return found
}

function latestLocals(context: FunctionLowering): SourceBinding[] {
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

function bindingValues(context: FunctionLowering, bindings: SourceBinding[]): string[] {
  let result: string[] = []
  for binding of bindings {
    current := findBinding(context, binding.name)
    result.push(if current == none then binding.valueName else current!.valueName)
  }
  return result
}

function result(context: FunctionLowering, op: string, args: string[], typeName: string): string {
  name := "%v" + string(context.nextValue)
  context.nextValue = context.nextValue + 1
  context.currentBlock.instructions.push(MinusInstruction {
    op, result: MinusValue { name, typeName }, args, line: context.currentLine, sourcePath: context.sourcePath,
  })
  return name
}

function effect(context: FunctionLowering, op: string, args: string[]): none {
  context.currentBlock.instructions.push(MinusInstruction { op, args, line: context.currentLine, sourcePath: context.sourcePath })
}

function blockContext(parent: FunctionLowering, locals: SourceBinding[], id: int, suffix: string, name: string): FunctionLowering {
  let params: MinusValue[] = []
  let child = FunctionLowering { currentBlock: MinusBlock { name, line: 0 } }
  for binding of parent.bindings { child.bindings.push(binding) }
  for interfaceName of parent.interfaceNames { child.interfaceNames.push(interfaceName) }
  child.nextValue = parent.nextValue
  child.nextBlock = parent.nextBlock
  for index of 0..<locals.length {
    valueName := "%b" + string(id) + suffix + string(index)
    params.push(MinusValue { name: valueName, typeName: locals[index].typeName })
    child.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName })
  }
  child.sourcePath = parent.sourcePath
  child.currentBlock = MinusBlock { name, params, line: 0, sourcePath: parent.sourcePath }
  child.blocks.push(child.currentBlock)
  return child
}

function concatValues(prefix: string[], suffix: string[]): string[] {
  let result: string[] = []
  for value of prefix { result.push(value) }
  for value of suffix { result.push(value) }
  return result
}

function appendContext(parent: FunctionLowering, child: FunctionLowering): none {
  for block of child.blocks { parent.blocks.push(block) }
  parent.currentBlock = child.currentBlock
  if child.nextValue > parent.nextValue { parent.nextValue = child.nextValue }
  if child.nextBlock > parent.nextBlock { parent.nextBlock = child.nextBlock }
}

function nestedElseIf(statement: IfStatement, index: int): IfStatement {
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

function lowerIf(context: FunctionLowering, statement: IfStatement): none {
  condition := lowerExpression(context, statement.condition)
  if context.failed != "" { return }
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  yesName := "if_yes" + string(id)
  noName := "if_no" + string(id)
  joinName := "if_join" + string(id)
  yesValues := bindingValues(context, locals)
  noValues := bindingValues(context, locals)
  let branchArgs: string[] = [condition, yesName]
  for value of yesValues { branchArgs.push(value) }
  branchArgs.push("|"); branchArgs.push(noName)
  for value of noValues { branchArgs.push(value) }
  effect(context, "branch", branchArgs)

  yesContext := blockContext(context, locals, id, "y", yesName)
  noContext := blockContext(context, locals, id, "n", noName)
  lowerStatements(yesContext, statement.body.statements)
  if yesContext.failed != "" { context.failed = yesContext.failed; return }
  noContext.nextValue = yesContext.nextValue
  noContext.nextBlock = yesContext.nextBlock
  if statement.elseIfs.length > 0 {
    lowerIf(noContext, nestedElseIf(statement, 0))
  } else if statement.else_ != none {
    lowerStatements(noContext, statement.else_!.statements)
  }
  if noContext.failed != "" { context.failed = noContext.failed; return }
  yesFlows := !yesContext.terminated
  noFlows := !noContext.terminated
  if yesFlows || noFlows {
    let joinParams: MinusValue[] = []
    for index of 0..<locals.length {
      name := "%b" + string(id) + "j" + string(index)
      joinParams.push(MinusValue { name, typeName: locals[index].typeName })
    }
    if yesFlows { effect(yesContext, "jump", concatValues([joinName], bindingValues(yesContext, locals))) }
    if noFlows { effect(noContext, "jump", concatValues([joinName], bindingValues(noContext, locals))) }
    appendContext(context, yesContext)
    appendContext(context, noContext)
    context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
    context.blocks.push(context.currentBlock)
    for index of 0..<locals.length {
      context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name })
    }
    context.terminated = false
  } else {
    appendContext(context, yesContext)
    appendContext(context, noContext)
    context.terminated = true
  }
}

function lowerWhile(context: FunctionLowering, statement: WhileStatement): none {
  if statement.label != none { context.failed = "labeled loops are not supported by doof-wasm yet"; return }
  if statement.then_ != none { context.failed = "while-else clauses are not supported by doof-wasm yet"; return }
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  conditionName := "while_cond" + string(id)
  bodyName := "while_body" + string(id)
  exitName := "while_exit" + string(id)
  effect(context, "jump", concatValues([conditionName], bindingValues(context, locals)))
  conditionContext := blockContext(context, locals, id, "c", conditionName)
  condition := lowerExpression(conditionContext, statement.condition)
  if conditionContext.failed != "" { context.failed = conditionContext.failed; return }
  edgeValues := bindingValues(conditionContext, locals)
  let branchArgs: string[] = [condition, bodyName]
  for value of edgeValues { branchArgs.push(value) }
  branchArgs.push("|"); branchArgs.push(exitName)
  for value of edgeValues { branchArgs.push(value) }
  effect(conditionContext, "branch", branchArgs)

  bodyContext := blockContext(conditionContext, locals, id, "w", bodyName)
  lowerStatements(bodyContext, statement.body.statements)
  if bodyContext.failed != "" { context.failed = bodyContext.failed; return }
  if !bodyContext.terminated { effect(bodyContext, "jump", concatValues([conditionName], bindingValues(bodyContext, locals))) }
  exitContext := blockContext(conditionContext, locals, id, "x", exitName)
  exitContext.nextValue = bodyContext.nextValue
  exitContext.nextBlock = bodyContext.nextBlock
  appendContext(context, conditionContext)
  appendContext(context, bodyContext)
  appendContext(context, exitContext)
  for binding of latestLocals(exitContext) { context.bindings.push(binding) }
  context.terminated = exitContext.terminated
}

function lowerCaseStatement(context: FunctionLowering, statement: CaseStatement): none {
  if typeFromValue(statement.subject) != "any" {
    context.failed = "case statements currently require an any-backed union subject"
    return
  }
  if statement.arms.length == 0 {
    context.failed = "case statement needs at least one arm"
    return
  }
  let targets: string[] = []
  let wildcards: bool[] = []
  for armIndex of 0..<statement.arms.length {
    arm := statement.arms[armIndex]
    if arm.patterns.length != 1 {
      context.failed = "case arms currently support one pattern each"
      return
    }
    let target = ""
    let wildcard = false
    case arm.patterns[0] {
      pattern: TypePattern -> {
        if pattern.resolvedType == none { context.failed = "unresolved case type pattern"; return }
        target = resolvedName(pattern.resolvedType!)
        if target == "" || target == "any" { context.failed = "unsupported case type pattern"; return }
      }
      pattern: ValuePattern -> {
        case pattern.value {
          _: NoneLiteral -> { target = "none" }
          _ -> { context.failed = "case value patterns currently support only none"; return }
        }
      }
      _: WildcardPattern -> { wildcard = true }
      _ -> { context.failed = "case range patterns are not supported by doof-wasm"; return }
    }
    if wildcard && armIndex != statement.arms.length - 1 {
      context.failed = "wildcard case pattern must be the final arm"
      return
    }
    targets.push(target)
    wildcards.push(wildcard)
  }

  subject := lowerExpression(context, statement.subject)
  if context.failed != "" { return }
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  let armNames: string[] = []
  let armContexts: FunctionLowering[] = []
  let testContexts: FunctionLowering[] = []
  let armSubjectParams: string[] = []
  let testSubjectParams: string[] = []
  for index of 0..<statement.arms.length {
    armName := "case_arm" + string(id) + "_" + string(index)
    armNames.push(armName)
    armContext := blockContext(context, locals, id, "a" + string(index), armName)
    subjectParam := "%b" + string(id) + "a" + string(index) + string(locals.length)
    armContext.currentBlock.params.push(MinusValue { name: subjectParam, typeName: "any" })
    armSubjectParams.push(subjectParam)
    armContexts.push(armContext)
    if index > 0 {
      testName := "case_test" + string(id) + "_" + string(index)
      testContext := blockContext(context, locals, id, "t" + string(index), testName)
      subjectParam := "%b" + string(id) + "t" + string(index) + string(locals.length)
      testContext.currentBlock.params.push(MinusValue { name: subjectParam, typeName: "any" })
      testSubjectParams.push(subjectParam)
      testContexts.push(testContext)
    }
  }

  let nextValue = context.nextValue
  let nextBlock = context.nextBlock
  for index of 0..<statement.arms.length {
    testContext := if index == 0 then context else testContexts[index - 1]
    testSubject := if index == 0 then subject else testSubjectParams[index - 1]
    testContext.nextValue = nextValue
    testContext.nextBlock = nextBlock
    if wildcards[index] {
      effect(testContext, "jump", concatValues([armNames[index]], concatValues(bindingValues(testContext, locals), [testSubject])))
      nextValue = testContext.nextValue
      nextBlock = testContext.nextBlock
      break
    }
    condition := result(testContext, "is", [testSubject, targets[index]], "bool")
    noTarget := if index + 1 < statement.arms.length then "case_test" + string(id) + "_" + string(index + 1) else if statement.resolvedCompletes! then "case_join" + string(id) else armNames[statement.arms.length - 1]
    let branchArgs: string[] = [condition, armNames[index]]
    for value of bindingValues(testContext, locals) { branchArgs.push(value) }
    branchArgs.push(testSubject)
    branchArgs.push("|"); branchArgs.push(noTarget)
    if index + 1 < statement.arms.length || !statement.resolvedCompletes! {
      for value of bindingValues(testContext, locals) { branchArgs.push(value) }
      branchArgs.push(testSubject)
    } else {
      for value of bindingValues(testContext, locals) { branchArgs.push(value) }
    }
    effect(testContext, "branch", branchArgs)
    nextValue = testContext.nextValue
    nextBlock = testContext.nextBlock
  }

  for index of 0..<armContexts.length {
    armContext := armContexts[index]
    armContext.nextValue = nextValue
    armContext.nextBlock = nextBlock
    pattern := statement.arms[index].patterns[0]
    case pattern {
      type_: TypePattern -> {
        if type_.name != "_" {
          captured := result(armContext, "cast", [armSubjectParams[index], targets[index]], targets[index])
          armContext.bindings.push(SourceBinding { name: type_.name, typeName: targets[index], valueName: captured })
        }
      }
      _ -> { }
    }
    arm := statement.arms[index]
    case arm.body {
      body: Block -> { lowerStatements(armContext, body.statements) }
      expression: Expression -> { _ := lowerExpression(armContext, expression) }
    }
    if armContext.failed != "" { context.failed = armContext.failed; return }
    nextValue = armContext.nextValue
    nextBlock = armContext.nextBlock
  }

  let joinParams: MinusValue[] = []
  if statement.resolvedCompletes! {
    for index of 0..<locals.length {
      joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: locals[index].typeName })
    }
    for armContext of armContexts {
      if !armContext.terminated {
        effect(armContext, "jump", concatValues(["case_join" + string(id)], bindingValues(armContext, locals)))
      }
    }
  }

  for index of 0..<testContexts.length { appendContext(context, testContexts[index]) }
  for armContext of armContexts { appendContext(context, armContext) }
  context.nextValue = nextValue
  context.nextBlock = nextBlock
  if statement.resolvedCompletes! {
    context.currentBlock = MinusBlock { name: "case_join" + string(id), params: joinParams, sourcePath: context.sourcePath }
    context.blocks.push(context.currentBlock)
    for index of 0..<locals.length {
      context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name })
    }
    context.terminated = false
  } else {
    context.terminated = true
  }
}

function lowerPrimitiveArrayLiteral(context: FunctionLowering, literal: ArrayLiteral, expression: Expression): string {
  arrayClass := typeFromValue(expression)
  elementType := if arrayClass == BYTE_ARRAY_CLASS then "byte" else if arrayClass == CHAR_ARRAY_CLASS then "char" else ""
  if elementType == "" {
    context.failed = "only byte[] and char[] literals are supported by doof-wasm"
    return ""
  }
  if literal.elements.length > 1024 {
    context.failed = elementType + "[] literals are limited to 1024 elements"
    return ""
  }
  length := result(context, "const", [string(literal.elements.length)], "int")
  data := result(context, "array-alloc", [length, elementType], "int")
  for index of 0..<literal.elements.length {
    item := lowerExpected(context, literal.elements[index], elementType)
    offset := result(context, "const", [string(index)], "int")
    effect(context, "array-set", [data, offset, item])
  }
  if context.failed != "" { return "" }
  return result(context, "new", [arrayClass, data], arrayClass)
}

function lowerExpression(context: FunctionLowering, expression: Expression): string {
  if context.failed != "" { return "" }
  context.currentLine = expression.span.start.line
  case expression {
    value: IntLiteral -> { return result(context, "const", [string(value.value)], typeFromValue(expression)) }
    value: LongLiteral -> { return result(context, "const", [string(value.value)], "long") }
    value: FloatLiteral -> { return result(context, "const", [value.raw], "float") }
    value: DoubleLiteral -> { return result(context, "const", [value.raw], "double") }
    value: StringLiteral -> {
      if value.interpolations.length > 0 { context.failed = "string interpolation is not supported by doof-wasm"; return "" }
      if value.value.length > 1024 { context.failed = "string literals are limited to 1024 characters"; return "" }
      for index of 0..<value.value.length {
        if int(value.value[index]) > 255 { context.failed = "string literal characters must fit in one UTF-8 byte"; return "" }
      }
      return result(context, "string-const", [value.value], STRING_CLASS)
    }
    value: CharLiteral -> { return result(context, "const", [string(int(value.value))], "char") }
    value: BoolLiteral -> { return result(context, "const", [if value.value then "true" else "false"], "bool") }
    _: NoneLiteral -> { return result(context, "const", ["none"], "none") }
    value: Identifier -> {
      binding := findBinding(context, value.name)
      if binding == none { context.failed = "unsupported global value " + value.name; return "" }
      return binding!.valueName
    }
    _: ThisExpression -> {
      binding := findBinding(context, "this")
      if binding == none { context.failed = "this is only available in a class method"; return "" }
      return binding!.valueName
    }
    value: BinaryExpression -> {
      if !["+", "-", "*", "/", "==", "<", "!=", ">", "<=", ">="].contains(value.operator) {
        context.failed = "operator " + value.operator + " is not supported by doof-wasm"; return ""
      }
      if value.operator == "==" || value.operator == "!=" {
        case value.left {
          _: NoneLiteral -> {
            if typeFromValue(value.right) == "any" {
              boxed := lowerExpression(context, value.right)
              isNone := result(context, "is", [boxed, "none"], "bool")
              if value.operator == "==" { return isNone }
              no := result(context, "const", ["false"], "bool")
              return result(context, "eq", [isNone, no], "bool")
            }
          }
          _ -> { }
        }
        case value.right {
          _: NoneLiteral -> {
            if typeFromValue(value.left) == "any" {
              boxed := lowerExpression(context, value.left)
              isNone := result(context, "is", [boxed, "none"], "bool")
              if value.operator == "==" { return isNone }
              no := result(context, "const", ["false"], "bool")
              return result(context, "eq", [isNone, no], "bool")
            }
          }
          _ -> { }
        }
      }
      let left = lowerExpression(context, value.left)
      let right = lowerExpression(context, value.right)
      if context.failed != "" { return "" }
      let op = value.operator
      if op == "+" { op = "add" }
      if op == "-" { op = "sub" }
      if op == "*" { op = "mul" }
      if op == "/" { op = "div" }
      if op == "==" || op == "!=" { op = "eq" }
      if op == "<" { op = "lt" }
      if op == ">" && typeFromValue(value.left) != STRING_CLASS { op = "lt"; let swap = left; left = right; right = swap }
      if typeFromValue(value.left) == STRING_CLASS && ["==", "!=", "<", ">", "<=", ">="].contains(value.operator) {
        compared := result(context, "call-method", [left, "compare", right], "int")
        zero := result(context, "const", ["0"], "int")
        if value.operator == "==" { return result(context, "eq", [compared, zero], "bool") }
        if value.operator == "!=" {
          equal := result(context, "eq", [compared, zero], "bool")
          no := result(context, "const", ["false"], "bool")
          return result(context, "eq", [equal, no], "bool")
        }
        if value.operator == "<" { return result(context, "lt", [compared, zero], "bool") }
        if value.operator == ">" { return result(context, "lt", [zero, compared], "bool") }
        if value.operator == "<=" {
          greater := result(context, "lt", [zero, compared], "bool")
          no := result(context, "const", ["false"], "bool")
          return result(context, "eq", [greater, no], "bool")
        }
        less := result(context, "lt", [compared, zero], "bool")
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [less, no], "bool")
      }
      if value.operator == "<=" || value.operator == ">=" {
        strict := if value.operator == "<=" then result(context, "lt", [right, left], "bool") else result(context, "lt", [left, right], "bool")
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [strict, no], "bool")
      }
      compared := result(context, op, [left, right], typeFromValue(expression))
      if value.operator == "!=" {
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [compared, no], "bool")
      }
      return compared
    }
    value: AssignmentExpression -> {
      if value.operator != "=" { context.failed = "compound assignment is not supported by doof-wasm"; return "" }
      case value.target {
        target: Identifier -> {
          binding := findBinding(context, target.name)
          if binding == none || target.resolvedBinding == none || !target.resolvedBinding!.mutable {
            context.failed = "assignment target must be a mutable local"; return ""
          }
          assigned := lowerExpected(context, value.value, binding!.typeName)
          context.bindings.push(SourceBinding { name: target.name, typeName: binding!.typeName, valueName: assigned })
          return assigned
        }
        target: MemberExpression -> {
          owner := lowerExpression(context, target.object)
          expected := if target.resolvedMember == none || target.resolvedMember!.type_ == none then "" else resolvedName(target.resolvedMember!.type_!)
          assigned := if expected == "" then lowerExpression(context, value.value) else lowerExpected(context, value.value, expected)
          effect(context, "set", [owner, target.property, assigned])
          return assigned
        }
        target: IndexExpression -> {
          if target.optional { context.failed = "optional array indexing is not supported by doof-wasm"; return "" }
          array := lowerExpression(context, target.object)
          index := lowerExpression(context, target.index)
          assigned := lowerExpected(context, value.value, typeFromValue(expression))
          return result(context, "call-method", [array, "set", index, assigned], typeFromValue(expression))
        }
        _ -> { context.failed = "assignment target is not supported by doof-wasm"; return "" }
      }
    }
    value: UnaryExpression -> {
      operand := lowerExpression(context, value.operand)
      if value.operator == "-" {
        zero := result(context, "const", ["0"], typeFromValue(value.operand))
        return result(context, "sub", [zero, operand], typeFromValue(expression))
      }
      if value.operator == "!" {
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [operand, no], "bool")
      }
      context.failed = "unary operator " + value.operator + " is not supported by doof-wasm"
      return ""
    }
    value: MemberExpression -> {
      if value.optional || value.force { context.failed = "optional member access is not supported by doof-wasm"; return "" }
      if value.property == "length" && (typeFromValue(value.object) == BYTE_ARRAY_CLASS || typeFromValue(value.object) == CHAR_ARRAY_CLASS) {
        array := lowerExpression(context, value.object)
        return result(context, "call-method", [array, "length"], "int")
      }
      if value.property == "length" && typeFromValue(value.object) == STRING_CLASS {
        stringValue := lowerExpression(context, value.object)
        return result(context, "call-method", [stringValue, "length"], "int")
      }
      owner := lowerExpression(context, value.object)
      return result(context, "get", [owner, value.property], typeFromValue(expression))
    }
    value: IndexExpression -> {
      if value.optional { context.failed = "optional array indexing is not supported by doof-wasm"; return "" }
      array := lowerExpression(context, value.object)
      index := lowerExpression(context, value.index)
      return result(context, "call-method", [array, "get", index], typeFromValue(expression))
    }
    value: ArrayLiteral -> { return lowerPrimitiveArrayLiteral(context, value, expression) }
    value: CallExpression -> { return lowerCall(context, value, expression) }
    value: ConstructExpression -> {
      if value.spread != none { context.failed = "construction spreads are not supported by doof-wasm"; return "" }
      if value.resolvedClass == none { context.failed = "unresolved class construction"; return "" }
      let args: string[] = [qualifiedName(value.resolvedClass!.resolvedSymbol!.module, value.resolvedClass!.name)]
      for field of value.resolvedClass!.fields {
        if field.names.length != 1 { context.failed = "multiple-name fields are not supported by doof-wasm"; return "" }
        let found = false
        for property of value.args {
          if property.name == field.names[0] {
            if property.value == none { context.failed = "missing construction field value"; return "" }
            args.push(lowerExpected(context, property.value!, annotationName(field.resolvedType)))
            found = true
          }
        }
        if !found {
          if field.defaultValue == none { context.failed = "required class field " + field.names[0] + " is missing"; return "" }
          args.push(lowerExpected(context, field.defaultValue!, annotationName(field.resolvedType)))
          if context.failed != "" { return "" }
        }
      }
      return result(context, "new", args, typeFromValue(expression))
    }
    value: AsExpression -> {
      source := lowerExpression(context, value.expression)
      target := if value.targetType.resolvedType == none then "" else resolvedName(value.targetType.resolvedType!)
      sourceType := typeFromValue(value.expression)
      if sourceType == "any" { return result(context, "cast", [source, target], target) }
      if ["byte", "short", "int", "long", "float", "double"].contains(target) { return result(context, "convert", [source], target) }
      return result(context, "as", [source], target)
    }
    _ -> { context.failed = "expression is not supported by doof-wasm"; return "" }
  }
}

function lowerCall(context: FunctionLowering, call: CallExpression, expression: Expression): string {
  case call.callee {
    callee: Identifier -> {
      if callee.name == "panic" && call.resolvedFunction == none {
        if call.args.length != 1 { context.failed = "panic requires one message argument"; return "" }
        effect(context, "panic", [])
        context.terminated = true
        return ""
      }
    }
    _ -> { }
  }
  if call.resolvedClass != none {
    class_ := call.resolvedClass!
    if call.resolvedConstructor != none {
      context.failed = "class constructor factories are not supported by doof-wasm"
      return ""
    }
    let supplied: string[] = []
    for field of class_.fields { supplied.push("") }
    let positionalIndex = 0
    let hasNamed = false
    for argument of call.args { if argument.name != none { hasNamed = true } }
    for argument of call.args {
      let fieldIndex_ = positionalIndex
      if hasNamed {
        if argument.name == none { context.failed = "named construction cannot mix named and positional arguments"; return "" }
        fieldIndex_ = -1
        for index of 0..<class_.fields.length {
          if class_.fields[index].names.length == 1 && class_.fields[index].names[0] == argument.name! { fieldIndex_ = index }
        }
        if fieldIndex_ < 0 { context.failed = "unknown construction field " + argument.name!; return "" }
      } else { positionalIndex = positionalIndex + 1 }
      if fieldIndex_ >= class_.fields.length { context.failed = "too many construction arguments"; return "" }
      field := class_.fields[fieldIndex_]
      if field.names.length != 1 { context.failed = "multiple-name fields are not supported by doof-wasm"; return "" }
      supplied[fieldIndex_] = lowerExpected(context, argument.value, annotationName(field.resolvedType))
      if context.failed != "" { return "" }
    }
    let args: string[] = [qualifiedName(class_.resolvedSymbol!.module, class_.name)]
    for index of 0..<class_.fields.length {
      field := class_.fields[index]
      if field.names.length != 1 { context.failed = "multiple-name fields are not supported by doof-wasm"; return "" }
      if supplied[index] != "" { args.push(supplied[index]); continue }
      if field.defaultValue == none { context.failed = "missing required construction field " + field.names[0]; return "" }
      args.push(lowerExpected(context, field.defaultValue!, annotationName(field.resolvedType)))
      if context.failed != "" { return "" }
    }
    return result(context, "new", args, typeFromValue(expression))
  }
  let receiver = ""
  case call.callee { member: MemberExpression -> { receiver = lowerExpression(context, member.object) } _ -> { } }
  let args: string[] = []
  let hasNamed = false
  for argument of call.args { if argument.name != none { hasNamed = true } }
  if call.resolvedFunction != none {
    parameters := call.resolvedFunction!.params
    let supplied: string[] = []
    for _ of parameters { supplied.push("") }
    let positionalIndex = 0
    // Evaluate provided expressions in source order, then arrange their SSA
    // values in declaration order for the fixed-arity doof-- call.
    for argument of call.args {
      let parameterIndex = positionalIndex
      if hasNamed {
        if argument.name == none { context.failed = "named calls cannot mix named and positional arguments"; return "" }
        parameterIndex = -1
        for index of 0..<parameters.length {
          if parameters[index].name == argument.name! { parameterIndex = index }
        }
        if parameterIndex < 0 { context.failed = "unknown named argument " + argument.name!; return "" }
      } else { positionalIndex = positionalIndex + 1 }
      if parameterIndex >= parameters.length { context.failed = "too many call arguments"; return "" }
      expected := annotationName(parameters[parameterIndex].resolvedType)
      supplied[parameterIndex] = lowerExpected(context, argument.value, expected)
      if context.failed != "" { return "" }
    }
    for index of 0..<parameters.length {
      if supplied[index] != "" { args.push(supplied[index]); continue }
      parameter := parameters[index]
      if parameter.defaultValue == none { context.failed = "missing required argument " + parameter.name; return "" }
      args.push(lowerExpected(context, parameter.defaultValue!, annotationName(parameter.resolvedType)))
      if context.failed != "" { return "" }
    }
  } else {
    if hasNamed { context.failed = "named calls require a declaration-backed function"; return "" }
    for index of 0..<call.args.length {
      expected := callParameterType(call, index)
      args.push(if expected == "" then lowerExpression(context, call.args[index].value) else lowerExpected(context, call.args[index].value, expected))
    }
  }
  if context.failed != "" { return "" }
  case call.callee {
    callee: Identifier -> {
      if ["byte", "short", "int", "long", "float", "double"].contains(callee.name) {
        if args.length != 1 { context.failed = "numeric conversion requires one argument"; return "" }
        if typeFromValue(call.args[0].value) == callee.name { return args[0] }
        return result(context, "convert", [args[0]], callee.name)
      }
      targetModule := if call.resolvedFunctionModule == "" then context.sourcePath else call.resolvedFunctionModule
      target := if call.resolvedFunction == none then callee.name else qualifiedName(targetModule, call.resolvedFunction!.name)
      return result(context, "call", concatValues([target], args), typeFromValue(expression))
    }
    callee: MemberExpression -> {
      return result(context, "call-method", concatValues([receiver, callee.property], args), typeFromValue(expression))
    }
    _ -> { context.failed = "call target is not supported by doof-wasm"; return "" }
  }
}

function lowerExpected(context: FunctionLowering, expression: Expression, expected: string): string {
  value := lowerExpression(context, expression)
  if context.terminated || context.failed != "" { return "" }
  actual := typeFromValue(expression)
  if actual == expected { return value }
  if expected == "any" && actual != "any" {
    if context.interfaceNames.contains(actual) {
      context.failed = "interface values must be converted to a concrete class before boxing"
      return ""
    }
    return result(context, "box", [value], "any")
  }
  if context.interfaceNames.contains(expected) { return result(context, "as", [value], expected) }
  if ["byte", "short", "int", "long", "float", "double"].contains(expected) &&
      ["byte", "short", "int", "long", "float", "double"].contains(actual) {
    return result(context, "convert", [value], expected)
  }
  return value
}

function callParameterType(call: CallExpression, index: int): string {
  if call.resolvedFunction != none && index < call.resolvedFunction!.params.length {
    return annotationName(call.resolvedFunction!.params[index].resolvedType)
  }
  case call.callee {
    member: MemberExpression -> {
      if member.resolvedMember != none && member.resolvedMember!.type_ != none {
        case member.resolvedMember!.type_! {
          function_: FunctionType -> { if index < function_.params.length { return resolvedName(function_.params[index].type_) } }
          _ -> { }
        }
      }
    }
    _ -> { }
  }
  return ""
}

function lowerNullableBinding(context: FunctionLowering, binding: ImmutableBinding): none {
  value := lowerExpression(context, binding.value)
  if context.failed != "" { return }
  typeName := declarationType(binding.resolvedType, typeFromValue(binding.value))
  if typeName == "any" || typeName == "" {
    context.failed = "nullable else bindings need one supported non-none type"
    return
  }
  condition := result(context, "is", [value, "none"], "bool")
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  failureName := "unwrap_none" + string(id)
  successName := "unwrap_value" + string(id)
  values := bindingValues(context, locals)
  let branchArgs: string[] = [condition, failureName]
  for item of values { branchArgs.push(item) }
  branchArgs.push(value)
  branchArgs.push("|"); branchArgs.push(successName)
  for item of values { branchArgs.push(item) }
  branchArgs.push(value)
  effect(context, "branch", branchArgs)

  failureContext := blockContext(context, locals, id, "f", failureName)
  failureValueName := "%b" + string(id) + "f" + string(locals.length)
  failureContext.currentBlock.params.push(MinusValue { name: failureValueName, typeName: "any" })
  lowerStatements(failureContext, binding.else_!.statements)
  if failureContext.failed != "" { context.failed = failureContext.failed; return }
  if !failureContext.terminated { context.failed = "nullable else handler must terminate"; return }

  successContext := blockContext(context, locals, id, "v", successName)
  successValueName := "%b" + string(id) + "v" + string(locals.length)
  successContext.currentBlock.params.push(MinusValue { name: successValueName, typeName: "any" })
  successContext.nextValue = failureContext.nextValue
  successContext.nextBlock = failureContext.nextBlock
  unwrapped := result(successContext, "cast", [successValueName, typeName], typeName)
  successContext.bindings.push(SourceBinding { name: binding.name, typeName, valueName: unwrapped })
  appendContext(context, failureContext)
  appendContext(context, successContext)
  context.currentBlock = successContext.currentBlock
  context.bindings.push(SourceBinding { name: binding.name, typeName, valueName: unwrapped })
  context.terminated = false
}

function lowerStatements(context: FunctionLowering, statements: Statement[]): none {
  for statement of statements {
    context.currentLine = statement.span.start.line
    if context.terminated { context.failed = "unreachable statements after a terminating branch are not supported"; return }
    if context.failed != "" { return }
    case statement {
      value: ImmutableBinding -> {
        if value.else_ != none {
          if value.name == "_" { context.failed = "discarded fallible bindings are not supported by doof-wasm"; return }
          lowerNullableBinding(context, value)
          if context.failed != "" { return }
          continue
        }
        if value.name == "_" { context.failed = "discarded bindings are not supported by doof-wasm"; return }
        typeName := declarationType(value.resolvedType, typeFromValue(value.value))
        emitted := lowerExpected(context, value.value, typeName)
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted }) }
      }
      value: ReadonlyDeclaration -> {
        typeName := declarationType(value.resolvedType, typeFromValue(value.value))
        emitted := lowerExpected(context, value.value, typeName)
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted }) }
      }
      value: LetDeclaration -> {
        typeName := declarationType(value.resolvedType, typeFromValue(value.value))
        emitted := lowerExpected(context, value.value, typeName)
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted }) }
      }
      value: ReturnStatement -> {
        if value.value == none { effect(context, "return", []) }
        else {
          returned := lowerExpected(context, value.value!, annotationName(value.resolvedExpectedType))
          if !context.terminated { effect(context, "return", [returned]); context.terminated = true }
        }
      }
      value: ExpressionStatement -> { _ := lowerExpression(context, value.expression) }
      _: Block -> { context.failed = "nested lexical blocks are not supported by doof-wasm"; return }
      value: IfStatement -> { lowerIf(context, value) }
      value: CaseStatement -> { lowerCaseStatement(context, value) }
      value: WhileStatement -> { lowerWhile(context, value) }
      _ -> { context.failed = "statement is not supported by doof-wasm"; return }
    }
  }
}

function functionResultType(fn: FunctionDeclaration): ResolvedType | none {
  if fn.resolvedType == none { return none }
  case fn.resolvedType! {
    function_: FunctionType -> { return function_.returnType }
    _ -> { return none }
  }
}

function lowerFunction(fn: FunctionDeclaration, modulePath: string, className: string = "", interfaceNames: string[] = []): Result<MinusFunction, string> {
  let params: MinusValue[] = []
  let functionName = qualifiedName(modulePath, fn.name)
  let context = FunctionLowering { sourcePath: modulePath, currentBlock: MinusBlock { name: "entry", line: fn.span.start.line, sourcePath: modulePath } }
  for interfaceName of interfaceNames { context.interfaceNames.push(interfaceName) }
  if className != "" {
    functionName = className + "." + fn.name
    params.push(MinusValue { name: "%self", typeName: className })
    context.bindings.push(SourceBinding { name: "this", typeName: className, valueName: "%self", parameter: true })
  }
  for parameter of fn.params {
    typeName := annotationName(parameter.resolvedType)
    if typeName == "" { return Failure(atLine(fn.span.start.line, "unsupported parameter type on " + fn.name)) }
    valueName := "%arg" + string(params.length)
    params.push(MinusValue { name: valueName, typeName })
    context.bindings.push(SourceBinding { name: parameter.name, typeName, valueName, parameter: true })
  }
  resultType := annotationName(functionResultType(fn))
  if resultType == "" { return Failure(atLine(fn.span.start.line, "unsupported return type on " + fn.name)) }
  context.blocks.push(context.currentBlock)
  case fn.body {
    body: Block -> { lowerStatements(context, body.statements) }
    body: Expression -> {
      returned := lowerExpected(context, body, resultType)
      if !context.terminated { effect(context, "return", [returned]); context.terminated = true }
    }
  }
  if context.failed != "" { return Failure(atLine(context.currentLine, "in " + functionName + ": " + context.failed)) }
  if resultType == "none" && !context.terminated { effect(context, "return", []) }
  let function_ = MinusFunction { name: functionName, params, result: resultType, exported: fn.exported && className == "", blocks: context.blocks, line: fn.span.start.line, sourcePath: modulePath }
  return Success(function_)
}

function lowerHostImport(fn: FunctionDeclaration, modulePath: string): Result<MinusImport, string> {
  if fn.typeParams.length > 0 { return Failure(atLine(fn.span.start.line, "generic host imports are not supported by doof-wasm")) }
  let params: MinusValue[] = []
  for parameter of fn.params {
    typeName := annotationName(parameter.resolvedType)
    if typeName == "" { return Failure(atLine(fn.span.start.line, "unsupported host import parameter type on " + fn.name)) }
    params.push(MinusValue { name: "%" + parameter.name, typeName })
  }
  resultType := annotationName(functionResultType(fn))
  if resultType == "" { return Failure(atLine(fn.span.start.line, "unsupported host import result type on " + fn.name)) }
  return Success(MinusImport {
    name: qualifiedName(modulePath, fn.name),
    importModule: if fn.nativeHeader == "" then "doof" else fn.nativeHeader,
    importName: if fn.nativeCppName == "" then fn.name else fn.nativeCppName,
    params, result: resultType, line: fn.span.start.line, sourcePath: modulePath,
  })
}

function lowerTypes(program: Program, module_: MinusModule, modulePath: string): Result<none, string> {
  for statement of program.statements {
    case statement {
      class_: ClassDeclaration -> {
        if class_.struct_ { return Failure(atLine(class_.span.start.line, "structs are not supported by doof-wasm")) }
        if class_.typeParams.length > 0 { return Failure(atLine(class_.span.start.line, "generic classes are not supported by doof-wasm")) }
        let classOut = MinusClass { name: qualifiedName(modulePath, class_.name), line: class_.span.start.line, sourcePath: modulePath }
        for implemented of class_.implements_ {
          if implemented.typeArgs.length > 0 { return Failure(atLine(implemented.span.start.line, "generic interface implementations are not supported by doof-wasm")) }
          classOut.interfaces.push(if implemented.resolvedSymbol == none then implemented.name else qualifiedName(implemented.resolvedSymbol!.module, implemented.name))
        }
        for field of class_.fields {
          if field.static_ || field.weak_ || field.names.length != 1 {
            return Failure(atLine(field.span.start.line, "static, weak, and multiple fields are not supported by doof-wasm"))
          }
          typeName := annotationName(field.resolvedType)
          if typeName == "" { return Failure(atLine(field.span.start.line, "unsupported field type in " + class_.name)) }
          classOut.fields.push(MinusField { name: field.names[0], typeName, mutable: field.let_, line: field.span.start.line, sourcePath: modulePath })
        }
        module_.classes.push(classOut)
      }
      interface_: InterfaceDeclaration -> {
        if interface_.typeParams.length > 0 { return Failure(atLine(interface_.span.start.line, "generic interfaces are not supported by doof-wasm")) }
        let interfaceOut = MinusInterface { name: qualifiedName(modulePath, interface_.name), line: interface_.span.start.line, sourcePath: modulePath }
        for field of interface_.fields {
          interfaceOut.fields.push(MinusField {
            name: field.name, typeName: annotationName(field.resolvedType), mutable: field.let_, line: field.span.start.line, sourcePath: modulePath,
          })
        }
        for method of interface_.methods {
          let paramTypes: string[] = []
          for parameter of method.params { paramTypes.push(annotationName(parameter.resolvedType)) }
          interfaceOut.methods.push(MinusMethod {
            name: method.name, params: paramTypes, result: annotationName(functionResultType(method)), line: method.span.start.line, sourcePath: modulePath,
          })
        }
        module_.interfaces.push(interfaceOut)
      }
      _ -> { }
    }
  }
  return Success(none)
}

function moduleUsesArrayClass(module_: MinusModule, arrayClass: string): bool {
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

function injectPrimitiveArrayImplementation(module_: MinusModule, arrayClass: string, elementType: string, destructorName: string): none {
  let class_ = MinusClass { name: arrayClass, finalizer: destructorName }
  class_.fields.push(MinusField { name: "data", typeName: "int" })
  module_.classes.push(class_)
  module_.functions.push(MinusFunction {
    name: destructorName,
    params: [MinusValue { name: "%self", typeName: arrayClass }],
    result: "none",
    blocks: [MinusBlock { name: "entry", instructions: [
      MinusInstruction { op: "get", result: MinusValue { name: "%data", typeName: "int" }, args: ["%self", "data"] },
      MinusInstruction { op: "array-free", args: ["%data"] },
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

function injectStringImplementation(module_: MinusModule): none {
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

export function lowerDoofProgram(program: Program, modulePath: string = "/main.do", entryPath: string = "/main.do"): Result<MinusModule, string> {
  let module_ = MinusModule {}
  try lowerTypes(program, module_, modulePath)
  let interfaceNames: string[] = []
  for interface_ of module_.interfaces { interfaceNames.push(interface_.name) }
  for statement of program.statements {
    case statement {
      fn: FunctionDeclaration -> {
        if fn.native_ {
          if fn.exported { return Failure(atLine(fn.span.start.line, "host imports cannot be exported")) }
          try imported := lowerHostImport(fn, modulePath)
          module_.imports.push(imported)
          continue
        }
        if fn.typeParams.length > 0 { return Failure(atLine(fn.span.start.line, "generic functions are not supported by doof-wasm")) }
        if fn.bodyless || fn.isolated_ { return Failure(atLine(fn.span.start.line, "bodyless and isolated functions are not supported by doof-wasm")) }
        try lowered := lowerFunction(fn, modulePath, "", interfaceNames)
        lowered.exported = fn.exported && modulePath == entryPath
        if lowered.exported { lowered.exportName = fn.name }
        module_.functions.push(lowered)
      }
      class_: ClassDeclaration -> {
        for method of class_.methods {
          if method.static_ { return Failure(atLine(method.span.start.line, "static methods are not supported by doof-wasm")) }
          if method.bodyless || method.isolated_ || method.typeParams.length > 0 {
            return Failure(atLine(method.span.start.line, "bodyless, isolated, or generic methods are not supported by doof-wasm"))
          }
          try lowered := lowerFunction(method, modulePath, qualifiedName(modulePath, class_.name), interfaceNames)
          module_.functions.push(lowered)
        }
      }
      _: InterfaceDeclaration -> { }
      _: ImportDeclaration -> { }
      _: ExportList -> { }
      _ -> { return Failure(atLine(statement.span.start.line, "top-level declarations must be functions, classes, or interfaces")) }
    }
  }
  if moduleUsesArrayClass(module_, STRING_CLASS) { injectStringImplementation(module_) }
  if moduleUsesArrayClass(module_, BYTE_ARRAY_CLASS) {
    injectPrimitiveArrayImplementation(module_, BYTE_ARRAY_CLASS, "byte", BYTE_ARRAY_DESTRUCTOR)
  }
  if moduleUsesArrayClass(module_, CHAR_ARRAY_CLASS) {
    injectPrimitiveArrayImplementation(module_, CHAR_ARRAY_CLASS, "char", CHAR_ARRAY_DESTRUCTOR)
  }
  return Success(module_)
}
