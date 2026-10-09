// Explicit native reference gate for the portable Wasm compiler. Keep acquisition
// and fixture-file writing outside the portable source-compiler graph.
import { writeText } from "std/fs"
import { formatJsonValue } from "std/json"
import { SourceFile } from "doof/src/semantic"
import { compileDoofWasmSourcesWithBindings, WasmLoweringOptions, WasmCompilationArtifacts } from "../src/doof-compiler"
import { nativeSourceEnvironment } from "../src/source-environment-native"
import { encodeWasmHex } from "../src/selfhost-hex"

class FixtureSource { path: string; source: string }
class Fixture {
  name: string
  source: string
  files: FixtureSource[] = []
  let wasmHex: string = ""
  let bindings: string = ""
  let diagnostic: string = ""
}

function main(arguments: string[]): int {
  if arguments.length != 1 { println("usage: selfhost-fixtures output.json"); return 2 }
  fixtures := [
    Fixture { name: "arithmetic", source: "export function answer(): int => 40 + 2" },
    Fixture { name: "imports", source: `import { add } from "./math"
export function answer(): int => add(40, 2)`, files: [FixtureSource { path: "/math.do", source: "export function add(left: int, right: int): int => left + right" }] },
    Fixture { name: "formatting", source: `import { State as Phase, current } from "./state"
export function format(ready: bool): string => "phase=\${current(ready)};ready=\${ready};value=\${if ready then 42 else -1}"`, files: [FixtureSource { path: "/state.do", source: `export enum State { cold = -7, ready = 9 }
export function current(ready: bool): State => if ready then .ready else .cold` }] },
    Fixture { name: "numeric", source: `import { parseInt } from "std/parse"
export function answer(text: string): int => parseInt(text)!` },
    Fixture { name: "closures", source: `class Box { let value: int }
export function answer(): int {
  box := Box { value: 40 }
  add := (amount: int): int => { box.value += amount; return box.value }
  return add(2)
}` },
    Fixture { name: "result-absence", source: `class Value {
  number: int
  read(): Result<int, string> => Success(number)
}
function load(mode: int): Result<Value | none, string> | none {
  if mode == 0 { return none }
  if mode == 1 { return Failure("missing") }
  if mode == 2 { return Success(none) }
  return Success(Value { number: 42 })
}
function propagate(): Result<int, string> {
  let value = 0
  try value = load(3)!.read()
  return Success(value)
}
export function answer(): int {
  absent := load(2)?.read()
  case absent {
    s: Success -> { if s.value != none { return 0 } }
    _: Failure -> { return 0 }
  }
  if (load(0)? ?? Value { number: 7 }).number != 7 { return 0 }
  let handled = 0
  _ := load(1) else error { handled = if error == "missing" then 1 else 0 }
  if handled != 1 || Success(42) != Success(42) { return 0 }
  return propagate()!
}` },
    Fixture { name: "removed-prefix-unwrap", source: "export function answer(): int { value: Result<int, string> := Success(42); return try! value }" },
    Fixture { name: "large", source: "export function answer(): string => \"" + "x".repeat(262145) + "\"" },
    Fixture { name: "malformed", source: "export function answer(: int => 42" },
    Fixture { name: "type-error", source: "export function answer(): int => \"wrong\"" },
    Fixture { name: "unknown", source: "export function answer(): int => missing" },
    Fixture { name: "missing-import", source: `import { missing } from "./absent"
export function answer(): int => 42` },
    Fixture { name: "missing-stdlib", source: `import { missing } from "std/unavailable"
export function answer(): int => 42` },
    Fixture { name: "recovery", source: "export function answer(): int => 42" },
  ]
  environment := nativeSourceEnvironment("examples/selfhost-compiler.do", "std/wasm") else error { println(error); return 1 }
  options := WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true }
  let references: SerialValue[] = []
  for fixture of fixtures {
    sources := [SourceFile { path: "/main.do", source: fixture.source }]
    for file of fixture.files { sources.push(SourceFile { path: file.path, source: file.source }) }
    result := compileDoofWasmSourcesWithBindings(sources, "/main.do", (path: string) => environment.load(path), true, options)
    case result {
      success: Success<WasmCompilationArtifacts> -> {
        fixture.wasmHex = encodeWasmHex(success.value.bytes)
        fixture.bindings = success.value.bindings
      }
      failure: Failure<string> -> { fixture.diagnostic = failure.error }
    }
    references.push(fixture.toSerialObject())
  }
  _ := writeText(arguments[0], formatJsonValue(references.cloneReadonly())) else { println("could not write " + arguments[0]); return 1 }
  println("native references: " + string(fixtures.length))
  return 0
}
