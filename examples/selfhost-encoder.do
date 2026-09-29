// Bootstrap library entry: compile with the native doof-wasm CLI, then call
// compile through the generated JavaScript bridge and createDoofStdHost(io).
import { compileDoofMinus } from "../src/minus-wasm"
import { writeBlob } from "std/fs"

export function compile(source: string, outputPath: string): string {
  bytes := compileDoofMinus(source) else error { return error }
  _ := writeBlob(outputPath, bytes.cloneReadonly()) else { return "could not write " + outputPath }
  return "ok"
}
