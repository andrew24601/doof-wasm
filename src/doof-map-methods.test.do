import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { lowerDoofWasmSources, WasmLoweringOptions } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function checkMaps(sources: SourceFile[], script: string, options: WasmLoweringOptions = WasmLoweringOptions {}): none {
  module_ := lowerDoofWasmSources{sources, entry: "/main.do", options} else error { panic(error) }
  bytes := try! encodeDoofMinus(module_, true)
  base := "/tmp/doof-map-methods-" + string(pid())
  try! writeBlob(base + ".wasm", bytes.cloneReadonly())
  try! writeText(base + ".mjs", renderDoofJs(module_, true))
  result := try! run("node", ["-e", `
const fs=require('fs'),assert=require('assert'),{pathToFileURL}=require('url');
(async()=>{
const ffi=await import(pathToFileURL(process.argv[1]+'.mjs').href);
const {instance}=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]+'.wasm'));
const api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
${script}
})().catch(error=>{console.error(error);process.exit(1)});
`, base], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  try! remove(base + ".wasm")
  try! remove(base + ".mjs")
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

export function testCompilerCacheMapsShareAliasesAndCompareStringContents(): none {
  checkMaps([
    SourceFile { path: "/cache.do", source: `
export class JsonEligibilityCache {
  serialization: Map<string, bool> = {}
  deserialization: Map<string, bool> = {}
}
export function read(values: Map<string, bool>, key: string): bool => try! values.get(key)
` },
    SourceFile { path: "/main.do", source: `
import { JsonEligibilityCache, read } from "./cache"
function make(): Map<string, bool> => { first: true, second: false }
export function check(key: string): bool {
  cache := JsonEligibilityCache {}
  alias := cache.serialization
  if alias.size != 0 || alias.has(key) { return false }
  case alias.get(key) {
    error: Failure<string> -> { if error.error != "Map key not found" { return false } }
    _ -> { return false }
  }
  cache.serialization.set(key, true)
  if !alias.has("" + key) || !read(alias, "" + key) { return false }
  alias.set("" + key, false)
  if cache.serialization.size != 1 || read(cache.serialization, key) { return false }
  if cache.deserialization.has(key) { return false }
  cache.deserialization.set(key, true)
  if !read(cache.deserialization, key) || read(alias, key) { return false }
  values := make()
  return values.size == 2 && read(values, "first") && !read(values, "second")
}
export function captured(): bool {
  values: Map<string, bool> := { ready: false }
  readValue := (): bool => try! values.get("ready")
  values.set("ready", true)
  return readValue()
}
export function nullable(): int {
  values: Map<string, bool> | none := make()
  return values!.size
}
export function readonlyRead(): bool {
  readonly values: Map<string, bool> = { ready: true }
  return values.size == 1 && values.has("ready") && (try! values.get("ready"))
}
export function nestedArrays(): bool {
  values: Map<string, bool>[][] := [[make()]]
  alias := values[0][0]
  alias.set("first", false)
  return !(try! values[0][0].get("first"))
}
function unused(values: Map<string, bool>[][]): none {}
` },
  ], `
for(const key of ['', 'same', 'a'.repeat(1025), 'a'.repeat(262145)]) {
  assert.strictEqual(api.check(key),true);
  assert.deepStrictEqual(live(),baseline,'cache keys and Results released');
}
for(let i=0;i<20;i++) {
  assert.strictEqual(api.check('repeat'),true);assert.strictEqual(api.captured(),true);assert.strictEqual(api.nullable(),2);assert.strictEqual(api.readonlyRead(),true);assert.strictEqual(api.nestedArrays(),true);
  assert.deepStrictEqual(live(),baseline,'aliases, captures, and nullable maps released');
}
`)
}

export function testMapStorageGrowthUpdatesAndResultFailuresReleaseAllKeys(): none {
  checkMaps([SourceFile { path: "/main.do", source: `
export function grow(length: int): bool {
  values: Map<string, bool> := {}
  alias := values
  for i of 0..<length { values.set("key-" + string(i), i % 2 == 0) }
  if alias.size != length { return false }
  for i of 0..<length {
    key := "key-" + string(i)
    if !alias.has(key) || (try! alias.get(key)) != (i % 2 == 0) { return false }
    alias.set(key, i % 2 != 0)
    if (try! values.get(key)) != (i % 2 != 0) { return false }
  }
  if values.size != length || values.has("missing") { return false }
  case values.get("missing") {
    error: Failure<string> -> { return error.error == "Map key not found" }
    _ -> { return false }
  }
}
export function failure(): string {
  values: Map<string, bool> := {}
  values.set("present", false)
  value := values.get("absent") else error { return error }
  return string(value)
}
` }], `
for(const length of [0,1,255,256,257,1023,1024,1025]) {
  assert.strictEqual(api.grow(length),true,'length '+length);
  assert.strictEqual(api.failure(),'Map key not found');
  assert.deepStrictEqual(live(),baseline,'map growth and failures release storage');
}
const end=instance.exports.__doof_debug_heap_end.value;
for(let i=0;i<3;i++){assert.strictEqual(api.grow(1025),true);assert.deepStrictEqual(live(),baseline);}
assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'freed map storage reused');
`)
}

export function testMissingMapForcedUnwrapCapturesPanicAndReleasesCache(): none {
  checkMaps([SourceFile { path: "/main.do", source: `
function fail(): bool {
  values: Map<string, bool> := {}
  values.set("owned key", true)
  return try! values.get("missing")
}
export function captured(): string {
  case catchPanic(=> fail()) {
    error: Failure<string> -> { return error.error }
    _ -> { return "unexpected success" }
  }
}
export function escaped(): bool => fail()
` }], `
for(let i=0;i<20;i++) {
  assert.strictEqual(api.captured(),'Result forced unwrap failed');
  assert.throws(()=>api.escaped(),/Result forced unwrap failed/);
  assert.deepStrictEqual(live(),baseline,'failed unwrap releases map, keys, and Result');
}
`, WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true })
}

export function testMapSubsetRetainsReadonlyChecksAndRejectsUnsupportedOperations(): none {
  sources := [
    "function check(): none { readonly values: Map<string, bool> = {}; values.set(\"x\", true) }",
    "class Cache { values: Map<string, int> = {} }",
    "function check(): none { values: Map<string, bool> := {}; values.delete(\"x\") }",
    "function check(): bool { values: Map<string, bool> := {}; return values[\"x\"] }",
    "function check(): none { values: Map<string, bool> := {}; values[\"x\"] = true }",
  ]
  messages := ["readonly", "unsupported field type", "Map method delete is not supported", "Map indexing is not supported", "Map indexing is not supported"]
  for index of 0..<sources.length {
    result := lowerDoofWasmSources([SourceFile { path: "/main.do", source: sources[index] }], "/main.do")
    case result {
      error: Failure<string> -> { Assert.stringContains(error.error, messages[index]) }
      _ -> { Assert.fail("Unsupported map operation must return a diagnostic") }
    }
  }
}

export function testMapTypesOnlyInNestedArraySignaturesHaveRuntimeDefinitions(): none {
  checkMaps([SourceFile { path: "/main.do", source: `
class Storage { values: Map<string, bool>[][] }
function unused(values: Map<string, bool>[][]): none {}
export function check(): bool => true
` }], `assert.strictEqual(api.check(),true);assert.deepStrictEqual(live(),baseline);`)
}
