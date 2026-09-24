// Doof source front end and doof-- model compiler.
import { analyzeWithLoader } from "doof/src/frontend"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { AnalysisResult, ModuleInfo } from "doof/src/analyzer"
import { ImportDeclaration, EnumDeclaration, TypeAliasDeclaration } from "doof/src/ast"
import { noSourceLoader } from "doof/src/resolver"
import { encodeDoofMinus } from "./minus-wasm"
import { validateDoofMinus } from "./minus-validate"
import { lowerDoofProgram } from "./doof-lowering"
import { MinusModule } from "./minus-ir"
import { renderDoofMinus } from "./minus-render"

function firstError(diagnostics: Diagnostic[]): string {
  for diagnostic of diagnostics {
    if diagnostic.severity == "error" { return "line " + string(diagnostic.span.start.line) + ": " + diagnostic.message }
  }
  return "source could not be analyzed"
}

function entryModule(analysis: AnalysisResult): ModuleInfo | none {
  for module of analysis.modules { if module.path == "/main.do" { return module } }
  return none
}

/** Lower one checked Doof source file directly to a validated doof-- model. */
export function lowerDoofWasmSource(source: string): Result<MinusModule, string> {
  frontend := analyzeWithLoader([SourceFile { path: "/main.do", source }], "/main.do", noSourceLoader)
  if frontend.diagnostics.length > 0 { return Failure(firstError(frontend.diagnostics)) }
  module := entryModule(frontend.analysis)
  if module == none { return Failure("source module was not parsed") }
  for statement of module!.program.statements {
    case statement {
      _: ImportDeclaration -> { return Failure("imports and modules are not supported by doof-wasm yet") }
      _: EnumDeclaration -> { return Failure("enums are not supported by doof-wasm") }
      _: TypeAliasDeclaration -> { return Failure("type aliases are not supported by doof-wasm") }
      _ -> { }
    }
  }
  try lowered := lowerDoofProgram(module!.program)
  try validateDoofMinus(lowered)
  return Success(lowered)
}

/** Render the validated doof-- model for compiler debugging. */
export function dumpDoofWasmMinus(source: string): Result<string, string> {
  try module_ := lowerDoofWasmSource(source)
  return Success(renderDoofMinus(module_))
}

/** Compile one checked Doof source file directly to WebAssembly. */
export function compileDoofWasm(source: string): Result<byte[], string> {
  try lowered := lowerDoofWasmSource(source)
  return encodeDoofMinus(lowered)
}
