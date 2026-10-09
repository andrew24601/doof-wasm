import { minusBlocks } from "./minus-control-flow"
import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { readText, remove, writeBlob, writeText } from "std/fs"
import { formatJsonValue } from "std/json"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { lowerDoofWasmSources, WasmLoweringOptions } from "./doof-compiler"
import { MinusModule } from "./minus-ir"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"
import { encodeWasmHex } from "./selfhost-hex"

function checkFormatting(module_: MinusModule, script: string): none {
  bytes := encodeDoofMinus(module_, true)!
  base := "/tmp/doof-formatting-" + string(pid())
  writeBlob(base + ".wasm", bytes.cloneReadonly())!
  writeText(base + ".mjs", renderDoofJs(module_, true))!
  result := run("node", ["-e", `
const fs=require('fs'),assert=require('assert'),{pathToFileURL}=require('url');
(async()=>{
const ffi=await import(pathToFileURL(process.argv[1]+'.mjs').href);
const bridge=ffi.createDoofImports(ffi.createDoofStdHost());
const {instance}=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]+'.wasm'),bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
${script}
assert.deepStrictEqual(live(),baseline,'formatting releases temporary strings and boxes');
})().catch(error=>{console.error(error);process.exit(1)});
`, base], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
  remove(base + ".wasm")!
  remove(base + ".mjs")!
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

export function testInterpolationPrimitiveFormattingMatchesNative(): none {
  source := `
export function render(i: int, l: long, b: byte, flag: bool, c: char, f: float, d: double, text: string): string =>
  "i=\${i};l=\${l};b=\${b};flag=\${flag};c=\${c};f=\${f};d=\${d};text=\${text};none=\${none}"
export function adjacent(value: int, flag: bool): string => "\${value}\${flag}"
export function plain(): string => "no expressions"
`
  module_ := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")!
  i := -2147483647 - 1
  l := -9223372036854775807L - 1L
  b := byte(255)
  f := float(1.23456789)
  d := 1.23456789
  expected := formatJsonValue("i=${i};l=${l};b=${b};flag=${true};c=${'A'};f=${f};d=${d};text=${"value"};none=${none}")
  checkFormatting(module_, `
assert.strictEqual(api.render(-2147483648,-9223372036854775808n,255,true,65,1.23456789,1.23456789,'value'),${expected});
assert.strictEqual(api.adjacent(0,false),'0false');assert.strictEqual(api.adjacent(-1,true),'-1true');
assert.strictEqual(api.plain(),'no expressions');
for(const size of [0,1023,1024,1025,262145]){
 const text='x'.repeat(size)+'\\0tail';
 assert.strictEqual(api.render(0,1n,2,false,255,0,0,text),'i=0;l=1;b=2;flag=false;c=ÿ;f=0;d=0;text='+text+';none=null');
}
for(let i=0;i<30;i++)api.render(i,BigInt(i),255,true,65,1.5,2.5,'x'.repeat(1025));
`)
}

export function testInterpolationEvaluatesOnceInOrderAcrossBranchesAndClosures(): none {
  source := `
class Counter { let value: int = 0 }
function next(counter: Counter): int { counter.value += 1; return counter.value }
export function ordered(flag: bool): string {
  counter := Counter {}
  let text = "start"
  render := (): string => "\${text}:\${next(counter)}:A\${if flag then next(counter) else 0}:B\${next(counter)}:\${flag}"
  text = "changed"
  result := render()
  return result + ":" + string(counter.value)
}
export function nested(flag: bool): string => "outer=\${if flag then "inner=\${2}" else "no"}!"
`
  module_ := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")!
  checkFormatting(module_, `
for(let i=0;i<30;i++){
 assert.strictEqual(api.ordered(true),'changed:1:A2:B3:true:3');
 assert.strictEqual(api.ordered(false),'changed:1:A0:B2:false:2');
 assert.strictEqual(api.nested(true),'outer=inner=2!');assert.strictEqual(api.nested(false),'outer=no!');
}
`)
}

export function testInterpolationImportedEnumNamesAndPanicCleanup(): none {
  sources := [
    SourceFile { path: "/kind.do", source: `
export enum State { cold = -7, ready = 9, done = 2147483647 }
export function state(ready: bool): State => if ready then .ready else .cold
export function name(): string => string(State.done)
` },
    SourceFile { path: "/main.do", source: `
import { State as Phase, state, name } from "./kind"
function invalid(): Phase => Phase.ready
function fail(): string { values := ["owned"]; panic(values[0]) }
export function render(ready: bool): string => "phase=\${state(ready)}:end=\${name()}"
export function explicit(ready: bool): string => string(state(ready))
export function caught(): string {
  result := catchPanic((): string => "prefix=\${["temporary"][0]}:\${fail()}:unreached")
  case result { failure: Failure<string> -> { return failure.error } _ -> { return "unexpected" } }
}

export function diverges(): string => "prefix=\${panic("never value")}:unreached"
export function escaping(): string => "prefix=\${fail()}:unreached"
export function invalidName(): string => string(invalid())
export function caughtInvalid(): string {
  result := catchPanic((): string => "prefix=\${invalid()}")
  case result { failure: Failure<string> -> { return failure.error } _ -> { return "unexpected" } }
}
` },
  ]
  module_ := lowerDoofWasmSources{sources, entry: "/main.do", options: WasmLoweringOptions { synchronousAsync: true }}!
  // Exercise the native invalid-enum path by corrupting only the producer's
  // backing constant. Checked Doof source cannot manufacture invalid enums.
  for function_ of module_.functions {
    if !function_.name.endsWith("_invalid") { continue }
    for block of minusBlocks(function_) {
      for instruction of block.instructions {
        if instruction.op == "const" && instruction.args[0] == "9" { instruction.args[0] = "123" }
      }
    }
  }
  checkFormatting(module_, `
for(let i=0;i<30;i++){
 assert.strictEqual(api.render(true),'phase=ready:end=done');assert.strictEqual(api.render(false),'phase=cold:end=done');
 assert.strictEqual(api.explicit(true),'ready');assert.strictEqual(api.explicit(false),'cold');
 assert.strictEqual(api.caught(),'owned');assert.throws(()=>api.escaping(),/owned/);
 assert.throws(()=>api.diverges(),/never value/);
 assert.strictEqual(api.caughtInvalid(),'Invalid State enum value: 123');
 assert.throws(()=>api.invalidName(),/Invalid State enum value: 123/);
 assert.deepStrictEqual(live(),baseline,'caught and escaping formatting panics clean up');
}
`)
}

export function testSelfHostingHexPublicationMatchesNative(): none {
  Assert.equal(encodeWasmHex([]), "")
  Assert.equal(encodeWasmHex([byte(0), byte(1), byte(15), byte(16), byte(127), byte(128), byte(255)]), "00010f107f80ff")
  bytes: byte[] := []
  for index of 0..<1025 { bytes.push(byte(index % 256)) }
  nativeHex := formatJsonValue(encodeWasmHex(bytes))
  sources := [
    SourceFile { path: "/selfhost-hex.do", source: readText("src/selfhost-hex.do")! },
    SourceFile { path: "/main.do", source: `
import { encodeWasmHex } from "./selfhost-hex"
export function encode(count: int): string {
  bytes: byte[] := []
  bytes.reserve(count)
  for index of 0..<count { bytes.push(byte(index % 256)) }
  return encodeWasmHex(bytes)
}
` },
  ]
  module_ := lowerDoofWasmSources(sources, "/main.do")!
  checkFormatting(module_, `
assert.strictEqual(api.encode(1025),${nativeHex});
for(const size of [0,1,255,256,257,1023,1024,1025,262145]){
 const expected=Buffer.from(Array.from({length:size},(_,i)=>i%256)).toString('hex');
 assert.strictEqual(api.encode(size),expected);
}
for(let i=0;i<20;i++)assert.strictEqual(api.encode(257),Buffer.from(Array.from({length:257},(_,i)=>i%256)).toString('hex'));
`)
}
