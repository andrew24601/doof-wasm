import { Assert } from "std/assert"
import { BlobReader, BlobBuilder } from "std/blob"
import { sha256HexString } from "std/crypto"
import { parseDouble } from "std/parse"
import { formatJsonValue } from "std/json"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { Parser } from "doof/src/parser"
import { ImmutableBinding, CallExpression, ArrayLiteral, StringLiteral, IntLiteral, LongLiteral } from "doof/src/ast"
import { lowerDoofWasmSources, WasmLoweringOptions } from "./doof-compiler"
import { encodeDoofMinus, compileDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"
import { nativeSourceEnvironment } from "./source-environment-native"

function runStdSource(source: string, name: string, script: string, options: WasmLoweringOptions = WasmLoweringOptions {}): none {
  environment := nativeSourceEnvironment("src/doof-cli.do", "std/wasm")!
  lowered := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do", (path: string): Result<SourceFile | none, Diagnostic> => environment.load(path), options)
  module_ := lowered else error { panic(error) }
  bytes := encodeDoofMinus(module_, true)!
  base := "/tmp/doof-wasm-stdlib-" + string(pid()) + "-" + name
  writeBlob(base + ".wasm", bytes.cloneReadonly())!
  writeText(base + ".mjs", renderDoofJs(module_, true))!
  result := run("node", ["-e", `
const fs=require('fs'), assert=require('assert'), {pathToFileURL}=require('url');
(async()=>{
const ffi=await import(pathToFileURL(process.argv[1]+'.mjs').href);
const bytes=fs.readFileSync(process.argv[1]+'.wasm');
${script}
})().catch(error=>{console.error(error);process.exit(1)});
`, base], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
  remove(base + ".wasm")!
  remove(base + ".mjs")!
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

export function testWasmStdlibNumericParsingAndIeeeBytes(): none {
  runStdSource(`
import { parseLong, parseInt, parseByte, parseDouble, parseFloat, ParsingError } from "std/parse"
import { BlobBuilder } from "std/blob"
export function integer(text: string): long { value := parseLong(text) else { return 99L }; return value }
export function forced(text: string): long => parseLong(text)!
export function integerError(text: string): int { value := parseLong(text) else error { return error.value }; return -1 }
export function narrowError(text: string): int { value := parseInt(text) else error { return error.value }; return -1 }
export function byteError(text: string): int { value := parseByte(text) else error { return error.value }; return -1 }
export function decimal(text: string): double { value := parseDouble(text) else { return -1.0 }; return value }
export function decimalError(text: string, single: bool): int {
  if single { value := parseFloat(text) else error { return error.value }; return -1 }
  value := parseDouble(text) else error { return error.value }; return -1
}
export function floatByte(value: float, index: int): int { builder := BlobBuilder {}; builder.writeFloat(value); return int(builder.build()[index]) }
export function doubleByte(value: double, index: int): int { builder := BlobBuilder {}; builder.writeDouble(value); return int(builder.build()[index]) }
export function snapshot(): int { builder := BlobBuilder {}; builder.writeFloat(float(1.0)); first := builder.build(); builder.writeFloat(float(2.0)); return first.length }
export function copies(length: int): int {
  let bytes: byte[] = []
  for index of 0..<length { bytes.push(byte(index % 256)) }
  frozen := bytes.cloneReadonly()
  copy := frozen.cloneMutable()
  if length > 0 { bytes[0] = byte(255); copy[0] = byte(254) }
  for index of 0..<length { if frozen[index] != byte(index % 256) { return -1 } }
  return frozen.length + copy.length
}
`, "numeric", `
const bridge=ffi.createDoofImports(ffi.createDoofStdHost());
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance);
for(const n of [0n,1n,-1n,9223372036854775807n,-9223372036854775808n]) assert.strictEqual(api.integer(String(n)),n);
assert.strictEqual(api.integer('+42'),42n);
for(const s of ['','+',' 1','1 ','1x','1.0']) assert(api.integerError(s)>=0,s);
assert.strictEqual(api.integerError('9223372036854775808'),1);
assert.strictEqual(api.integerError('-9223372036854775809'),2);
assert.strictEqual(api.narrowError('2147483647'),-1);assert.strictEqual(api.narrowError('2147483648'),1);
assert.strictEqual(api.narrowError('-2147483649'),2);
assert.strictEqual(api.byteError('255'),-1);assert.strictEqual(api.byteError('256'),1);assert.strictEqual(api.byteError('-1'),2);
for(const s of ['0','-0','1.5','1e30','-.25']) assert.strictEqual(api.decimal(s),Number(s));
assert.strictEqual(api.decimalError('0x10',false),0);assert.strictEqual(api.decimalError('1e999',false),1);
assert.strictEqual(api.decimalError('1e-999',false),2);assert.strictEqual(api.decimalError('1e39',true),1);
for(const v of [0,-0,1,-1,1.5,Infinity,-Infinity,NaN,Number.MIN_VALUE,Number.MAX_VALUE]) {
 const data=new DataView(new ArrayBuffer(8));data.setFloat64(0,v,true);
 for(let i=0;i<8;i++) assert.strictEqual(api.doubleByte(v,i),data.getUint8(i),String(v)+' byte '+i);
 data.setFloat32(0,v,true);for(let i=0;i<4;i++) assert.strictEqual(api.floatByte(v,i),data.getUint8(i));
}
assert.strictEqual(api.snapshot(),4);
const heap=ffi.createDoofHeapInspector(instance), live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(const length of [0,1,1023,1024,1025,2050]) assert.strictEqual(api.copies(length),length*2);
for(let i=0;i<20;i++) { api.copies(1025);api.decimal('1.5');api.integerError('bad'); }
assert.deepStrictEqual(live(),baseline);
assert.strictEqual(api.forced('-9223372036854775808'),-9223372036854775808n);
assert.throws(()=>api.forced('invalid'),WebAssembly.RuntimeError);
`)
}

export function testWasmStdlibCompilerIoProtocol(): none {
  runStdSource(`
import { readText, writeText, writeBlob } from "std/fs"
import { absolute } from "std/path"
export function read(path: string): string { value := readText(path) else { return "failed" }; return value }
export function readError(path: string): int { value := readText(path) else error { return error.value }; return -1 }
export function text(path: string, value: string): int { _ := writeText(path,value) else error { return error.value }; return -1 }
export function blob(path: string): int { _ := writeBlob(path,[byte(0),byte(128),byte(255)]) else error { return error.value }; return -1 }
export function path(value: string): string { result := absolute(value) else { return "failed" }; return result }
`, "io", `
const files=new Map([['input','']]);
const io={readText:path=>{if(!files.has(path))throw Object.assign(new Error('missing'),{code:'ENOENT'});return files.get(path)},
writeText:(path,text)=>files.set(path,text),writeBlob:(path,data)=>{if(path==='denied')throw Object.assign(new Error('denied'),{code:'EACCES'});files.set(path,Array.from(data))},absolute:path=>'/project/'+path};
const bridge=ffi.createDoofImports(ffi.createDoofStdHost(io));const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance);
assert.strictEqual(api.read('input'),'');assert.strictEqual(api.readError('missing'),0);
assert.strictEqual(api.text('text','hello'),-1);assert.strictEqual(api.read('text'),'hello');
assert.strictEqual(api.blob('bytes'),-1);assert.deepStrictEqual(files.get('bytes'),[0,128,255]);
assert.strictEqual(api.blob('denied'),1);assert.strictEqual(api.path('input'),'/project/input');
for(let i=0;i<20;i++){assert.strictEqual(api.read('text'),'hello');assert.strictEqual(api.blob('bytes'),-1)}
`)
}

export function testWasmStdlibPhaseTimingsClockContract(): none {
  runStdSource(`
import { PhaseTimings } from "doof/src/phase-timings"
import { MonotonicInstant } from "std/time"
export function disabled(): string {
  timings := PhaseTimings {}
  started := timings.start()
  timings.finish("unused", started)
  timings.record("unused", 42L)
  return timings.render()
}
export function enabled(): string {
  timings := PhaseTimings { enabled: true }
  timings.finish("absent", none)
  first := timings.start()
  timings.finish("parse", first)
  second := timings.start()
  timings.finish("parse", second)
  timings.record("lower", 500000L)
  return timings.render()
}
export function duration(): long {
  first := MonotonicInstant.now()
  return first.durationUntil(MonotonicInstant.now()).toNanos()
}
`, "time", `
let calls=0, clock=0n;
const host=ffi.createDoofStdHost({monotonicNanos:()=>{calls++;clock+=1250000n;return clock;}});
const bridge=ffi.createDoofImports(host);
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance);
const heap=ffi.createDoofHeapInspector(instance), live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let i=0;i<20;i++) assert.strictEqual(api.disabled(),'');
assert.strictEqual(calls,0);
for(let i=0;i<20;i++) {
 assert.strictEqual(api.enabled(),'[timings] wall milliseconds; parent phases include their children\\n[timings] parse ms=2.5 count=2\\n[timings] lower ms=0.5 count=1\\n');
 assert.strictEqual(api.duration(),1250000n);
}
assert.strictEqual(calls,120);
assert.deepStrictEqual(live(),baseline);
assert.throws(()=>ffi.createDoofStdHost().doofStdMonotonicNanos(),/missing compiler host operation monotonicNanos/);
for(const value of [undefined,0,1.5,-1n,9223372036854775808n,Promise.resolve(1n)]) {
 assert.throws(()=>ffi.createDoofStdHost({monotonicNanos:()=>value}).doofStdMonotonicNanos(),/signed 64-bit bigint synchronously/);
}
let tick=4n;const decreasing=ffi.createDoofStdHost({monotonicNanos:()=>tick});
assert.strictEqual(decreasing.doofStdMonotonicNanos(),4n);
assert.strictEqual(decreasing.doofStdMonotonicNanos(),4n);
tick=3n;assert.throws(()=>decreasing.doofStdMonotonicNanos(),/must not decrease/);
const limit=ffi.createDoofStdHost({monotonicNanos:()=>9223372036854775807n});
assert.strictEqual(limit.doofStdMonotonicNanos(),9223372036854775807n);
`, WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true })
}

export function testWasmFloatingFormattingMatchesNative(): none {
  let fixtures = "["
  tiny := parseDouble("1e-100")!
  large := parseDouble("1e100")!
  for value of [0.0, -0.0, 1.25, -1.25, 0.00001, 0.0001, 100000.0, 1000000.0, 123456.5, 123457.5, -123456.5, 1234567.0, 1.23456789, 9.999999, tiny, large] {
    if fixtures != "[" { fixtures += "," }
    // Exact IEEE bytes carry the input; the expected spelling is native Doof.
    builder := BlobBuilder {}
    builder.writeDouble(value)
    fixtures += "{bytes:["
    data := builder.build()
    for index of 0..<data.length {
      if index > 0 { fixtures += "," }
      fixtures += string(data[index])
    }
    fixtures += "],double:'" + string(value) + "',float:'" + string(float(value)) + "'}"
  }
  fixtures += "]"
  runStdSource(`
export function formatDouble(value: double): string => string(value)
export function formatFloat(value: float): string => string(value)
export function twice(value: double): string => string(value) + string(value)
`, "format-float", `
const bridge=ffi.createDoofImports(ffi.createDoofStdHost());
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance);
const heap=ffi.createDoofHeapInspector(instance), live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let pass=0;pass<20;pass++) for(const fixture of ${fixtures}) {
 const value=new DataView(Uint8Array.from(fixture.bytes).buffer).getFloat64(0,true);
 assert.strictEqual(api.formatDouble(value),fixture.double);
 assert.strictEqual(api.formatFloat(value),fixture.float);
 assert.strictEqual(api.twice(value),fixture.double+fixture.double);
}
for(const [value,expected] of [[NaN,'nan'],[Infinity,'inf'],[-Infinity,'-inf'],[-0,'-0']]) {
 assert.strictEqual(api.formatDouble(value),expected);assert.strictEqual(api.formatFloat(value),expected);
}
assert.deepStrictEqual(live(),baseline);
`)
}

export function testWasmStaticMethodsAndImplicitInstanceMembers(): none {
  runStdSource(`
class A {
  let value: int
  static b_c(value: int = 7): A => A { value }
  increment(amount: int): none { value += amount }
  apply(): int {
    increment(3)
    let next = (): int => { increment(2); return value }
    return next()
  }
  shadow(value: int): int => value
}
class A_b {
  static c(): int => 99
}
export function check(): int {
  first := A.b_c()
  second := A.b_c{ value: 20 }
  return first.apply() + second.apply() + first.shadow(5) + A_b.c()
}
`, "static-methods", `
const {instance}=await WebAssembly.instantiate(bytes);
const api=ffi.createDoofModule(instance);
const heap=ffi.createDoofHeapInspector(instance), live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let i=0;i<20;i++) assert.strictEqual(api.check(),141);
assert.deepStrictEqual(live(),baseline);
`)
}
export function testWasmStdlibSha256MatchesNative(): none {
  byteBuilder := BlobBuilder {}
  for index of 0..<256 { byteBuilder.writeByte(byte(index)) }
  allBytes := BlobReader(byteBuilder.build()).readString(256L)
  let longSource = ""
  for index of 0..<8193 { longSource += "a" }
  // Hex transports native byte strings into JS without changing their encoding.
  digits := "0123456789abcdef"
  let fixtures = "["
  for source of ["", "abc", "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", allBytes, longSource] {
    let hex = ""
    for index of 0..<source.length {
      value := int(source[index])
      hex += string(digits[value \ 16]) + string(digits[value % 16])
    }
    if fixtures != "[" { fixtures += "," }
    fixtures += "{hex:'" + hex + "',digest:'" + sha256HexString(source) + "'}"
  }
  fixtures += "]"
  runStdSource(`
import { sha256HexString } from "std/crypto"
export function digest(source: string): string => sha256HexString(source)
`, "sha256", `
const crypto=require('crypto');
const host=ffi.createDoofStdHost({sha256HexString:text=>crypto.createHash('sha256').update(Buffer.from(text,'latin1')).digest('hex')});
const bridge=ffi.createDoofImports(host);
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance);
const fixtures=${fixtures};
assert.strictEqual(fixtures[0].digest,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
assert.strictEqual(fixtures[1].digest,'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
const heap=ffi.createDoofHeapInspector(instance), live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let pass=0;pass<10;pass++) for(const fixture of fixtures) assert.strictEqual(api.digest(Buffer.from(fixture.hex,'hex').toString('latin1')),fixture.digest);
assert.deepStrictEqual(live(),baseline);
assert.throws(()=>ffi.createDoofStdHost().doofStdSha256HexString('abc'),/missing compiler host operation sha256HexString/);
for(const value of [undefined,42,'', 'a'.repeat(63),'A'.repeat(64),'g'.repeat(64),Promise.resolve('a'.repeat(64))]) {
 assert.throws(()=>ffi.createDoofStdHost({sha256HexString:()=>value}).doofStdSha256HexString('abc'),/64 lowercase hexadecimal characters synchronously/);
}
`)
}

export function testWasmStdlibSelfHostedEncoderMatchesNativeBytes(): none {
  let fixtures = "["
  for typeName of ["int", "long", "float", "double"] {
    literal := if typeName == "int" then "42" else if typeName == "long" then "-9223372036854775808" else "-1.5"
    fixture := "export func answer() -> " + typeName + "\nblock entry\n%answer:" + typeName + " = const " + literal + "\nreturn %answer\nend\n"
    native := compileDoofMinus(fixture)!
    if fixtures != "[" { fixtures += "," }
    fixtures += "{source:'export func answer() -> " + typeName + "\\nblock entry\\n%answer:" + typeName + " = const " + literal + "\\nreturn %answer\\nend\\n',bytes:["
    for index of 0..<native.length {
      if index > 0 { fixtures += "," }
      fixtures += string(native[index])
    }
    fixtures += "]}"
  }
  fixtures += "]"
  runStdSource(`
import { compile as compileModule } from "doof-wasm/examples/selfhost-encoder"
export function compile(source: string, path: string): string => compileModule(source,path)
`, "encoder", `
let output;
const bridge=ffi.createDoofImports(ffi.createDoofStdHost({writeBlob:(path,data)=>{output=Array.from(data)}}));
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance);
for(const fixture of ${fixtures}) {
 assert.strictEqual(api.compile(fixture.source,'output'),'ok');assert.deepStrictEqual(output,fixture.bytes);
 const {instance:compiled}=await WebAssembly.instantiate(Uint8Array.from(output));
 assert.strictEqual(compiled.exports.answer(),fixture.source.includes('long')?-9223372036854775808n:fixture.source.includes('int')?42:-1.5);
}
assert(api.compile('garbage','output').includes('invalid declaration'));
`)
}

function parserSnapshot(source: string): string {
  parser := Parser { source }
  parsed := catchPanic(=> parser.parse())
  program := parsed else error { return "error:" + string(parser.errorLine) + ":" + string(parser.errorColumn) + ":" + parser.errorMessage }
  let summary = ""
  for statement of program.statements {
    summary += statement.kind + ":" + string(statement.span.start.offset) + ":" + string(statement.span.end.offset) + "\n"
    case statement {
      binding: ImmutableBinding -> {
        case binding.value {
          integer: IntLiteral -> { summary += string(integer.value) + "\n" }
          wide: LongLiteral -> { summary += string(wide.value) + "\n" }
          text: StringLiteral -> { summary += text.value + "\n" }
          call: CallExpression -> {
            for argument of call.args {
              if argument.name != "children" { continue }
              case argument.value {
                children: ArrayLiteral -> {
                  for child of children.elements {
                    case child { text: StringLiteral -> { summary += text.value + "\n" } _ -> { } }
                  }
                }
                _ -> { }
              }
            }
          }
          _ -> { }
        }
      }
      _ -> { }
    }
  }
  return summary
}

export function testSelfHostingRealParserMatchesNativeAndRecoversFromMalformedInput(): none {
  fixtures := [
    "", "value := 30_000\nwide := 0xFF_FFL\ntext := \"a\\07\"",
    "value := <Foo>\r\n    hello\r\n    world\r\n</Foo>",
    "value := <Foo>\n    hello {name}\n    world\n</Foo>",
    "class Box { value: int }\nfunction make(): Box => Box { value: 42 }",
    "value := <Foo></Bar>", "value := <Foo id=1 id=2/>",
    "value := <Foo children={items}>text</Foo>", "function broken( {", "value := (1 + )",
  ]
  let rows = ""
  for source of fixtures { rows += "[" + formatJsonValue(source) + "," + formatJsonValue(parserSnapshot(source)) + "]," }
  runStdSource(`
import { Parser } from "doof/src/parser"
import { ImmutableBinding, CallExpression, ArrayLiteral, StringLiteral, IntLiteral, LongLiteral } from "doof/src/ast"
export function parse(source: string): string {
  parser := Parser { source }
  parsed := catchPanic(=> parser.parse())
  program := parsed else error { return "error:" + string(parser.errorLine) + ":" + string(parser.errorColumn) + ":" + parser.errorMessage }
  let summary = ""
  for statement of program.statements {
    summary += statement.kind + ":" + string(statement.span.start.offset) + ":" + string(statement.span.end.offset) + "\\n"
    case statement {
      binding: ImmutableBinding -> {
        case binding.value {
          integer: IntLiteral -> { summary += string(integer.value) + "\\n" }
          wide: LongLiteral -> { summary += string(wide.value) + "\\n" }
          text: StringLiteral -> { summary += text.value + "\\n" }
          call: CallExpression -> {
            for argument of call.args {
              if argument.name != "children" { continue }
              case argument.value {
                children: ArrayLiteral -> {
                  for child of children.elements {
                    case child { text: StringLiteral -> { summary += text.value + "\\n" } _ -> { } }
                  }
                }
                _ -> { }
              }
            }
          }
          _ -> { }
        }
      }
      _ -> { }
    }
  }
  return summary
}
`, "real-parser", `
const host=ffi.createDoofStdHost();host['doof_runtime.hpp']={'doof::char_from_utf8':value=>value.charCodeAt(0)};
const bridge=ffi.createDoofImports(host);
const {instance}=await WebAssembly.instantiate(bytes,bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
for(let i=0;i<3;i++)for(const [source,expected] of [${rows}]) {
 assert.strictEqual(api.parse(source),expected,'native parser parity for '+source.slice(0,50));
 assert.deepStrictEqual(live(),baseline,'AST, token arrays, and parser panic temporaries released');
}
`, WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true })
}
