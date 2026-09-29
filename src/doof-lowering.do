// Lower source declarations and orchestrate module-level runtime synthesis.
import { FunctionDeclaration, ClassDeclaration, InterfaceDeclaration, EnumDeclaration, ImportDeclaration, ExportList, Program, TypeAliasDeclaration, ReadonlyDeclaration, ConstDeclaration, ImmutableBinding } from "doof/src/ast"
import { MinusModule, MinusClass, MinusField, MinusInterface, MinusMethod, MinusImport, MinusEnum, MinusValue } from "./minus-ir"
import { BYTE_ARRAY_CLASS, CHAR_ARRAY_CLASS, STRING_CLASS, STRING_BOOL_MAP_CLASS, arrayElementFromClassName, isArrayClass } from "./doof-lowering-constants"
import { qualifiedName, atLine, resolvedName, annotationName, functionResultType, registerClosureType, SourceConstant, SourceNameCache } from "./doof-lowering-support"
import { lowerFunction, lowerArrayConstant, constantExpression } from "./doof-lowering-functions"
import { moduleUsesArrayClass, moduleUsesArrayPop, injectResultClassesIfUsed, injectArrayClassRecursively, usedArrayTypes, injectStringImplementation } from "./doof-lowering-runtime"
import { WasmLoweringOptions } from "./doof-lowering-options"
import { injectSynchronousPromises } from "./doof-lowering-promises"
import { injectStringBoolMap } from "./doof-lowering-maps"

function lowerHostImport(fn: FunctionDeclaration, modulePath: string, names: SourceNameCache): Result<MinusImport, string> {
  if fn.typeParams.length > 0 { return Failure(atLine(fn.span.start.line, "generic host imports are not supported by doof-wasm")) }
  let params: MinusValue[] = []
  for parameter of fn.params {
    typeName := annotationName(parameter.resolvedType, names)
    if typeName == "" { return Failure(atLine(fn.span.start.line, "unsupported host import parameter type on " + fn.name)) }
    params.push(MinusValue { name: "%" + parameter.name, typeName })
  }
  resultType := annotationName(functionResultType(fn), names)
  if resultType == "" { return Failure(atLine(fn.span.start.line, "unsupported host import result type on " + fn.name)) }
  return Success(MinusImport {
    name: qualifiedName(modulePath, fn.name, names),
    importModule: if fn.nativeHeader == "" then "doof" else fn.nativeHeader,
    importName: if fn.nativeCppName == "" then fn.name else fn.nativeCppName,
    params, result: resultType, line: fn.span.start.line, sourcePath: modulePath,
  })
}

function lowerTypes(program: Program, module_: MinusModule, modulePath: string, options: WasmLoweringOptions, names: SourceNameCache): Result<none, string> {
  for statement of program.statements {
    case statement {
      class_: ClassDeclaration -> {
        if class_.struct_ && !options.boxImmutableStructs { return Failure(atLine(class_.span.start.line, "structs are not supported by doof-wasm; self-hosting can enable boxImmutableStructs")) }
        if class_.typeParams.length > 0 { return Failure(atLine(class_.span.start.line, "generic classes are not supported by doof-wasm")) }
        let classOut = MinusClass { name: qualifiedName(modulePath, class_.name, names), line: class_.span.start.line, sourcePath: modulePath }
        for implemented of class_.implements_ {
          if implemented.typeArgs.length > 0 { return Failure(atLine(implemented.span.start.line, "generic interface implementations are not supported by doof-wasm")) }
          classOut.interfaces.push(if implemented.resolvedSymbol == none then implemented.name else qualifiedName(implemented.resolvedSymbol!.module, implemented.name, names))
        }
        for field of class_.fields {
          if class_.struct_ && field.let_ { return Failure(atLine(field.span.start.line, "boxImmutableStructs requires immutable struct fields")) }
          if field.static_ || field.weak_ || field.names.length != 1 {
            return Failure(atLine(field.span.start.line, "static, weak, and multiple fields are not supported by doof-wasm"))
          }
          typeName := annotationName(field.resolvedType, names)
          if typeName == "" { return Failure(atLine(field.span.start.line, "unsupported field type in " + class_.name)) }
          if !options.synchronousAsync && typeName.contains("__doof_promise") { return Failure(atLine(field.span.start.line, "Promise types require synchronousAsync self-hosting mode")) }
          classOut.fields.push(MinusField { name: field.names[0], typeName, mutable: field.let_, line: field.span.start.line, sourcePath: modulePath })
        }
        module_.classes.push(classOut)
      }
      interface_: InterfaceDeclaration -> {
        if interface_.typeParams.length > 0 { return Failure(atLine(interface_.span.start.line, "generic interfaces are not supported by doof-wasm")) }
        let interfaceOut = MinusInterface { name: qualifiedName(modulePath, interface_.name, names), line: interface_.span.start.line, sourcePath: modulePath }
        for field of interface_.fields {
          interfaceOut.fields.push(MinusField {
            name: field.name, typeName: annotationName(field.resolvedType, names), mutable: field.let_, line: field.span.start.line, sourcePath: modulePath,
          })
        }
        for method of interface_.methods {
          let paramTypes: string[] = []
          for parameter of method.params { paramTypes.push(annotationName(parameter.resolvedType, names)) }
          interfaceOut.methods.push(MinusMethod {
            name: method.name, params: paramTypes, result: annotationName(functionResultType(method), names), line: method.span.start.line, sourcePath: modulePath,
          })
        }
        module_.interfaces.push(interfaceOut)
      }
      enum_: EnumDeclaration -> {
        module_.enums.push(MinusEnum { name: qualifiedName(modulePath, enum_.name, names), line: enum_.span.start.line, sourcePath: modulePath })
      }
      _ -> { }
    }
  }
  for statement of program.statements {
    case statement {
      fn: FunctionDeclaration -> {
        registerClosureType(module_, fn.resolvedType, fn.span.start.line, modulePath, names)
        for parameter of fn.params { registerClosureType(module_, parameter.resolvedType, parameter.span.start.line, modulePath, names) }
      }
      class_: ClassDeclaration -> {
        for field of class_.fields { registerClosureType(module_, field.resolvedType, field.span.start.line, modulePath, names) }
        for method of class_.methods {
          registerClosureType(module_, method.resolvedType, method.span.start.line, modulePath, names)
          for parameter of method.params { registerClosureType(module_, parameter.resolvedType, parameter.span.start.line, modulePath, names) }
        }
      }
      interface_: InterfaceDeclaration -> {
        for field of interface_.fields { registerClosureType(module_, field.resolvedType, field.span.start.line, modulePath, names) }
        for method of interface_.methods {
          registerClosureType(module_, method.resolvedType, method.span.start.line, modulePath, names)
          for parameter of method.params { registerClosureType(module_, parameter.resolvedType, method.span.start.line, modulePath, names) }
        }
      }
      _ -> { }
    }
  }
  return Success(none)
}

export function lowerDoofProgram(program: Program, modulePath: string = "/main.do", entryPath: string = "/main.do", enumDeclarations: EnumDeclaration[] = [], enumModules: string[] = [], constants: SourceConstant[] = [], options: WasmLoweringOptions = WasmLoweringOptions {}, classDeclarations: ClassDeclaration[] = [], names: SourceNameCache = SourceNameCache {}): Result<MinusModule, string> {
  let module_ = MinusModule { recoverPanics: options.synchronousAsync }
  let sourceClasses: ClassDeclaration[] = []
  for declaration of classDeclarations { sourceClasses.push(declaration) }
  if sourceClasses.length == 0 {
    for statement of program.statements {
      case statement { class_: ClassDeclaration -> { sourceClasses.push(class_) } _ -> { } }
    }
  }
  for constant of constants {
    if constant.modulePath == modulePath && !constantExpression(constant.value) {
      return Failure(atLine(constant.value.span.start.line, "top-level constant " + constant.name + " requires a literal constant initializer"))
    }
  }
  try lowerTypes(program, module_, modulePath, options, names)
  for constant of constants {
    if constant.modulePath == modulePath && isArrayClass(constant.typeName) {
      try lowerArrayConstant(constant, module_, constants, enumDeclarations, enumModules, options, names)
    }
  }
  let interfaceNames: string[] = []
  for interface_ of module_.interfaces { interfaceNames.push(interface_.name) }
  for statement of program.statements {
    case statement {
      fn: FunctionDeclaration -> {
        if fn.native_ {
          if fn.exported { return Failure(atLine(fn.span.start.line, "host imports cannot be exported")) }
          try imported := lowerHostImport(fn, modulePath, names)
          module_.imports.push(imported)
          continue
        }
        if fn.typeParams.length > 0 { return Failure(atLine(fn.span.start.line, "generic functions are not supported by doof-wasm")) }
        if fn.bodyless || (fn.isolated_ && !options.synchronousAsync) { return Failure(atLine(fn.span.start.line, "bodyless and isolated functions are not supported by doof-wasm")) }
        try lowered := lowerFunction(fn, modulePath, module_, "", interfaceNames, enumDeclarations, enumModules, constants, options, sourceClasses, names)
        lowered.exported = fn.exported && modulePath == entryPath
        if lowered.exported { lowered.exportName = fn.name }
        module_.functions.push(lowered)
      }
      class_: ClassDeclaration -> {
        for method of class_.methods {
          if method.bodyless || (method.isolated_ && !options.synchronousAsync) || method.typeParams.length > 0 {
            return Failure(atLine(method.span.start.line, "bodyless, isolated, or generic methods are not supported by doof-wasm"))
          }
          try lowered := lowerFunction(method, modulePath, module_, qualifiedName(modulePath, class_.name, names), interfaceNames, enumDeclarations, enumModules, constants, options, sourceClasses)
          module_.functions.push(lowered)
        }
      }
      _: InterfaceDeclaration -> { }
      _: EnumDeclaration -> { }
      _: ImportDeclaration -> { }
      _: ExportList -> { }
      _: TypeAliasDeclaration -> { }
      _: ReadonlyDeclaration -> { }
      _: ConstDeclaration -> { }
      _: ImmutableBinding -> { }
      _ -> { return Failure(atLine(statement.span.start.line, "top-level declaration is not supported by doof-wasm")) }
    }
  }
  if options.synchronousAsync { injectSynchronousPromises(module_) }
  let usesMap = moduleUsesArrayClass(module_, STRING_BOOL_MAP_CLASS)
  for arrayClass of usedArrayTypes(module_) {
    let element = arrayClass
    while isArrayClass(element) { element = arrayElementFromClassName(element) }
    if element == STRING_BOOL_MAP_CLASS { usesMap = true }
  }
  if usesMap { injectStringBoolMap(module_) }
  if options.synchronousAsync || moduleUsesArrayClass(module_, STRING_CLASS) || moduleUsesArrayPop(module_) { injectStringImplementation(module_) }
  let injectedArrays: string[] = []
  if moduleUsesArrayClass(module_, BYTE_ARRAY_CLASS) { injectArrayClassRecursively(module_, BYTE_ARRAY_CLASS, injectedArrays) }
  if moduleUsesArrayClass(module_, CHAR_ARRAY_CLASS) { injectArrayClassRecursively(module_, CHAR_ARRAY_CLASS, injectedArrays) }
  for arrayClass of usedArrayTypes(module_) {
    injectArrayClassRecursively(module_, arrayClass, injectedArrays)
  }
  injectResultClassesIfUsed(module_)
  if moduleUsesArrayClass(module_, BYTE_ARRAY_CLASS) && !injectedArrays.contains(BYTE_ARRAY_CLASS) { injectArrayClassRecursively(module_, BYTE_ARRAY_CLASS, injectedArrays) }
  if moduleUsesArrayClass(module_, CHAR_ARRAY_CLASS) && !injectedArrays.contains(CHAR_ARRAY_CLASS) { injectArrayClassRecursively(module_, CHAR_ARRAY_CLASS, injectedArrays) }
  return Success(module_)
}
