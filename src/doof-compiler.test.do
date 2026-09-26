import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { compileDoofWasmSources, lowerDoofWasmSources } from "./doof-compiler"
import { MinusModule } from "./minus-ir"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function runWasm(bytes: byte[], name: string, script: string): none {
  path := "/tmp/doof-wasm-arrays-" + string(pid()) + "-" + name + ".wasm"
  try! writeBlob(path, bytes.cloneReadonly())
  result := try! run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  _ := remove(path) else { panic("Could not remove temporary Wasm file") }
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

function runSourceWithBindings(source: string, name: string, script: string): none {
  module_ := try! lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  bytes := try! encodeDoofMinus(module_, true)
  wasmPath := "/tmp/doof-source-arrays-" + string(pid()) + "-" + name + ".wasm"
  jsPath := "/tmp/doof-source-arrays-" + string(pid()) + "-" + name + ".mjs"
  try! writeBlob(wasmPath, bytes.cloneReadonly())
  try! writeText(jsPath, renderDoofJs(module_, true))
  result := try! run("node", ["-e", `
const fs = require('fs'), assert = require('assert'), {pathToFileURL} = require('url');
(async () => {
  const ffi = await import(pathToFileURL(process.argv[2]).href);
  const bytes = fs.readFileSync(process.argv[1]);
  ${script}
})().catch(error => { console.error(error); process.exit(1); });
`, wasmPath, jsPath], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  _ := remove(wasmPath) else { panic("Could not remove temporary Wasm file") }
  _ := remove(jsPath) else { panic("Could not remove temporary JavaScript file") }
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

function repeatedArrayElements(element: string, length: int): string {
  let elements = ""
  for index of 0..<length {
    if index > 0 { elements += "," }
    elements += element
  }
  return elements
}

export function testHostStringImportsAndGeneratedBindingsEndToEnd(): none {
  sources := [SourceFile {
    path: "/main.do",
    source: "import function println(value: string): none\nimport function echo(value: string): string\nexport function callHost(value: string): string { println(value)\nreturn echo(value) }\nexport function literal(): string => \"ready\"",
  }]
  lowered := lowerDoofWasmSources(sources, "/main.do")
  let module_: MinusModule | none = none
  case lowered {
    success: Success<MinusModule> -> { module_ = success.value }
    failure: Failure<string> -> { panic(failure.error) }
  }
  bytes := try! encodeDoofMinus(module_!, true)
  wasmPath := "/tmp/doof-host-ffi-" + string(pid()) + ".wasm"
  jsPath := "/tmp/doof-host-ffi-" + string(pid()) + ".mjs"
  try! writeBlob(wasmPath, bytes.cloneReadonly())
  try! writeText(jsPath, renderDoofJs(module_!, true))
  result := try! run("node", ["-e", `const fs=require('fs');const {pathToFileURL}=require('url');(async()=>{const ffi=await import(pathToFileURL(process.argv[2]).href);let printed='';let debug=null;const host=ffi.createDoofImports({println:value=>{printed=value;const heap=debug.dumpHeap();if(!heap.some(block=>block.kind==='string'&&block.value===value)||!heap.some(block=>block.kind==='char-array'&&block.value===value)||!heap.some(block=>block.kind==='array-data'&&block.length===value.length))throw new Error('idiomatic string/array heap view missing')},echo:value=>value+'!'});const {instance}=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]),host.imports);host.attach(instance);debug=ffi.createDoofHeapInspector(instance);const api=ffi.createDoofModule(instance);if(api.callHost('hello')!=='hello!'||api.literal()!=='ready'||printed!=='hello')process.exit(1)})().catch(error=>{console.error(error);process.exit(2)});`, wasmPath, jsPath], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  _ := remove(wasmPath) else { panic("Could not remove temporary Wasm file") }
  _ := remove(jsPath) else { panic("Could not remove temporary JavaScript file") }
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

export function testLowersImportedModulesAndDisambiguatesNames(): none {
  result := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source: "import { same as first, Item as First } from \"./one\"\nimport { same as second, Item as Second } from \"./two\"\nfunction useFirst(value: First): First => value\nfunction useSecond(value: Second): Second => value\nexport function main(): int => first() + second()" },
    SourceFile { path: "/one.do", source: "export class Item { value: int }\nexport function same(): int => 1" },
    SourceFile { path: "/two.do", source: "export class Item { value: int }\nexport function same(): int => 2" },
  ], "/main.do")
  case result {
    success: Success<MinusModule> -> {
      Assert.equal(success.value.functions.length, 5)
      Assert.equal(success.value.functions[2].exported, true)
      Assert.equal(success.value.functions[2].exportName, "main")
      Assert.equal(success.value.functions[3].name == success.value.functions[4].name, false)
      Assert.equal(success.value.functions[3].exported || success.value.functions[4].exported, false)
      Assert.equal(success.value.functions[0].sourcePath, "/main.do")
      Assert.equal(success.value.functions[3].sourcePath, "/one.do")
      Assert.equal(success.value.functions[2].blocks[0].instructions[0].sourcePath, "/main.do")
      Assert.equal(success.value.functions[2].blocks[0].instructions[0].line, 5)
      Assert.equal(success.value.classes.length, 2)
      Assert.equal(success.value.classes[0].name == success.value.classes[1].name, false)
      Assert.equal(success.value.functions[0].params[0].typeName == success.value.classes[0].name, true)
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
}

export function testCompilesImportedFunctionGraph(): none {
  result := compileDoofWasmSources([
    SourceFile { path: "/main.do", source: "import { answer } from \"./lib\"\nexport function main(): int => answer()" },
    SourceFile { path: "/lib.do", source: "export function answer(): int => 42" },
  ], "/main.do")
  case result {
    success: Success<byte[]> -> { Assert.isTrue(success.value.length > 8) }
    failure: Failure<string> -> { panic(failure.error) }
  }
}

export function testLowersAndExecutesResultArmsAsDoofMinusClasses(): none {
  source := "export function successValue(): int { result: Result<int, int> := Success { value: 40 }\ncase result { value: Success<int> -> { return value.value }, error: Failure<int> -> { return error.error } } }\n" +
    "export function failureValue(): int { result: Result<int, int> := Failure { error: 2 }\ncase result { value: Success<int> -> { return value.value }, error: Failure<int> -> { return error.error } } }\n" +
    "export function main(): int => successValue() + failureValue()"
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  case lowered {
    success: Success<MinusModule> -> {
      Assert.equal(success.value.classes.length, 2)
      Assert.equal(success.value.classes[0].name, "__doof_result_success")
      Assert.equal(success.value.classes[0].fields[0].name, "value")
      Assert.equal(success.value.classes[0].fields[0].typeName, "any")
      Assert.equal(success.value.classes[1].name, "__doof_result_failure")
      Assert.equal(success.value.classes[1].fields[0].name, "error")
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
  bytes := try! compileDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  runWasm(bytes, "result-arms", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.successValue()!==40||e.failureValue()!==2||e.main()!==42)throw new Error("Result arm lowering returned the wrong payload")`)
}

export function testLowersAndExecutesClosureWithImmutableCapture(): none {
  source := "function makeAdder(base: int): (value: int): int => (value: int): int => base + value\n" +
    "export function main(): int { add := makeAdder(40)\nreturn add(2) }"
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  case lowered {
    success: Success<MinusModule> -> {
      let foundInterface = false
      let foundInvoke = false
      for interface_ of success.value.interfaces { if interface_.name == "__closure_int_int" { foundInterface = true } }
      for function_ of success.value.functions { if function_.name.endsWith(".invoke") { foundInvoke = true } }
      Assert.isTrue(foundInterface)
      Assert.isTrue(foundInvoke)
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
  bytes := try! compileDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  runWasm(bytes, "closure-capture", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw new Error("Captured closure returned the wrong value")`)
}

export function testLowersAndExecutesEscapingClosureWithReferenceCapture(): none {
  source := "class Box { value: int }\n" +
    "function makeReader(): (): int { box := Box { value: 42 }\nreturn (): int => box.value }\n" +
    "export function main(): int { read := makeReader()\nreturn read() }"
  bytes := try! compileDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  runWasm(bytes, "closure-reference-capture", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw new Error("Escaping closure lost its captured object")`)
}

export function testLowersTwoArgumentStringClosureSignature(): none {
  source := "function makeText(text: string): (left: int, right: int): string => (left: int, right: int): string => text\n" +
    "export function main(): int { callback := makeText(\"ready\")\nresult := callback(1, 2)\nreturn result.length }"
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  case lowered {
    success: Success<MinusModule> -> {
      let found = false
      for interface_ of success.value.interfaces { if interface_.name == "__closure_string_int_int" { found = true } }
      Assert.isTrue(found)
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
  bytes := try! compileDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  runWasm(bytes, "closure-signature", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.main()!==5)throw new Error("Two argument string closure returned the wrong value")`)
}

export function testLowersMutableClosureCapture(): none {
  source := "export function main(): int { let value = 40\nstep := (): int => { value = value + 1\nreturn value }\nvalue = 50\ninside := step()\nreturn value + inside }"
  result := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source },
  ], "/main.do")
  case result {
    success: Success<MinusModule> -> {
      let foundCell = false
      let foundCellRead = false
      let foundCellWrite = false
      for function_ of success.value.functions {
        for block of function_.blocks {
          for instruction of block.instructions {
            if instruction.op == "box" && instruction.args.length == 2 { foundCell = true }
            if instruction.op == "get" && instruction.args.length == 2 && instruction.args[1] == "value" { foundCellRead = true }
            if instruction.op == "set" && instruction.args.length == 3 && instruction.args[1] == "value" { foundCellWrite = true }
          }
        }
      }
      Assert.isTrue(foundCell)
      Assert.isTrue(foundCellRead)
      Assert.isTrue(foundCellWrite)
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
  bytes := try! compileDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  runWasm(bytes, "mutable-closure-capture", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.main()!==102)throw new Error("Mutable closure capture did not share its boxed value")`)
}

export function testLowersImportedIntegerEnums(): none {
  result := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source: "import { Kind, getKind } from \"./kinds\"\nexport function main(): int => getKind().value" },
    SourceFile { path: "/kinds.do", source: "export enum Kind { First = 2, Last = 9 }\nexport function getKind(): Kind => Kind.Last\nexport function isKind(value: int | Kind | none): bool { case value { _: Kind -> { return true }, _: int -> { return false }, none -> { return false } } }" },
  ], "/main.do")
  case result {
    success: Success<MinusModule> -> {
      Assert.equal(success.value.enums.length, 1)
      let found = false
      for function_ of success.value.functions {
        if function_.sourcePath == "/kinds.do" {
          for block of function_.blocks {
            for instruction of block.instructions {
              if instruction.op == "const" && instruction.args[0] == "9" { found = true }
            }
          }
        }
      }
      Assert.isTrue(found)
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
}

export function testLowersByteArrayToOnDemandWrapperAndTypedOperations(): none {
  result := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source: "export function main(): int { values: byte[] := [1, 2, 255]\nvalues[1] = 9\nreturn int(values[0]) + int(values[1]) + int(values[2]) + values.length }" },
  ], "/main.do")
  case result {
    success: Success<MinusModule> -> {
      Assert.equal(success.value.classes.length, 1)
      Assert.equal(success.value.classes[0].name, "__doof_array_byte")
      Assert.equal(success.value.classes[0].finalizer, "__doof_array_byte.destroy")
      let sawAlloc = false
      let sawMethodSet = false
      let sawMethodGet = false
      let sawMethodLength = false
      for instruction of success.value.functions[0].blocks[0].instructions {
        if instruction.op == "array-alloc" { sawAlloc = true }
        if instruction.op == "call-method" && instruction.args.length > 1 && instruction.args[1] == "set" { sawMethodSet = true }
        if instruction.op == "call-method" && instruction.args.length > 1 && instruction.args[1] == "get" { sawMethodGet = true }
        if instruction.op == "call-method" && instruction.args.length > 1 && instruction.args[1] == "length" { sawMethodLength = true }
      }
      Assert.isTrue(sawAlloc)
      Assert.isTrue(sawMethodSet)
      Assert.isTrue(sawMethodGet)
      Assert.isTrue(sawMethodLength)
      let wrapperUsesOps = false
      for function_ of success.value.functions {
        if function_.name == "__doof_array_byte.get" { for instruction of function_.blocks[0].instructions { if instruction.op == "array-get" { wrapperUsesOps = true } } }
      }
      Assert.isTrue(wrapperUsesOps)
    }
    failure: Failure<string> -> { panic(failure.error) }
  }
}

export function testExecutesByteArrayReadsWritesBoundsAndFinalRelease(): none {
  bytes := try! compileDoofWasmSources([
    SourceFile { path: "/main.do", source: "export function main(): int { values: byte[] := [1, 2, 255]\nvalues[1] = 9\nreturn int(values[0]) + int(values[1]) + int(values[2]) + values.length }\nexport function bounds(): int { values: byte[] := [7]\nreturn int(values[2]) }" },
  ], "/main.do")
  runWasm(bytes, "byte-array", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;for(let i=0;i<1000;i++)if(e.main()!==268)process.exit(1);try{e.bounds();process.exit(2)}catch(x){if(!(x instanceof WebAssembly.RuntimeError))process.exit(3)}`)
}

export function testArraySourceChunkingAndPrimitiveAndEnumElements(): none {
  let values = ""
  for index of 0..<1025 {
    if index > 0 { values += "," }
    values += "0"
  }
  tooLong := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source: "function main(): none { values: byte[] := [" + values + "] }" },
  ], "/main.do")
  case tooLong {
    failure: Failure<string> -> { Assert.fail("Expected an oversized byte[] literal to lower: " + failure.error) }
    _ -> { }
  }
  bytes := try! compileDoofWasmSources([
    SourceFile { path: "/main.do", source: "enum Kind { First = 2, Last = 9 }\nexport function primitivePart(): int { values: int[] := [1, 2, 3]\nvalues[1] = 7\nreturn values[0] + values[1] + values[2] + values.length }\nexport function enumPart(): int { kinds: Kind[] := [Kind.First, Kind.Last]\nkinds[0] = Kind.Last\nreturn kinds[0].value + kinds[1].value + kinds.length }\nexport function main(): int { return primitivePart() + enumPart() }" },
  ], "/main.do")
  runWasm(bytes, "primitive-enum-arrays", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;const actual=e.main();if(actual!==34)throw new Error("expected 34, got "+actual)`)
}

export function testSourceArraysAllSupportedWidthsThroughBindingsAndDestruction(): none {
  types := ["bool", "char", "byte", "int", "float", "long", "double", "Kind"]
  initial := ["false", "'a'", "byte(1)", "-1234567", "float(1.25)", "9007199254740993L", "3.125", "Kind.First"]
  replacement := ["true", "'z'", "byte(255)", "1234567", "float(2.5)", "9007199254740995L", "6.25", "Kind.Last"]
  for typeIndex of 0..<types.length {
    typeName := types[typeIndex]
    width := if typeIndex < 3 then 1 else if typeName == "long" || typeName == "double" then 8 else 4
    capacity := 1024 \ width
    let source = `
import function checkpoint(length: int): none
enum Kind { First = 2, Last = 9 }
function verify(values: ${typeName}[], length: int): bool {
  if values.length != length { return false }
  for value of values { if value != ${initial[typeIndex]} { return false } }
  if length > 0 {
    values[0] = ${replacement[typeIndex]}
    values[length - 1] = ${replacement[typeIndex]}
    if values[0] != ${replacement[typeIndex]} { return false }
    if values[length - 1] != ${replacement[typeIndex]} { return false }
  }
  if length > ${capacity} {
    values[${capacity - 1}] = ${replacement[typeIndex]}
    values[${capacity}] = ${replacement[typeIndex]}
    if values[${capacity - 1}] != ${replacement[typeIndex]} { return false }
    if values[${capacity}] != ${replacement[typeIndex]} { return false }
  }
  checkpoint(length)
  return true
}
`
    for length of [0, capacity, capacity + 1, capacity * 2, capacity * 2 + 1] {
      elements := repeatedArrayElements(initial[typeIndex], length)
      source += `
function make_${length}(): ${typeName}[] { values: ${typeName}[] := [${elements}]
  return values }
export function case_${length}(): bool => verify(make_${length}(), ${length})
`
    }
    source += `
export function bounds(index: int): ${typeName} { values := make_${capacity + 1}()
  return values[index] }
export function writeBounds(index: int): none { values := make_${capacity + 1}()
  values[index] = ${replacement[typeIndex]} }
export function readonlyArray(): bool {
  readonly values: ${typeName}[] = [${repeatedArrayElements(initial[typeIndex], capacity + 1)}]
  for value of values { if value != ${initial[typeIndex]} { return false } }
  return values.length == ${capacity + 1}
}
`
    runSourceWithBindings(source, "width-" + typeName, `
let heap, calls = 0;
const bridge = ffi.createDoofImports({checkpoint(length) {
  calls++;
  const blocks = heap.dumpHeap();
  const raw = blocks.find(block => (block.kind === 'array-data' || block.kind === 'array-descriptor') && block.length === length);
  assert(raw, 'source array must be visible while its wrapper is alive');
  assert.strictEqual(raw.kind, length <= ${capacity} ? 'array-data' : 'array-descriptor');
  if (length > ${capacity}) assert.strictEqual(raw.chunkCount, Math.ceil(length / ${capacity}));
}});
const {instance} = await WebAssembly.instantiate(bytes, bridge.imports); bridge.attach(instance);
heap = ffi.createDoofHeapInspector(instance);
const api = ffi.createDoofModule(instance);
for (const length of [0,${capacity},${capacity + 1},${capacity * 2},${capacity * 2 + 1}]) {
  assert.strictEqual(api['case_'+length](), true);
  assert(heap.dumpHeap().every(block => block.kind === 'free'), 'wrappers and data must be destroyed');
  const end = instance.exports.__doof_debug_heap_end.value;
  for (let repeat = 0; repeat < 10; repeat++) assert.strictEqual(api['case_'+length](), true);
  assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'repeated source calls must reuse storage');
}
assert.strictEqual(calls,55);
assert.strictEqual(api.readonlyArray(),true);
assert(heap.dumpHeap().every(block => block.kind === 'free'));
// Trapping calls use separate instances: Wasm traps do not unwind reference locals.
for (const name of ['bounds','writeBounds']) for (const index of [-1,${capacity + 1}]) {
  const other = await WebAssembly.instantiate(bytes, bridge.imports);
  assert.throws(() => ffi.createDoofModule(other.instance)[name](index), WebAssembly.RuntimeError);
}
`)
  }
}

export function testSourceReferenceArraysAndNestedArraysThroughBindings(): none {
  types := ["Box", "HasValue", "Box | int | none", "int[]", "string"]
  declarations := ["item := Box { value: 7 }", "item := Box { value: 7 }", "item := Box { value: 7 }", "item: int[] := [" + repeatedArrayElements("7", 257) + "]", "item := \"first\""]
  replacement := ["Box { value: 99 }", "Box { value: 99 }", "99", "[" + repeatedArrayElements("99", 257) + "]", "\"last\""]
  readInitial := ["values[index].value", "values[index].value", "read(values[index])", "values[index][0]", "values[index].length"]
  readChanged := ["values[0].value", "values[0].value", "read(values[0])", "values[0][0]", "values[0].length"]
  readNeighbor := ["values[2].value", "values[2].value", "read(values[2])", "values[2][0]", "values[2].length"]
  readAssigned := ["assigned.value", "assigned.value", "assigned", "assigned[0]", "assigned.length"]
  for typeIndex of 0..<types.length {
    typeName := types[typeIndex]
    let source = `
import function checkpoint(): none
interface HasValue { value: int }
class Box implements HasValue { value: int }
function read(value: Box | int | none): int {
  case value { box: Box -> { return box.value }, number: int -> { return number }, none -> { return -1 } }
}

function verify(values: (${typeName})[], length: int): bool {
  if values.length != length { return false }
  for index of 0..<length { if ${readInitial[typeIndex]} != ${if typeName == "string" then 5 else 7} { return false } }
  assigned := values[0] = ${replacement[typeIndex]}
  if ${readAssigned[typeIndex]} != ${if typeName == "string" then 4 else 99} { return false }
  values[length - 1] = values[0]
  values[0] = values[0]
  if ${readChanged[typeIndex]} != ${if typeName == "string" then 4 else 99} { return false }
  if ${readNeighbor[typeIndex]} != ${if typeName == "string" then 5 else 7} { return false }
  checkpoint()
  return true
}
`
    for length of [4, 257, 513] {
      elements := repeatedArrayElements("item", length)
      source += `
function make_${length}(): (${typeName})[] { ${declarations[typeIndex]}
  values: (${typeName})[] := [${elements}]
  return values }
export function case_${length}(): bool => verify(make_${length}(), ${length})
`
    }
    if typeIndex == 2 {
      source += `
export function unionNone(): int {
  values: (Box | int | none)[] := [none, 1, Box { value: 7 }]
  values[1] = none
  return read(values[0]) + read(values[1])
}
`
    }
    runSourceWithBindings(source, "references-" + string(typeIndex), `
let heap, calls = 0;
const bridge = ffi.createDoofImports({checkpoint() {
  calls++;
  assert(heap.dumpHeap().some(block => block.kind === 'class' && block.fields.data), 'array wrapper must be alive');
}});
const {instance} = await WebAssembly.instantiate(bytes, bridge.imports); bridge.attach(instance);
heap = ffi.createDoofHeapInspector(instance); const api = ffi.createDoofModule(instance);
function live() { return heap.dumpHeap().filter(block => block.kind !== 'free').map(block => [block.address,block.kind,block.refCount]); }
const baseline = live();
for (const length of [4,257,513]) {
  assert.strictEqual(api['case_'+length](),true);
  assert.deepStrictEqual(live(),baseline,'only pooled string literals may remain alive');
  const end = instance.exports.__doof_debug_heap_end.value;
  for (let repeat = 0; repeat < 30; repeat++) {
    assert.strictEqual(api['case_'+length](),true);
    assert.deepStrictEqual(live(),baseline,'reference elements and nested wrappers must be released');
  }
  assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'reference arrays must reuse storage');
}
assert.strictEqual(calls,93);
if (api.unionNone) { assert.strictEqual(api.unionNone(),-2); assert.deepStrictEqual(live(),baseline); }
`)
  }
}

export function testOptionalArrayOwnerCallsAndCoalescing(): none {
  bytes := try! compileDoofWasmSources([SourceFile { path: "/main.do", source: `
class Box { values: int[]
  value: int
  count(): int => this.values.length }
function count(box: Box | none): int => box?.count() ?? 0
function value(box: Box | none): int => box?.value ?? 0
export function main(): int {
  box := Box { values: [7, 8], value: 7 }
  return count(box) + count(none) + value(box) + value(none)
}

` }], "/main.do")
  runWasm(bytes, "optional-array-owner", `const e=new WebAssembly.Instance(new WebAssembly.Module(require('fs').readFileSync(process.argv[1]))).exports;require('assert').strictEqual(e.main(),9);`)
}
