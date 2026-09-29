import { createMinusFunction } from "./minus-build"
// Lower checked function bodies, expressions, control flow, and lambdas.
import {
  PrimitiveType, ClassType, EnumType, ArrayResolvedType, SerialValueResolvedType, NoneType,
  UnionResolvedType, ResultResolvedType, SuccessResolvedType, FailureResolvedType, WeakResolvedType, ResolvedType, FunctionType, PromiseType, ActorType,
} from "doof/src/semantic"
import {
  Statement, FunctionDeclaration, ClassDeclaration, EnumDeclaration, Expression, Block, ReturnStatement, ImmutableBinding, LetDeclaration,
  ReadonlyDeclaration, ExpressionStatement, IntLiteral, LongLiteral, FloatLiteral, DoubleLiteral, StringLiteral,
  CharLiteral, BoolLiteral, NoneLiteral, Identifier, BinaryExpression, UnaryExpression, AssignmentExpression,
  ObjectProperty, ObjectLiteral, CallExpression, MemberExpression, ConstructExpression, ArrayLiteral, IndexExpression, AsExpression, ThisExpression,
  DotShorthand, IfStatement, IfBranch, IfExpression, CaseStatement, TypePattern, ValuePattern, WildcardPattern, WhileStatement,
  ForStatement, ForOfStatement, LambdaExpression, BreakStatement, ContinueStatement, TryStatement, ConstDeclaration, AsyncExpression, YieldStatement,
} from "doof/src/ast"
import { collectNestedExpressions, collectBlockExpressions } from "doof/src/ast-walk"
import { WasmLoweringOptions } from "./doof-lowering-options"
import {
  MinusModule, MinusClass, MinusField, MinusValue, MinusFunction, MinusGlobal, MinusBlock, MinusInstruction, MinusImport,
} from "./minus-ir"
import { BYTE_ARRAY_CLASS, CHAR_ARRAY_CLASS, STRING_CLASS, STRING_BOOL_MAP_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS, arrayClassName, arrayElementFromClassName, isArrayClass } from "./doof-lowering-constants"
import {
  SourceBinding, SourceConstant, LoopTarget, FunctionLowering, SourceNameCache, qualifiedName, staticFunctionName, atLine, enumVariantValue, resolvedName, closureInterfaceName,
  annotationName, typeFromValue, declarationType, findBinding, latestLocals, bindingValues, result, effect,
  blockContext, concatValues, appendContext, nestedElseIf, functionResultType, registerClosureType,
} from "./doof-lowering-support"

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
      storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
      joinParams.push(MinusValue { name, typeName: storageType })
    }
    if yesFlows { effect(yesContext, "jump", concatValues([joinName], bindingValues(yesContext, locals))) }
    if noFlows { effect(noContext, "jump", concatValues([joinName], bindingValues(noContext, locals))) }
    appendContext(context, yesContext)
    appendContext(context, noContext)
    context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
    context.blocks.push(context.currentBlock)
    for index of 0..<locals.length {
      context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
    }
    context.terminated = false
  } else {
    appendContext(context, yesContext)
    appendContext(context, noContext)
    context.terminated = true
  }
}

function alwaysTrue(value: Expression | none): bool {
  if value == none { return true }
  case value! { literal: BoolLiteral -> { return literal.value } _ -> { return false } }
}

function jumpsTo(context: FunctionLowering, target: string): bool {
  for block of context.blocks {
    for instruction of block.instructions {
      if instruction.op == "jump" && instruction.args[0] == target { return true }
    }
  }
  return false
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
  if alwaysTrue(statement.condition) { effect(conditionContext, "jump", concatValues([bodyName], edgeValues)) }
  else { effect(conditionContext, "branch", branchArgs) }

  bodyContext := blockContext(conditionContext, locals, id, "w", bodyName)
  bodyContext.loopTarget = LoopTarget { breakName: exitName, continueName: conditionName, locals }
  lowerStatements(bodyContext, statement.body.statements)
  if bodyContext.failed != "" { context.failed = bodyContext.failed; return }
  if !bodyContext.terminated { effect(bodyContext, "jump", concatValues([conditionName], bindingValues(bodyContext, locals))) }
  exitContext := blockContext(conditionContext, locals, id, "x", exitName)
  exitContext.nextValue = bodyContext.nextValue
  exitContext.nextBlock = bodyContext.nextBlock
  appendContext(context, conditionContext)
  appendContext(context, bodyContext)
  if alwaysTrue(statement.condition) && !jumpsTo(bodyContext, exitName) {
    context.terminated = true
  } else {
    appendContext(context, exitContext)
    for binding of latestLocals(exitContext) { context.bindings.push(binding) }
    context.terminated = exitContext.terminated
  }
}

// Source loops carry locals through the header, body, update, and exit blocks.
function lowerFor(context: FunctionLowering, statement: ForStatement): none {
  if statement.label != none { context.failed = "labeled loops are not supported by doof-wasm yet"; return }
  if statement.then_ != none { context.failed = "for-else clauses are not supported by doof-wasm yet"; return }
  if statement.init != none { lowerStatements(context, [statement.init!]) }
  if context.failed != "" || context.terminated { return }
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  conditionName := "for_cond" + string(id)
  bodyName := "for_body" + string(id)
  exitName := "for_exit" + string(id)
  effect(context, "jump", concatValues([conditionName], bindingValues(context, locals)))
  conditionContext := blockContext(context, locals, id, "c", conditionName)
  condition := if statement.condition == none then result(conditionContext, "const", ["true"], "bool") else lowerExpression(conditionContext, statement.condition!)
  if conditionContext.failed != "" { context.failed = conditionContext.failed; return }
  edgeValues := bindingValues(conditionContext, locals)
  let branchArgs: string[] = [condition, bodyName]
  for value of edgeValues { branchArgs.push(value) }
  branchArgs.push("|"); branchArgs.push(exitName)
  for value of edgeValues { branchArgs.push(value) }
  if alwaysTrue(statement.condition) { effect(conditionContext, "jump", concatValues([bodyName], edgeValues)) }
  else { effect(conditionContext, "branch", branchArgs) }

  bodyContext := blockContext(conditionContext, locals, id, "f", bodyName)
  updateName := "for_update" + string(id)
  bodyContext.loopTarget = LoopTarget { breakName: exitName, continueName: updateName, locals }
  lowerStatements(bodyContext, statement.body.statements)
  if bodyContext.failed != "" { context.failed = bodyContext.failed; return }
  if !bodyContext.terminated { effect(bodyContext, "jump", concatValues([updateName], bindingValues(bodyContext, locals))) }
  updateContext := blockContext(bodyContext, locals, id, "u", updateName)
  updateContext.loopTarget = context.loopTarget
  for update of statement.update { _ := lowerExpression(updateContext, update); if updateContext.failed != "" { context.failed = updateContext.failed; return } }
  effect(updateContext, "jump", concatValues([conditionName], bindingValues(updateContext, locals)))
  exitContext := blockContext(conditionContext, locals, id, "x", exitName)
  exitContext.nextValue = updateContext.nextValue
  exitContext.nextBlock = updateContext.nextBlock
  appendContext(context, conditionContext)
  appendContext(context, bodyContext)
  appendContext(context, updateContext)
  if alwaysTrue(statement.condition) && !jumpsTo(bodyContext, exitName) {
    context.terminated = true
  } else {
    appendContext(context, exitContext)
    for binding of latestLocals(exitContext) { context.bindings.push(binding) }
    context.terminated = exitContext.terminated
  }
}

function lowerForOf(context: FunctionLowering, statement: ForOfStatement): none {
  if statement.label != none { context.failed = "labeled loops are not supported by doof-wasm yet"; return }
  if statement.then_ != none { context.failed = "for-of-else clauses are not supported by doof-wasm yet"; return }
  if statement.bindings.length > 1 { context.failed = "for-of destructuring is not supported by doof-wasm yet"; return }
  let isRange = false
  case statement.iterable {
    range: BinaryExpression -> { isRange = range.operator == "..<" || range.operator == ".." }
    _ -> { }
  }
  let elementType = ""
  if isRange { elementType = "int" }
  else if statement.iterable.resolvedType != none {
    case statement.iterable.resolvedType! {
      array: ArrayResolvedType -> { elementType = resolvedName(array.elementType, context.names) }
      _ -> { }
    }
  }
  if elementType == "" || statement.iterable.resolvedType == none {
    context.failed = "for-of currently supports arrays and integer ranges in doof-wasm"
    return
  }

  // Keep the iterable and cursor as loop-carried values so both are evaluated once.
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  let iterableName = "%doof_for_iterable_" + string(id)
  let cursorName = "%doof_for_cursor_" + string(id)
  let iterableValue = ""
  let endValue = ""
  let startValue = ""
  if isRange {
    case statement.iterable {
      range: BinaryExpression -> {
        startValue = lowerExpression(context, range.left)
        endValue = lowerExpression(context, range.right)
      }
      _ -> { }
    }
  } else {
    iterableValue = lowerExpression(context, statement.iterable)
  }
  if context.failed != "" { return }
  let originalBindings: SourceBinding[] = []
  for binding of context.bindings { originalBindings.push(binding) }
  let carried = latestLocals(context)
  if isRange { context.bindings.push(SourceBinding { name: iterableName, typeName: "int", valueName: endValue }) }
  else { context.bindings.push(SourceBinding { name: iterableName, typeName: typeFromValue(statement.iterable, context.names), valueName: iterableValue }) }
  zero := if isRange then startValue else result(context, "const", ["0"], "int")
  context.bindings.push(SourceBinding { name: cursorName, typeName: "int", valueName: zero, mutable: true })
  for binding of latestLocals(context) { if binding.name == iterableName || binding.name == cursorName { carried.push(binding) } }

  conditionName := "for_of_cond" + string(id)
  bodyName := "for_of_body" + string(id)
  exitName := "for_of_exit" + string(id)
  effect(context, "jump", concatValues([conditionName], bindingValues(context, carried)))
  conditionContext := blockContext(context, carried, id, "c", conditionName)
  cursor := findBinding(conditionContext, cursorName)!
  let limit = if isRange then findBinding(conditionContext, iterableName)!.valueName else endValue
  if !isRange {
    array := findBinding(conditionContext, iterableName)!.valueName
    limit = result(conditionContext, "call-method", [array, "length"], "int")
  }
  let condition = ""
  if isRange {
    case statement.iterable {
      range: BinaryExpression -> {
        if range.operator == ".." {
          above := result(conditionContext, "lt", [limit, cursor.valueName], "bool")
          no := result(conditionContext, "const", ["false"], "bool")
          condition = result(conditionContext, "eq", [above, no], "bool")
        } else { condition = result(conditionContext, "lt", [cursor.valueName, limit], "bool") }
      }
      _ -> { }
    }
  } else { condition = result(conditionContext, "lt", [cursor.valueName, limit], "bool") }
  edgeValues := bindingValues(conditionContext, carried)
  let branchArgs: string[] = [condition, bodyName]
  for value of edgeValues { branchArgs.push(value) }
  branchArgs.push("|"); branchArgs.push(exitName)
  for value of edgeValues { branchArgs.push(value) }
  effect(conditionContext, "branch", branchArgs)

  bodyContext := blockContext(conditionContext, carried, id, "b", bodyName)
  bodyCursor := findBinding(bodyContext, cursorName)!
  bodyIterable := findBinding(bodyContext, iterableName)!
  item := if isRange then bodyCursor.valueName else result(bodyContext, "call-method", [bodyIterable.valueName, "get", bodyCursor.valueName], elementType)
  if statement.bindings.length == 1 && statement.bindings[0] != "_" {
    bodyContext.bindings.push(SourceBinding { name: statement.bindings[0], typeName: elementType, valueName: item })
  }
  updateName := "for_of_update" + string(id)
  bodyContext.loopTarget = LoopTarget { breakName: exitName, continueName: updateName, locals: carried }
  lowerStatements(bodyContext, statement.body.statements)
  if bodyContext.failed != "" { context.failed = bodyContext.failed; return }
  if !bodyContext.terminated { effect(bodyContext, "jump", concatValues([updateName], bindingValues(bodyContext, carried))) }
  updateContext := blockContext(bodyContext, carried, id, "u", updateName)
  updateContext.loopTarget = context.loopTarget
  currentCursor := findBinding(updateContext, cursorName)!
  one := result(updateContext, "const", ["1"], "int")
  nextCursor := result(updateContext, "add", [currentCursor.valueName, one], "int")
  updateContext.bindings.push(SourceBinding { name: cursorName, typeName: "int", valueName: nextCursor, mutable: true })
  effect(updateContext, "jump", concatValues([conditionName], bindingValues(updateContext, carried)))
  exitContext := blockContext(conditionContext, carried, id, "x", exitName)
  exitContext.nextValue = updateContext.nextValue
  exitContext.nextBlock = updateContext.nextBlock
  appendContext(context, conditionContext)
  appendContext(context, bodyContext)
  appendContext(context, updateContext)
  appendContext(context, exitContext)
  while context.bindings.length > originalBindings.length { ignored := try! context.bindings.pop() }
  for binding of latestLocals(exitContext) { if binding.name != iterableName && binding.name != cursorName { context.bindings.push(binding) } }
  context.terminated = exitContext.terminated
}

function caseTypeTargets(type_: ResolvedType, targets: string[]): bool {
  case type_ {
    union_: UnionResolvedType -> {
      for member of union_.types { if !caseTypeTargets(member, targets) { return false } }
      return true
    }
    _ -> {
      target := resolvedName(type_)
      if target == "" || target == "any" { return false }
      if !targets.contains(target) { targets.push(target) }
      return true
    }
  }
}

// A union pattern matches any of its concrete tags. Keep the captured value
// boxed so subsequent narrowing still sees its original runtime tag.
function lowerCaseTypeCondition(context: FunctionLowering, subject: string, targets: string[]): string {
  if targets.length == 1 { return result(context, "is", [subject, targets[0]], "bool") }
  id := context.nextBlock
  context.nextBlock += 1
  joinName := "case_match" + string(id)
  matched := "%case_match" + string(id)
  for index of 0..<targets.length {
    condition := result(context, "is", [subject, targets[index]], "bool")
    if index + 1 == targets.length {
      effect(context, "jump", [joinName, condition])
    } else {
      nextName := "case_match_test" + string(id) + "_" + string(index + 1)
      effect(context, "branch", [condition, joinName, condition, "|", nextName])
      context.currentBlock = MinusBlock { name: nextName, sourcePath: context.sourcePath }
      context.blocks.push(context.currentBlock)
    }
  }
  context.currentBlock = MinusBlock { name: joinName, params: [MinusValue { name: matched, typeName: "bool" }], sourcePath: context.sourcePath }
  context.blocks.push(context.currentBlock)
  return matched
}

function lowerCaseStatement(context: FunctionLowering, statement: CaseStatement): none {
  if typeFromValue(statement.subject, context.names) != "any" {
    context.failed = "case statements currently require an any-backed union subject"
    return
  }
  if statement.arms.length == 0 {
    context.failed = "case statement needs at least one arm"
    return
  }
  let targets: string[][] = []
  let wildcards: bool[] = []
  for armIndex of 0..<statement.arms.length {
    arm := statement.arms[armIndex]
    if arm.patterns.length != 1 {
      context.failed = "case arms currently support one pattern each"
      return
    }
    let target: string[] = []
    let wildcard = false
    case arm.patterns[0] {
      pattern: TypePattern -> {
        if pattern.resolvedType == none { context.failed = "unresolved case type pattern"; return }
        if !caseTypeTargets(pattern.resolvedType!, target) || target.length == 0 { context.failed = "unsupported case type pattern"; return }
      }
      pattern: ValuePattern -> {
        case pattern.value {
          _: NoneLiteral -> { target.push("none") }
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
    condition := lowerCaseTypeCondition(testContext, testSubject, targets[index])
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
          typeName := resolvedName(type_.resolvedType!, context.names)
          captured := if typeName == "any" then armSubjectParams[index] else result(armContext, "cast", [armSubjectParams[index], typeName], typeName)
          armContext.bindings.push(SourceBinding { name: type_.name, typeName, valueName: captured })
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
      storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
      joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: storageType })
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
      context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
    }
    context.terminated = false
  } else {
    context.terminated = true
  }
}

function lowerArrayLiteral(context: FunctionLowering, literal: ArrayLiteral, expression: Expression): string {
  arrayClass := typeFromValue(expression, context.names)
  elementType := if arrayClass == BYTE_ARRAY_CLASS then "byte" else if arrayClass == CHAR_ARRAY_CLASS then "char" else arrayElementFromClassName(arrayClass)
  if elementType == "" {
    context.failed = "only byte[] and char[] literals or class-instance arrays are supported by doof-wasm"
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

function lowerMapLiteral(context: FunctionLowering, literal: ObjectLiteral): string {
  if typeFromValue(literal, context.names) != STRING_BOOL_MAP_CLASS || literal.spread != none {
    context.failed = "doof-wasm object literals require Map<string, bool> without spreads"
    return ""
  }
  zero := result(context, "const", ["0"], "int")
  keyData := result(context, "array-alloc", [zero, STRING_CLASS], "int")
  keys := result(context, "new", [arrayClassName(STRING_CLASS), keyData], arrayClassName(STRING_CLASS))
  valueData := result(context, "array-alloc", [zero, "bool"], "int")
  values := result(context, "new", [arrayClassName("bool"), valueData], arrayClassName("bool"))
  map := result(context, "new", [STRING_BOOL_MAP_CLASS, keys, values], STRING_BOOL_MAP_CLASS)
  for property of literal.properties {
    key := if property.key == none then result(context, "string-const", [property.name], STRING_CLASS) else lowerExpected(context, property.key!, STRING_CLASS)
    item := lowerExpected(context, propertyExpression(property), "bool")
    if context.failed != "" { return "" }
    _ := result(context, "call-method", [map, "set", key, item], "none")
  }
  return map
}

function scanClosureExpression(expression: Expression, names: string[]): none {
  let pending: Expression[] = [expression]
  let cursor = 0
  while cursor < pending.length {
    current := pending[cursor]
    cursor = cursor + 1
    case current {
      identifier: Identifier -> {
        implicitThis := identifier.resolvedBinding != none && ["field", "method"].contains(identifier.resolvedBinding!.kind)
        name := if implicitThis then "this" else identifier.name
        if !names.contains(name) { names.push(name) }
      }
      _: ThisExpression -> { if !names.contains("this") { names.push("this") } }
      _ -> { }
    }
    collectNestedExpressions(current, pending)
  }
}

function closureLocalNames(expression: LambdaExpression): string[] {
  let names: string[] = []
  for parameter of expression.params { names.push(parameter.name) }
  case expression.body {
    block: Block -> {
      for statement of block.statements {
        case statement {
          binding: ImmutableBinding -> { names.push(binding.name) }
          readonly_: ReadonlyDeclaration -> { names.push(readonly_.name) }
          let_: LetDeclaration -> { names.push(let_.name) }
          _ -> { }
        }
      }
    }
    _ -> { }
  }
  return names
}

function closureCaptures(context: FunctionLowering, expression: LambdaExpression): SourceBinding[] {
  let references: string[] = []
  case expression.body {
    block: Block -> {
      let expressions: Expression[] = []
      collectBlockExpressions(block, expressions)
      for child of expressions { scanClosureExpression(child, references) }
    }
    body: Expression -> { scanClosureExpression(body, references) }
  }
  localNames := closureLocalNames(expression)
  let captures: SourceBinding[] = []
  for name of references {
    if localNames.contains(name) { continue }
    binding := findBinding(context, name)
    if binding == none { continue }
    captures.push(binding!)
  }
  return captures
}

function ensureClosureInterface(context: FunctionLowering, function_: FunctionType, name: string): none {
  if context.module_ == none { context.failed = "closure lowering has no module context"; return }
  registerClosureType(context.module_!, function_, context.currentLine, context.sourcePath, context.names)
  for interface_ of context.module_!.interfaces {
    if interface_.name == name && !context.interfaceNames.contains(name) { context.interfaceNames.push(name) }
  }
}

// Free functions use the same owned interface representation as lambdas. The
// adapter has no captures and forwards the complete checked signature, including
// reference and Result values, to the original declaration or host import.
function lowerNamedFunction(context: FunctionLowering, identifier: Identifier): string {
  if context.module_ == none || identifier.resolvedType == none || identifier.resolvedBinding == none || identifier.resolvedBinding!.symbol == none {
    context.failed = "named function is missing its resolved declaration or module context"
    return ""
  }
  let functionType: FunctionType | none = none
  case identifier.resolvedType! {
    type_: FunctionType -> { functionType = type_ }
    _ -> { context.failed = "named function does not have a function type"; return "" }
  }
  if functionType!.typeParams.length > 0 { context.failed = "generic function values are not supported by doof-wasm"; return "" }
  signature := closureInterfaceName(functionType!, context.names)
  ensureClosureInterface(context, functionType!, signature)
  if context.failed != "" { return "" }
  symbol := identifier.resolvedBinding!.symbol!
  target := qualifiedName(symbol.module, if symbol.originalName == "" then symbol.name else symbol.originalName, context.names)
  className := "__doof_function_value_" + string(target.length) + "_" + target
  let found = false
  for existing of context.module_!.classes { if existing.name == className { found = true } }
  if !found {
    context.module_!.classes.push(MinusClass { name: className, interfaces: [signature], line: context.currentLine, sourcePath: context.sourcePath })
    let invoke = FunctionLowering { names: context.names, sourcePath: context.sourcePath, currentLine: context.currentLine, currentBlock: MinusBlock { name: "entry", line: context.currentLine, sourcePath: context.sourcePath } }
    invoke.blocks.push(invoke.currentBlock)
    let params: MinusValue[] = [MinusValue { name: "%self", typeName: className }]
    let args: string[] = [target]
    for index of 0..<functionType!.params.length {
      typeName := resolvedName(functionType!.params[index].type_, context.names)
      if typeName == "" { context.failed = "unsupported named function parameter type"; return "" }
      valueName := "%arg" + string(index)
      params.push(MinusValue { name: valueName, typeName })
      args.push(valueName)
    }
    resultType := resolvedName(functionType!.returnType, context.names)
    if resultType == "" { context.failed = "unsupported named function return type"; return "" }
    if resultType == "none" {
      _ := result(invoke, "call", args, "none")
      effect(invoke, "return", [])
    } else {
      returned := result(invoke, "call", args, resultType)
      effect(invoke, "return", [returned])
    }
    context.module_!.functions.push(createMinusFunction{ name: className + ".invoke", params, result: resultType, blocks: invoke.blocks, line: context.currentLine, sourcePath: context.sourcePath })
  }
  created := result(context, "new", [className], className)
  return result(context, "as", [created], signature)
}

function lowerLambda(context: FunctionLowering, expression: LambdaExpression, captureCompletion: bool = false): string {
  if context.module_ == none || expression.resolvedType == none {
    context.failed = "lambda is missing its resolved function type or module context"
    return ""
  }
  let functionType: FunctionType | none = none
  case expression.resolvedType! {
    function_: FunctionType -> { functionType = function_ }
    _ -> { context.failed = "lambda does not have a function type"; return "" }
  }
  let completionType = ""
  if captureCompletion {
    completionType = resolvedName(functionType!.returnType, context.names)
    if completionType == "" { context.failed = "unsupported synchronous completion type"; return "" }
    functionType = FunctionType { params: functionType!.params, returnType: ResultResolvedType { valueType: functionType!.returnType, errorType: PrimitiveType { name: "string" } } }
  }
  signature := closureInterfaceName(functionType!, context.names)
  ensureClosureInterface(context, functionType!, signature)
  if context.failed != "" { return "" }
  captures := closureCaptures(context, expression)
  if context.failed != "" { return "" }
  closureId := context.closureIndex
  context.closureIndex = context.closureIndex + 1
  className := context.closurePrefix + "_" + string(closureId)
  let closureClass = MinusClass { name: className, interfaces: [signature], line: context.currentLine, sourcePath: context.sourcePath }
  let args: string[] = [className]
  for index of 0..<captures.length {
    let capture = captures[index]
    if capture.mutable && capture.boxedTypeName == "" {
      boxClassName := context.closurePrefix + "_box_" + string(context.closureIndex) + "_" + string(index)
      context.closureIndex = context.closureIndex + 1
      boxClass := MinusClass { name: boxClassName, line: context.currentLine, sourcePath: context.sourcePath }
      boxClass.fields.push(MinusField { name: "value", typeName: capture.typeName, mutable: true, line: context.currentLine, sourcePath: context.sourcePath })
      context.module_!.classes.push(boxClass)
      current := findBinding(context, capture.name)
      if current == none { context.failed = "missing captured binding " + capture.name; return "" }
      boxed := result(context, "box", [boxClassName, current!.valueName], boxClassName)
      context.bindings.push(SourceBinding { name: capture.name, typeName: capture.typeName, valueName: boxed, mutable: true, boxedTypeName: boxClassName })
      capture = findBinding(context, capture.name)!
      captures[index] = capture
    }
    fieldName := "_capture_" + string(index)
    captureStorageType := if capture.boxedTypeName == "" then capture.typeName else capture.boxedTypeName
    closureClass.fields.push(MinusField { name: fieldName, typeName: captureStorageType, line: context.currentLine, sourcePath: context.sourcePath })
    current := findBinding(context, capture.name)
    args.push(if current == none then capture.valueName else current!.valueName)
  }
  context.module_!.classes.push(closureClass)

  let invoke = FunctionLowering { names: context.names,
    options: context.options, completionType,
    sourcePath: context.sourcePath,
    module_: context.module_,
    closureIndex: context.closureIndex,
    closurePrefix: context.closurePrefix,
    currentBlock: MinusBlock { name: "entry", line: context.currentLine, sourcePath: context.sourcePath },
  }
  for constant of context.constants { invoke.constants.push(constant) }
  for interfaceName of context.interfaceNames { invoke.interfaceNames.push(interfaceName) }
  for declaration of context.enumDeclarations { invoke.enumDeclarations.push(declaration) }
  for enumModule of context.enumModules { invoke.enumModules.push(enumModule) }
  for declaration of context.classDeclarations { invoke.classDeclarations.push(declaration) }
  invoke.blocks.push(invoke.currentBlock)
  invoke.bindings.push(SourceBinding { name: "this", typeName: className, valueName: "%self", parameter: true })
  let params: MinusValue[] = [MinusValue { name: "%self", typeName: className }]
  for index of 0..<captures.length {
    capture := captures[index]
    captureStorageType := if capture.boxedTypeName == "" then capture.typeName else capture.boxedTypeName
    captured := result(invoke, "get", ["%self", "_capture_" + string(index)], captureStorageType)
    invoke.bindings.push(SourceBinding { name: capture.name, typeName: capture.typeName, valueName: captured, mutable: capture.mutable, boxedTypeName: capture.boxedTypeName })
  }
  for index of 0..<expression.params.length {
    parameter := expression.params[index]
    typeName := resolvedName(functionType!.params[index].type_, context.names)
    valueName := "%arg" + string(index + 1)
    params.push(MinusValue { name: valueName, typeName })
    if parameter.name != "_" { invoke.bindings.push(SourceBinding { name: parameter.name, typeName, valueName, parameter: true }) }
  }
  resultType := resolvedName(functionType!.returnType, context.names)
  case expression.body {
    block: Block -> { lowerStatements(invoke, block.statements) }
    body: Expression -> {
      let returned = lowerExpected(invoke, body, if captureCompletion then completionType else resultType)
      if captureCompletion && !invoke.terminated && invoke.failed == "" { returned = completionSuccess(invoke, returned, completionType) }
      if !invoke.terminated && invoke.failed == "" { effect(invoke, "return", [returned]); invoke.terminated = true }
    }
  }
  if invoke.failed != "" { context.failed = "in closure: " + invoke.failed; return "" }
  if invoke.closureIndex > context.closureIndex { context.closureIndex = invoke.closureIndex }
  if captureCompletion && completionType == "none" && !invoke.terminated {
    unit := result(invoke, "const", ["none"], "none")
    completed := completionSuccess(invoke, unit, "none")
    effect(invoke, "return", [completed])
  } else if resultType == "none" && !invoke.terminated { effect(invoke, "return", []) }
  function_ := createMinusFunction{
    capturePanics: captureCompletion,
    name: className + ".invoke", params, result: resultType, blocks: invoke.blocks,
    line: context.currentLine, sourcePath: context.sourcePath,
  }
  context.module_!.functions.push(function_)
  created := result(context, "new", args, className)
  return result(context, "as", [created], signature)
}

function completionSuccess(context: FunctionLowering, value: string, typeName: string): string {
  payload := if typeName == "any" then value else result(context, "box", [value], "any")
  arm := result(context, "new", [RESULT_SUCCESS_CLASS, payload], RESULT_SUCCESS_CLASS)
  return result(context, "box", [arm], "any")
}

function emitPanic(context: FunctionLowering, message: string = ""): none {
  if context.options.synchronousAsync {
    text := if message == "" then result(context, "string-const", ["Result forced unwrap failed"], STRING_CLASS) else message
    effect(context, "panic", [text])
  } else { effect(context, "panic", []) }
  context.terminated = true
}

function lowerSynchronousAsync(context: FunctionLowering, expression: AsyncExpression): string {
  if !context.options.synchronousAsync { context.failed = "async is not supported by doof-wasm; self-hosting can enable synchronousAsync"; return "" }
  if expression.resolvedType == none { context.failed = "async expression has no resolved promise type"; return "" }
  let promise: PromiseType | none = none
  case expression.resolvedType! { value: PromiseType -> { promise = value } _ -> { context.failed = "async expression must produce a Promise"; return "" } }
  thunk := LambdaExpression { kind: "lambda-expression", params: [], returnType: none, parameterless: true, trailing: false, body: expression.expression, span: expression.span, resolvedType: FunctionType { params: [], returnType: promise!.valueType } }
  closure := lowerLambda(context, thunk, true)
  if context.failed != "" { return "" }
  completion := result(context, "call-method", [closure, "invoke"], "any")
  return result(context, "new", ["__doof_promise", completion], "__doof_promise")
}

function lowerExpression(context: FunctionLowering, expression: Expression): string {
  if context.failed != "" { return "" }
  context.currentLine = expression.span.start.line
  case expression {
    value: IntLiteral -> { return result(context, "const", [string(value.value)], typeFromValue(expression, context.names)) }
    value: LongLiteral -> { return result(context, "const", [string(value.value)], "long") }
    value: FloatLiteral -> { return result(context, "const", [value.raw], "float") }
    value: DoubleLiteral -> { return result(context, "const", [value.raw], "double") }
    value: StringLiteral -> {
      if value.interpolations.length == 0 { return lowerStringPart(context, value.value) }
      let text = lowerStringPart(context, value.parts[0])
      for index of 0..<value.interpolations.length {
        formatted := lowerStringValue(context, value.interpolations[index])
        if context.failed != "" || context.terminated { return "" }
        text = result(context, "call-method", [text, "concat", formatted], STRING_CLASS)
        part := lowerStringPart(context, value.parts[index * 2 + 2])
        if context.failed != "" { return "" }
        text = result(context, "call-method", [text, "concat", part], STRING_CLASS)
      }
      return text
    }
    value: CharLiteral -> { return result(context, "const", [string(int(value.value))], "char") }
    value: BoolLiteral -> { return result(context, "const", [if value.value then "true" else "false"], "bool") }
    _: NoneLiteral -> { return result(context, "const", ["none"], "none") }
    value: IfExpression -> {
      condition := lowerExpression(context, value.condition)
      if context.failed != "" { return "" }
      return lowerConditionalValue(context, condition, value.then_, value.else_, typeFromValue(expression, context.names), "if_value")
    }
    value: Identifier -> {
      if value.resolvedBinding != none && value.resolvedBinding!.kind == "field" {
        self := findBinding(context, "this")
        if self == none { context.failed = "instance field requires this"; return "" }
        return result(context, "get", [self!.valueName, value.name], typeFromValue(expression, context.names))
      }
      binding := if value.resolvedBinding != none && value.resolvedBinding!.symbol != none then none else findBinding(context, value.name)
      if binding == none {
        if value.resolvedBinding != none {
          symbol := value.resolvedBinding!.symbol
          if symbol != none && symbol!.kind == "function" { return lowerNamedFunction(context, value) }
          modulePath := if symbol == none then value.resolvedBinding!.module else symbol!.module
          name := if symbol == none then value.name else symbol!.name
          for constant of context.constants {
            if constant.modulePath != modulePath || constant.name != name { continue }
            key := qualifiedName(modulePath, name, context.names)
            if isArrayClass(constant.typeName) { return result(context, "global-get", [key], constant.typeName) }
            if context.expandingConstants.contains(key) { context.failed = "cyclic constant initializer " + name; return "" }
            if !constantExpression(constant.value) { context.failed = "top-level constant " + name + " requires a literal constant initializer"; return "" }
            context.expandingConstants.push(key)
            emitted := lowerExpected(context, constant.value, typeFromValue(expression, context.names))
            _ := try! context.expandingConstants.pop()
            return emitted
          }
        }
        context.failed = "unsupported global value " + value.name; return ""
      }
      if binding!.boxedTypeName != "" { return result(context, "get", [binding!.valueName, "value"], binding!.typeName) }
      return binding!.valueName
    }
    _: ThisExpression -> {
      binding := findBinding(context, "this")
      if binding == none { context.failed = "this is only available in a class method"; return "" }
      return binding!.valueName
    }
    value: BinaryExpression -> {
      if value.operator == "??" { return lowerCoalesce(context, value, expression) }
      if value.operator == "&&" || value.operator == "||" {
        condition := lowerExpression(context, value.left)
        literal := BoolLiteral { kind: "bool-literal", value: value.operator == "||", resolvedType: expression.resolvedType, span: expression.span }
        return if value.operator == "&&" then lowerConditionalValue(context, condition, value.right, literal, "bool", "and") else lowerConditionalValue(context, condition, literal, value.right, "bool", "or")
      }
      if !["+", "-", "*", "/", "\\", "%", "==", "<", "!=", ">", "<=", ">="].contains(value.operator) {
        context.failed = "operator " + value.operator + " is not supported by doof-wasm"; return ""
      }
      if value.operator == "==" || value.operator == "!=" {
        case value.left {
          _: NoneLiteral -> {
            if typeFromValue(value.right, context.names) == "any" {
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
            if typeFromValue(value.left, context.names) == "any" {
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
      if ["==", "!="].contains(value.operator) &&
          (typeFromValue(value.left, context.names) == "any" || typeFromValue(value.right, context.names) == "any") {
        left = coerceValue(context, left, typeFromValue(value.left, context.names), "any")
        right = coerceValue(context, right, typeFromValue(value.right, context.names), "any")
        if context.failed != "" { return "" }
        equal := result(context, "eq", [left, right], "bool")
        if value.operator == "==" { return equal }
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [equal, no], "bool")
      }
      if ["+", "-", "*", "/", "\\", "%"].contains(value.operator) && ["int", "long", "float", "double"].contains(typeFromValue(expression, context.names)) {
        targetType := typeFromValue(expression, context.names)
        if typeFromValue(value.left, context.names) != targetType { left = result(context, "convert", [left], targetType) }
        if typeFromValue(value.right, context.names) != targetType { right = result(context, "convert", [right], targetType) }
      }
      let op = value.operator
      if op == "+" { op = "add" }
      if op == "-" { op = "sub" }
      if op == "*" { op = "mul" }
      if op == "/" || op == "\\" { op = "div" }
      if op == "%" { op = "rem" }
      if op == "add" && typeFromValue(value.left, context.names) == STRING_CLASS { return result(context, "call-method", [left, "concat", right], STRING_CLASS) }
      if op == "==" || op == "!=" { op = "eq" }
      if op == "<" { op = "lt" }
      if op == ">" && typeFromValue(value.left, context.names) != STRING_CLASS { op = "lt"; let swap = left; left = right; right = swap }
      if typeFromValue(value.left, context.names) == STRING_CLASS && (value.operator == "==" || value.operator == "!=") {
        // Equality rejects differing lengths before scanning any storage.
        equal := result(context, "call-method", [left, "equals", right], "bool")
        if value.operator == "==" { return equal }
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [equal, no], "bool")
      }
      if typeFromValue(value.left, context.names) == STRING_CLASS && ["<", ">", "<=", ">="].contains(value.operator) {
        compared := result(context, "call-method", [left, "compare", right], "int")
        zero := result(context, "const", ["0"], "int")
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
      compared := result(context, op, [left, right], typeFromValue(expression, context.names))
      if value.operator == "!=" {
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [compared, no], "bool")
      }
      return compared
    }
    value: AssignmentExpression -> {
      case value.target {
        target: Identifier -> {
          if target.resolvedBinding != none && target.resolvedBinding!.kind == "field" {
            self := findBinding(context, "this")
            if self == none { context.failed = "instance field requires this"; return "" }
            expected := typeFromValue(target, context.names)
            old := if value.operator == "=" then "" else result(context, "get", [self!.valueName, target.name], expected)
            assigned := lowerAssigned(context, value, old, expected)
            stored := coerceValue(context, assigned, typeFromValue(expression, context.names), expected)
            effect(context, "set", [self!.valueName, target.name, stored])
            return assigned
          }
          binding := findBinding(context, target.name)
          if binding == none || target.resolvedBinding == none || !target.resolvedBinding!.mutable {
            context.failed = "assignment target must be a mutable local"; return ""
          }
          old := if binding!.boxedTypeName == "" then binding!.valueName else result(context, "get", [binding!.valueName, "value"], binding!.typeName)
          assigned := lowerAssigned(context, value, old, binding!.typeName)
          stored := coerceValue(context, assigned, typeFromValue(expression, context.names), binding!.typeName)
          if binding!.boxedTypeName != "" {
            effect(context, "set", [binding!.valueName, "value", stored])
            return assigned
          }
          context.bindings.push(SourceBinding { name: target.name, typeName: binding!.typeName, valueName: stored, mutable: binding!.mutable })
          return assigned
        }
        target: MemberExpression -> {
          if typeFromValue(target.object, context.names) == "any" && (!target.force || nonNoneTypeName(target.object.resolvedType) == "any") {
            owner := lowerExpression(context, target.object)
            expected := memberValueTypeName(target)
            old := if value.operator == "=" then "" else lowerUnionField(context, target, owner)
            assigned := lowerAssigned(context, value, old, expected)
            stored := coerceValue(context, assigned, typeFromValue(expression, context.names), expected)
            if context.failed != "" || context.terminated { return "" }
            _ := lowerUnionField(context, target, owner, stored)
            return assigned
          }
          owner := lowerReceiver(context, target)
          expected := if target.resolvedMember == none || target.resolvedMember!.type_ == none then "" else resolvedName(target.resolvedMember!.type_!, context.names)
          old := if value.operator == "=" then "" else result(context, "get", [owner, target.property], expected)
          assigned := lowerAssigned(context, value, old, expected)
          stored := coerceValue(context, assigned, typeFromValue(expression, context.names), expected)
          effect(context, "set", [owner, target.property, stored])
          return assigned
        }
        target: IndexExpression -> {
          if typeFromValue(target.object, context.names) == STRING_BOOL_MAP_CLASS { context.failed = "Map indexing is not supported by doof-wasm; use .get() and .set()"; return "" }
          if target.optional { context.failed = "optional array indexing is not supported by doof-wasm"; return "" }
          array := lowerExpression(context, target.object)
          index := lowerExpression(context, target.index)
          elementType := typeFromValue(target, context.names)
          old := if value.operator == "=" then "" else result(context, "call-method", [array, "get", index], elementType)
          assigned := lowerAssigned(context, value, old, elementType)
          stored := coerceValue(context, assigned, typeFromValue(expression, context.names), elementType)
          _ := result(context, "call-method", [array, "set", index, stored], elementType)
          // Assignment expressions keep the checked right-hand-side type.
          return assigned
        }
        _ -> { context.failed = "assignment target is not supported by doof-wasm"; return "" }
      }
    }
    value: UnaryExpression -> {
      if value.operator == "!" && !value.prefix && value.operand.resolvedType != none {
        case value.operand.resolvedType! {
          _: ResultResolvedType -> {
            return lowerTryOperator(context, UnaryExpression {
              kind: value.kind, operator: "try!", prefix: true, operand: value.operand,
              span: value.span, resolvedType: value.resolvedType,
            }, expression)
          }
          _ -> { }
        }
      }
      if value.operator == "try!" || value.operator == "try?" || value.operator == "try" {
        return lowerTryOperator(context, value, expression)
      }
      operand := lowerExpression(context, value.operand)
      if value.operator == "-" {
        zero := result(context, "const", ["0"], typeFromValue(value.operand, context.names))
        return result(context, "sub", [zero, operand], typeFromValue(expression, context.names))
      }
      if value.operator == "!" && !value.prefix {
        if typeFromValue(value.operand, context.names) == "any" && typeFromValue(expression, context.names) == "any" { return lowerUnionPresence(context, operand) }
        return if typeFromValue(value.operand, context.names) == "any" then result(context, "cast", [operand, typeFromValue(expression, context.names)], typeFromValue(expression, context.names)) else operand
      }
      if value.operator == "!" {
        no := result(context, "const", ["false"], "bool")
        return result(context, "eq", [operand, no], "bool")
      }
      context.failed = "unary operator " + value.operator + " is not supported by doof-wasm"
      return ""
    }
    value: MemberExpression -> {
      if value.optional && hasNoneType(value.object.resolvedType) {
        return lowerOptionalMember(context, value, expression)
      }
      if hasWeakType(value.object.resolvedType) && (value.force || value.optional) { context.failed = "weak-reference member access is not supported by doof-wasm"; return "" }
      if value.property == "value" && isEnumType(value.object.resolvedType) {
        enumValue := lowerExpression(context, value.object)
        return result(context, "convert", [enumValue], typeFromValue(expression, context.names))
      }
      if value.resolvedMember != none && value.resolvedMember!.owner != none {
        case value.resolvedMember!.owner! {
          enum_: EnumType -> {
            if value.property == "value" {
              enumValue := lowerExpression(context, value.object)
              return result(context, "convert", [enumValue], typeFromValue(expression, context.names))
            }
            variant := enumVariantValue(context.enumDeclarations, context.enumModules, enum_.symbol.module, enum_.name, value.property)
            if variant != none { return result(context, "const", [string(variant!)], resolvedName(enum_, context.names)) }
          }
          _ -> { }
        }
      }
      if value.resolvedMember != none && value.resolvedMember!.type_ != none {
        case value.resolvedMember!.type_! {
          enum_: EnumType -> {
            variant := enumVariantValue(context.enumDeclarations, context.enumModules, enum_.symbol.module, enum_.name, value.property)
            if variant != none { return result(context, "const", [string(variant!)], resolvedName(enum_, context.names)) }
          }
          _ -> { }
        }
      }
      if value.force {
        owner := if nonNoneTypeName(value.object.resolvedType) == "any" then lowerExpression(context, value.object) else lowerReceiver(context, value)
        return lowerMemberOnOwner(context, value, owner)
      }
      if value.property == "value" && value.object.resolvedType != none {
        case value.object.resolvedType! {
          enum_: EnumType -> { return result(context, "convert", [lowerExpression(context, value.object)], "int") }
          _ -> { }
        }
      }
      if value.property == "length" && isArrayClass(typeFromValue(value.object, context.names)) {
        array := lowerExpression(context, value.object)
        return result(context, "call-method", [array, "length"], "int")
      }
      if value.property == "length" && typeFromValue(value.object, context.names) == STRING_CLASS {
        stringValue := lowerExpression(context, value.object)
        return result(context, "call-method", [stringValue, "length"], "int")
      }
      owner := lowerExpression(context, value.object)
      return lowerMemberOnOwner(context, value, owner)
    }
    value: IndexExpression -> {
      if typeFromValue(value.object, context.names) == STRING_BOOL_MAP_CLASS { context.failed = "Map indexing is not supported by doof-wasm; use .get() and .set()"; return "" }
      if value.optional { context.failed = "optional array indexing is not supported by doof-wasm"; return "" }
      array := lowerExpression(context, value.object)
      index := lowerExpression(context, value.index)
      return result(context, "call-method", [array, "get", index], typeFromValue(expression, context.names))
    }
    value: ArrayLiteral -> { return lowerArrayLiteral(context, value, expression) }
    value: ObjectLiteral -> { return lowerMapLiteral(context, value) }
    value: LambdaExpression -> { return lowerLambda(context, value) }
    value: AsyncExpression -> { return lowerSynchronousAsync(context, value) }
    shorthand: DotShorthand -> {
      if shorthand.resolvedShorthandOwnerKind == "enum" {
        variant := enumVariantValue(context.enumDeclarations, context.enumModules, shorthand.resolvedShorthandOwnerModule, shorthand.resolvedShorthandOwnerName, shorthand.name)
        if variant != none { return result(context, "const", [string(variant!)], typeFromValue(expression, context.names)) }
      }
      context.failed = "unsupported shorthand value"
      return ""
    }
    value: CallExpression -> { return lowerCall(context, value, expression) }
    value: ConstructExpression -> {
      if value.spread != none { context.failed = "construction spreads are not supported by doof-wasm"; return "" }
      if value.type_ == "Success" || value.type_ == "Failure" {
        let className = if value.type_ == "Success" then RESULT_SUCCESS_CLASS else RESULT_FAILURE_CLASS
        let propertyName = if value.type_ == "Success" then "value" else "error"
        if value.args.length > 1 { context.failed = value.type_ + " construction needs one payload"; return "" }
        let payload = ""
        if value.args.length == 1 {
          argument := value.args[0]
          if argument.name != "" && argument.name != propertyName {
            context.failed = value.type_ + " construction payload must be named " + propertyName
            return ""
          }
          argumentValue := propertyExpression(argument)
          payload = lowerExpression(context, argumentValue)
          if context.failed != "" { return "" }
          if typeFromValue(argumentValue, context.names) != "any" { payload = result(context, "box", [payload], "any") }
        } else {
          noneValue := result(context, "const", ["none"], "none")
          payload = result(context, "box", [noneValue], "any")
        }
        instance := result(context, "new", [className, payload], className)
        return result(context, "box", [instance], "any")
      }
      if value.resolvedClass == none { context.failed = "unresolved class construction"; return "" }
      let args: string[] = [qualifiedName(value.resolvedClass!.resolvedSymbol!.module, value.resolvedClass!.name, context.names)]
      for field of value.resolvedClass!.fields {
        if field.names.length != 1 { context.failed = "multiple-name fields are not supported by doof-wasm"; return "" }
        let found = false
        for property of value.args {
          if property.name == field.names[0] {
            args.push(lowerExpected(context, propertyExpression(property), annotationName(field.resolvedType, context.names)))
            found = true
          }
        }
        if !found {
          if field.defaultValue == none { context.failed = "required class field " + field.names[0] + " is missing"; return "" }
          args.push(lowerExpected(context, field.defaultValue!, annotationName(field.resolvedType, context.names)))
          if context.failed != "" { return "" }
        }
      }
      return result(context, "new", args, typeFromValue(expression, context.names))
    }
    value: AsExpression -> {
      source := lowerExpression(context, value.expression)
      target := if value.targetType.resolvedType == none then "" else resolvedName(value.targetType.resolvedType!, context.names)
      sourceType := typeFromValue(value.expression, context.names)
      if sourceType == "any" { return result(context, "cast", [source, target], target) }
      if ["byte", "int", "long", "float", "double"].contains(target) { return result(context, "convert", [source], target) }
      return result(context, "as", [source], target)
    }
    _ -> { context.failed = "expression is not supported by doof-wasm"; return "" }
  }
}

function lowerOptionalMember(context: FunctionLowering, value: MemberExpression, expression: Expression): string {
  object := lowerExpression(context, value.object)
  if context.failed != "" { return "" }
  missing := result(context, "is", [object, "none"], "bool")
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  missingName := "optional_member_none" + string(id)
  presentName := "optional_member_value" + string(id)
  joinName := "optional_member_join" + string(id)
  let args: string[] = [missing, missingName]
  for localValue of bindingValues(context, locals) { args.push(localValue) }
  args.push(object); args.push("|"); args.push(presentName)
  for localValue of bindingValues(context, locals) { args.push(localValue) }
  args.push(object)
  effect(context, "branch", args)
  noneContext := blockContext(context, locals, id, "n", missingName)
  presentContext := blockContext(context, locals, id, "p", presentName)
  noneContext.currentLine = expression.span.start.line
  presentContext.currentLine = expression.span.start.line
  objectTypeName := typeFromValue(value.object, context.names)
  noneOwner := "%b" + string(id) + "n" + string(locals.length)
  presentOwner := "%b" + string(id) + "p" + string(locals.length)
  noneContext.currentBlock.params.push(MinusValue { name: noneOwner, typeName: objectTypeName })
  presentContext.currentBlock.params.push(MinusValue { name: presentOwner, typeName: objectTypeName })
  resultType := typeFromValue(expression, context.names)
  let noneValue = result(noneContext, "const", ["none"], "none")
  if resultType == "any" { noneValue = result(noneContext, "box", [noneValue], "any") }
  presentContext.nextValue = noneContext.nextValue
  presentObjectType := nonNoneTypeName(value.object.resolvedType)
  if presentObjectType == "" {
    context.failed = "optional member access needs a supported non-none receiver type"
    return ""
  }
  presentTypedOwner := if presentObjectType == "any" then presentOwner else result(presentContext, "cast", [presentOwner, presentObjectType], presentObjectType)
  let presentValue = lowerMemberOnOwner(presentContext, value, presentTypedOwner)
  actualMemberType := memberValueTypeName(value)
  if resultType == "any" && actualMemberType != "any" {
    presentValue = result(presentContext, "box", [presentValue], "any")
  }
  if presentContext.failed != "" { context.failed = presentContext.failed; return "" }
  let joinParams: MinusValue[] = []
  for index of 0..<locals.length {
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: storageType })
  }
  joined := "%b" + string(id) + "j" + string(locals.length)
  joinParams.push(MinusValue { name: joined, typeName: resultType })
  effect(noneContext, "jump", concatValues([joinName], concatValues(bindingValues(noneContext, locals), [noneValue])))
  effect(presentContext, "jump", concatValues([joinName], concatValues(bindingValues(presentContext, locals), [presentValue])))
  appendContext(context, noneContext)
  appendContext(context, presentContext)
  context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
  context.blocks.push(context.currentBlock)
  for index of 0..<locals.length {
    context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
  }
  context.terminated = false
  return joined
}

// Shared source fields can have different offsets and different concrete value
// types. Dispatch on the receiver tag and coerce each checked field to the
// checker's joined member type, rather than treating an any box as a class.
// Writes use the same dispatch and require identical checked field types.
function classTypeName(class_: ClassType): string => if class_.symbol.originalName == "" then class_.symbol.name else class_.symbol.originalName

function sameClassType(left: ClassType, right: ClassType): bool => classTypeName(left) == classTypeName(right) && left.symbol.module == right.symbol.module

function unionFieldClasses(type_: ResolvedType, classes: ClassType[]): bool {
  case type_ {
    _: NoneType -> { return true }
    class_: ClassType -> {
      // Same identity as comparing resolvedName, without encoding module paths.
      for existing of classes { if sameClassType(existing, class_) { return true } }
      classes.push(class_)
      return true
    }
    union_: UnionResolvedType -> {
      for member of union_.types { if !unionFieldClasses(member, classes) { return false } }
      return true
    }
    _ -> { return false }
  }
}

function unionFieldType(context: FunctionLowering, class_: ClassType, property: string): string {
  // Compare the declaration's module and name directly; building their
  // qualified names for every candidate made field lookups quadratic.
  targetName := if class_.symbol.originalName == "" then class_.symbol.name else class_.symbol.originalName
  for declaration of context.classDeclarations {
    if declaration.resolvedSymbol == none || declaration.name != targetName { continue }
    if declaration.resolvedSymbol!.module != class_.symbol.module { continue }
    for field of declaration.fields {
      if field.names.contains(property) && !field.static_ { return annotationName(field.resolvedType, context.names) }
    }
  }
  return ""
}

function unionHelperContext(context: FunctionLowering): FunctionLowering {
  helper := FunctionLowering { names: context.names,
    options: context.options, sourcePath: context.sourcePath, currentLine: context.currentLine,
    currentBlock: MinusBlock { name: "entry", line: context.currentLine, sourcePath: context.sourcePath },
  }
  for name of context.interfaceNames { helper.interfaceNames.push(name) }
  helper.blocks.push(helper.currentBlock)
  return helper
}

function lowerUnionField(context: FunctionLowering, value: MemberExpression, owner: string, assigned: string = ""): string {
  if context.failed != "" { return "" }
  let classes: ClassType[] = []
  if context.module_ == none || value.object.resolvedType == none ||
      !unionFieldClasses(value.object.resolvedType!, classes) || classes.length == 0 ||
      value.resolvedMember == none || !value.resolvedMember!.field {
    context.failed = "shared union field access requires checked concrete class fields"
    return ""
  }
  memberType := memberValueTypeName(value)
  let fieldTypes: string[] = []
  for class_ of classes {
    fieldType := unionFieldType(context, class_, value.property)
    if fieldType == "" { context.failed = "unsupported shared field " + resolvedName(class_, context.names) + "." + value.property; return "" }
    if assigned != "" && fieldType != memberType { context.failed = "shared union field writes require identical field types"; return "" }
    fieldTypes.push(fieldType)
  }
  // Sibling source branches may start with the same closure counter. Helpers
  // are published immediately, so the module function count stays unique.
  name := context.closurePrefix + (if assigned == "" then "_union_field_" else "_union_set_") + string(context.module_!.functions.length)
  helper := unionHelperContext(context)
  for index of 0..<classes.length {
    className := resolvedName(classes[index], context.names)
    yesName := "field_value" + string(index)
    nextName := "field_next" + string(index)
    matches := result(helper, "is", ["%owner", className], "bool")
    effect(helper, "branch", [matches, yesName, "|", nextName])
    helper.currentBlock = MinusBlock { name: yesName, line: context.currentLine, sourcePath: context.sourcePath }
    helper.blocks.push(helper.currentBlock)
    typedOwner := result(helper, "cast", ["%owner", className], className)
    if assigned == "" {
      field := result(helper, "get", [typedOwner, value.property], fieldTypes[index])
      returned := coerceValue(helper, field, fieldTypes[index], memberType)
      if helper.failed != "" { context.failed = helper.failed; return "" }
      effect(helper, "return", [returned])
    } else {
      effect(helper, "set", [typedOwner, value.property, "%assigned"])
      effect(helper, "return", [])
    }
    helper.currentBlock = MinusBlock { name: nextName, line: context.currentLine, sourcePath: context.sourcePath }
    helper.blocks.push(helper.currentBlock)
  }
  message := result(helper, "string-const", ["Nullable forced unwrap failed"], STRING_CLASS)
  emitPanic(helper, message)
  let params: MinusValue[] = [MinusValue { name: "%owner", typeName: "any" }]
  let args: string[] = [name, owner]
  if assigned != "" { params.push(MinusValue { name: "%assigned", typeName: memberType }); args.push(assigned) }
  resultType := if assigned == "" then memberType else "none"
  context.module_!.functions.push(createMinusFunction{
    name, params, result: resultType,
    blocks: helper.blocks, line: context.currentLine, sourcePath: context.sourcePath,
  })
  return result(context, "call", args, resultType)
}

// A presence assertion on a multi-class union must retain its boxed tag.
function lowerUnionPresence(context: FunctionLowering, owner: string): string {
  if context.module_ == none { context.failed = "union presence assertion has no module context"; return "" }
  name := context.closurePrefix + "_union_present_" + string(context.module_!.functions.length)
  helper := unionHelperContext(context)
  missing := result(helper, "is", ["%owner", "none"], "bool")
  effect(helper, "branch", [missing, "missing", "|", "present"])
  helper.currentBlock = MinusBlock { name: "missing", line: context.currentLine, sourcePath: context.sourcePath }
  helper.blocks.push(helper.currentBlock)
  message := result(helper, "string-const", ["Nullable forced unwrap failed"], STRING_CLASS)
  emitPanic(helper, message)
  helper.currentBlock = MinusBlock { name: "present", line: context.currentLine, sourcePath: context.sourcePath }
  helper.blocks.push(helper.currentBlock)
  effect(helper, "return", ["%owner"])
  context.module_!.functions.push(createMinusFunction{
    name, params: [MinusValue { name: "%owner", typeName: "any" }], result: "any",
    blocks: helper.blocks, line: context.currentLine, sourcePath: context.sourcePath,
  })
  return result(context, "call", [name, owner], "any")
}

function lowerMemberOnOwner(context: FunctionLowering, value: MemberExpression, owner: string): string {
  ownerType := nonNoneTypeName(value.object.resolvedType)
  fieldType := memberValueTypeName(value)
  // Ordinary nullable field reads still have boxed storage, even when there
  // is only one non-none class. Forced and optional reads unbox their owner
  // before reaching here; ordinary reads need the same tag dispatch as unions.
  if ownerType == "any" || (!value.force && !value.optional && typeFromValue(value.object, context.names) == "any") {
    return lowerUnionField(context, value, owner)
  }
  if value.property == "value" && isEnumType(nonNoneResolvedType(value.object.resolvedType)) {
    return result(context, "convert", [owner], fieldType)
  }
  if value.property == "length" && isArrayClass(ownerType) {
    return result(context, "call-method", [owner, "length"], "int")
  }
  if value.property == "length" && ownerType == STRING_CLASS {
    return result(context, "call-method", [owner, "length"], "int")
  }
  if value.property == "size" && ownerType == STRING_BOOL_MAP_CLASS {
    return result(context, "call-method", [owner, "size"], "int")
  }
  if (ownerType == RESULT_SUCCESS_CLASS && value.property == "value") || (ownerType == RESULT_FAILURE_CLASS && value.property == "error") {
    field := result(context, "get", [owner, value.property], "any")
    if fieldType == "any" { return field }
    return result(context, "cast", [field, fieldType], fieldType)
  }
  return result(context, "get", [owner, value.property], fieldType)
}

function memberValueTypeName(value: MemberExpression): string {
  if value.resolvedMember == none || value.resolvedMember!.type_ == none { return "" }
  return resolvedName(value.resolvedMember!.type_!)
}

function nonNoneTypeName(type_: ResolvedType | none): string {
  if type_ == none { return "" }
  case type_! {
    union_: UnionResolvedType -> {
      let present = ""
      for member of union_.types {
        if member.kind == "none" { continue }
        name := resolvedName(member)
        if present == "" { present = name }
        else if present != name { return "any" }
      }
      return present
    }
    _ -> { return resolvedName(type_!) }
  }
}

function hasNoneType(type_: ResolvedType | none): bool {
  if type_ == none { return false }
  case type_! {
    _: NoneType -> { return true }
    union_: UnionResolvedType -> { for member of union_.types { if member.kind == "none" { return true } } }
    _ -> { }
  }
  return false
}

function hasWeakType(type_: ResolvedType | none): bool {
  if type_ == none { return false }
  case type_! {
    _: WeakResolvedType -> { return true }
    union_: UnionResolvedType -> { for member of union_.types { if member.kind == "weak" { return true } } }
    _ -> { }
  }
  return false
}

function lowerConditionalValue(context: FunctionLowering, condition: string, yesExpression: Expression, noExpression: Expression, resultType: string, prefix: string): string {
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  yesName := prefix + "_yes" + string(id)
  noName := prefix + "_no" + string(id)
  joinName := prefix + "_join" + string(id)
  let branchArgs: string[] = [condition, yesName]
  for value of bindingValues(context, locals) { branchArgs.push(value) }
  branchArgs.push("|"); branchArgs.push(noName)
  for value of bindingValues(context, locals) { branchArgs.push(value) }
  effect(context, "branch", branchArgs)

  yesContext := blockContext(context, locals, id, "y", yesName)
  noContext := blockContext(context, locals, id, "n", noName)
  yesContext.currentLine = context.currentLine
  noContext.currentLine = context.currentLine
  yesValue := lowerExpected(yesContext, yesExpression, resultType)
  noContext.nextValue = yesContext.nextValue
  noContext.nextBlock = yesContext.nextBlock
  noValue := lowerExpected(noContext, noExpression, resultType)
  if yesContext.failed != "" { context.failed = yesContext.failed; return "" }
  if noContext.failed != "" { context.failed = noContext.failed; return "" }

  yesFlows := !yesContext.terminated
  noFlows := !noContext.terminated
  if !yesFlows && !noFlows {
    appendContext(context, yesContext)
    appendContext(context, noContext)
    context.terminated = true
    return ""
  }

  let joinParams: MinusValue[] = []
  for index of 0..<locals.length {
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: storageType })
  }
  valueName := "%b" + string(id) + "j" + string(locals.length)
  joinParams.push(MinusValue { name: valueName, typeName: resultType })
  if yesFlows { effect(yesContext, "jump", concatValues([joinName], concatValues(bindingValues(yesContext, locals), [yesValue]))) }
  if noFlows { effect(noContext, "jump", concatValues([joinName], concatValues(bindingValues(noContext, locals), [noValue]))) }

  appendContext(context, yesContext)
  appendContext(context, noContext)
  context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
  context.blocks.push(context.currentBlock)
  for index of 0..<locals.length {
    context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
  }
  context.terminated = false
  return valueName
}

function lowerCoalesce(context: FunctionLowering, value: BinaryExpression, expression: Expression): string {
  let presentType = ""
  leftType := value.left.resolvedType
  if leftType == none { context.failed = "operator ?? left operand has no resolved type"; return "" }
  if leftType!.kind == "none" {
    _ := lowerExpression(context, value.left)
    if context.failed != "" { return "" }
    return lowerExpected(context, value.right, typeFromValue(expression, context.names))
  }
  case leftType! {
    resultType_: ResultResolvedType -> { presentType = resolvedName(resultType_.valueType, context.names) }
    union_: UnionResolvedType -> {
      for member of union_.types {
        case member {
          _: NoneType -> { }
          _ -> {
            memberType := resolvedName(member, context.names)
            if presentType == "" { presentType = memberType }
            else if presentType != memberType { presentType = "any" }
          }
        }
      }
    }
    _: NoneType -> { presentType = "none" }
    _ -> { }
  }
  if presentType == "" { context.failed = "operator ?? needs a supported optional or Result value"; return "" }
  left := lowerExpression(context, value.left)
  if context.failed != "" { return "" }
  let missing: string = ""
  if leftType!.kind == "result" {
    missing = result(context, "is", [left, RESULT_FAILURE_CLASS], "bool")
  } else {
    missing = result(context, "is", [left, "none"], "bool")
  }
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  // Branch to the fallback for a missing value; otherwise extract the payload.
  localsValues := bindingValues(context, locals)
  fallbackName := "coalesce_fallback" + string(id)
  presentName := "coalesce_present" + string(id)
  joinName := "coalesce_join" + string(id)
  let branchArgs: string[] = [missing, fallbackName]
  for localValue of localsValues { branchArgs.push(localValue) }
  branchArgs.push(left)
  branchArgs.push("|"); branchArgs.push(presentName)
  for localValue of localsValues { branchArgs.push(localValue) }
  branchArgs.push(left)
  effect(context, "branch", branchArgs)
  fallbackContext := blockContext(context, locals, id, "f", fallbackName)
  presentContext := blockContext(context, locals, id, "p", presentName)
  fallbackContext.currentLine = expression.span.start.line
  presentContext.currentLine = expression.span.start.line
  // Carry the already evaluated left value as a block parameter to avoid reevaluating it.
  leftParamName := "%b" + string(id) + "p" + string(locals.length)
  fallbackContext.currentBlock.params.push(MinusValue { name: "%b" + string(id) + "f" + string(locals.length), typeName: typeFromValue(value.left, context.names) })
  presentContext.currentBlock.params.push(MinusValue { name: leftParamName, typeName: typeFromValue(value.left, context.names) })
  fallbackResult := lowerExpected(fallbackContext, value.right, typeFromValue(expression, context.names))
  presentContext.nextValue = fallbackContext.nextValue
  let presentResult = leftParamName
  if leftType!.kind == "result" {
    presentResult = result(presentContext, "get", [leftParamName, "value"], "any")
    if presentType != "any" { presentResult = result(presentContext, "cast", [presentResult, presentType], presentType) }
  } else if presentType != "any" {
    presentResult = result(presentContext, "cast", [leftParamName, presentType], presentType)
  }
  resultType := typeFromValue(expression, context.names)
  if resultType == "any" && presentType != "any" { presentResult = result(presentContext, "box", [presentResult], "any") }
  if fallbackContext.failed != "" { context.failed = fallbackContext.failed; return "" }
  if presentContext.failed != "" { context.failed = presentContext.failed; return "" }
  let joinParams: MinusValue[] = []
  for index of 0..<locals.length {
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: storageType })
  }
  resultName := "%b" + string(id) + "j" + string(locals.length)
  joinParams.push(MinusValue { name: resultName, typeName: resultType })
  effect(fallbackContext, "jump", concatValues([joinName], concatValues(bindingValues(fallbackContext, locals), [fallbackResult])))
  effect(presentContext, "jump", concatValues([joinName], concatValues(bindingValues(presentContext, locals), [presentResult])))
  appendContext(context, fallbackContext)
  appendContext(context, presentContext)
  context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
  context.blocks.push(context.currentBlock)
  for index of 0..<locals.length {
    context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
  }
  context.terminated = false
  return resultName
}

function lowerTryOperator(context: FunctionLowering, operation: UnaryExpression, expression: Expression): string {
  operand := lowerExpression(context, operation.operand)
  if context.failed != "" { return "" }
  context.currentLine = expression.span.start.line
  operandType := operation.operand.resolvedType
  if operandType == none {
    context.failed = operation.operator + " operand has no resolved type"
    return ""
  }
  case operandType! {
    _: ResultResolvedType -> { }
    _ -> { context.failed = operation.operator + " operand is not a Result"; return "" }
  }

  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  failureName := "try_failure" + string(id)
  successName := "try_success" + string(id)
  joinName := "try_join" + string(id)
  let branchArgs: string[] = [result(context, "is", [operand, RESULT_FAILURE_CLASS], "bool"), failureName]
  for local of locals { branchArgs.push(local.valueName) }
  branchArgs.push(operand)
  branchArgs.push("|"); branchArgs.push(successName)
  for local of locals { branchArgs.push(local.valueName) }
  branchArgs.push(operand)
  effect(context, "branch", branchArgs)

  failureContext := blockContext(context, locals, id, "f", failureName)
  failureSubject := "%b" + string(id) + "f" + string(locals.length)
  failureContext.currentBlock.params.push(MinusValue { name: failureSubject, typeName: "any" })
  if operation.operator == "try!" {
    emitPanic(failureContext)
  } else if operation.operator == "try" {
    effect(failureContext, "return", [failureSubject])
    failureContext.terminated = true
  } else {
    let failureValue: string = result(failureContext, "const", ["none"], "none")
    targetType := typeFromValue(expression, context.names)
    if targetType == "any" { failureValue = result(failureContext, "box", [failureValue], "any") }
    effect(failureContext, "jump", concatValues([joinName], concatValues(bindingValues(failureContext, locals), [failureValue])))
  }

  successContext := blockContext(context, locals, id, "s", successName)
  successSubject := "%b" + string(id) + "s" + string(locals.length)
  successContext.currentBlock.params.push(MinusValue { name: successSubject, typeName: "any" })
  successContext.nextValue = failureContext.nextValue
  successContext.nextBlock = failureContext.nextBlock
  successArm := result(successContext, "cast", [successSubject, RESULT_SUCCESS_CLASS], RESULT_SUCCESS_CLASS)
  let payload = result(successContext, "get", [successArm, "value"], "any")
  let successType = ""
  case operandType! { resultType: ResultResolvedType -> { successType = resolvedName(resultType.valueType, context.names) } _ -> { } }
  if successType != "" && successType != "any" { payload = result(successContext, "cast", [payload, successType], successType) }
  if operation.operator == "try?" {
    targetType := typeFromValue(expression, context.names)
    if targetType == "any" && successType != "any" { payload = result(successContext, "box", [payload], "any") }
  }

  resultType := typeFromValue(expression, context.names)
  effect(successContext, "jump", concatValues([joinName], concatValues(bindingValues(successContext, locals), [payload])))

  let joinParams: MinusValue[] = []
  for index of 0..<locals.length {
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: storageType })
  }
  joinNameValue := "%b" + string(id) + "j" + string(locals.length)
  joinParams.push(MinusValue { name: joinNameValue, typeName: resultType })
  appendContext(context, failureContext)
  appendContext(context, successContext)
  context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
  context.blocks.push(context.currentBlock)
  for index of 0..<locals.length {
    context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
  }
  context.terminated = false
  return joinNameValue
}

function isEnumType(type_: ResolvedType | none): bool {
  if type_ == none { return false }
  case type_! { _: EnumType -> { return true } _ -> { return false } }
}

// Interpolation and explicit conversion share native primitive/enum formatting.
function lowerStringPart(context: FunctionLowering, text: string): string {
  for index of 0..<text.length {
    if int(text[index]) > 255 { context.failed = "string literal characters must fit in one UTF-8 byte"; return "" }
  }
  return result(context, "string-const", [text], STRING_CLASS)
}

function lowerEnumString(context: FunctionLowering, enum_: EnumType, input: string): string {
  typeName := resolvedName(enum_, context.names)
  name := "__doof_format_enum_" + typeName
  for function_ of context.module_!.functions {
    if function_.name == name { return result(context, "call", [name, input], STRING_CLASS) }
  }
  let declaration: EnumDeclaration | none = none
  for index of 0..<context.enumDeclarations.length {
    candidate := context.enumDeclarations[index]
    if candidate.name == enum_.name && context.enumModules[index] == enum_.symbol.module { declaration = candidate; break }
  }
  if declaration == none { context.failed = "missing enum declaration for string conversion of " + typeName; return "" }
  formatter := FunctionLowering { names: context.names,
    options: context.options, sourcePath: enum_.symbol.module, currentLine: declaration!.span.start.line,
    currentBlock: MinusBlock { name: "entry", sourcePath: enum_.symbol.module },
  }
  formatter.blocks.push(formatter.currentBlock)
  for index of 0..<declaration!.variants.length {
    variant := declaration!.variants[index]
    value := result(formatter, "const", [string(variant.resolvedIntValue!)], typeName)
    matches := result(formatter, "eq", ["%value", value], "bool")
    yesName := "variant" + string(index)
    noName := "next" + string(index)
    effect(formatter, "branch", [matches, yesName, "|", noName])
    formatter.currentBlock = MinusBlock { name: yesName, sourcePath: formatter.sourcePath }
    formatter.blocks.push(formatter.currentBlock)
    text := lowerStringPart(formatter, variant.name)
    effect(formatter, "return", [text])
    formatter.currentBlock = MinusBlock { name: noName, sourcePath: formatter.sourcePath }
    formatter.blocks.push(formatter.currentBlock)
  }
  let message = ""
  if context.options.synchronousAsync {
    prefix := lowerStringPart(formatter, "Invalid " + declaration!.name + " enum value: ")
    wide := result(formatter, "convert", ["%value"], "long")
    number := result(formatter, "call", ["__doof_format_long", wide], STRING_CLASS)
    message = result(formatter, "call-method", [prefix, "concat", number], STRING_CLASS)
  }
  emitPanic(formatter, message)
  if formatter.failed != "" { context.failed = formatter.failed; return "" }
  context.module_!.functions.push(createMinusFunction{
    name, params: [MinusValue { name: "%value", typeName }], result: STRING_CLASS,
    blocks: formatter.blocks, line: context.currentLine, sourcePath: formatter.sourcePath,
  })
  return result(context, "call", [name, input], STRING_CLASS)
}

function lowerStringValue(context: FunctionLowering, argument: Expression): string {
  input := lowerExpression(context, argument)
  if context.failed != "" || context.terminated { return "" }
  typeName := typeFromValue(argument, context.names)
  if typeName == STRING_CLASS { return input }
  if typeName == "none" { return lowerStringPart(context, "null") }
  if typeName == "bool" {
    yes := StringLiteral { kind: "string-literal", value: "true", parts: [], interpolations: [], span: argument.span, resolvedType: PrimitiveType { name: "string" } }
    no := StringLiteral { kind: "string-literal", value: "false", parts: [], interpolations: [], span: argument.span, resolvedType: PrimitiveType { name: "string" } }
    return lowerConditionalValue(context, input, yes, no, STRING_CLASS, "format_bool")
  }
  if typeName == "char" { return result(context, "call", ["__doof_format_char", input], STRING_CLASS) }
  if ["byte", "int", "long"].contains(typeName) {
    wide := if typeName == "long" then input else result(context, "convert", [input], "long")
    return result(context, "call", ["__doof_format_long", wide], STRING_CLASS)
  }
  if typeName == "float" || typeName == "double" {
    name := "__doof_format_" + typeName
    let found = false
    for imported of context.module_!.imports { if imported.name == name { found = true } }
    if !found {
      context.module_!.imports.push(MinusImport {
        name, importName: if typeName == "float" then "doofStdFormatFloat" else "doofStdFormatDouble",
        params: [MinusValue { name: "%value", typeName }], result: STRING_CLASS,
      })
    }
    return result(context, "call", [name, input], STRING_CLASS)
  }
  if argument.resolvedType != none {
    case argument.resolvedType! { enum_: EnumType -> { return lowerEnumString(context, enum_, input) } _ -> { } }
  }
  context.failed = "string conversion is not supported by doof-wasm for " + typeName
  return ""
}

function lowerCall(context: FunctionLowering, call: CallExpression, expression: Expression): string {
  case call.callee {
    callee: Identifier -> {
      if callee.name == "catchPanic" && callee.resolvedBinding != none && callee.resolvedBinding!.kind == "builtin" {
        if !context.options.synchronousAsync { context.failed = "catchPanic requires synchronousAsync self-hosting mode"; return "" }
        case call.args[0].value {
          lambda: LambdaExpression -> {
            closure := lowerLambda(context, lambda, true)
            if context.failed != "" { return "" }
            return result(context, "call-method", [closure, "invoke"], "any")
          }
          _ -> { context.failed = "self-hosting catchPanic requires an inline lambda"; return "" }
        }
      }
      if ["Success", "Failure"].contains(callee.name) && callee.resolvedBinding != none && callee.resolvedBinding!.kind == "builtin" {
        payload := lowerExpected(context, call.args[0].value, "any")
        className := if callee.name == "Success" then RESULT_SUCCESS_CLASS else RESULT_FAILURE_CLASS
        instance := result(context, "new", [className, payload], className)
        return if typeFromValue(expression, context.names) == "any" then result(context, "box", [instance], "any") else instance
      }
      if callee.name == "string" && callee.resolvedBinding != none && callee.resolvedBinding!.kind == "builtin" {
        return lowerStringValue(context, call.args[0].value)
      }
      if callee.name == "panic" && call.resolvedFunction == none {
        if call.args.length != 1 { context.failed = "panic requires one message argument"; return "" }
        message := if context.options.synchronousAsync then lowerExpected(context, call.args[0].value, STRING_CLASS) else ""
        if context.failed != "" { return "" }
        emitPanic(context, message)
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
      supplied[fieldIndex_] = lowerExpected(context, argument.value, annotationName(field.resolvedType, context.names))
      if context.failed != "" { return "" }
    }
    let args: string[] = [qualifiedName(class_.resolvedSymbol!.module, class_.name, context.names)]
    for index of 0..<class_.fields.length {
      field := class_.fields[index]
      if field.names.length != 1 { context.failed = "multiple-name fields are not supported by doof-wasm"; return "" }
      if supplied[index] != "" { args.push(supplied[index]); continue }
      if field.defaultValue == none { context.failed = "missing required construction field " + field.names[0]; return "" }
      args.push(lowerExpected(context, field.defaultValue!, annotationName(field.resolvedType, context.names)))
      if context.failed != "" { return "" }
    }
    return result(context, "new", args, typeFromValue(expression, context.names))
  }
  case call.callee {
    member: MemberExpression -> {
      if member.optional && hasNoneType(member.object.resolvedType) {
        return lowerOptionalCall(context, call, member, expression)
      }
    }
    _ -> { }
  }
  let receiver = ""
  let closureCall = false
  let canBeClosure = call.resolvedFunction == none
  case call.callee {
    callee: Identifier -> {
      if ["byte", "int", "long", "float", "double"].contains(callee.name) { canBeClosure = false }
    }
    member: MemberExpression -> {
      receiverType := nonNoneTypeName(member.object.resolvedType)
      if receiverType == STRING_BOOL_MAP_CLASS {
        if !["has", "get", "set"].contains(member.property) { context.failed = "Map method " + member.property + " is not supported by doof-wasm"; return "" }
        canBeClosure = false
      }
      if isArrayClass(receiverType) || receiverType == STRING_CLASS || receiverType == "__doof_promise" { canBeClosure = false }
    }
    _ -> { }
  }
  if canBeClosure && call.callee.resolvedType != none {
    case call.callee.resolvedType! {
      _: FunctionType -> { receiver = lowerExpression(context, call.callee); closureCall = true }
      _ -> { }
    }
  }
  case call.callee { member: MemberExpression -> { if member.resolvedStaticOwner == none { receiver = lowerReceiver(context, member) } } _ -> { } }
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
      expected := annotationName(parameters[parameterIndex].resolvedType, context.names)
      supplied[parameterIndex] = lowerExpected(context, argument.value, expected)
      if context.failed != "" { return "" }
    }
    for index of 0..<parameters.length {
      if supplied[index] != "" { args.push(supplied[index]); continue }
      parameter := parameters[index]
      if parameter.defaultValue == none { context.failed = "missing required argument " + parameter.name; return "" }
      args.push(lowerExpected(context, parameter.defaultValue!, annotationName(parameter.resolvedType, context.names)))
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
  if closureCall { return result(context, "call-method", concatValues([receiver, "invoke"], args), typeFromValue(expression, context.names)) }
  case call.callee {
    callee: Identifier -> {
      if ["byte", "int", "long", "float", "double"].contains(callee.name) {
        if args.length != 1 { context.failed = "numeric conversion requires one argument"; return "" }
        if typeFromValue(call.args[0].value, context.names) == callee.name { return args[0] }
        return result(context, "convert", [args[0]], callee.name)
      }
      if callee.resolvedBinding != none && callee.resolvedBinding!.kind == "method" {
        self := findBinding(context, "this")
        if self == none { context.failed = "instance method requires this"; return "" }
        return result(context, "call-method", concatValues([self!.valueName, callee.name], args), callResultTypeName(call, expression))
      }
      targetModule := if call.resolvedFunctionModule == "" then context.sourcePath else call.resolvedFunctionModule
      target := if call.resolvedFunction == none then callee.name else qualifiedName(targetModule, call.resolvedFunction!.name, context.names)
      return result(context, "call", concatValues([target], args), typeFromValue(expression, context.names))
    }
    callee: MemberExpression -> {
      if callee.resolvedStaticOwner != none {
        targetModule := if call.resolvedFunctionModule == "" then context.sourcePath else call.resolvedFunctionModule
        target := staticFunctionName(qualifiedName(targetModule, callee.resolvedStaticOwner!.name, context.names), callee.property)
        return result(context, "call", concatValues([target], args), callResultTypeName(call, expression))
      }
      if typeFromValue(callee.object, context.names) == STRING_CLASS && callee.property == "substring" && args.length == 1 {
        args.push(result(context, "call-method", [receiver, "length"], "int"))
      }
      if typeFromValue(callee.object, context.names) == STRING_CLASS && callee.property == "trimEnd" {
        whitespace := args.length == 0
        if whitespace { args.push(result(context, "const", ["0"], "char")) }
        args.push(result(context, "const", [if whitespace then "true" else "false"], "bool"))
      }
      return result(context, "call-method", concatValues([receiver, callee.property], args), callResultTypeName(call, expression))
    }
    _ -> { context.failed = "call target is not supported by doof-wasm"; return "" }
  }
}

function lowerOptionalCall(context: FunctionLowering, call: CallExpression, member: MemberExpression, expression: Expression): string {
  object := lowerExpression(context, member.object)
  if context.failed != "" { return "" }
  missing := result(context, "is", [object, "none"], "bool")
  locals := latestLocals(context)
  id := context.nextBlock
  context.nextBlock = context.nextBlock + 1
  noneName := "optional_call_none" + string(id)
  invokeName := "optional_call_invoke" + string(id)
  joinName := "optional_call_join" + string(id)
  let branchArgs: string[] = [missing, noneName]
  for localValue of bindingValues(context, locals) { branchArgs.push(localValue) }
  branchArgs.push(object); branchArgs.push("|"); branchArgs.push(invokeName)
  for localValue of bindingValues(context, locals) { branchArgs.push(localValue) }
  branchArgs.push(object)
  effect(context, "branch", branchArgs)
  noneContext := blockContext(context, locals, id, "n", noneName)
  invokeContext := blockContext(context, locals, id, "c", invokeName)
  noneContext.currentLine = expression.span.start.line
  invokeContext.currentLine = expression.span.start.line
  receiverType := nonNoneResolvedType(member.object.resolvedType)
  receiverTypeName := if receiverType == none then "" else resolvedName(receiverType!, context.names)
  if receiverTypeName == "" || receiverTypeName == "any" {
    context.failed = "optional method access needs one concrete non-none receiver type"
    return ""
  }
  noneOwner := "%b" + string(id) + "n" + string(locals.length)
  invokeOwner := "%b" + string(id) + "c" + string(locals.length)
  noneContext.currentBlock.params.push(MinusValue { name: noneOwner, typeName: typeFromValue(member.object, context.names) })
  invokeContext.currentBlock.params.push(MinusValue { name: invokeOwner, typeName: typeFromValue(member.object, context.names) })
  resultType := typeFromValue(expression, context.names)
  let noneValue = result(noneContext, "const", ["none"], "none")
  if resultType == "any" { noneValue = result(noneContext, "box", [noneValue], "any") }
  invokeContext.nextValue = noneContext.nextValue
  typedOwner := result(invokeContext, "cast", [invokeOwner, receiverTypeName], receiverTypeName)
  syntheticName := "__optional_receiver_" + string(id)
  synthetic := Identifier { kind: "identifier", name: syntheticName, resolvedType: receiverType!, span: member.object.span }
  syntheticMember := MemberExpression {
    kind: member.kind, object: synthetic, property: member.property, optional: false, force: member.force,
    completionPoint: member.completionPoint, resolvedStaticOwner: member.resolvedStaticOwner,
    resolvedNamespaceAccess: member.resolvedNamespaceAccess, resolvedNamespaceSymbol: member.resolvedNamespaceSymbol,
    resolvedMember: member.resolvedMember, resolvedCallableField: member.resolvedCallableField,
    resolvedType: member.resolvedType, span: member.span,
  }
  syntheticCall := CallExpression {
    kind: call.kind, callee: syntheticMember, args: call.args, typeArgs: call.typeArgs,
    resolvedGenericTypeArgs: call.resolvedGenericTypeArgs, resolvedFunction: call.resolvedFunction,
    resolvedFunctionModule: call.resolvedFunctionModule, resolvedConstructor: call.resolvedConstructor,
    resolvedClass: call.resolvedClass, resolvedConstruction: call.resolvedConstruction,
    resolvedType: call.resolvedType, span: call.span,
  }
  invokeContext.bindings.push(SourceBinding { name: syntheticName, typeName: receiverTypeName, valueName: typedOwner })
  let invoked = lowerCall(invokeContext, syntheticCall, expression)
  invokedType := callResultTypeName(call, expression)
  if resultType == "any" && invokedType != "any" { invoked = result(invokeContext, "box", [invoked], "any") }
  if invokeContext.failed != "" { context.failed = invokeContext.failed; return "" }
  let joinParams: MinusValue[] = []
  for index of 0..<locals.length {
    storageType := if locals[index].boxedTypeName == "" then locals[index].typeName else locals[index].boxedTypeName
    joinParams.push(MinusValue { name: "%b" + string(id) + "j" + string(index), typeName: storageType })
  }
  joined := "%b" + string(id) + "j" + string(locals.length)
  joinParams.push(MinusValue { name: joined, typeName: resultType })
  effect(noneContext, "jump", concatValues([joinName], concatValues(bindingValues(noneContext, locals), [noneValue])))
  effect(invokeContext, "jump", concatValues([joinName], concatValues(bindingValues(invokeContext, locals), [invoked])))
  appendContext(context, noneContext)
  appendContext(context, invokeContext)
  context.currentBlock = MinusBlock { name: joinName, params: joinParams, sourcePath: context.sourcePath }
  context.blocks.push(context.currentBlock)
  for index of 0..<locals.length {
    context.bindings.push(SourceBinding { name: locals[index].name, typeName: locals[index].typeName, valueName: joinParams[index].name, mutable: locals[index].mutable, boxedTypeName: locals[index].boxedTypeName })
  }
  context.terminated = false
  return joined
}

function callResultTypeName(call: CallExpression, expression: Expression): string {
  case call.callee {
    member: MemberExpression -> {
      if member.resolvedMember != none && member.resolvedMember!.type_ != none {
        case member.resolvedMember!.type_! {
          function_: FunctionType -> { return resolvedName(function_.returnType) }
          _ -> { }
        }
      }
    }
    _ -> { }
  }
  return typeFromValue(expression)
}

function nonNoneResolvedType(type_: ResolvedType | none): ResolvedType | none {
  if type_ == none { return none }
  case type_! {
    union_: UnionResolvedType -> {
      let present: ResolvedType | none = none
      for member of union_.types {
        if member.kind == "none" { continue }
        if present != none && resolvedName(present!) != resolvedName(member) { return none }
        present = member
      }
      return present
    }
    _ -> { return type_ }
  }
}

function lowerExpected(context: FunctionLowering, expression: Expression, expected: string): string {
  value := lowerExpression(context, expression)
  if context.terminated || context.failed != "" { return "" }
  actual := typeFromValue(expression, context.names)
  return coerceValue(context, value, actual, expected)
}

function coerceValue(context: FunctionLowering, value: string, actual: string, expected: string): string {
  if actual == expected { return value }
  if expected == "any" && actual != "any" {
    if context.interfaceNames.contains(actual) {
      context.failed = "interface values must be converted to a concrete class before boxing"
      return ""
    }
    return result(context, "box", [value], "any")
  }
  if context.interfaceNames.contains(expected) { return result(context, "as", [value], expected) }
  if ["byte", "int", "long", "float", "double"].contains(expected) &&
      ["byte", "int", "long", "float", "double"].contains(actual) {
    return result(context, "convert", [value], expected)
  }
  return value
}

function callParameterType(call: CallExpression, index: int): string {
  if call.resolvedFunction != none && index < call.resolvedFunction!.params.length {
    return annotationName(call.resolvedFunction!.params[index].resolvedType)
  }
  case call.callee {
    callee: Identifier -> {
      if ["byte", "int", "long", "float", "double"].contains(callee.name) { return "" }
    }
    _ -> { }
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
    _ -> {
      if call.callee.resolvedType != none {
        case call.callee.resolvedType! {
          function_: FunctionType -> { if index < function_.params.length { return resolvedName(function_.params[index].type_) } }
          _ -> { }
        }
      }
    }
  }
  if call.callee.resolvedType != none {
    case call.callee.resolvedType! {
      function_: FunctionType -> { if index < function_.params.length { return resolvedName(function_.params[index].type_) } }
      _ -> { }
    }
  }
  return ""
}

function lowerNullableBinding(context: FunctionLowering, binding: ImmutableBinding): none {
  value := lowerExpression(context, binding.value)
  if context.failed != "" { return }
  typeName := declarationType(binding.resolvedType, typeFromValue(binding.value, context.names), context.names)
  let resultType: ResultResolvedType | none = none
  if binding.value.resolvedType != none {
    case binding.value.resolvedType! { resolved: ResultResolvedType -> { resultType = resolved } _ -> { } }
  }
  if typeName == "" || (typeName == "any" && resultType == none) {
    context.failed = "nullable else bindings need one supported non-none type"
    return
  }
  condition := result(context, "is", [value, if resultType == none then "none" else RESULT_FAILURE_CLASS], "bool")
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
  if resultType != none && binding.failureName != none && binding.failureName! != "_" {
    failureArm := result(failureContext, "cast", [failureValueName, RESULT_FAILURE_CLASS], RESULT_FAILURE_CLASS)
    let failurePayload = result(failureContext, "get", [failureArm, "error"], "any")
    errorType := resolvedName(resultType!.errorType, context.names)
    if errorType != "any" { failurePayload = result(failureContext, "cast", [failurePayload, errorType], errorType) }
    failureContext.bindings.push(SourceBinding { name: binding.failureName!, typeName: errorType, valueName: failurePayload })
  }
  lowerStatements(failureContext, binding.else_!.statements)
  if failureContext.failed != "" { context.failed = failureContext.failed; return }
  if !failureContext.terminated { context.failed = "nullable else handler must terminate"; return }

  successContext := blockContext(context, locals, id, "v", successName)
  successValueName := "%b" + string(id) + "v" + string(locals.length)
  successContext.currentBlock.params.push(MinusValue { name: successValueName, typeName: "any" })
  successContext.nextValue = failureContext.nextValue
  successContext.nextBlock = failureContext.nextBlock
  let unwrapped = ""
  if resultType != none {
    successArm := result(successContext, "cast", [successValueName, RESULT_SUCCESS_CLASS], RESULT_SUCCESS_CLASS)
    unwrapped = result(successContext, "get", [successArm, "value"], "any")
    if typeName != "any" { unwrapped = result(successContext, "cast", [unwrapped, typeName], typeName) }
  } else { unwrapped = result(successContext, "cast", [successValueName, typeName], typeName) }
  if binding.name != "_" { successContext.bindings.push(SourceBinding { name: binding.name, typeName, valueName: unwrapped }) }
  appendContext(context, failureContext)
  appendContext(context, successContext)
  context.currentBlock = successContext.currentBlock
  if binding.name != "_" { context.bindings.push(SourceBinding { name: binding.name, typeName, valueName: unwrapped }) }
  context.terminated = false
}

function lowerStatements(context: FunctionLowering, statements: Statement[]): none {
  for statement of statements {
    context.currentLine = statement.span.start.line
    // The frontend has checked these statements. A return, loop exit, or
    // exhaustive terminating branch leaves no path on which to emit them.
    if context.terminated { return }
    if context.failed != "" { return }
    case statement {
      value: ImmutableBinding -> {
        if value.else_ != none {
          lowerNullableBinding(context, value)
          if context.failed != "" { return }
          continue
        }
        if value.name == "_" { _ := lowerExpression(context, value.value); continue }
        typeName := declarationType(value.resolvedType, typeFromValue(value.value, context.names), context.names)
        emitted := lowerExpected(context, value.value, typeName)
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted }) }
      }
      value: ReadonlyDeclaration -> {
        typeName := declarationType(value.resolvedType, typeFromValue(value.value, context.names), context.names)
        emitted := lowerExpected(context, value.value, typeName)
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted }) }
      }
      value: LetDeclaration -> {
        typeName := declarationType(value.resolvedType, typeFromValue(value.value, context.names), context.names)
        emitted := lowerExpected(context, value.value, typeName)
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted, mutable: true }) }
      }
      value: ReturnStatement -> {
        if value.value == none {
          if context.completionType != "" {
            empty := result(context, "const", ["none"], "none")
            completed := completionSuccess(context, empty, "none")
            effect(context, "return", [completed])
          } else { effect(context, "return", []) }
          context.terminated = true
        }
        else {
          let returned = lowerExpected(context, value.value!, annotationName(value.resolvedExpectedType, context.names))
          if context.completionType != "" && !context.terminated { returned = completionSuccess(context, returned, context.completionType) }
          if !context.terminated { effect(context, "return", [returned]); context.terminated = true }
        }
      }
      value: YieldStatement -> {
        if context.completionType == "" { context.failed = "yield requires synchronousAsync self-hosting mode"; return }
        returned := lowerExpected(context, value.value, context.completionType)
        if !context.terminated {
          completion := completionSuccess(context, returned, context.completionType)
          effect(context, "return", [completion]); context.terminated = true
        }
      }
      value: ExpressionStatement -> { _ := lowerExpression(context, value.expression) }
      value: TryStatement -> { lowerTryStatement(context, value) }
      value: BreakStatement -> { lowerLoopExit(context, false, value.label) }
      value: ContinueStatement -> { lowerLoopExit(context, true, value.label) }
      _: Block -> { context.failed = "nested lexical blocks are not supported by doof-wasm"; return }
      value: IfStatement -> { lowerIf(context, value) }
      value: CaseStatement -> { lowerCaseStatement(context, value) }
      value: WhileStatement -> { lowerWhile(context, value) }
      value: ForStatement -> { lowerFor(context, value) }
      value: ForOfStatement -> { lowerForOf(context, value) }
      _ -> { context.failed = "statement is not supported by doof-wasm"; return }
    }
  }
}

export function lowerFunction(fn: FunctionDeclaration, modulePath: string, module_: MinusModule, className: string = "", interfaceNames: string[] = [], enumDeclarations: EnumDeclaration[] = [], enumModules: string[] = [], constants: SourceConstant[] = [], options: WasmLoweringOptions = WasmLoweringOptions {}, classDeclarations: ClassDeclaration[] = [], names: SourceNameCache = SourceNameCache {}): Result<MinusFunction, string> {
  let params: MinusValue[] = []
  let functionName = qualifiedName(modulePath, fn.name, names)
  let context = FunctionLowering { names, options, sourcePath: modulePath, module_, closurePrefix: qualifiedName(modulePath, "_closure_" + string(fn.span.start.offset), names), currentBlock: MinusBlock { name: "entry", line: fn.span.start.line, sourcePath: modulePath } }
  for declaration of classDeclarations { context.classDeclarations.push(declaration) }
  for constant of constants { context.constants.push(constant) }
  for interfaceName of interfaceNames { context.interfaceNames.push(interfaceName) }
  for declaration of enumDeclarations { context.enumDeclarations.push(declaration) }
  for enumModule of enumModules { context.enumModules.push(enumModule) }
  if className != "" {
    functionName = if fn.static_ then staticFunctionName(className, fn.name) else className + "." + fn.name
    if !fn.static_ {
      params.push(MinusValue { name: "%self", typeName: className })
      context.bindings.push(SourceBinding { name: "this", typeName: className, valueName: "%self", parameter: true })
    }
  }
  for parameter of fn.params {
    typeName := annotationName(parameter.resolvedType, names)
    if !options.synchronousAsync && typeName.contains("__doof_promise") { return Failure(atLine(fn.span.start.line, "Promise types require synchronousAsync self-hosting mode")) }
    if typeName == "" { return Failure(atLine(fn.span.start.line, "unsupported parameter type on " + fn.name)) }
    valueName := "%arg" + string(params.length)
    params.push(MinusValue { name: valueName, typeName })
    context.bindings.push(SourceBinding { name: parameter.name, typeName, valueName, parameter: true })
  }
  resultType := annotationName(functionResultType(fn), names)
  if !options.synchronousAsync && resultType.contains("__doof_promise") { return Failure(atLine(fn.span.start.line, "Promise types require synchronousAsync self-hosting mode")) }
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
  for block of context.blocks {
    if block.instructions.length == 0 || !["return", "jump", "branch", "panic"].contains(block.instructions[block.instructions.length - 1].op) {
      return Failure(atLine(fn.span.start.line, "in " + functionName + ": unsupported fallthrough in block " + block.name))
    }
  }
  let function_ = createMinusFunction{ name: functionName, params, result: resultType, exported: fn.exported && className == "", blocks: context.blocks, line: fn.span.start.line, sourcePath: modulePath }
  return Success(function_)
}

export function constantExpression(value: Expression): bool {
  case value {
    _: IntLiteral -> { return true }
    _: LongLiteral -> { return true }
    _: FloatLiteral -> { return true }
    _: DoubleLiteral -> { return true }
    literal: StringLiteral -> { return literal.interpolations.length == 0 }
    _: CharLiteral -> { return true }
    _: BoolLiteral -> { return true }
    _: NoneLiteral -> { return true }
    _: Identifier -> { return true }
    array: ArrayLiteral -> {
      for element of array.elements { if !constantExpression(element) { return false } }
      return true
    }
    binary: BinaryExpression -> { return constantExpression(binary.left) && constantExpression(binary.right) }
    unary: UnaryExpression -> { return ["-", "!"].contains(unary.operator) && constantExpression(unary.operand) }
    _ -> { return false }
  }
}

export function lowerArrayConstant(constant: SourceConstant, module_: MinusModule, constants: SourceConstant[], enumDeclarations: EnumDeclaration[], enumModules: string[], options: WasmLoweringOptions, names: SourceNameCache = SourceNameCache {}): Result<none, string> {
  name := qualifiedName(constant.modulePath, constant.name, names)
  initializer := "__doof_init_" + name
  context := FunctionLowering { names, options, sourcePath: constant.modulePath, module_, closurePrefix: initializer, currentLine: constant.value.span.start.line, currentBlock: MinusBlock { name: "entry", line: constant.value.span.start.line, sourcePath: constant.modulePath } }
  for item of constants { context.constants.push(item) }
  for declaration of enumDeclarations { context.enumDeclarations.push(declaration) }
  for enumModule of enumModules { context.enumModules.push(enumModule) }
  context.blocks.push(context.currentBlock)
  value := lowerExpected(context, constant.value, constant.typeName)
  if context.failed != "" { return Failure(atLine(context.currentLine, "in constant " + constant.name + ": " + context.failed)) }
  effect(context, "return", [value])
  module_.functions.push(createMinusFunction{ name: initializer, result: constant.typeName, blocks: context.blocks, line: constant.value.span.start.line, sourcePath: constant.modulePath })
  module_.globals.push(MinusGlobal { name, typeName: constant.typeName, initializer, line: constant.value.span.start.line, sourcePath: constant.modulePath })
  return Success(none)
}

function lowerAssigned(context: FunctionLowering, assignment: AssignmentExpression, old: string, typeName: string): string {
  if assignment.operator == "=" { return lowerExpression(context, assignment.value) }
  right := lowerExpected(context, assignment.value, typeName)
  operator := assignment.operator.substring(0, assignment.operator.length - 1)
  if operator == "+" && typeName == STRING_CLASS { return result(context, "call-method", [old, "concat", right], STRING_CLASS) }
  let op = ""
  if operator == "+" { op = "add" }
  if operator == "-" { op = "sub" }
  if operator == "*" { op = "mul" }
  if operator == "/" || operator == "\\" { op = "div" }
  if operator == "%" { op = "rem" }
  if op == "" { context.failed = "unsupported compound assignment " + assignment.operator; return "" }
  return result(context, op, [old, right], typeName)
}

function lowerLoopExit(context: FunctionLowering, continuing: bool, label: string | none): none {
  if label != none { context.failed = "labeled loop exits are not supported by doof-wasm"; return }
  if context.loopTarget == none { context.failed = "loop exit outside a loop"; return }
  target := context.loopTarget!
  effect(context, "jump", concatValues([if continuing then target.continueName else target.breakName], bindingValues(context, target.locals)))
  context.terminated = true
}

function lowerTryStatement(context: FunctionLowering, statement: TryStatement): none {
  let operand: Expression | none = none
  let name = "_"
  let mutable = false
  case statement.binding {
    binding: ImmutableBinding -> {
      if binding.else_ != none { context.failed = "try binding else handlers are not supported by doof-wasm"; return }
      operand = binding.value; name = binding.name
    }
    binding: ReadonlyDeclaration -> { operand = binding.value; name = binding.name }
    binding: ConstDeclaration -> { operand = binding.value; name = binding.name }
    binding: LetDeclaration -> { operand = binding.value; name = binding.name; mutable = true }
    binding: ExpressionStatement -> { operand = binding.expression }
    _ -> { context.failed = "try destructuring is not supported by doof-wasm"; return }
  }
  let valueType: ResolvedType | none = none
  if operand!.resolvedType != none {
    case operand!.resolvedType! { resultType: ResultResolvedType -> { valueType = resultType.valueType } _ -> { } }
  }
  operation := UnaryExpression { kind: "unary-expression", operator: "try", prefix: true, operand: operand!, resolvedType: valueType, span: statement.span }
  emitted := lowerTryOperator(context, operation, operation)
  if name != "_" { context.bindings.push(SourceBinding { name, typeName: annotationName(valueType, context.names), valueName: emitted, mutable }) }
}

function propertyExpression(property: ObjectProperty): Expression {
  if property.value != none { return property.value! }
  return Identifier { kind: "identifier", name: property.name, resolvedType: property.resolvedType, resolvedBinding: property.resolvedBinding, span: property.span }
}

function lowerReceiver(context: FunctionLowering, member: MemberExpression): string {
  owner := lowerExpression(context, member.object)
  if member.force && typeFromValue(member.object, context.names) == "any" {
    target := nonNoneTypeName(member.object.resolvedType)
    if target == "" || target == "any" { context.failed = "forced member access needs one concrete non-none receiver type"; return "" }
    present := lowerUnionPresence(context, owner)
    if present == "" { return "" }
    return result(context, "cast", [present, target], target)
  }
  return owner
}
