// Portable library entry. All acquisition and publication use synchronous host
// callbacks; no filesystem, process, package acquisition, or native driver APIs.
import { compileDoofWasmSourcesWithBindings, WasmLoweringOptions } from "../src/doof-compiler"
import { encodeWasmHex } from "../src/selfhost-hex"
import { SourceFile, Diagnostic, SemanticLocation, SemanticSpan } from "doof/src/semantic"

// 0 = absent, 1 = found, 2 = acquisition failed. sourceValue is the source or
// error message from the immediately preceding sourceStatus call.
import function sourceStatus(path: string): int
import function sourceValue(): string
// Outputs use lowercase hex for bytes and the generated ES module for metadata.
// The host receives both together, only after compilation succeeds.
import function compilerOutput(wasmHex: string, bindings: string): none

function loadSource(path: string): Result<SourceFile | none, Diagnostic> {
  status := sourceStatus(path)
  if status == 0 { return Success(none) }
  if status == 1 { return Success(SourceFile { path, source: sourceValue() }) }
  location := SemanticLocation { line: 0, column: 0, offset: 0 }
  message := if status == 2 then sourceValue() else "invalid sourceStatus response"
  return Failure(Diagnostic { severity: "error", message, module: path, span: SemanticSpan { start: location, end: location } })
}

export function compile(source: string, entry: string, debugHeap: bool): string {
  options := WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true }
  artifacts := compileDoofWasmSourcesWithBindings([SourceFile { path: entry, source }], entry, loadSource, debugHeap, options) else error { return error }
  hex := encodeWasmHex(artifacts.bytes)
  compilerOutput(hex, artifacts.bindings)
  return ""
}
