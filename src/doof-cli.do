import { readText, writeBlob, writeText } from "std/fs"
import { absolute } from "std/path"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { lowerDoofWasmSources, WasmLoweringOptions } from "./doof-compiler"
import { renderDoofMinus } from "./minus-render"
import { MinusModule } from "./minus-ir"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"
import { nativeSourceEnvironment } from "./source-environment-native"

function main(arguments: string[]): int {
  let selfHosting = false
  let debugHeap = false
  let dump = false
  let start = 0
  while start < arguments.length && arguments[start].startsWith("--") {
    flag := arguments[start]
    if flag == "--self-hosting" { selfHosting = true }
    else if flag == "--debug-heap" { debugHeap = true }
    else if flag == "--dump-minus" { dump = true }
    else { println("unknown option: " + flag); return 2 }
    start += 1
  }
  if arguments.length - start != 2 {
    println("usage: doof-wasm [--self-hosting] [--debug-heap | --dump-minus] input.do output")
    return 2
  }
  options := WasmLoweringOptions { boxImmutableStructs: selfHosting, synchronousAsync: selfHosting }
  if dump { return dumpMinus(arguments[start], arguments[start + 1], options) }
  return compileWithJs(arguments[start], arguments[start + 1], debugHeap, options)
}

function compileWithJs(inputPath: string, outputPath: string, debugHeap: bool, options: WasmLoweringOptions): int {
  path := absolute(inputPath)!
  source := readText(path) else {
    println("could not read " + inputPath)
    return 1
  }
  environment := nativeSourceEnvironment(path) else error { println(error); return 1 }
  lowered := lowerDoofWasmSources([SourceFile { path, source }], path, (importPath: string): Result<SourceFile | none, Diagnostic> => environment.load(importPath), options)
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

function dumpMinus(inputPath: string, outputPath: string, options: WasmLoweringOptions): int {
  path := absolute(inputPath)!
  source := readText(path) else {
    println("could not read " + inputPath)
    return 1
  }
  environment := nativeSourceEnvironment(path) else error { println(error); return 1 }
  lowered := lowerDoofWasmSources([SourceFile { path, source }], path, (importPath: string): Result<SourceFile | none, Diagnostic> => environment.load(importPath), options)
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
