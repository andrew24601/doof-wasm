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
  module_ := try! lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  runModuleWithBindings(module_, name, script)
}

function runModuleWithBindings(module_: MinusModule, name: string, script: string): none {
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
    sources.push(SourceFile { path: "/src/" + name + ".do", source: try! readText("src/" + name + ".do") })
  }
  module_ := try! lowerDoofWasmSources(sources, "/src/entry.do")
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
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source: "export function format(value: double): string => string(value)" }], "/main.do")
  case lowered {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "string conversion is not supported by doof-wasm for double") }
    _ -> { Assert.fail("Expected an actionable formatting diagnostic") }
  }
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
  module_ := try! lowerDoofWasmSources(sources, "/main.do")
  runModuleWithBindings(module_, "module-constants", `
const {instance}=await WebAssembly.instantiate(bytes);
assert.strictEqual(ffi.createDoofModule(instance).check(),21);
`)
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source: "readonly values = [1]\nexport function check(): int => 1" }], "/main.do")
  case lowered {
    failure: Failure<string> -> { Assert.stringContains(failure.error, "requires a scalar constant initializer") }
    _ -> { Assert.fail("Unsupported module initializers must be diagnosed even when unused") }
  }
}
