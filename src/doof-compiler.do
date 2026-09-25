// Doof source front end and doof-- model compiler.
import { analyzeWithLoader } from "doof/src/frontend"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { AnalysisResult, ModuleInfo } from "doof/src/analyzer"
import { EnumDeclaration } from "doof/src/ast"
import { SourceLoader, noSourceLoader } from "doof/src/resolver"
import { encodeDoofMinus } from "./minus-wasm"
import { validateDoofMinus } from "./minus-validate"
import { lowerDoofProgram } from "./doof-lowering"
import { MinusModule } from "./minus-ir"
import { renderDoofMinus } from "./minus-render"

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
  for interface_ of source.interfaces { target.interfaces.push(interface_) }
  for import_ of source.imports { target.imports.push(import_) }
  for function_ of source.functions {
    let found = false
    for existing of target.functions { if existing.name == function_.name { found = true } }
    if !found { target.functions.push(function_) }
  }
}

/** Lower a checked Doof module graph to one disambiguated doof-- module. */
export function lowerDoofWasmSources(sources: SourceFile[], entry: string, loader: SourceLoader = noSourceLoader): Result<MinusModule, string> {
  entryPath := if entry.endsWith(".do") then entry else entry + ".do"
  frontend := analyzeWithLoader(sources, entry, loader)
  if frontend.diagnostics.length > 0 { return Failure(firstError(frontend.diagnostics)) }
  let lowered = MinusModule {}
  let enumDeclarations: EnumDeclaration[] = []
  let enumModules: string[] = []
  for module of frontend.analysis.modules {
    for statement of module.program.statements {
      case statement {
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
  for module of frontend.analysis.modules {
    result := lowerDoofProgram(module.program, module.path, entryPath, enumDeclarations, enumModules)
    case result {
      success: Success<MinusModule> -> { merge(lowered, success.value) }
      failure: Failure<string> -> { return Failure(module.path + ": " + failure.error) }
    }
  }
  try validateDoofMinus(lowered)
  return Success(lowered)
}

/** Lower one in-memory Doof source file directly to a validated doof-- model. */
export function lowerDoofWasmSource(source: string): Result<MinusModule, string> {
  return lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
}

/** Render the validated doof-- model for compiler debugging. */
export function dumpDoofWasmMinus(source: string): Result<string, string> {
  try module_ := lowerDoofWasmSource(source)
  return Success(renderDoofMinus(module_))
}

/** Compile one in-memory Doof source file directly to WebAssembly. */
export function compileDoofWasm(source: string, debugHeap: bool = false): Result<byte[], string> {
  try lowered := lowerDoofWasmSource(source)
  return encodeDoofMinus(lowered, debugHeap)
}

/** Compile a loaded Doof module graph directly to WebAssembly. */
export function compileDoofWasmSources(sources: SourceFile[], entry: string, loader: SourceLoader = noSourceLoader, debugHeap: bool = false): Result<byte[], string> {
  try lowered := lowerDoofWasmSources(sources, entry, loader)
  return encodeDoofMinus(lowered, debugHeap)
}
