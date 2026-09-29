import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { lowerDoofWasmSource, WasmLoweringOptions } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { renderDoofJs } from "./minus-js"

function runSelfHostingSource(source: string, script: string, options: WasmLoweringOptions = WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true }): none {
  module_ := lowerDoofWasmSource(source, options) else error { panic(error) }
  bytes := try! encodeDoofMinus(module_, true)
  base := "/tmp/doof-self-hosting-mode-" + string(pid())
  try! writeBlob(base + ".wasm", bytes.cloneReadonly())
  try! writeText(base + ".mjs", renderDoofJs(module_, true))
  result := try! run("node", ["-e", `
const fs=require('fs'),assert=require('assert'),{pathToFileURL}=require('url');
(async()=>{
const ffi=await import(pathToFileURL(process.argv[1]+'.mjs').href);
const {instance}=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]+'.wasm'));
const api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
${script}
})().catch(error=>{console.error(error);process.exit(1)});
`, base], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  try! remove(base + ".wasm")
  try! remove(base + ".mjs")
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

export function testSelfHostingModeStructsAreOptInAndImmutable(): none {
  source := `
struct Location { line: int; column: int }
struct Span { start: Location; end: Location }
function offset(span: Span): int => span.start.line + span.end.column
export function check(): int {
  location := Location { line: 20, column: 2 }
  values := [Span { start: location, end: location }]
  alias := values[0]
  return offset(alias)
}
`
  case lowerDoofWasmSource(source) {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "structs are not supported") }
    _ -> { Assert.fail("Struct support must be opt-in") }
  }
  case lowerDoofWasmSource("struct Mutable { let value: int }\nexport function check(): int => 0", WasmLoweringOptions { boxImmutableStructs: true }) {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "requires immutable struct fields") }
    _ -> { Assert.fail("Boxing mutable structs would change copy semantics") }
  }
  runSelfHostingSource(source, `
const baseline=live();for(let i=0;i<30;i++)assert.strictEqual(api.check(),22);assert.deepStrictEqual(live(),baseline);
`, WasmLoweringOptions { boxImmutableStructs: true })
}

export function testSelfHostingModeAsyncIsOptInAndEager(): none {
  source := `
isolated function calculate(value: int): int => value + 1
export function check(value: int): int {
  promise := async calculate(value)
  first := try! promise.get()
  second := try! promise.get()
  block := async { local := value + 2; yield local * 2 }
  third := try! block.get()
  return first + second + third
}
`
  case lowerDoofWasmSource(source) {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "not supported") }
    _ -> { Assert.fail("Async support must be opt-in") }
  }
  runSelfHostingSource(source, `
const baseline=live();for(let i=0;i<30;i++)assert.strictEqual(api.check(i),4*i+6);assert.deepStrictEqual(live(),baseline);
`, WasmLoweringOptions { synchronousAsync: true })
}

export function testSelfHostingModePromisesConsumeInOrderAndCapturePanics(): none {
  runSelfHostingSource(`
class Work { value: int }
function fail(value: int): int {
  work := Work { value }
  data := [work,Work { value: value + 1 }]
  if data.length == 2 { panic("parse failed") }
  return 0
}
function calculate(value: int): int => value + 1
export function queue(): string {
  let pending: Promise<int>[] = []
  pending.push(async calculate(10))
  pending.push(async fail(0))
  pending.push(async { yield 30 })
  alias := pending
  first := try! pending.takeFirstCompleted()
  second := pending.takeFirstCompleted() else error {
    third := try! alias.takeFirstCompleted()
    empty := pending.takeFirstCompleted() else missing {
      return string(first) + ":" + error + ":" + string(third) + ":" + string(alias.length) + ":" + missing
    }
    return "expected empty queue"
  }
  return "expected failed job"
}
export function caught(): string {
  result := catchPanic(=> fail(0))
  value := result else message { return message }
  return string(value)
}
`, `
const expected='11:parse failed:30:0:takeFirstCompleted called on an empty array';
const baseline=live();
for(let i=0;i<30;i++){assert.strictEqual(api.queue(),expected);assert.strictEqual(api.caught(),'parse failed')}
assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingModeNestedJobsAndEscapedPanics(): none {
  runSelfHostingSource(`
class Value { text: string }
function unit(): none { value := Value { text: "temporary" } }
function fail(): int { value := Value { text: "temporary" }; if value.text.length > 0 { panic("escaped failure") } return 0 }
export function check(): string {
  completed := async unit()
  _ := try! completed.get()
  nested := async { inner := async { yield Value { text: "nested" } }; yield try! inner.get() }
  value := try! nested.get()
  failed := async fail()
  first := failed.get() else message {
    second := failed.get() else repeated { return value.text + ":" + message + ":" + repeated }
    return "expected repeated failure"
  }
  return "expected failure"
}
export function escaped(): int => fail()
`, `
const baseline=live();
for(let i=0;i<30;i++){
assert.strictEqual(api.check(),'nested:escaped failure:escaped failure');
assert.throws(()=>api.escaped(),/escaped failure/);
}
assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingModeNamedCallbacksReleaseOnPanic(): none {
  runSelfHostingSource(`
readonly MESSAGES = ["callback failed"]
class Work { text: string }
function fail(value: Work): int { panic(value.text) }
function apply(callback: (value: Work): int): int => callback(Work { text: MESSAGES[0] })
export function caught(): string {
  result := catchPanic(=> apply(fail))
  value := result else message { return message }
  return string(value)
}
export function escaped(): int => apply(fail)
`, `
const baseline=live();for(let i=0;i<30;i++){
assert.strictEqual(api.caught(),'callback failed');assert.throws(()=>api.escaped(),/callback failed/);
}assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingModeMinusMetadataRoundTrip(): none {
  text := `recover_panics
capture func capture(%message:__doof_string) -> any
block entry
panic %message
end
`
  parsed := try! parseDoofMinus(text)
  Assert.equal(parsed.recoverPanics, true)
  Assert.equal(parsed.functions[0].capturePanics, true)
  Assert.equal(renderDoofMinus(parsed), text)
}

export function testSelfHostingModeSharedUnionFieldsReleaseOnPanic(): none {
  runSelfHostingSource(`
class First { let kind: string = "first"; values: string[] = ["temporary"] }
class Second { values: string[] = ["temporary"]; let kind: string = "second" }
function read(value: First | Second | none): string => value!.kind
function present(value: First | Second | none): First | Second => value!
function ordinary(value: First | none): string => value!.kind
function write(value: First | Second | none, text: string): none { value!.kind = text }
export function writePanic(rhs: bool): string {
  allocated := [Second {}, Second {}]
  value: First | Second | none := if rhs then First {} else none
  result := catchPanic(=> { write(value, if rhs then panic("rhs") else "temporary" + string(42)); return "ok" })
  completed := result else message { return message }
  return completed
}
export function single(ready: bool): string {
  allocated := [Second {}, Second {}]
  value := catchPanic(=> ordinary(if ready then First {} else none)) else message { return message }
  return value
}
export function caught(postfix: bool): string {
  allocated := [First {}, First {}]
  result := catchPanic(=> if postfix then present(none).kind else read(none))
  value := result else message { return message }
  return value
}
export function escaped(flag: bool): string {
  allocated := [Second {}, Second {}]
  return read(if flag then First {} else none)
}
`, `
const baseline=live();for(let i=0;i<30;i++){
assert.strictEqual(api.caught(false),'Nullable forced unwrap failed');
assert.strictEqual(api.caught(true),'Nullable forced unwrap failed');
assert.strictEqual(api.escaped(true),'first');
assert.strictEqual(api.single(true),'first');
assert.strictEqual(api.single(false),'Nullable forced unwrap failed');
assert.strictEqual(api.writePanic(false),'Nullable forced unwrap failed');
assert.strictEqual(api.writePanic(true),'rhs');
assert.throws(()=>api.escaped(false),/Nullable forced unwrap failed/);
assert.deepStrictEqual(live(),baseline,'panic unwinds union receivers and caller references');
}
`)
}
