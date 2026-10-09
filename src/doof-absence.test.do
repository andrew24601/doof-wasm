import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { lowerDoofWasmSources, WasmLoweringOptions } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function checkSource(source: string, name: string, script: string, options: WasmLoweringOptions = WasmLoweringOptions {}): none {
  module_ := lowerDoofWasmSources{sources: [SourceFile { path: "/main.do", source }], entry: "/main.do", options}!
  wasmPath := "/tmp/doof-control-" + string(pid()) + "-" + name + ".wasm"
  jsPath := "/tmp/doof-control-" + string(pid()) + "-" + name + ".mjs"
  writeBlob(wasmPath, (encodeDoofMinus(module_, true)!).cloneReadonly())!
  writeText(jsPath, renderDoofJs(module_, true))!
  execution := run("node", ["-e", `
const fs = require('fs'), assert = require('assert'), {pathToFileURL} = require('url');
(async () => {
  const ffi = await import(pathToFileURL(process.argv[2]).href);
  const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[1]));
  const api = ffi.createDoofModule(instance), e = instance.exports;
  const heap = ffi.createDoofHeapInspector(instance);
  const live = () => heap.dumpHeap().filter(b => b.kind !== 'free').map(b => [b.address, b.kind, b.refCount]);
  const baseline = live();
  for (let repeat = 0; repeat < 20; repeat++) {
    ${script}
    assert.deepStrictEqual(live(), baseline, 'temporary references must be released');
  }
})().catch(error => { console.error(error); process.exit(1); });
`, wasmPath, jsPath], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
  remove(wasmPath)!
  remove(jsPath)!
  if execution.exitCode != 0 { println(BlobReader(execution.stdout).readString(long(execution.stdout.length))) }
  Assert.equal(execution.exitCode, 0)
}

export function testAbsenceOperatorsAcrossResultAndNoneLayers(): none {
  checkSource(`function value(mode: int): Result<int | none, string> | none {
  if mode == 0 { return none }
  if mode == 1 { return Failure("bad") }
  if mode == 2 { return Success(none) }
  return Success(42)
}
export function optional(mode: int): int => value(mode)? ?? 7
export function fallback(mode: int): int => value(mode) ?? 9
export function required(mode: int): int => value(mode)!
export function handled(mode: int): string {
  item := value(mode) else error { return error ?? "absent" }
  return string(item)
}
export function discarded(mode: int): int {
  let count = 1
  _ := value(mode) else { count += 10 }
  return count
}
export function unit(ok: bool): none {
  result: Result<none, string> := if ok then Success() else Failure("unit failure")
  result!
}
export function propagation(mode: int): int {
  value := propagating(mode) else { return 7 }
  return value
}
export function plainFallback(mode: int): int => successful(mode) ?? 9
function successful(mode: int): Result<int, string> => if mode == 0 then Failure("bad") else Success(42)
function propagating(mode: int): Result<int, string> {
  let answer = 0
  try answer = successful(mode)
  return Success(answer)
}
`, "absence-layers", `
for (let mode = 0; mode < 4; mode++) {
  assert.equal(e.optional(mode), mode === 3 ? 42 : 7);
  assert.equal(e.fallback(mode), mode === 3 ? 42 : 9);
  assert.equal(api.handled(mode), mode === 3 ? '42' : mode === 1 ? 'bad' : 'absent');
  assert.equal(e.discarded(mode), mode === 3 ? 1 : 11);
}
assert.equal(e.required(3), 42);
e.unit(true);
assert.equal(e.propagation(0), 7); assert.equal(e.propagation(1), 42);
assert.equal(e.plainFallback(0), 9); assert.equal(e.plainFallback(1), 42);
`)
}

export function testAbsenceResultOptionalAccessKeepsMemberFailure(): none {
  checkSource(`class Value {
  text: string
  profile(ok: bool): Result<string, string> => if ok then Success(text) else Failure("profile failure")
}
function load(mode: int): Result<Value | none, string> | none {
  if mode == 0 { return none }
  if mode == 1 { return Failure("load failure") }
  if mode == 2 { return Success(none) }
  return Success(Value { text: "ready" })
}
export function name(mode: int): string => load(mode)?.text ?? "absent"
export function member(mode: int, ok: bool): string {
  result := load(mode)?.profile(ok)
  case result { s: Success -> { return s.value ?? "absent" }, f: Failure -> { return f.error } }
}
export function index(mode: int): int {
  items: Result<int[] | none, string> := if mode == 0 then Failure("bad") else if mode == 1 then Success(none) else Success([42])
  let calls = 0
  next := (): int => { calls += 1; return 0 }
  value := items?[next()] ?? 7
  return value + calls
}
`, "absence-access", `
for (let mode = 0; mode < 4; mode++) {
  assert.equal(api.name(mode), mode === 3 ? 'ready' : 'absent');
  assert.equal(api.member(mode, true), mode === 3 ? 'ready' : 'absent');
  assert.equal(api.member(mode, false), mode === 3 ? 'profile failure' : 'absent');
}
assert.equal(e.index(0), 7); assert.equal(e.index(1), 7); assert.equal(e.index(2), 43);
`)
}

export function testAbsenceIntrinsicResultStructEquality(): none {
  checkSource(`function value(ok: bool): Result<string, string> => if ok then Success("same" + "!") else Failure("same" + "!")
export function compare(): bool {
  a: Result<string, string> := value(true)
  b: Result<string, string> := value(false)
  nested: Result<Result<string, string>, string> := Success(a)
  nestedAgain: Result<Result<string, string>, string> := Success(value(true))
  named := Success { value: 42 }
  failed := Failure {}
  arm: Success<int> | none := Success(42)
  return a == value(true) && a == Success("same!") && b == value(false) && b != a && Success(42) == Success(42) && Failure() == Failure() && nested == nestedAgain && arm == Success(42) && named.value == 42 && named == Success(42) && failed == Failure()
}
`, "result-equality", `assert.equal(e.compare(),1);`)
}

export function testAbsenceForcedUnwrapPanicsAndCleansUpEveryLayer(): none {
  checkSource(`class Box { text: string }
function load(mode: int): Result<Box | none, string> | none {
  if mode == 0 { return none }
  if mode == 1 { return Failure("specific error") }
  if mode == 2 { return Success(none) }
  return Success(Box { text: "ready" })
}
export function captured(mode: int): string {
  result := catchPanic(=> load(mode)!.text)
  value := result else error { return error }
  return value
}
`, "absence-panic", `
for(let mode = 0; mode < 3; mode++) {
  const message = api.captured(mode);
  assert.ok(message.startsWith('/main.do:'));
  assert.ok(message.includes('forced unwrap failed'));
  assert.equal(message.includes('specific error'), mode === 1);
}
assert.equal(api.captured(3), 'ready');
`, WasmLoweringOptions { synchronousAsync: true })
}

export function testAbsenceRemovedPrefixFormsHaveActionableDiagnostics(): none {
  for operator of ["try!", "try?"] {
    source := "export function value(): int { result: Result<int, string> := Success(42); value := " + operator + " result; return 0 }"
    checked := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
    case checked {
      failure: Failure -> { Assert.stringContains(failure.error, "was removed"); Assert.stringContains(failure.error, "write 'value" + operator.substring(3) + "'") }
      _ -> { Assert.fail("Removed prefix forms must be rejected") }
    }
  }
}
