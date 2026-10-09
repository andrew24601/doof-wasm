import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { readText, remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { MinusModule } from "./minus-ir"
import { lowerDoofWasmSources } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function runSourceWithBindings(source: string, name: string, script: string): none {
  module_ := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")!
  runModuleWithBindings(module_, name, script)
}

function runModuleWithBindings(module_: MinusModule, name: string, script: string): none {
  bytes := encodeDoofMinus(module_, true)!
  wasmPath := "/tmp/doof-source-arrays-" + string(pid()) + "-" + name + ".wasm"
  jsPath := "/tmp/doof-source-arrays-" + string(pid()) + "-" + name + ".mjs"
  writeBlob(wasmPath, bytes.cloneReadonly())!
  writeText(jsPath, renderDoofJs(module_, true))!
  result := run("node", ["-e", `
const fs = require('fs'), assert = require('assert'), {pathToFileURL} = require('url');
(async () => {
  const ffi = await import(pathToFileURL(process.argv[2]).href);
  const bytes = fs.readFileSync(process.argv[1]);
  ${script}
})().catch(error => { console.error(error); process.exit(1); });
`, wasmPath, jsPath], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
  _ := remove(wasmPath) else { panic("Could not remove temporary Wasm file") }
  _ := remove(jsPath) else { panic("Could not remove temporary JavaScript file") }
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}


export function testSelfHostingCompoundTargetsAndShortCircuit(): none {
  runSourceWithBindings(`
class Box { let value: int; let calls: int = 0 }
function owner(box: Box): Box { box.calls += 1; return box }
function index(box: Box): int { box.calls += 10; return 0 }
export function compound(): int {
  box := Box { value: 8 }
  owner(box).value += 4
  values := [20]
  values[index(box)] \\= 3
  values[index(box)] %= 4
  let n = 5
  n *= 6
  n -= 2
  n += values[0]
  if false && owner(box).value == 12 { return -1 }
  if true || owner(box).value == 0 { n += box.calls }
  return n + box.value
}
`, "compound", `
const {instance} = await WebAssembly.instantiate(bytes);
assert.strictEqual(ffi.createDoofModule(instance).compound(),63);
`)
}

export function testSelfHostingLoopExitsCarryValuesAndRunUpdates(): none {
  runSourceWithBindings(`
export function loops(): int {
  let total = 0
  for let i = 0; i < 10; i += 1 {
    if i == 2 { continue }
    if i == 5 { break }
    total += i
  }
  let j = 0
  while j < 5 {
    j += 1
    if j == 2 { continue }
    if j == 4 { break }
    total += j
  }
  for item of [1,2,3,4] {
    if item == 2 { continue }
    if item == 4 { break }
    total += item
  }
  for i of 0..<3 {
    for k of 0..<4 { if k == 1 { break }
 total += 1 }
    if i == 1 { continue }
    total += 10
  }
  return total
}
`, "loop-exits", `
const {instance} = await WebAssembly.instantiate(bytes);
const api = ffi.createDoofModule(instance);
for(let i=0;i<20;i++) assert.strictEqual(api.loops(),39);
`)
}

export function testSelfHostingIntegerDivisionAndRemainder(): none {
  runSourceWithBindings(`
export function quotient(a: int, b: int): int => a \\ b
export function remainder(a: int, b: int): int => a % b
export function wideQuotient(a: long, b: long): long => a \\ b
export function wideRemainder(a: long, b: long): long => a % b
export function octet(a: byte, b: byte): byte => byte(a % b)
export function leb(value: long): string {
  let remaining = value
  let output = ""
  while true {
    let next = remaining \\ 128L
    if remaining < 0L && remaining % 128L != 0L { next -= 1L }
    low := remaining - next * 128L
    output += string(low) + ","
    if next == 0L && low < 64L { break }
    if next == -1L && low >= 64L { break }
    remaining = next
  }
  return output
}
`, "division", `
const {instance} = await WebAssembly.instantiate(bytes), api=ffi.createDoofModule(instance);
for (const [a,b] of [[7,3],[-7,3],[7,-3],[-7,-3],[-2147483648,128],[2147483647,128]]) {
 assert.strictEqual(api.quotient(a,b),Math.trunc(a/b)); assert.strictEqual(api.remainder(a,b),(a%b)||0);
}
for (const a of [0n,9223372036854775807n,-9223372036854775808n,-129n]) {
 assert.strictEqual(api.wideQuotient(a,128n),a/128n); assert.strictEqual(api.wideRemainder(a,128n),a%128n);
}
assert.strictEqual(api.octet(255,128),127);
assert.strictEqual(api.leb(624485n),'101,14,38,'); assert.strictEqual(api.leb(-624485n),'27,113,89,');
assert.throws(()=>api.quotient(1,0),WebAssembly.RuntimeError);
assert.throws(()=>api.remainder(1,0),WebAssembly.RuntimeError);
assert.strictEqual(api.remainder(-2147483648,-1),0);
`)
}

export function testSelfHostingStringConstructionFormattingAndSplitting(): none {
  runSourceWithBindings(`
export function join(a: string, b: string): string { let output = a; output += b; return output }
export function integer(value: int): string => string(value)
export function wide(value: long): string => string(value)
export function boolean(value: bool): string => string(value)
export function character(value: char): string => string(value)
export function octet(value: byte): string => string(value)
export function identity(value: string): string => string(value)
export function splitAt(source: string, separator: string, index: int): string => source.split(separator)[index]
export function splitCount(source: string, separator: string): int => source.split(separator).length
`, "strings", `
const {instance} = await WebAssembly.instantiate(bytes), api=ffi.createDoofModule(instance), heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(b=>b.kind!=='free').map(b=>[b.address,b.kind,b.refCount]);
const baseline=live();
for (const n of [0,1,1023,1024,1025,262145]) assert.strictEqual(api.join('a'.repeat(n),'b'.repeat(17)),'a'.repeat(n)+'b'.repeat(17));
for(const value of [0,1,-1,2147483647,-2147483648]) assert.strictEqual(api.integer(value),String(value));
for(const value of [0n,1n,-1n,9223372036854775807n,-9223372036854775808n]) assert.strictEqual(api.wide(value),String(value));
assert.strictEqual(api.boolean(true),'true'); assert.strictEqual(api.boolean(false),'false');
assert.strictEqual(api.character(65),'A'); assert.strictEqual(api.character(255),String.fromCharCode(255));
assert.strictEqual(api.octet(255),'255'); assert.strictEqual(api.identity('abc'),'abc');
for(const [s,d] of [['',''],['','x'],['a\\nb\\n','\\n'],['a::::b::','::'],['aaaaa','aa'],['abc','xyz'],['abc',''],['x'.repeat(1023)+'::tail','::']]) {
 const expected=d===''?s.split(''):s.split(d);
 assert.strictEqual(api.splitCount(s,d),expected.length);
 for(let i=0;i<expected.length;i++) assert.strictEqual(api.splitAt(s,d,i),expected[i]);
}
for(let i=0;i<50;i++){api.join('a'.repeat(1025),'b');api.splitCount('x\\ny\\nz\\n','\\n');api.wide(-9223372036854775808n);}
assert.deepStrictEqual(live(),baseline,'all temporary strings and split arrays released');
`)
}

export function testSelfHostingConstantsAliasesAndTryPropagation(): none {
  runSourceWithBindings(`
readonly OFFSET = 3
readonly BASE = OFFSET * 7
type Number = int
function value(ok: bool): Result<Number,string> { if ok { return Success(BASE) }
 return Failure("failed") }
function propagate(ok: bool): Result<int,string> { try n := value(ok); _ := n; return Success(n + 1) }
export function check(ok: bool): string {
  case propagate(ok) {
    success: Success<int> -> { return string(success.value) }
    failure: Failure<string> -> { return failure.error }
  }
}
`, "constants-try", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance);
assert.strictEqual(api.check(true),'22');assert.strictEqual(api.check(false),'failed');
`)
}

export function testSelfHostingExistingParserAndRendererInWasm(): none {
  entry := `
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { MinusModule } from "./minus-ir"
export function parse(source: string): string {
  case parseDoofMinus(source) {
    success: Success<MinusModule> -> { return renderDoofMinus(success.value) }
    failure: Failure<string> -> { return failure.error }
  }
}
`
  let sources = [SourceFile { path: "/src/entry.do", source: entry }]
  for name of ["minus-parse", "minus-render", "minus-ir"] {
    sources.push(SourceFile { path: "/src/" + name + ".do", source: readText("src/" + name + ".do")! })
  }
  module_ := lowerDoofWasmSources(sources, "/src/entry.do")!
  runModuleWithBindings(module_, "existing-parser", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance);
const source='export func answer() -> int\\nblock entry\\n%answer:int = const 42\\nreturn %answer\\nend\\n';
const output=api.parse(source);
assert(output.includes('export func')); assert(output.includes('const 42'));
assert.strictEqual(api.parse('garbage'),'line 1: invalid declaration');
for(let i=0;i<20;i++) assert.strictEqual(api.parse(output),output);
`)
}

export function testSelfHostingExpressionTemporariesAcrossBranches(): none {
  runSourceWithBindings(`
class Box { let value: int }
function sum(a: int, b: int): int => a + b
function change(values: int[]): int { values[0] = 20; return 10 }
export function temporary(flag: bool): int {
  box := Box { value: 1 }
  box.value += if flag then 2 else 4
  values := [2]
  values[0] += if flag then change(values) else 3
  return sum(box.value, if flag then values[0] else 7)
}
export function literal(flag: bool): string => "%literal" + if flag then "yes" else "no"
`, "temporaries", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance);
assert.strictEqual(api.temporary(true),15);assert.strictEqual(api.temporary(false),12);
assert.strictEqual(api.literal(true),'%literalyes');assert.strictEqual(api.literal(false),'%literalno');
`)
}

export function testSelfHostingUnsupportedFormattingDiagnostic(): none {
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source: "export function format(values: int[]): string => \"\${values}\"" }], "/main.do")
  case lowered {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "string conversion is not supported by doof-wasm for "); Assert.stringContains(failure.error, "__doof_array_type_int") }
    _ -> { Assert.fail("Expected an actionable formatting diagnostic") }
  }
}

export function testSelfHostingUnsupportedStringRepeatDiagnostic(): none {
  lowered := lowerDoofWasmSources([SourceFile { path: "/lexer.do", source: `
export function normalize(source: string): string => source.repeat(2)
` }], "/lexer.do")
  case lowered {
    failure: Failure<string> -> {
      Assert.stringContains(failure.error, "/lexer.do: line 2:")
      Assert.stringContains(failure.error, "unknown class method repeat")
    }
    _ -> { Assert.fail("Unsupported string methods must retain their source diagnostic") }
  }
}

export function testSelfHostingCheckedNullableReadsInWasm(): none {
  runSourceWithBindings(`
class Violation { reason: string }
function find(ready: bool): Violation | none => if ready then Violation { reason: "unsafe" } else none
export function reason(ready: bool): string {
  violation := find(ready)
  if violation != none { return violation!.reason }
  return "safe"
}
function guarded(value: Violation | none): string {
  if value == none { return "safe" }
  return value!.reason
}
export function guard(ready: bool): string => guarded(find(ready))
export function capture(ready: bool): string {
  violation := find(ready)
  read := (): string => {
    if violation != none { return violation!.reason }
    return "safe"
  }
  return read()
}
export function mutableCapture(): string {
  let violation: Violation | none = none
  read := (): string => {
    if violation != none { return violation!.reason }
    return "safe"
  }
  let text = read()
  violation = Violation { reason: "unsafe" }
  text += read()
  violation = none
  return text + read()
}
export function joined(ready: bool): string {
  let violation = find(ready)
  let text = ""
  if violation != none { text = violation!.reason }
  violation = none
  if violation == none { return text + "safe" }
  return "unreachable"
}
export function longReason(ready: bool, input: string): string {
  violation: Violation | none := if ready then Violation { reason: input } else none
  if violation != none { return violation!.reason }
  return "safe"
}
`, "checked-nullable", `
const {instance}=await WebAssembly.instantiate(bytes);
const api=ffi.createDoofModule(instance), heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free');
const baseline=live();
for(let i=0;i<40;i++){
  for(const ready of [false,true]){
    for(const name of ['reason','guard','capture'])assert.strictEqual(api[name](ready),ready?'unsafe':'safe');
    assert.strictEqual(api.joined(ready),ready?'unsafesafe':'safe');
    const text='x'+'a'.repeat(1025);
    assert.strictEqual(api.longReason(ready,text),ready?text:'safe');
  }
  assert.strictEqual(api.mutableCapture(),'safeunsafesafe');
  assert.deepStrictEqual(live(),baseline,'narrowed reads release casts and captured cells');
}
`)
}

export function testSelfHostingSharedUnionFieldsInWasm(): none {
  runSourceWithBindings(`
class Child { text: string }
class First {
  padding: long = 99l
  kind: string = "first"
  child: Child
  items: string[]
  payload: int = 42
}
class Second {
  kind: string = "second"
  padding: int = 7
  payload: string = "text"
  items: string[]
  child: Child
}
type Choice = First | Second
class Counter { let calls: int = 0 }
function make(flag: bool, missing: bool, counter: Counter): Choice | none {
  counter.calls += 1
  if missing { return none }
  if flag { return First { child: Child { text: "a" }, items: ["one"] } }
  return Second { child: Child { text: "b" }, items: ["two", "three"] }
}
function payload(value: Choice): string {
  case value.payload {
    number: int -> { return string(number) }
    text: string -> { return text }
  }
}
export function check(flag: bool): string {
  counter := Counter {}
  value := make(flag, false, counter)!
  captured := => value.kind
  chosen := if flag then value.child.text else value.items[1]
  return captured() + ":" + chosen + ":" + payload(value) + ":" + string(counter.calls)
}
export function optional(flag: bool, missing: bool): string {
  counter := Counter {}
  text := make(flag, missing, counter)?.kind ?? "none"
  child := make(flag, missing, counter)?.child
  items := make(flag, missing, counter)?.items
  return text + ":" + (child?.text ?? "none") + ":" + string(items?.length ?? 0) + ":" + string(counter.calls)
}
export function forced(flag: bool): string {
  counter := Counter {}
  return make(flag, false, counter)!.kind + ":" + string(counter.calls)
}
export function numeric(flag: bool): long {
  counter := Counter {}
  return make(flag, false, counter)!.padding
}
`, "shared-union-fields", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(b=>b.kind!=='free').map(b=>[b.address,b.kind,b.refCount]);
const baseline=live();
for(let i=0;i<30;i++){
  assert.strictEqual(api.check(true),'first:a:42:1');assert.strictEqual(api.check(false),'second:three:text:1');
  assert.strictEqual(api.forced(true),'first:1');assert.strictEqual(api.forced(false),'second:1');
  assert.strictEqual(api.numeric(true),99n);assert.strictEqual(api.numeric(false),7n);
  assert.strictEqual(api.optional(true,false),'first:a:1:3');assert.strictEqual(api.optional(false,false),'second:b:2:3');
  for(const flag of [false,true])assert.strictEqual(api.optional(flag,true),'none:none:0:3');
  assert.deepStrictEqual(live(),baseline,'union boxes, fields, and closures are released');
}
`)
}

export function testSelfHostingImportedSharedUnionFieldsInWasm(): none {
  module_ := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source: `
import { Item as First, read as firstRead } from "./first"
import { Item as Second, read as secondRead } from "./second"
export function check(flag: bool): string {
  value: First | Second | none := if flag then First {} else Second {}
  return value!.kind + ":" + firstRead(value!) + ":" + secondRead(value!)
}

` },
    SourceFile { path: "/first.do", source: `
import { Item as Second } from "./second"
export class Item { padding: int = 0; kind: string = "first" }
export function read(value: Item | Second): string => value.kind
` },
    SourceFile { path: "/second.do", source: `
import { Item as First } from "./first"
export class Item { kind: string = "second"; padding: long = 0l }
export function read(value: Item | First): string => value.kind
` },
  ], "/main.do")!
  runModuleWithBindings(module_, "imported-union-fields", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(b=>b.kind!=='free').map(b=>[b.address,b.kind,b.refCount]);const baseline=live();
for(let i=0;i<30;i++){
assert.strictEqual(api.check(true),'first:first:first');assert.strictEqual(api.check(false),'second:second:second');
assert.deepStrictEqual(live(),baseline);
}
`)
}

export function testSelfHostingSharedUnionFieldWritesInWasm(): none {
  module_ := lowerDoofWasmSources([
    SourceFile { path: "/main.do", source: `
import { First as A, Second as B, Child, Other } from "./fields"
type Choice = A | B | none
class Counter { let trace: string = "" }
function receiver(value: Choice, counter: Counter): Choice { counter.trace += "r"; return value }
function number(counter: Counter, value: int): int { counter.trace += "v"; return value }
function choose(flag: bool): Choice => if flag then A {} else B {}
export function check(flag: bool): string {
  counter := Counter {}
  value := choose(flag)
  assigned := receiver(value, counter)!.count = number(counter, 40)
  receiver(value, counter)!.count += if flag then number(counter, 2) else number(counter, 3)
  value!.kind = "new"
  value!.kind += if flag then "A" else "B"
  value!.items = [value!.kind, "tail"]
  value!.items = value!.items
  selected := value!.payload = Child { text: "child" }
  if selected.text != "child" { return "wrong assignment result type" }
  value!.payload = value!.payload
  previous := value!.payload
  captured := => { value!.payload = Other { text: "other" }; value!.enabled = true }
  captured()
  let text = ""
  case previous {
    child: Child -> { text = child.text }
    _ -> { return "replaced reference was lost" }
  }
  case value!.payload {
    child: Child -> { text += child.text }
    other: Other -> { text += other.text }
    _: none -> { text = "missing" }
  }
  value!.payload = none
  return string(assigned) + ":" + string(value!.count) + ":" + value!.items[0] + ":" + text + ":" + string(value!.enabled) + ":" + counter.trace
}
export function single(flag: bool): int {
  value: A | none := if flag then A {} else none
  if value != none { value!.count = 42; return value!.count }
  return 0
}
` },
    SourceFile { path: "/fields.do", source: `
export class Child { text: string }
export class Other { text: string }
export class First {
  padding: long = 99l
  let count: int = 1
  let kind: string = "first"
  let items: string[] = ["original"]
  let payload: Child | Other | none = none
  let enabled: bool = false
}
export class Second {
  let payload: Child | Other | none = none
  let items: string[] = ["original"]
  let kind: string = "second"
  let count: int = 2
  let enabled: bool = false
  padding: int = 7
}
` },
  ], "/main.do")!
  runModuleWithBindings(module_, "union-field-writes", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let i=0;i<40;i++){
  assert.strictEqual(api.check(true),'40:42:newA:childother:true:rvrv');
  assert.strictEqual(api.check(false),'40:43:newB:childother:true:rvrv');
  assert.strictEqual(api.single(true),42);assert.strictEqual(api.single(false),0);
  assert.deepStrictEqual(live(),baseline,'union writes release replaced fields and assigned temporaries');
}
`)
}

export function testSelfHostingUnionFieldWritesPreserveCheckerRules(): none {
  sources := [
    "class A { let value: int = 0 }\nclass B { value: int = 0 }\nfunction write(value: A | B): none { value.value = 1 }",
    "class A { let value: int = 0 }\nclass B { let value: long = 0l }\nfunction write(value: A | B): none { value.value = 1 }",
  ]
  messages := ["Cannot assign to immutable field", "is not an assignable field"]
  for index of 0..<sources.length {
    source := sources[index]
    case lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do") {
      failure: Failure<string> -> { Assert.stringContains(failure.error, messages[index], failure.error) }
      _ -> { Assert.fail("Union writes require mutable fields of the same checked type") }
    }
  }
}

export function testSelfHostingNullableAndConcreteEqualityInWasm(): none {
  runSourceWithBindings(`
class Box { value: int }
class Other { value: int }
export function strings(value: string, expected: string, missing: bool): bool {
  nullable: string | none := if missing then none else value
  return (nullable == expected) == (expected == nullable) &&
    (nullable != expected) == (expected != nullable) &&
    (nullable == expected) != (nullable != expected)
}
export function matches(value: string, expected: string, missing: bool): bool {
  nullable: string | none := if missing then none else value
  return nullable == expected
}
export function references(flag: bool): bool {
  box := Box { value: 42 }
  nullable: Box | Other | none := if flag then box else Other { value: 42 }
  return (nullable == box) == flag && (box != nullable) != flag
}
export function scalars(missing: bool): bool {
  integer: int | none := if missing then none else 42
  wide: long | none := if missing then none else 42l
  boolean: bool | none := if missing then none else true
  return (integer == 42) != missing && (42l == wide) != missing && (boolean != true) == missing
}
`, "nullable-equality", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(b=>b.kind!=='free').map(b=>[b.address,b.kind,b.refCount]);const baseline=live();
for(let i=0;i<30;i++){
for(const missing of [false,true]){
  for(const [value,expected] of [['same','same'],['same','different'],['x'.repeat(1025),'x'.repeat(1025)],['','']]){
    assert.strictEqual(api.strings(value,expected,missing),true);
    assert.strictEqual(api.matches(value,expected,missing),!missing&&value===expected);
  }
  assert.strictEqual(api.references(missing),true);assert.strictEqual(api.scalars(missing),true);
}
assert.deepStrictEqual(live(),baseline,'comparison boxes and their payload references are released');
}
`)
}

export function testSelfHostingNamedFunctionCallbacksExecuteAndRelease(): none {
  runSourceWithBindings(`
function identity(value: int): int => value
function apply(callback: (value: int): int): int => callback(42)
export function answer(): int => apply(identity)
function increment(value: int): int => value + 1
function choose(flag: bool): (value: int): int => if flag then identity else increment
function relay(callback: (value: int): int): (value: int): int => callback
function recurse(value: int): int {
  if value == 0 { return 1 }
  callback := recurse
  return callback(value - 1) + 1
}
export function stored(flag: bool): int {
  callbacks := [identity, choose(flag), relay(increment)]
  first := callbacks[0]
  second := callbacks[1]
  third := callbacks[2]
  captured := => apply(identity) + second(10)
  return first(1) + third(2) + captured() + recurse(4)
}
export function shadowed(): int { identity := increment; return apply(identity) }
`, "named-functions", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let i=0;i<30;i++){assert.strictEqual(api.answer(),42);assert.strictEqual(api.stored(true),61);assert.strictEqual(api.stored(false),62);assert.strictEqual(api.shadowed(),43)}
assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingNamedFunctionImportsKeepDeclarationIdentity(): none {
  module_ := lowerDoofWasmSources([
    SourceFile { path: "/one.do", source: "function original(value: int): int => value + 1\nexport { original as same }" },
    SourceFile { path: "/two.do", source: "export function same(value: int): int => value + 2" },
    SourceFile { path: "/apply.do", source: "export function apply(callback: (value: int): int): int => callback(10)" },
    SourceFile { path: "/main.do", source: `
import { same as first } from "./one"
import { same as second } from "./two"
import { apply } from "./apply"
import function host(value: string): string
import function publish(value: string): none
function invoke(callback: (value: string): string): string => callback("hello")
function notify(callback: (value: string): none): none { callback("published") }
export function check(): string {
  notify(publish)
  return string(apply(first)) + ":" + string(apply(second)) + ":" + invoke(host)
}
` },
  ], "/main.do")!
  runModuleWithBindings(module_, "named-function-imports", `
let publications=0;
const bridge=ffi.createDoofImports({host:value=>value+'!',publish:value=>{assert.strictEqual(value,'published');publications++}});
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();for(let i=0;i<30;i++)assert.strictEqual(api.check(),'11:12:hello!');
assert.strictEqual(publications,30);assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingNamedFunctionReferenceAndResultSignatures(): none {
  runSourceWithBindings(`
class Source { text: string }
function load(path: string): Result<Source | none, string> {
  if path == "missing" { return Success(none) }
  if path == "bad" { return Failure("load failed") }
  return Success(Source { text: path })
}
function compile(path: string, loader: (path: string): Result<Source | none, string>): string {
  source := loader(path) else message { return message ?? "absent" }
  case source {
    loaded: Source -> { return loaded.text }
    _ -> { return "absent" }
  }
}
function identity(value: Source): Source => value
function roundTrip(callback: (value: Source): Source): string => callback(Source { text: "owned" }).text
export function check(path: string): string => compile(path, load) + ":" + roundTrip(identity)
`, "named-function-results", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();for(let i=0;i<30;i++){
assert.strictEqual(api.check('ready'),'ready:owned');assert.strictEqual(api.check('missing'),'absent:owned');assert.strictEqual(api.check('bad'),'load failed:owned');
}assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingUnionTypePatternsPreserveTagsAndLocals(): none {
  runSourceWithBindings(`
class Text { value: string }
class Count { value: int }
class Other { value: int }
type Node = Text | Count
type Small = int | none
type Subject = Node | Other | Small
function inspect(subject: Subject): string {
  let prefix = "before:"
  case subject {
    node: Node -> {
      prefix = "node:"
      case node {
        text: Text -> { return prefix + text.value }
        count: Count -> { return prefix + string(count.value) }
      }
    }
    small: Small -> {
      case small {
        number: int -> { prefix = "int:" + string(number) }
        _ -> { prefix = "none" }
      }
    }
    _ -> { prefix = "other" }
  }
  return prefix
}
function classify(value: Node | Small): string {
  case value {
    _: Node -> { return "node" }
    _: Small -> { return "small" }
  }
  return "fallback"
}
export function check(): string {
  return inspect(Text { value: "owned" }) + ":" + inspect(Count { value: 42 }) + ":" + inspect(Other { value: 0 }) + ":" + inspect(7) + ":" + inspect(none) + ":" + classify(Text { value: "unused" }) + ":" + classify(none)
}
`, "union-patterns", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();for(let i=0;i<30;i++)assert.strictEqual(api.check(),'node:owned:node:42:other:int:7:none:node:small');
assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingModuleConstantsRespectImportsAndShadowing(): none {
  sources := [
    SourceFile { path: "/constants.do", source: "readonly BASE = 7\nexport readonly VALUE = BASE * 2\nexport readonly OTHER = 7" },
    SourceFile { path: "/main.do", source: `
import { VALUE as OFFSET, OTHER } from "./constants"
export function check(): int {
  BASE := 100
  return OFFSET + OTHER + BASE - 100
}
` },
  ]
  module_ := lowerDoofWasmSources(sources, "/main.do")!
  runModuleWithBindings(module_, "module-constants", `
const {instance}=await WebAssembly.instantiate(bytes);
assert.strictEqual(ffi.createDoofModule(instance).check(),21);
`)
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source: "function make(): int => 1\nreadonly values = [make()]\nexport function check(): int => 1" }], "/main.do")
  case lowered {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "must be a literal tree") }
    _ -> { Assert.fail("Unsupported module initializers must be diagnosed even when unused") }
  }
}

export function testSelfHostingArrayConstantsRespectImportsAndOwnReferences(): none {
  sources := [
    SourceFile { path: "/main.do", source: `
import { TYPES as IMPORTED, NESTED } from "./constants"
readonly EMPTY: string[] = []
readonly LOCAL = ["shadow"]
export function check(): string {
  ALIAS := IMPORTED
  LOCAL := ["local"]
  return ALIAS[0] + ":" + NESTED[1][1] + ":" + LOCAL[0] + ":" + string(EMPTY.length)
}
export function count(): int => IMPORTED.length
` },
    SourceFile { path: "/constants.do", source: `
export readonly NESTED = [["int", "long"], ["float", "double"]]
export readonly TYPES = ["int", "long"]
` },
  ]
  module_ := lowerDoofWasmSources(sources, "/main.do")!
  Assert.equal(module_.globals.length, 4)
  runModuleWithBindings(module_, "array-constants", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let i=0;i<30;i++){assert.strictEqual(api.check(),'int:double:local:0');assert.strictEqual(api.count(),2)}
assert.deepStrictEqual(live(),baseline);
assert.ok(baseline.length>0);
`)
}

export function testSelfHostingArrayConstantsPreserveMutableInteriorsAndInstanceIsolation(): none {
  runSourceWithBindings(`
VALUES := [1]
export function append(value: int): int { ALIAS := VALUES; ALIAS.push(value); return VALUES.length }
export function read(): int => VALUES[VALUES.length - 1]
`, "shared-array-constants", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance);
assert.strictEqual(api.append(42),2);assert.strictEqual(api.read(),42);
assert.strictEqual(api.append(7),3);assert.strictEqual(api.read(),7);
const other=await WebAssembly.instantiate(bytes),otherApi=ffi.createDoofModule(other.instance);
assert.strictEqual(otherApi.read(),1);assert.strictEqual(api.read(),7);
`)
}

export function testSelfHostingArrayConstantsWithoutStringPool(): none {
  runSourceWithBindings(`
readonly OFFSET = 20
readonly INTS = [OFFSET, 22]
readonly LONGS = [9007199254740993l]
readonly FLOATS: float[] = [1.5f]
readonly DOUBLES = [2.25]
readonly FLAGS = [true, false]
readonly CHARS = ['x']
readonly BYTES: byte[] = [7]
export function check(): int => INTS[0] + INTS[1] + int(BYTES[0])
export function wide(): long => LONGS[0]
export function decimals(): double => double(FLOATS[0]) + DOUBLES[0]
export function flag(): bool => FLAGS[0] && !FLAGS[1]
export function character(): char => CHARS[0]
`, "numeric-array-constants", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();for(let i=0;i<30;i++){
assert.strictEqual(api.check(),49);assert.strictEqual(api.wide(),9007199254740993n);
assert.strictEqual(api.decimals(),3.75);assert.strictEqual(api.flag(),true);assert.strictEqual(api.character(),120);
}assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingTerminatingBranchesOmitCheckedDeadStatements(): none {
  runSourceWithBindings(`
class Text { value: string }
function describe(value: Text | none): string {
  case value {
    text: Text -> { return text.value }
    _ -> { return "none" }
  }
  return "dead case tail"
}

function choose(value: bool): string {
  if value { return describe(Text { value: "owned" }) } else { return describe(none) }
  return "dead if tail"
}
export function check(value: bool): string {
  for index of 0..<2 {
    if index == 0 { continue; ignored := [Text { value: "dead continue" }] }
    break
    ignored := [Text { value: "dead break" }]
  }
  return choose(value)
  ignored := [Text { value: "dead return" }]
}
`, "terminating-branches", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();for(let i=0;i<30;i++){assert.strictEqual(api.check(true),'owned');assert.strictEqual(api.check(false),'none')}
assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingConstantTrueLoopsReturnAndBreak(): none {
  runSourceWithBindings(`
class Text { value: string }
export function scan(limit: int): string {
  let index = 0
  while true {
    text := Text { value: string(index) }
    if index == limit { return text.value }
    index += 1
    continue
  }
}
export function nested(): string {
  while true { while true { break } return "nested" }
  return "dead loop tail"
}
export function forScan(limit: int): int {
  for let index = 0; ; index += 1 {
    if index == limit { return index + 20 }
  }
  return -1
}
export function stop(limit: int): int {
  let index = 0
  while true { if index == limit { break } index += 1 }
  for ; true; index += 1 { if index == limit + 2 { break } }
  return index
}
`, "constant-true-loops", `
const {instance}=await WebAssembly.instantiate(bytes),api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();for(let i=0;i<30;i++){
assert.strictEqual(api.scan(i),String(i));assert.strictEqual(api.forScan(i),i+20);assert.strictEqual(api.stop(i),i+2);assert.strictEqual(api.nested(),'nested');
}assert.deepStrictEqual(live(),baseline);
`)
}
