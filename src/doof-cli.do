import { readText, writeBlob, writeText } from "std/fs"
import { absolute } from "std/path"
import { SourceFile, Diagnostic, SemanticLocation, SemanticSpan } from "doof/src/semantic"
import { SourceLoader } from "doof/src/resolver"
import { lowerDoofWasmSources } from "./doof-compiler"
import { renderDoofMinus } from "./minus-render"
import { MinusModule } from "./minus-ir"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function main(arguments: string[]): int {
  if arguments.length == 3 && arguments[0] == "--dump-minus" {
    return dumpMinus(arguments[1], arguments[2])
  }
  if arguments.length == 3 && arguments[0] == "--debug-heap" {
    return compileWithJs(arguments[1], arguments[2], true)
  }
  if arguments.length != 2 {
    println("usage: doof-wasm input.do output.wasm (also writes output.js)")
    println("       doof-wasm --debug-heap input.do output.wasm (adds heap inspection to output.js)")
    println("       doof-wasm --dump-minus input.do output.dm")
    return 2
  }
  return compileWithJs(arguments[0], arguments[1], false)
}

function compileWithJs(inputPath: string, outputPath: string, debugHeap: bool): int {
  path := try! absolute(inputPath)
  source := readText(path) else {
    println("could not read " + inputPath)
    return 1
  }
  lowered := lowerDoofWasmSources([SourceFile { path, source }], path, loadModule)
  let module_: MinusModule | none = none
  case lowered {
    success: Success<MinusModule> -> { module_ = success.value }
    failure: Failure<string> -> { println("compile error: " + failure.error); return 1 }
  }
  compiled := encodeDoofMinus(module_!, debugHeap)
  let bytes: byte[] = []
  case compiled {
    success: Success<byte[]> -> { bytes = success.value }
    failure: Failure<string> -> { println("compile error: " + failure.error); return 1 }
  }
  _ := writeBlob(outputPath, bytes.cloneReadonly()) else {
    println("could not write " + outputPath)
    return 1
  }
  debugPath := if outputPath.endsWith(".wasm") then outputPath.substring(0, outputPath.length - 5) + ".js" else outputPath + ".js"
  _ := writeText(debugPath, renderDoofJs(module_!, debugHeap)) else {
    println("could not write " + debugPath)
    return 1
  }
  return 0
}

function dumpMinus(inputPath: string, outputPath: string): int {
  path := try! absolute(inputPath)
  source := readText(path) else {
    println("could not read " + inputPath)
    return 1
  }
  lowered := lowerDoofWasmSources([SourceFile { path, source }], path, loadModule)
  let module_: MinusModule | none = none
  case lowered {
    success: Success<MinusModule> -> { module_ = success.value }
    failure: Failure<string> -> { println("compile error: " + failure.error); return 1 }
  }
  _ := writeText(outputPath, renderDoofMinus(module_!)) else {
    println("could not write " + outputPath)
    return 1
  }
  return 0
}

function loadModule(path: string): Result<SourceFile | none, Diagnostic> {
  source := readText(path) else {
    location := SemanticLocation { line: 0, column: 0, offset: 0 }
    return Failure(Diagnostic {
      severity: "error", message: "could not read imported module " + path,
      module: path, span: SemanticSpan { start: location, end: location },
    })
  }
  return Success(SourceFile { path, source })
}
