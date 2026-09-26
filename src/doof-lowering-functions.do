// Lower checked function bodies, expressions, control flow, and lambdas.
import {
  PrimitiveType, ClassType, EnumType, ArrayResolvedType, SerialValueResolvedType, NoneType,
  UnionResolvedType, ResultResolvedType, SuccessResolvedType, FailureResolvedType, WeakResolvedType, ResolvedType, FunctionType,
} from "doof/src/semantic"
import {
  Statement, FunctionDeclaration, EnumDeclaration, Expression, Block, ReturnStatement, ImmutableBinding, LetDeclaration,
  ReadonlyDeclaration, ExpressionStatement, IntLiteral, LongLiteral, FloatLiteral, DoubleLiteral, StringLiteral,
  CharLiteral, BoolLiteral, NoneLiteral, Identifier, BinaryExpression, UnaryExpression, AssignmentExpression,
  CallExpression, MemberExpression, ConstructExpression, ArrayLiteral, IndexExpression, AsExpression, ThisExpression,
  DotShorthand, IfStatement, IfBranch, IfExpression, CaseStatement, TypePattern, ValuePattern, WildcardPattern, WhileStatement,
  ForStatement, ForOfStatement, LambdaExpression,
} from "doof/src/ast"
import { collectNestedExpressions, collectBlockExpressions } from "doof/src/ast-walk"
import {
  MinusModule, MinusClass, MinusField, MinusValue, MinusFunction, MinusBlock, MinusInstruction,
} from "./minus-ir"
import { BYTE_ARRAY_CLASS, CHAR_ARRAY_CLASS, STRING_CLASS, RESULT_SUCCESS_CLASS, RESULT_FAILURE_CLASS, arrayElementFromClassName, isArrayClass } from "./doof-lowering-constants"
import {
  SourceBinding, FunctionLowering, qualifiedName, atLine, enumVariantValue, resolvedName, closureInterfaceName,
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

// Source loops use explicit header, body, and exit blocks; future break/continue
// edges can target those blocks while preserving the same carried local values.
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
  effect(conditionContext, "branch", branchArgs)

  bodyContext := blockContext(conditionContext, locals, id, "f", bodyName)
  lowerStatements(bodyContext, statement.body.statements)
  if bodyContext.failed != "" { context.failed = bodyContext.failed; return }
  if !bodyContext.terminated {
    for update of statement.update { _ := lowerExpression(bodyContext, update); if bodyContext.failed != "" { context.failed = bodyContext.failed; return } }
    effect(bodyContext, "jump", concatValues([conditionName], bindingValues(bodyContext, locals)))
  }
  exitContext := blockContext(conditionContext, locals, id, "x", exitName)
  exitContext.nextValue = bodyContext.nextValue
  exitContext.nextBlock = bodyContext.nextBlock
  appendContext(context, conditionContext)
  appendContext(context, bodyContext)
  appendContext(context, exitContext)
  for binding of latestLocals(exitContext) { context.bindings.push(binding) }
  context.terminated = exitContext.terminated
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
      array: ArrayResolvedType -> { elementType = resolvedName(array.elementType) }
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
  else { context.bindings.push(SourceBinding { name: iterableName, typeName: typeFromValue(statement.iterable), valueName: iterableValue }) }
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
  lowerStatements(bodyContext, statement.body.statements)
  if bodyContext.failed != "" { context.failed = bodyContext.failed; return }
  if !bodyContext.terminated {
    currentCursor := findBinding(bodyContext, cursorName)!
    one := result(bodyContext, "const", ["1"], "int")
    nextCursor := result(bodyContext, "add", [currentCursor.valueName, one], "int")
    bodyContext.bindings.push(SourceBinding { name: cursorName, typeName: "int", valueName: nextCursor, mutable: true })
    effect(bodyContext, "jump", concatValues([conditionName], bindingValues(bodyContext, carried)))
  }
  exitContext := blockContext(conditionContext, carried, id, "x", exitName)
  exitContext.nextValue = bodyContext.nextValue
  exitContext.nextBlock = bodyContext.nextBlock
  appendContext(context, conditionContext)
  appendContext(context, bodyContext)
  appendContext(context, exitContext)
  while context.bindings.length > originalBindings.length { ignored := try! context.bindings.pop() }
  for binding of latestLocals(exitContext) { if binding.name != iterableName && binding.name != cursorName { context.bindings.push(binding) } }
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
  arrayClass := typeFromValue(expression)
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

function scanClosureExpression(expression: Expression, names: string[]): none {
  let pending: Expression[] = [expression]
  let cursor = 0
  while cursor < pending.length {
    current := pending[cursor]
    cursor = cursor + 1
    case current {
      identifier: Identifier -> { if !names.contains(identifier.name) { names.push(identifier.name) } }
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
  registerClosureType(context.module_!, function_, context.currentLine, context.sourcePath)
  for interface_ of context.module_!.interfaces {
    if interface_.name == name && !context.interfaceNames.contains(name) { context.interfaceNames.push(name) }
  }
}

function lowerLambda(context: FunctionLowering, expression: LambdaExpression): string {
  if context.module_ == none || expression.resolvedType == none {
    context.failed = "lambda is missing its resolved function type or module context"
    return ""
  }
  let functionType: FunctionType | none = none
  case expression.resolvedType! {
    function_: FunctionType -> { functionType = function_ }
    _ -> { context.failed = "lambda does not have a function type"; return "" }
  }
  signature := closureInterfaceName(functionType!)
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

  let invoke = FunctionLowering {
    sourcePath: context.sourcePath,
    module_: context.module_,
    closureIndex: context.closureIndex,
    closurePrefix: context.closurePrefix,
    currentBlock: MinusBlock { name: "entry", line: context.currentLine, sourcePath: context.sourcePath },
  }
  for interfaceName of context.interfaceNames { invoke.interfaceNames.push(interfaceName) }
  for declaration of context.enumDeclarations { invoke.enumDeclarations.push(declaration) }
  for enumModule of context.enumModules { invoke.enumModules.push(enumModule) }
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
    typeName := resolvedName(functionType!.params[index].type_)
    valueName := "%arg" + string(index + 1)
    params.push(MinusValue { name: valueName, typeName })
    if parameter.name != "_" { invoke.bindings.push(SourceBinding { name: parameter.name, typeName, valueName, parameter: true }) }
  }
  resultType := resolvedName(functionType!.returnType)
  case expression.body {
    block: Block -> { lowerStatements(invoke, block.statements) }
    body: Expression -> {
      returned := lowerExpected(invoke, body, resultType)
      if !invoke.terminated && invoke.failed == "" { effect(invoke, "return", [returned]); invoke.terminated = true }
    }
  }
  if invoke.failed != "" { context.failed = "in closure: " + invoke.failed; return "" }
  if invoke.closureIndex > context.closureIndex { context.closureIndex = invoke.closureIndex }
  if resultType == "none" && !invoke.terminated { effect(invoke, "return", []) }
  context.module_!.functions.push(MinusFunction {
    name: className + ".invoke", params, result: resultType, blocks: invoke.blocks,
    line: context.currentLine, sourcePath: context.sourcePath,
  })
  created := result(context, "new", args, className)
  return result(context, "as", [created], signature)
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
    value: IfExpression -> {
      condition := lowerExpression(context, value.condition)
      if context.failed != "" { return "" }
      return lowerConditionalValue(context, condition, value.then_, value.else_, typeFromValue(expression), "if_value")
    }
    value: Identifier -> {
      binding := findBinding(context, value.name)
      if binding == none { context.failed = "unsupported global value " + value.name; return "" }
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
          if binding!.boxedTypeName != "" {
            effect(context, "set", [binding!.valueName, "value", assigned])
            return assigned
          }
          context.bindings.push(SourceBinding { name: target.name, typeName: binding!.typeName, valueName: assigned, mutable: binding!.mutable })
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
          elementType := typeFromValue(target)
          assigned := lowerExpression(context, value.value)
          stored := coerceValue(context, assigned, typeFromValue(value.value), elementType)
          _ := result(context, "call-method", [array, "set", index, stored], elementType)
          // Assignment expressions keep the checked right-hand-side type.
          return assigned
        }
        _ -> { context.failed = "assignment target is not supported by doof-wasm"; return "" }
      }
    }
    value: UnaryExpression -> {
      if value.operator == "try!" || value.operator == "try?" {
        return lowerTryOperator(context, value, expression)
      }
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
      if value.optional && hasNoneType(value.object.resolvedType) {
        return lowerOptionalMember(context, value, expression)
      }
      if value.force || (value.optional && hasWeakType(value.object.resolvedType)) { context.failed = "weak-reference member access is not supported by doof-wasm"; return "" }
      if value.property == "value" && isEnumType(value.object.resolvedType) {
        enumValue := lowerExpression(context, value.object)
        return result(context, "convert", [enumValue], typeFromValue(expression))
      }
      if value.resolvedMember != none && value.resolvedMember!.owner != none {
        case value.resolvedMember!.owner! {
          enum_: EnumType -> {
            if value.property == "value" {
              enumValue := lowerExpression(context, value.object)
              return result(context, "convert", [enumValue], typeFromValue(expression))
            }
            variant := enumVariantValue(context.enumDeclarations, context.enumModules, enum_.symbol.module, enum_.name, value.property)
            if variant != none { return result(context, "const", [string(variant!)], resolvedName(enum_)) }
          }
          _ -> { }
        }
      }
      if value.resolvedMember != none && value.resolvedMember!.type_ != none {
        case value.resolvedMember!.type_! {
          enum_: EnumType -> {
            variant := enumVariantValue(context.enumDeclarations, context.enumModules, enum_.symbol.module, enum_.name, value.property)
            if variant != none { return result(context, "const", [string(variant!)], resolvedName(enum_)) }
          }
          _ -> { }
        }
      }
      if value.property == "length" && isArrayClass(typeFromValue(value.object)) {
        array := lowerExpression(context, value.object)
        return result(context, "call-method", [array, "length"], "int")
      }
      if value.property == "length" && typeFromValue(value.object) == STRING_CLASS {
        stringValue := lowerExpression(context, value.object)
        return result(context, "call-method", [stringValue, "length"], "int")
      }
      owner := lowerExpression(context, value.object)
      return lowerMemberOnOwner(context, value, owner)
    }
    value: IndexExpression -> {
      if value.optional { context.failed = "optional array indexing is not supported by doof-wasm"; return "" }
      array := lowerExpression(context, value.object)
      index := lowerExpression(context, value.index)
      return result(context, "call-method", [array, "get", index], typeFromValue(expression))
    }
    value: ArrayLiteral -> { return lowerArrayLiteral(context, value, expression) }
    value: LambdaExpression -> { return lowerLambda(context, value) }
    shorthand: DotShorthand -> {
      if shorthand.resolvedShorthandOwnerKind == "enum" {
        variant := enumVariantValue(context.enumDeclarations, context.enumModules, shorthand.resolvedShorthandOwnerModule, shorthand.resolvedShorthandOwnerName, shorthand.name)
        if variant != none { return result(context, "const", [string(variant!)], typeFromValue(expression)) }
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
          if argument.value == none { context.failed = value.type_ + " construction payload is missing"; return "" }
          argumentValue := argument.value!
          payload = lowerExpression(context, argumentValue)
          if context.failed != "" { return "" }
          if typeFromValue(argumentValue) != "any" { payload = result(context, "box", [payload], "any") }
        } else {
          noneValue := result(context, "const", ["none"], "none")
          payload = result(context, "box", [noneValue], "any")
        }
        instance := result(context, "new", [className, payload], className)
        return result(context, "box", [instance], "any")
      }
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
  objectTypeName := typeFromValue(value.object)
  noneOwner := "%b" + string(id) + "n" + string(locals.length)
  presentOwner := "%b" + string(id) + "p" + string(locals.length)
  noneContext.currentBlock.params.push(MinusValue { name: noneOwner, typeName: objectTypeName })
  presentContext.currentBlock.params.push(MinusValue { name: presentOwner, typeName: objectTypeName })
  resultType := typeFromValue(expression)
  let noneValue = result(noneContext, "const", ["none"], "none")
  if resultType == "any" { noneValue = result(noneContext, "box", [noneValue], "any") }
  presentContext.nextValue = noneContext.nextValue
  presentObjectType := nonNoneTypeName(value.object.resolvedType)
  if presentObjectType == "" || presentObjectType == "any" {
    context.failed = "optional member access needs one concrete non-none receiver type"
    return ""
  }
  presentTypedOwner := result(presentContext, "cast", [presentOwner, presentObjectType], presentObjectType)
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

function lowerMemberOnOwner(context: FunctionLowering, value: MemberExpression, owner: string): string {
  ownerType := nonNoneTypeName(value.object.resolvedType)
  fieldType := memberValueTypeName(value)
  if value.property == "value" && isEnumType(nonNoneResolvedType(value.object.resolvedType)) {
    return result(context, "convert", [owner], fieldType)
  }
  if value.property == "length" && isArrayClass(ownerType) {
    return result(context, "call-method", [owner, "length"], "int")
  }
  if value.property == "length" && ownerType == STRING_CLASS {
    return result(context, "call-method", [owner, "length"], "int")
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
    return lowerExpected(context, value.right, typeFromValue(expression))
  }
  case leftType! {
    resultType_: ResultResolvedType -> { presentType = resolvedName(resultType_.valueType) }
    union_: UnionResolvedType -> {
      for member of union_.types {
        case member {
          _: NoneType -> { }
          _ -> {
            memberType := resolvedName(member)
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
  fallbackContext.currentBlock.params.push(MinusValue { name: "%b" + string(id) + "f" + string(locals.length), typeName: typeFromValue(value.left) })
  presentContext.currentBlock.params.push(MinusValue { name: leftParamName, typeName: typeFromValue(value.left) })
  fallbackResult := lowerExpected(fallbackContext, value.right, typeFromValue(expression))
  presentContext.nextValue = fallbackContext.nextValue
  let presentResult = leftParamName
  if leftType!.kind == "result" {
    presentResult = result(presentContext, "get", [leftParamName, "value"], "any")
    if presentType != "any" { presentResult = result(presentContext, "cast", [presentResult, presentType], presentType) }
  } else if presentType != "any" {
    presentResult = result(presentContext, "cast", [leftParamName, presentType], presentType)
  }
  resultType := typeFromValue(expression)
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
    effect(failureContext, "panic", [])
    failureContext.terminated = true
  } else {
    let failureValue: string = result(failureContext, "const", ["none"], "none")
    targetType := typeFromValue(expression)
    if targetType == "any" { failureValue = result(failureContext, "box", [failureValue], "any") }
    effect(failureContext, "jump", concatValues([joinName], concatValues(bindingValues(failureContext, locals), [failureValue])))
  }

  successContext := blockContext(context, locals, id, "s", successName)
  successSubject := "%b" + string(id) + "s" + string(locals.length)
  successContext.currentBlock.params.push(MinusValue { name: successSubject, typeName: "any" })
  successContext.nextValue = failureContext.nextValue
  successContext.nextBlock = failureContext.nextBlock
  let payload = result(successContext, "get", [successSubject, "value"], "any")
  let successType = ""
  case operandType! { resultType: ResultResolvedType -> { successType = resolvedName(resultType.valueType) } _ -> { } }
  if successType != "" && successType != "any" { payload = result(successContext, "cast", [payload, successType], successType) }
  if operation.operator == "try?" {
    targetType := typeFromValue(expression)
    if targetType == "any" && successType != "any" { payload = result(successContext, "box", [payload], "any") }
  }

  resultType := typeFromValue(expression)
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
      receiverType := typeFromValue(member.object)
      if isArrayClass(receiverType) || receiverType == STRING_CLASS { canBeClosure = false }
    }
    _ -> { }
  }
  if canBeClosure && call.callee.resolvedType != none {
    case call.callee.resolvedType! {
      _: FunctionType -> { receiver = lowerExpression(context, call.callee); closureCall = true }
      _ -> { }
    }
  }
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
  if closureCall { return result(context, "call-method", concatValues([receiver, "invoke"], args), typeFromValue(expression)) }
  case call.callee {
    callee: Identifier -> {
      if ["byte", "int", "long", "float", "double"].contains(callee.name) {
        if args.length != 1 { context.failed = "numeric conversion requires one argument"; return "" }
        if typeFromValue(call.args[0].value) == callee.name { return args[0] }
        return result(context, "convert", [args[0]], callee.name)
      }
      targetModule := if call.resolvedFunctionModule == "" then context.sourcePath else call.resolvedFunctionModule
      target := if call.resolvedFunction == none then callee.name else qualifiedName(targetModule, call.resolvedFunction!.name)
      return result(context, "call", concatValues([target], args), typeFromValue(expression))
    }
    callee: MemberExpression -> {
      if typeFromValue(callee.object) == STRING_CLASS && callee.property == "substring" && args.length == 1 {
        args.push(result(context, "call-method", [receiver, "length"], "int"))
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
  receiverTypeName := if receiverType == none then "" else resolvedName(receiverType!)
  if receiverTypeName == "" || receiverTypeName == "any" {
    context.failed = "optional method access needs one concrete non-none receiver type"
    return ""
  }
  noneOwner := "%b" + string(id) + "n" + string(locals.length)
  invokeOwner := "%b" + string(id) + "c" + string(locals.length)
  noneContext.currentBlock.params.push(MinusValue { name: noneOwner, typeName: typeFromValue(member.object) })
  invokeContext.currentBlock.params.push(MinusValue { name: invokeOwner, typeName: typeFromValue(member.object) })
  resultType := typeFromValue(expression)
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
  actual := typeFromValue(expression)
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
        if !context.terminated { context.bindings.push(SourceBinding { name: value.name, typeName, valueName: emitted, mutable: true }) }
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
      value: ForStatement -> { lowerFor(context, value) }
      value: ForOfStatement -> { lowerForOf(context, value) }
      _ -> { context.failed = "statement is not supported by doof-wasm"; return }
    }
  }
}

export function lowerFunction(fn: FunctionDeclaration, modulePath: string, module_: MinusModule, className: string = "", interfaceNames: string[] = [], enumDeclarations: EnumDeclaration[] = [], enumModules: string[] = []): Result<MinusFunction, string> {
  let params: MinusValue[] = []
  let functionName = qualifiedName(modulePath, fn.name)
  let context = FunctionLowering { sourcePath: modulePath, module_, closurePrefix: qualifiedName(modulePath, "_closure_" + string(fn.span.start.offset)), currentBlock: MinusBlock { name: "entry", line: fn.span.start.line, sourcePath: modulePath } }
  for interfaceName of interfaceNames { context.interfaceNames.push(interfaceName) }
  for declaration of enumDeclarations { context.enumDeclarations.push(declaration) }
  for enumModule of enumModules { context.enumModules.push(enumModule) }
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
