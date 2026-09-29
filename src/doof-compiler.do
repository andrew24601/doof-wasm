// Doof source front end and doof-- model compiler.
import { analyzeWithLoader, FrontendResult } from "doof/src/frontend"
import { releaseCheckedReferences } from "doof/src/ast-walk"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { AnalysisResult, ModuleInfo } from "doof/src/analyzer"
import { ClassDeclaration, EnumDeclaration, ReadonlyDeclaration, ConstDeclaration, ImmutableBinding } from "doof/src/ast"
import { SourceLoader, noSourceLoader } from "doof/src/resolver"
import { encodeValidatedDoofMinus } from "./minus-wasm"
import { validateDoofMinus } from "./minus-validate"
import { SourceConstant, annotationName, SourceNameCache } from "./doof-lowering-support"
import { lowerDoofProgram } from "./doof-lowering"
import { flattenStringConcats } from "./doof-lowering-strings"
import { MinusModule } from "./minus-ir"
import { renderDoofMinus } from "./minus-render"
import { renderDoofJs } from "./minus-js"
import { WasmLoweringOptions } from "./doof-lowering-options"
export { WasmLoweringOptions } from "./doof-lowering-options"

function firstError(diagnostics: Diagnostic[]): string {
  for diagnostic of diagnostics {
    if diagnostic.severity == "error" {
      path := if diagnostic.module == "" then "" else diagnostic.module + ":"
      return path + string(diagnostic.span.start.line) + ":" + string(diagnostic.span.start.column) + ": " + diagnostic.message
    }
  }
  return "source could not be analyzed"
}

function merge(target: MinusModule, source: MinusModule): none {
  if source.recoverPanics { target.recoverPanics = true }
  for global_ of source.globals { target.globals.push(global_) }
  for enum_ of source.enums {
    let found = false
    for existing of target.enums { if existing.name == enum_.name { found = true } }
    if !found { target.enums.push(enum_) }
  }
  for class_ of source.classes {
    let found = false
    for existing of target.classes { if existing.name == class_.name { found = true } }
    if !found { target.classes.push(class_) }
  }
  for interface_ of source.interfaces {
    let found = false
    for existing of target.interfaces { if existing.name == interface_.name { found = true } }
    if !found { target.interfaces.push(interface_) }
  }
  for import_ of source.imports {
    let found = false
    for existing of target.imports { if existing.name == import_.name { found = true } }
    if !found { target.imports.push(import_) }
  }
  for function_ of source.functions {
    let found = false
    for existing of target.functions { if existing.name == function_.name { found = true } }
    if !found { target.functions.push(function_) }
  }
}

/** Lower a checked Doof module graph to one disambiguated doof-- module. */
export function lowerDoofWasmSources(sources: SourceFile[], entry: string, loader: SourceLoader = noSourceLoader, options: WasmLoweringOptions = WasmLoweringOptions {}): Result<MinusModule, string> {
  frontend := analyzeWithLoader(sources, entry, loader)
  result := lowerAnalysis(frontend, entry, options)
  // The lowered module owns no syntax. Break the checker's declaration
  // back-references so the checked program is freed with the analysis.
  for module of frontend.analysis.modules { releaseCheckedReferences(module.program.statements) }
  return result
}

function lowerAnalysis(frontend: FrontendResult, entry: string, options: WasmLoweringOptions): Result<MinusModule, string> {
  names := SourceNameCache {}
  entryPath := if entry.endsWith(".do") then entry else entry + ".do"
  if frontend.diagnostics.length > 0 { return Failure(firstError(frontend.diagnostics)) }
  let lowered = MinusModule {}
  let enumDeclarations: EnumDeclaration[] = []
  let enumModules: string[] = []
  let classDeclarations: ClassDeclaration[] = []
  for module of frontend.analysis.modules {
    for statement of module.program.statements {
      case statement {
        class_: ClassDeclaration -> { classDeclarations.push(class_) }
        value: EnumDeclaration -> {
          if value.backingKind != "int" {
            return Failure(module.path + ":" + string(value.span.start.line) + ": doof-wasm only supports integer-backed enums")
          }
          enumDeclarations.push(value)
          enumModules.push(module.path)
        }
        _ -> { }
      }
    }
  }
  let constants: SourceConstant[] = []
  for module of frontend.analysis.modules {
    for statement of module.program.statements {
      case statement {
        value: ReadonlyDeclaration -> { constants.push(SourceConstant { name: value.name, modulePath: module.path, value: value.value, typeName: annotationName(value.resolvedType, names) }) }
        value: ConstDeclaration -> { constants.push(SourceConstant { name: value.name, modulePath: module.path, value: value.value, typeName: annotationName(value.resolvedType, names) }) }
        value: ImmutableBinding -> { constants.push(SourceConstant { name: value.name, modulePath: module.path, value: value.value, typeName: annotationName(value.resolvedType, names) }) }
        _ -> { }
      }
    }
  }
  for module of frontend.analysis.modules {
    result := lowerDoofProgram(module.program, module.path, entryPath, enumDeclarations, enumModules, constants, options, classDeclarations, names)
    case result {
      success: Success<MinusModule> -> { merge(lowered, success.value) }
      failure: Failure<string> -> { return Failure(module.path + ": " + failure.error) }
    }
  }
  flattenStringConcats(lowered)
  try validateDoofMinus(lowered)
  return Success(lowered)
}

/** Lower one in-memory Doof source file directly to a validated doof-- model. */
export function lowerDoofWasmSource(source: string, options: WasmLoweringOptions = WasmLoweringOptions {}): Result<MinusModule, string> {
  return lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do", noSourceLoader, options)
}

/** Render the validated doof-- model for compiler debugging. */
export function dumpDoofWasmMinus(source: string, options: WasmLoweringOptions = WasmLoweringOptions {}): Result<string, string> {
  try module_ := lowerDoofWasmSource(source, options)
  return Success(renderDoofMinus(module_))
}

/** Compile one in-memory Doof source file directly to WebAssembly. */
export function compileDoofWasm(source: string, debugHeap: bool = false, options: WasmLoweringOptions = WasmLoweringOptions {}): Result<byte[], string> {
  try lowered := lowerDoofWasmSource(source, options)
  return encodeValidatedDoofMinus(lowered, debugHeap)
}

/** Compile a loaded Doof module graph directly to WebAssembly. */
export function compileDoofWasmSources(sources: SourceFile[], entry: string, loader: SourceLoader = noSourceLoader, debugHeap: bool = false, options: WasmLoweringOptions = WasmLoweringOptions {}): Result<byte[], string> {
  try lowered := lowerDoofWasmSources(sources, entry, loader, options)
  return encodeValidatedDoofMinus(lowered, debugHeap)
}

/** Bytes and bindings from the same checked and lowered module graph. */
export class WasmCompilationArtifacts {
  bytes: byte[]
  bindings: string
}

export function compileDoofWasmSourcesWithBindings(sources: SourceFile[], entry: string, loader: SourceLoader = noSourceLoader, debugHeap: bool = false, options: WasmLoweringOptions = WasmLoweringOptions {}): Result<WasmCompilationArtifacts, string> {
  try lowered := lowerDoofWasmSources(sources, entry, loader, options)
  try bytes := encodeValidatedDoofMinus(lowered, debugHeap)
  return Success(WasmCompilationArtifacts { bytes, bindings: renderDoofJs(lowered, debugHeap) })
}
