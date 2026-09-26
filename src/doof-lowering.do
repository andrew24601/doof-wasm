// Lower source declarations and orchestrate module-level runtime synthesis.
import { carryExpressionValues } from "./doof-lowering-values"
import { FunctionDeclaration, ClassDeclaration, InterfaceDeclaration, EnumDeclaration, ImportDeclaration, ExportList, Program, TypeAliasDeclaration, ReadonlyDeclaration, ConstDeclaration, ImmutableBinding } from "doof/src/ast"
import { MinusModule, MinusClass, MinusField, MinusInterface, MinusMethod, MinusImport, MinusEnum, MinusValue } from "./minus-ir"
import { BYTE_ARRAY_CLASS, CHAR_ARRAY_CLASS, STRING_CLASS } from "./doof-lowering-constants"
import { qualifiedName, atLine, resolvedName, annotationName, functionResultType, registerClosureType, SourceConstant } from "./doof-lowering-support"
import { lowerFunction, constantExpression } from "./doof-lowering-functions"
import { moduleUsesArrayClass, injectResultClassesIfUsed, injectArrayClassRecursively, usedArrayTypes, injectStringImplementation } from "./doof-lowering-runtime"

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
      enum_: EnumDeclaration -> {
        module_.enums.push(MinusEnum { name: qualifiedName(modulePath, enum_.name), line: enum_.span.start.line, sourcePath: modulePath })
      }
      _ -> { }
    }
  }
  for statement of program.statements {
    case statement {
      fn: FunctionDeclaration -> {
        registerClosureType(module_, fn.resolvedType, fn.span.start.line, modulePath)
        for parameter of fn.params { registerClosureType(module_, parameter.resolvedType, parameter.span.start.line, modulePath) }
      }
      class_: ClassDeclaration -> {
        for field of class_.fields { registerClosureType(module_, field.resolvedType, field.span.start.line, modulePath) }
        for method of class_.methods {
          registerClosureType(module_, method.resolvedType, method.span.start.line, modulePath)
          for parameter of method.params { registerClosureType(module_, parameter.resolvedType, parameter.span.start.line, modulePath) }
        }
      }
      interface_: InterfaceDeclaration -> {
        for field of interface_.fields { registerClosureType(module_, field.resolvedType, field.span.start.line, modulePath) }
        for method of interface_.methods {
          registerClosureType(module_, method.resolvedType, method.span.start.line, modulePath)
          for parameter of method.params { registerClosureType(module_, parameter.resolvedType, method.span.start.line, modulePath) }
        }
      }
      _ -> { }
    }
  }
  return Success(none)
}

export function lowerDoofProgram(program: Program, modulePath: string = "/main.do", entryPath: string = "/main.do", enumDeclarations: EnumDeclaration[] = [], enumModules: string[] = [], constants: SourceConstant[] = []): Result<MinusModule, string> {
  let module_ = MinusModule {}
  for constant of constants {
    if constant.modulePath == modulePath && !constantExpression(constant.value) {
      return Failure(atLine(constant.value.span.start.line, "top-level constant " + constant.name + " requires a scalar constant initializer"))
    }
  }
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
        try lowered := lowerFunction(fn, modulePath, module_, "", interfaceNames, enumDeclarations, enumModules, constants)
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
          try lowered := lowerFunction(method, modulePath, module_, qualifiedName(modulePath, class_.name), interfaceNames, enumDeclarations, enumModules, constants)
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
  if moduleUsesArrayClass(module_, STRING_CLASS) { injectStringImplementation(module_) }
  let injectedArrays: string[] = []
  if moduleUsesArrayClass(module_, BYTE_ARRAY_CLASS) { injectArrayClassRecursively(module_, BYTE_ARRAY_CLASS, injectedArrays) }
  if moduleUsesArrayClass(module_, CHAR_ARRAY_CLASS) { injectArrayClassRecursively(module_, CHAR_ARRAY_CLASS, injectedArrays) }
  for arrayClass of usedArrayTypes(module_) {
    injectArrayClassRecursively(module_, arrayClass, injectedArrays)
  }
  injectResultClassesIfUsed(module_)
  if moduleUsesArrayClass(module_, BYTE_ARRAY_CLASS) && !injectedArrays.contains(BYTE_ARRAY_CLASS) { injectArrayClassRecursively(module_, BYTE_ARRAY_CLASS, injectedArrays) }
  if moduleUsesArrayClass(module_, CHAR_ARRAY_CLASS) && !injectedArrays.contains(CHAR_ARRAY_CLASS) { injectArrayClassRecursively(module_, CHAR_ARRAY_CLASS, injectedArrays) }
  for function_ of module_.functions { carryExpressionValues(function_) }
  return Success(module_)
}
