import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { readText, remove, writeBlob, writeText } from "std/fs"
import { formatJsonValue } from "std/json"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { Lexer, tokenValue } from "doof/src/lexer"
import { lowerDoofWasmSources, WasmLoweringOptions } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function checkStrings(sources: SourceFile[], script: string, options: WasmLoweringOptions = WasmLoweringOptions {}): none {
  module_ := lowerDoofWasmSources{sources, entry: "/main.do", options} else error { panic(error) }
  bytes := encodeDoofMinus(module_, true)!
  base := "/tmp/doof-string-methods-" + string(pid())
  writeBlob(base + ".wasm", bytes.cloneReadonly())!
  writeText(base + ".mjs", renderDoofJs(module_, true))!
  result := run("node", ["-e", `
const fs=require('fs'),assert=require('assert'),{pathToFileURL}=require('url');
(async()=>{
const ffi=await import(pathToFileURL(process.argv[1]+'.mjs').href);
const calls=[];
const bridge=ffi.createDoofImports({echo:value=>{calls.push(value);return value;},'doof_runtime.hpp':{'doof::char_from_utf8':value=>value.charCodeAt(0)}});
const {instance}=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]+'.wasm'),bridge.imports);bridge.attach(instance);
const api=ffi.createDoofModule(instance),heap=ffi.createDoofHeapInspector(instance);
const live=()=>heap.dumpHeap().filter(block=>block.kind!=='free').map(block=>[block.address,block.kind,block.refCount]);
const baseline=live();
${script}
})().catch(error=>{console.error(error);process.exit(1)});
`, base], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
  remove(base + ".wasm")!
  remove(base + ".mjs")!
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}

function dataSectionSize(bytes: byte[]): int {
  let cursor = 8
  while cursor < bytes.length {
    section := int(bytes[cursor]); cursor += 1
    let size = 0
    let factor = 1
    while true {
      part := int(bytes[cursor]); cursor += 1
      size += (part % 128) * factor
      if part < 128 { break }
      factor *= 128
    }
    if section == 11 { return size }
    cursor += size
  }
  return 0
}

export function testLiteralDataInitializesWithoutStartupCode(): none {
  let source = ""
  let pooled = ""
  for index of 0..<300 {
    prefix := "export function literal" + string(index) + "(): string => "
    source += prefix + formatJsonValue("literal-" + string(index)) + "\n"
    pooled += prefix + "\"pooled\"\n"
  }
  sources := [SourceFile { path: "/main.do", source }]
  distinct := encodeDoofMinus(lowerDoofWasmSources{sources, entry: "/main.do"}!)!
  shared := encodeDoofMinus(lowerDoofWasmSources{sources: [SourceFile { path: "/main.do", source: pooled }], entry: "/main.do"}!)!
  // Shared literals now also share function bodies. Compare the data section
  // itself so this bound measures the static object graphs.
  Assert.isTrue(dataSectionSize(distinct) - dataSectionSize(shared) < 30000, "Each literal should add its static object graph")
  checkStrings(sources, `
const bytes=fs.readFileSync(process.argv[1]+'.wasm'),sections=[];
let position=8;
const leb=()=>{let value=0,shift=0,part;do{part=bytes[position++];value+=(part&127)*2**shift;shift+=7;}while(part&128);return value;};
while(position<bytes.length){sections.push(bytes[position++]);const length=leb();position+=length;}
assert(sections.includes(11),'literals have a data section');
assert(!sections.includes(8),'literals need no module start function');
assert(!sections.includes(12),'literals need no passive data count');
for(let repeat=0;repeat<3;repeat++)for(let index=0;index<300;index++) {
 assert.strictEqual(api['literal'+index](),'literal-'+index);
}
assert.deepStrictEqual(live(),baseline,'static literal roots keep stable ownership');
`)
}

export function testStaticLiteralGraphsCoverStorageBoundaries(): none {
  lengths := [0,1,15,16,17,1023,1024,1025,262144,262145]
  let source = ""
  for index of 0..<lengths.length {
    source += "export function literal" + string(index) + "(): string => " + formatJsonValue("x".repeat(lengths[index])) + "\n"
  }
  source += "export function withArgument(text: string): string => literal7() + text\n"
  checkStrings([SourceFile { path: "/main.do", source }], `
const lengths=[0,1,15,16,17,1023,1024,1025,262144,262145];
for(let repeat=0;repeat<3;repeat++)for(let index=0;index<lengths.length;index++) {
 assert.strictEqual(api['literal'+index](),'x'.repeat(lengths[index]));
 assert.deepStrictEqual(live(),baseline,'static compact/radix storage remains rooted');
}
for(let repeat=0;repeat<10;repeat++) {
 assert.strictEqual(api.withArgument('tail'),'x'.repeat(1025)+'tail');
 assert.deepStrictEqual(live(),baseline,'dynamic allocations preserve static heap prefix');
}
const second=await WebAssembly.instantiate(fs.readFileSync(process.argv[1]+'.wasm'),bridge.imports);
const secondApi=ffi.createDoofModule(second.instance);
assert.strictEqual(secondApi.literal9(),'x'.repeat(262145));
assert.notStrictEqual(second.instance.exports.__doof_ffi_memory.buffer,instance.exports.__doof_ffi_memory.buffer);
`)
}

export function testStringReplaceAllMatchesNativeSemantics(): none {
  fixtures := [
    ["", "", "insert"], ["abc", "", "insert"], ["", "a", "b"],
    ["abc", "missing", ""], ["abc", "abcd", "x"], ["aaaaa", "aa", "b"],
    ["aaa", "a", "aa"], ["aaaa", "aa", ""], ["abab", "ab", "ba"],
    ["ababa", "aba", "x"], ["one old old", "old", "new"], ["x", "x", "x"],
    ["1_000_000", "_", ""], ["a\r\nb\rc", "\r\n", "\n"],
    ["$x$x", "$x", "$&$$"], ["a" + string('\0') + "a", string('\0'), "zero"],
  ]
  let rows = ""
  for fixture of fixtures {
    rows += "[" + formatJsonValue(fixture[0]) + "," + formatJsonValue(fixture[1]) + "," + formatJsonValue(fixture[2]) + "," + formatJsonValue(fixture[0].replaceAll(fixture[1], fixture[2])) + "],"
  }
  checkStrings([SourceFile { path: "/main.do", source: `
export function replace(text: string, search: string, replacement: string): string => text.replaceAll(search, replacement)
` }], `
for(let i=0;i<10;i++)for(const [text,search,replacement,expected] of [${rows}]) {
 assert.strictEqual(api.replace(text,search,replacement),expected,'native replacement parity');
 assert.deepStrictEqual(live(),baseline,'results and no-op arguments released');
}
assert.strictEqual(api.replace(String.fromCharCode(255)+'a'+String.fromCharCode(255),String.fromCharCode(255),String.fromCharCode(128)),String.fromCharCode(128)+'a'+String.fromCharCode(128));
assert.deepStrictEqual(live(),baseline);
`)
}

export function testStringReplaceAllCrossesChunksAndReusesStorage(): none {
  checkStrings([SourceFile { path: "/main.do", source: `
export function replace(text: string, search: string, replacement: string): string => text.replaceAll(search, replacement)
` }], `
const nativeReplace=(text,search,replacement)=>search===''?text:text.split(search).join(replacement);
for(const length of [0,1,15,16,17,1023,1024,1025,2048,2049,262144,262145]) {
 const text=('ab_').repeat(Math.ceil(length/3)).slice(0,length);
 for(const [search,replacement] of [['_',''],['ab','xyz'],['ab_','ab_'],['missing','new']]) {
  assert.strictEqual(api.replace(text,search,replacement),nativeReplace(text,search,replacement));
  assert.deepStrictEqual(live(),baseline,'chunked result released at '+length);
 }
}
for(const offset of [1019,1023,1024,262143]) {
 const search='needle'.repeat(200),replacement='expanded'.repeat(300);
 const text='x'.repeat(offset)+search+'!'+search+'tail';
 assert.strictEqual(api.replace(text,search,replacement),'x'.repeat(offset)+replacement+'!'+replacement+'tail');
 assert.deepStrictEqual(live(),baseline,'search and replacement cross storage boundaries');
}
const text='a_'.repeat(131073),replacement='bc'.repeat(513);
assert.strictEqual(api.replace(text,'a_',replacement.slice(0,3)),replacement.slice(0,3).repeat(131073));
const end=instance.exports.__doof_debug_heap_end.value;
for(let i=0;i<3;i++) {
 assert.strictEqual(api.replace(text,'a_',replacement.slice(0,3)),replacement.slice(0,3).repeat(131073));
 assert.deepStrictEqual(live(),baseline);
 assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'replacement storage reused');
}
`)
}

export function testStringReplaceAllOwnsTemporariesImportsClosuresAndAliases(): none {
  checkStrings([
    SourceFile { path: "/replace.do", source: `
export function normalize(text: string): string => text.replaceAll("_", "")
` },
    SourceFile { path: "/main.do", source: `
import { normalize as clean } from "./replace"
import function echo(text: string): string
export function ordered(): string => echo("old_old").replaceAll(echo("old"), echo("new"))
export function check(text: string): string {
  alias := text
  replace := (search: string): string => alias.replaceAll(search, text)
  pieces := [replace("_"), clean(text), text.replaceAll(text, text)]
  return pieces[0] + ":" + pieces[1] + ":" + pieces[2] + ":" + alias
}
export function discarded(text: string): none { _ := (text + text).replaceAll("_", "long replacement") }
` },
  ], `
for(let i=0;i<20;i++) {
 calls.length=0;assert.strictEqual(api.ordered(),'new_new');assert.deepStrictEqual(calls,['old_old','old','new']);
 assert.strictEqual(api.check('a_b'),'aa_bb:ab:a_b:a_b');
 api.discarded('a_'.repeat(1025));assert.deepStrictEqual(live(),baseline,'temporaries and captured aliases released');
}
`)
}

export function testStringReplaceAllRejectsOverflowAndRecoversFromPanics(): none {
  checkStrings([SourceFile { path: "/main.do", source: `
function replace(text: string, replacement: string): string => text.replaceAll("a", replacement)
export function caught(text: string, replacement: string): bool {
  completion := async replace(text, replacement)
  case completion.get() { failure: Failure<string> -> { return failure.error == "String replacement exceeds the array length limit" } _ -> { return false } }
}
export function escaping(text: string, replacement: string): string => replace(text, replacement)
export function valid(text: string): string => text.replaceAll("a", "ok")
` }], `
// A 4 GiB output would wrap a 32-bit product; reject it before allocation.
const text='a'.repeat(65536),replacement='b'.repeat(65536);
for(let i=0;i<5;i++) {
 assert.strictEqual(api.caught(text,replacement),true);assert.deepStrictEqual(live(),baseline,'caught overflow releases inputs');
 assert.throws(()=>api.escaping(text,replacement));assert.deepStrictEqual(live(),baseline,'escaping overflow releases inputs');
 assert.strictEqual(api.valid('a_a'),'ok_ok');assert.deepStrictEqual(live(),baseline,'success after panic');
 if(i===0)var end=instance.exports.__doof_debug_heap_end.value;
 else assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'panic storage reused');
}
`, WasmLoweringOptions { synchronousAsync: true })
}

export function testStringTrimmingMatchesNativeWhitespaceAndSuffixSemantics(): none {
  whitespace := BlobReader([byte(32), byte(9), byte(10), byte(11), byte(12), byte(13)]).readString(6L)
  fixtures := ["", "plain", whitespace, whitespace + "middle" + whitespace, " a b ", "left\n", "\nright", string('\0') + " x " + string('\0')]
  let rows = ""
  for text of fixtures {
    rows += "[" + formatJsonValue(text) + "," + formatJsonValue(text.trim()) + "," + formatJsonValue(text.trimStart()) + "," + formatJsonValue(text.trimEnd()) + "],"
  }
  let suffixRows = ""
  for text of ["", "___", "__inside__", "_middle ", " x " + string('\0') + string('\0')] {
    for suffix of ['_', '\0', ' '] {
      suffixRows += "[" + formatJsonValue(text) + "," + string(int(suffix)) + "," + formatJsonValue(text.trimEnd(suffix)) + "],"
    }
  }
  checkStrings([SourceFile { path: "/main.do", source: `
export function trim(text: string): string => text.trim()
export function start(text: string): string => text.trimStart()
export function end(text: string): string => text.trimEnd()
export function suffix(text: string, character: char): string => text.trimEnd(character)
` }], `
for(let i=0;i<20;i++) {
 for(const [text,trimmed,start,end] of [${rows}]) {
  assert.strictEqual(api.trim(text),trimmed);assert.strictEqual(api.start(text),start);assert.strictEqual(api.end(text),end);
  assert.deepStrictEqual(live(),baseline,'trimmed strings released');
 }
 for(const [text,suffix,expected] of [${suffixRows}]) {
  assert.strictEqual(api.suffix(text,suffix),expected);assert.deepStrictEqual(live(),baseline,'explicit suffix released');
 }
}
// These byte characters are not in the native whitespace set.
for(const code of [0,8,14,31,127,160,255]) {
 const text=String.fromCharCode(code)+'x'+String.fromCharCode(code);
 assert.strictEqual(api.trim(text),text);assert.strictEqual(api.start(text),text);assert.strictEqual(api.end(text),text);
 assert.strictEqual(api.suffix(text,code),text.slice(0,-1));assert.deepStrictEqual(live(),baseline);
}
`)
}

export function testStringTrimmingCrossesChunksAndPreservesOptionalEvaluation(): none {
  checkStrings([
    SourceFile { path: "/trim.do", source: `
export function normalize(text: string): string => text.trimStart().trimEnd()
` },
    SourceFile { path: "/main.do", source: `
import { normalize } from "./trim"
class Counts { let calls: int = 0 }
class Custom { trimEnd(): int => 7 }
function receiver(counts: Counts, text: string, present: bool): string | none {
  counts.calls += 10
  return if present then text else none
}
function suffix(counts: Counts): char { counts.calls += 1; return '_' }
export function optional(text: string, present: bool): string {
  counts := Counts {}
  result := receiver(counts, text, present)?.trimEnd(suffix(counts)) ?? "missing"
  return result + ":" + string(counts.calls)
}
export function normalizeCaptured(text: string): string {
  trim := (): string => normalize(text)
  return trim()
}
export function trim(text: string): string => text.trim()
export function custom(): int => Custom {}.trimEnd()
` },
  ], `
assert.strictEqual(api.custom(),7);
for(const length of [0,1,15,16,17,1023,1024,1025,2048,2049,262145]) {
 const spaces=' '.repeat(length),text=spaces+'left middle right'+spaces;
 assert.strictEqual(api.trim(text),'left middle right');assert.strictEqual(api.normalizeCaptured(text),'left middle right');
 assert.strictEqual(api.trim(spaces),'');assert.deepStrictEqual(live(),baseline,'chunked trim released');
}
for(let i=0;i<20;i++) {
 assert.strictEqual(api.optional('value___',true),'value:11');
 assert.strictEqual(api.optional('value___',false),'missing:10');
 assert.deepStrictEqual(live(),baseline,'optional calls and closures released');
}
const end=instance.exports.__doof_debug_heap_end.value;
assert.strictEqual(api.trim(' '.repeat(262145)+'x'+' '.repeat(262145)),'x');
assert.strictEqual(instance.exports.__doof_debug_heap_end.value,end,'trim storage reused');
assert.deepStrictEqual(live(),baseline);
`)
}

export function testStringCompareCachesImmutableStorageAndPreservesByteOrder(): none {
  checkStrings([SourceFile { path: "/main.do", source: `
export function compare(left: string, right: string): int => if left < right then -1 else if left > right then 1 else 0
export function shared(value: string): int => if value == value then 0 else 1
export function equal(left: string, right: string): bool => left == right
export function captured(left: string, right: string): int {
  call := (): int => if left < right then -1 else if left > right then 1 else 0
  return call()
}
` }], `
const sign=(left,right)=>left===right?0:left<right?-1:1;
for(const length of [0,1,15,16,17,1023,1024,1025,2048,262145]){
  const prefix='x'.repeat(length);
  for(const [left,right] of [[prefix,prefix],[prefix,prefix+'x'],[prefix+'a',prefix+'b'],[prefix+'\\x00',prefix+'\\xff'],[prefix+'\\xff',prefix+'\\x80']]){
    for(const [a,b] of [[left,right],[right,left]]){
      assert.strictEqual(api.compare(a,b),sign(a,b));
      assert.strictEqual(api.captured(a,b),sign(a,b));
      assert.strictEqual(api.equal(a,b),a===b);
      assert.strictEqual(api.shared(a),0);
      assert.deepStrictEqual(live(),baseline,'comparison handles and captures released');
    }
  }
}
`)
}

function lexerSnapshot(source: string): string {
  lexer := Lexer { source }
  tokens := lexer.tokenize()
  let summary = ""
  for token of tokens {
    summary += string(token.kind.value) + ":" + string(token.line) + ":" + string(token.column) + ":" + string(token.offset) + ":" + string(token.length) + ":" + tokenValue(token, source) + "\n"
  }
  for diagnostic of lexer.diagnostics {
    summary += diagnostic.severity + ":" + string(diagnostic.line) + ":" + string(diagnostic.column) + ":" + diagnostic.message + "\n"
  }
  return summary
}

export function testWideStringComparisonAndBulkCopiesAtEveryWordAndChunkBoundary(): none {
  checkStrings([SourceFile { path: "/main.do", source: `
export function compare(left: string, right: string): int => if left < right then -1 else if left > right then 1 else 0
export function join(left: string, right: string): string => left + right
export function slice(text: string, start: int, end: int): string => text.substring(start, end)
` }], `
const sign=(a,b)=>a===b?0:a<b?-1:1;
const nativeSlice=(text,start,end)=>{start=Math.max(0,start);end=Math.min(text.length,end);return start>=end?'':text.slice(start,end);};
for(const length of [...Array.from({length:18},(_,i)=>i),23,24,25,31,32,33,1023,1024,1025,2049,262144,262145]){
 const text=Array.from({length},(_,i)=>String.fromCharCode([0,127,128,255][i%4])).join('');
 assert.strictEqual(api.compare(text,text),0);
 assert.strictEqual(api.compare(text,text+'\\x00'),-1);assert.strictEqual(api.compare(text+'\\x00',text),1);
 for(const position of [...new Set([...Array.from({length:Math.min(17,length)},(_,i)=>i),1022,1023,1024,1025,262143,262144,length-1])].filter(i=>i>=0&&i<length)){
  const other=text.slice(0,position)+String.fromCharCode((text.charCodeAt(position)+1)%256)+text.slice(position+1);
  assert.strictEqual(api.compare(text,other),sign(text,other),'first mismatch at '+position);
  assert.strictEqual(api.compare(other,text),sign(other,text));
 }
 for(const start of [0,1,7,8,15,16,1021,1023,1024,1025,length]){
  if(start>length)continue;
  for(const end of [...new Set([start,Math.min(length,start+7),Math.min(length,start+8),Math.min(length,start+9),length])]){
   assert.strictEqual(api.slice(text,start,end),nativeSlice(text,start,end));
   assert.strictEqual(api.join(text.slice(0,start),text.slice(start,end)),text.slice(0,end));
  }
 }
 for(const [start,end] of [[-2147483648,2147483647],[-1,4],[5,1],[0,-1],[length+1,length+10],[2147483647,2147483647]])assert.strictEqual(api.slice(text,start,end),nativeSlice(text,start,end));
 assert.deepStrictEqual(live(),baseline,'wide reads and bulk copies release all dynamic storage');
}
for(const [a,b] of [['a'+'\\xff'.repeat(7),'b'+'\\x00'.repeat(7)],['\\x7f'+'\\xff'.repeat(7),'\\x80'+'\\x00'.repeat(7)]]){
 assert.strictEqual(api.compare(a,b),-1);assert.strictEqual(api.compare(b,a),1);
}
assert.strictEqual(api.join('',''),'');
assert.deepStrictEqual(live(),baseline);
`)
}

export function testSelfHostingRealLexerMatchesNativeTokensAndDiagnostics(): none {
  let rows = ""
  let large = ""
  for i of 0..<1025 { large += "1_" }
  fixtures := [
    "", "let value := 42 + 3.5f // comment\nvalue",
    "0xFF_FF 0b1010_0001 42L 3.14 3.14f 30__000", "let\n  x = 30_000",
    "#!/usr/bin/env doof\r\nfunction main(): none {}", "\n#!/usr/bin/env doof",
    "\"a\\07\" \"escaped\\ntext\"", "`hello \${name}!`", "<box>\n  hello\n  world\n</box>",
    "\"unterminated", "/* unterminated", "`missing \${name", "30__000 #", large + "1",
  ]
  for source of fixtures {
    rows += "[" + formatJsonValue(source) + "," + formatJsonValue(lexerSnapshot(source)) + "],"
  }
  checkStrings([
    SourceFile { path: "/lexer.do", source: readText("../doof-lang/src/lexer.do")! },
    SourceFile { path: "/main.do", source: `
import { Lexer, tokenValue } from "./lexer"
export function scan(source: string): string {
  lexer := Lexer { source }
  tokens := lexer.tokenize()
  let summary = ""
  for token of tokens {
    summary += string(token.kind.value) + ":" + string(token.line) + ":" + string(token.column) + ":" + string(token.offset) + ":" + string(token.length) + ":" + tokenValue(token, source) + "\\n"
  }
  for diagnostic of lexer.diagnostics {
    summary += diagnostic.severity + ":" + string(diagnostic.line) + ":" + string(diagnostic.column) + ":" + diagnostic.message + "\\n"
  }
  return summary
}
` },
  ], `
for(let i=0;i<5;i++)for(const [source,expected] of [${rows}]) {
 assert.strictEqual(api.scan(source),expected,'native lexer parity for '+source.slice(0,40));
 assert.deepStrictEqual(live(),baseline,'lexer tokens, diagnostics, and stacks released');
}
`, WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true })
}
