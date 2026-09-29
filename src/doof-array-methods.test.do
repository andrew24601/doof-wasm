import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { lowerDoofWasmSources } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { MinusModule } from "./minus-ir"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofJs } from "./minus-js"

function checkArrays(source: string, name: string, script: string): none {
  module_ := try! lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  checkModule(module_, name, script)
}

function checkModule(module_: MinusModule, name: string, script: string): none {
  bytes := try! encodeDoofMinus(module_, true)
  path := "/tmp/doof-array-methods-" + string(pid()) + "-" + name
  try! writeBlob(path + ".wasm", bytes.cloneReadonly())
  try! writeText(path + ".mjs", renderDoofJs(module_, true))
  result := try! run("node", ["-e", `
const fs = require('fs'), assert = require('assert'), {pathToFileURL} = require('url');
(async () => {
  const ffi = await import(pathToFileURL(process.argv[2]).href);
  const bridge = ffi.createDoofImports({echo: value => value});
  const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[1]),bridge.imports); bridge.attach(instance);
  const api = ffi.createDoofModule(instance), heap = ffi.createDoofHeapInspector(instance);
  const live = () => heap.dumpHeap().filter(block => block.kind !== 'free').map(block => [block.address, block.kind, block.refCount]);
  const baseline = live();
  ${script}
})().catch(error => { console.error(error); process.exit(1); });
`, path + ".wasm", path + ".mjs"], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  try! remove(path + ".wasm")
  try! remove(path + ".mjs")
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

export function testPushAndContainsAllWidthsAcrossChunkAndRadixBoundaries(): none {
  types := ["bool", "byte", "char", "int", "long", "float", "double", "Choice"]
  first := ["false", "byte(7)", "'a'", "7", "7L", "7.0f", "7.0", "Choice.first"]
  last := ["true", "byte(99)", "'z'", "99", "99L", "99.0f", "99.0", "Choice.last"]
  capacities := [1024, 1024, 1024, 256, 128, 256, 128, 256]
  for index of 0..<types.length {
    checkArrays(`
enum Choice { first, last }
export function grow(length: int): bool {
  values: ${types[index]}[] := []
  alias := values
  if values.contains(${first[index]}) { return false }
  for let i = 0; i < length; i = i + 1 { values.push(${first[index]}) }
  if values.contains(${last[index]}) { return false }
  alias.push(${last[index]})
  if values.length != length + 1 { return false }
  if alias.length != values.length { return false }
  if values[length] != ${last[index]} { return false }
  if alias.contains(${last[index]}) == false { return false }
  for let j = 0; j < length; j = j + 1 { if values[j] != ${first[index]} { return false } }
  if length == 0 { return true }
  return values.contains(${first[index]})
}
`, "width-" + string(index), `
const capacity = ${capacities[index]};
for (const length of [0,1,15,16,17,capacity-1,capacity,capacity+1,2*capacity-1,2*capacity,2*capacity+1,256*capacity-1,256*capacity,256*capacity+1]) {
  assert.strictEqual(api.grow(length),true,'length '+length);
  assert.deepStrictEqual(live(),baseline,'all grown storage must be released at '+length);
}
const end = instance.exports.__doof_debug_heap_end.value;
assert.strictEqual(api.grow(256*capacity+1),true);
assert.deepStrictEqual(live(),baseline);
assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'growth must reuse freed blocks');
`)
  }
}

export function testPushAndContainsReferencesStringsNestedArraysAndUnions(): none {
  types := ["Box", "View", "int[]", "string", "Box | int | string | none"]
  values := ["Box { value: 7 }", "Box { value: 7 }", "[7]", "\"first\"", "Box { value: 7 }"]
  searches := ["item", "item", "item", "echo(\"first\")", "item"]
  missing := ["Box { value: 7 }", "Box { value: 7 }", "[7]", "\"missing\"", "Box { value: 7 }"]
  for index of 0..<types.length {
    checkArrays(`
import function echo(value: string): string
interface View { value: int }
class Box implements View { value: int }
export function grow(length: int): bool {
  values: (${types[index]})[] := []
  item := ${values[index]}
  for let i = 0; i < length; i = i + 1 { values.push(item) }
  if values.contains(${searches[index]}) == false { return false }
  if values.contains(${missing[index]}) { return false }
  values[0] = item
  return values.length == length
}
export function unions(): bool {
  values: (Box | int | string | none)[] := []
  values.push(none)
  values.push(7)
  values.push(echo("hello"))
  if values.contains(none) == false { return false }
  if values.contains(7) == false { return false }
  if values.contains("hello") == false { return false }
  return values.contains(8) == false
}
`, "reference-" + string(index), `
for (const length of [255,256,257,511,512,513,65535,65536,65537]) {
  assert.strictEqual(api.grow(length),true,'length '+length);
  assert.deepStrictEqual(live(),baseline,'references must survive migration and be released');
}
assert.strictEqual(api.unions(),true);
assert.deepStrictEqual(live(),baseline);
const end = instance.exports.__doof_debug_heap_end.value;
for (let i=0;i<3;i++) { assert.strictEqual(api.grow(65537),true); assert.strictEqual(api.unions(),true); assert.deepStrictEqual(live(),baseline); }
assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end);
`)
  }
}

export function testReadonlyArraysAllowContainsAndRejectPush(): none {
  checkArrays(`export function read(): bool { readonly values: int[] = [1, 2]; if values.contains(2) == false { return false }
 return values.contains(3) == false }`, "readonly", `assert.strictEqual(api.read(),true); assert.deepStrictEqual(live(),baseline);`)
  result := lowerDoofWasmSources([SourceFile { path: "/main.do", source: "function main(): none { readonly values: int[] = [1]; values.push(2) }" }], "/main.do")
  case result {
    failure: Failure<string> -> { Assert.isTrue(failure.error.contains("not available on readonly array")) }
    _: Success<MinusModule> -> { Assert.fail("Readonly arrays must reject push") }
  }
}

export function testPushAcrossUpperRadixBoundaryAndLengthOverflow(): none {
  module_ := try! parseDoofMinus(`
export func make(%length:int) -> int
block entry
%data:int = array-alloc %length,int
return %data
end
export func push(%data:int,%value:int) -> int
block entry
%grown:int = array-push %data,%value
return %grown
end
export func read(%data:int,%index:int) -> int
block entry
%value:int = array-get %data,%index
return %value
end
export func write(%data:int,%index:int,%value:int) -> none
block entry
array-set %data,%index,%value
return
end
export func drop(%data:int) -> none
block entry
array-free %data
return
end
`)
  checkModule(module_, "upper-radix", `
const length = 65536*256;
for (let repeat=0;repeat<2;repeat++) {
  const data=api.make(length);
  api.write(data,0,7); api.write(data,length-1,42);
  const grown=api.push(data,99);
  assert.strictEqual(grown,data,'descriptor must stay in place at upper radix boundary');
  assert.strictEqual(api.read(grown,0),7);
  assert.strictEqual(api.read(grown,length-1),42);
  assert.strictEqual(api.read(grown,length),99);
  api.drop(grown);
  assert.deepStrictEqual(live(),baseline);
  if(repeat===0) var end=instance.exports.__doof_debug_heap_end.value;
  else assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end);
}
const data=api.make(0);
const view=new DataView(instance.exports.__doof_ffi_memory.buffer);
view.setInt32(data+4,2147483647,true);
assert.throws(()=>api.push(data,1),WebAssembly.RuntimeError);
assert.strictEqual(view.getInt32(data+4,true),2147483647,'overflow must trap before modifying length');
view.setInt32(data+4,0,true); api.drop(data);
assert.deepStrictEqual(live(),baseline);
`)
}

export function testPushKeepsSoleOwnedObjectsAcrossMigration(): none {
  checkArrays(`
class Box { value: int }
export function grow(): bool {
  values: Box[] := []
  for let i = 0; i < 1025; i = i + 1 { values.push(Box { value: i }) }
  for let j = 0; j < values.length; j = j + 1 { if values[j].value != j { return false } }
  values.push(values[0])
  return values[1025].value == 0
}
export function literal(): bool {
  values := [1, 2, 3]
  alias := values
  for let i = 0; i < 1025; i = i + 1 { values.push(i) }
  if alias.length != 1028 { return false }
  if values[0] != 1 { return false }
  if values[2] != 3 { return false }
  return values[1027] == 1024
}
`, "sole-owners", `
for(let i=0;i<5;i++) {
  assert.strictEqual(api.grow(),true); assert.strictEqual(api.literal(),true);
  assert.deepStrictEqual(live(),baseline);
  if(i===0) var end=instance.exports.__doof_debug_heap_end.value;
  else assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end);
}
`)
}

export function testContainsUsesNominalUnionTagsAndFloatingEquality(): none {
  checkArrays(`
enum Choice { first = 1, last = 2 }
export function tags(value: double): bool {
  values: (Choice | int | long | float | double | bool | char | none)[] := []
  values.push(Choice.first)
  if values.contains(1) { return false }
  values.push(1)
  values.push(7L)
  if values.contains(7) { return false }
  values.push(2.0f)
  if values.contains(2.0) { return false }
  values.push(true)
  values.push('a')
  values.push(none)
  if values.contains(Choice.first) == false { return false }
  if values.contains(1) == false { return false }
  if values.contains(7L) == false { return false }
  if values.contains(2.0f) == false { return false }
  if values.contains(true) == false { return false }
  if values.contains('a') == false { return false }
  if values.contains(none) == false { return false }
  values.push(value)
  return values.contains(value)
}
export function floating(value: double): bool {
  values: double[] := []
  values.push(value)
  return values.contains(value)
}
`, "equality", `
for(const value of [0,-0,Infinity,-Infinity,7.5,NaN]) {
  assert.strictEqual(api.tags(value),!Number.isNaN(value));
  assert.strictEqual(api.floating(value),!Number.isNaN(value));
  assert.deepStrictEqual(live(),baseline);
}
`)
}

export function testStringBridgeAcrossChunkAndRadixBoundaries(): none {
  let literal = ""
  for index of 0..<1025 { literal = literal + "z" }
  checkArrays(`
import function echo(value: string): string
export function identity(value: string): string { return value }
export function forwarded(value: string): string { return echo(value) }
export function middle(value: string, start: int, end: int): string { return value.substring(start, end) }
export function length(value: string): int { return value.length }
export function literal(): string { return "${literal}" }
`, "string-bridge", `
for (const length of [0,1,16,17,1023,1024,1025,2048,2049,8193,262144,262145]) {
  const text = Array.from({length}, (_,i) => String.fromCharCode(i % 256)).join('');
  assert.strictEqual(api.identity(text),text,'export round trip '+length);
  assert.strictEqual(api.forwarded(text),text,'host import round trip '+length);
  assert.strictEqual(api.length(text),length);
  if (length > 1024) assert.strictEqual(api.middle(text,1019,Math.min(length,2053)),text.substring(1019,Math.min(length,2053)));
  assert.deepStrictEqual(live(),baseline,'strings must be released at '+length);
}
assert.strictEqual(api.literal(),'z'.repeat(1025),'long literals use chunked storage');
const end = instance.exports.__doof_debug_heap_end.value;
for (let i=0;i<3;i++) {
  assert.strictEqual(api.forwarded('x'.repeat(262145)),'x'.repeat(262145));
  assert.deepStrictEqual(live(),baseline,'reused directories must be initialized');
}
assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'string blocks must be reused');
assert.throws(() => api.identity('x'.repeat(1025)+'\\u0100'),RangeError);
assert.throws(() => api.forwarded('\\ud83d\\ude00'),RangeError);
assert.throws(() => api.identity(42),TypeError);
assert.deepStrictEqual(live(),baseline,'invalid input must not allocate');
`)
}

export function testPassiveLiteralPoolLargeLiteralsAndMultipleInitializers(): none {
  literal := ("z".repeat(1024) + "\\0").repeat(256) + "!"
  let entries = ""
  for index of 0..<260 {
    if index > 0 { entries += "," }
    entries += "\"s" + string(index) + "\""
  }
  source := `
readonly TEXTS = [${entries}, ""]
export function pool(index: int): string => TEXTS[index]
export function literal(): string => "${literal}"
`
  module_ := try! lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  first := try! encodeDoofMinus(module_, true)
  // A literal's bytes belong in data; startup code must not grow per character.
  Assert.isTrue(first.length < 1000000, "Large literal and 261 pooled entries must remain compact: " + string(first.length))
  _ := try! encodeDoofMinus(try! parseDoofMinus("export func answer() -> int\nblock entry\n%value:int = const 42\nreturn %value\nend"))
  second := try! encodeDoofMinus(module_, true)
  Assert.arrayEqual(second.cloneReadonly(), first.cloneReadonly(), "Pool state must be local to each encoding call")
  checkModule(module_, "passive-literal-pool", `
const expected=('z'.repeat(1024)+'\\0').repeat(256)+'!';
assert.strictEqual(api.literal(),expected);
for(let i=0;i<=260;i++)assert.strictEqual(api.pool(i),i===260?'':'s'+i);
const pointer=instance.exports.pool(0),alias=instance.exports.pool(0);
assert.strictEqual(pointer,alias,'literal identity remains shared');
instance.exports.__doof_ffi_release(pointer);instance.exports.__doof_ffi_release(alias);
for(let i=0;i<5;i++){assert.strictEqual(api.literal(),expected);assert.deepStrictEqual(live(),baseline)}
const other=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]));
const otherApi=ffi.createDoofModule(other.instance);
assert.strictEqual(otherApi.literal(),expected,'passive segments initialize every instance');
assert.strictEqual(otherApi.pool(259),'s259','all strings precede global initialization');
`)
}

export function testReserveAndPopAllWidthsAndResultFailures(): none {
  types := ["bool", "byte", "char", "int", "long", "float", "double", "Choice"]
  first := ["false", "byte(7)", "'a'", "7", "7L", "7.0f", "7.0", "Choice.first"]
  last := ["true", "byte(99)", "'z'", "99", "99L", "99.0f", "99.0", "Choice.last"]
  capacities := [1024, 1024, 1024, 256, 128, 256, 128, 256]
  for index of 0..<types.length {
    checkArrays(`
enum Choice { first, last }
export function check(length: int): bool {
  values: ${types[index]}[] := [${first[index]}]
  alias := values
  values.reserve(-1)
  values.reserve(0)
  alias.reserve(length + 1)
  if values.length != 1 || values[0] != ${first[index]} { return false }
  for i of 0..<length { values.push(${last[index]}) }
  values.reserve(1)
  for i of 0..<length {
    item := try! alias.pop()
    if item != ${last[index]} || values.length != length - i { return false }
  }
  item := try! values.pop()
  if item != ${first[index]} || alias.length != 0 { return false }
  failed := values.pop() else message {
    if message != "Attempted to pop from empty array" { return false }
    alias.push(${last[index]})
    return (try! values.pop()) == ${last[index]} && alias.length == 0
  }
  return false
}
`, "reserve-pop-width-" + string(index), `
const capacity=${capacities[index]};
for(const length of [0,1,3,4,5,15,16,17,capacity-1,capacity,capacity+1,2*capacity+1,256*capacity+1]) {
 assert.strictEqual(api.check(length),true,'length '+length);
 assert.deepStrictEqual(live(),baseline,'pop/reserve release storage at '+length);
}
const end=instance.exports.__doof_debug_heap_end.value;
assert.strictEqual(api.check(256*capacity+1),true);assert.deepStrictEqual(live(),baseline);
assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'reserved chunks must be reused');
`)
  }
}

export function testReserveAndPopTransferSoleOwnedReferences(): none {
  types := ["Box", "View", "int[]", "string", "Box | int | string | none"]
  values := ["Box { value: i }", "Box { value: i }", "[i]", "string(i)", "Box { value: i }"]
  reads := ["item.value", "item.value", "item[0]", "item.length", "unionValue(item)"]
  for index of 0..<types.length {
    checkArrays(`
interface View { value: int }
class Box implements View { value: int }
function unionValue(value: Box | int | string | none): int {
  case value { box: Box -> { return box.value } _ -> { return -1 } }
}
export function check(length: int): bool {
  values: (${types[index]})[] := []
  alias := values
  values.reserve(length + 1)
  for i of 0..<length { values.push(${values[index]}) }
  for i of 0..<length {
    completion := alias.pop()
    item := try! completion
    if ${reads[index]} != ${if index == 3 then "string(length - i - 1).length" else "length - i - 1"} { return false }
  }
  // Refill at a chunk boundary after popping, exercising existing capacity.
  for i of 0..<length { values.push(${values[index]}) }
  return alias.length == length
}
export function detached(): string {
  values: string[] := ["survives"]
  completion := values.pop()
  return try! completion
}
export function discarded(): none {
  values := [Box { value: 42 }]
  _ := values.pop()
  _ := values.pop()
}
`, "reserve-pop-reference-" + string(index), `
for(const length of [1,4,5,255,256,257,65537]) {
 assert.strictEqual(api.check(length),true);assert.deepStrictEqual(live(),baseline);
}
for(let i=0;i<10;i++){assert.strictEqual(api.detached(),'survives');api.discarded();assert.deepStrictEqual(live(),baseline);}
`)
  }
}

export function testReserveCapacityIsAllocatedAndRawPopTrapsWhenEmpty(): none {
  module_ := try! parseDoofMinus(`
export func make() -> int
block entry
%zero:int = const 0
%data:int = array-alloc %zero,int
return %data
end
export func reserve(%data:int,%capacity:int) -> int
block entry
%grown:int = array-reserve %data,%capacity,int
return %grown
end
export func push(%data:int,%value:int) -> int
block entry
%grown:int = array-push %data,%value
return %grown
end
export func pop(%data:int) -> int
block entry
%value:int = array-pop %data
return %value
end
export func length(%data:int) -> int
block entry
%length:int = array-length %data
return %length
end
export func drop(%data:int) -> none
block entry
array-free %data
return
end
`)
  checkModule(module_, "reserved-capacity", `
for(const capacity of [0,1,5,17,256,257,65537]) {
 let data=api.reserve(api.make(),capacity);assert.strictEqual(api.length(data),0);
 const end=instance.exports.__doof_debug_heap_end.value;
 for(let i=0;i<capacity;i++)data=api.push(data,i);
 assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'push must consume reserved capacity');
 for(let i=capacity-1;i>=0;i--)assert.strictEqual(api.pop(data),i);
 assert.throws(()=>api.pop(data),WebAssembly.RuntimeError);
 for(let i=0;i<capacity;i++)data=api.push(data,i);
 assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'pop must preserve reserved chunks');
 api.drop(data);assert.deepStrictEqual(live(),baseline);
}
`)
}

export function testReadonlyArraysRejectReserveAndPop(): none {
  for operation of ["reserve(8)", "pop()"] {
    case lowerDoofWasmSources([SourceFile { path: "/main.do", source: "function main(): none { readonly values: int[] = [1]; values." + operation + " }" }], "/main.do") {
      failure: Failure<string> -> { Assert.stringContains(failure.error, "not available on readonly array") }
      _ -> { Assert.fail("Readonly arrays must reject " + operation) }
    }
  }
}
