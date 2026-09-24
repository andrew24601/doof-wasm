import { readText, writeBlob, writeText } from "std/fs"
import { compileDoofWasm, lowerDoofWasmSource } from "./doof-compiler"
import { renderDoofMinus } from "./minus-render"
import { MinusModule } from "./minus-ir"

function main(arguments: string[]): int {
  if arguments.length == 3 && arguments[0] == "--dump-minus" {
    return dumpMinus(arguments[1], arguments[2])
  }
  if arguments.length != 2 {
    println("usage: doof-wasm input.do output.wasm")
    println("       doof-wasm --dump-minus input.do output.dm")
    return 2
  }
  source := readText(arguments[0]) else {
    println("could not read " + arguments[0])
    return 1
  }
  compiled := compileDoofWasm(source)
  let bytes: byte[] = []
  case compiled {
    success: Success<byte[]> -> { bytes = success.value }
    failure: Failure<string> -> { println("compile error: " + failure.error); return 1 }
  }
  _ := writeBlob(arguments[1], bytes.cloneReadonly()) else {
    println("could not write " + arguments[1])
    return 1
  }
  return 0
}

function dumpMinus(inputPath: string, outputPath: string): int {
  source := readText(inputPath) else {
    println("could not read " + inputPath)
    return 1
  }
  lowered := lowerDoofWasmSource(source)
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
