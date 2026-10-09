import { minusBlocks } from "./minus-control-flow"
import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { compileDoofMinus, encodeDoofMinus } from "./minus-wasm"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { validateDoofMinus } from "./minus-validate"
import { MinusImport, MinusInstruction, MinusValue } from "./minus-ir"

export function testBulkArrayCopyPreservesBitsOverlapBoundsAndChunkTransitions(): none {
    let source = ""
    for typeName of ["bool", "byte", "char", "int", "long", "float", "double"] {
        source += `export func alloc_${typeName}(%length:int) -> int
block entry
%data:int = array-alloc %length, ${typeName}
return %data
end
export func read_${typeName}(%data:int, %index:int) -> ${typeName}
block entry
%value:${typeName} = array-get %data, %index
return %value
end
export func write_${typeName}(%data:int, %index:int, %value:${typeName}) -> none
block entry
array-set %data, %index, %value
return
end
export func copy_${typeName}(%destination:int, %destinationIndex:int, %source:int, %sourceIndex:int, %count:int) -> none
block entry
array-copy %destination, %destinationIndex, %source, %sourceIndex, %count, ${typeName}
return
end
export func free_${typeName}(%data:int) -> none
block entry
array-free %data, ${typeName}
return
end
`
    }
    runWasm(source, "bulk-array-copy", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
const trap=f=>assert.throws(f,WebAssembly.RuntimeError);
for(const [type,width] of [['bool',1],['byte',1],['char',1],['int',4],['long',8],['float',4],['double',8]]){
 const capacity=1024/width,alloc=e['alloc_'+type],read=e['read_'+type],write=e['write_'+type],copy=e['copy_'+type],free=e['free_'+type];
 const item=i=>type==='bool'?i%2:type==='byte'||type==='char'?i%256:type==='long'?9007199254740993n+BigInt(i):type==='int'?i*7919-10000:i%13===0?-0:i*0.25-100;
 for(const length of [...new Set([0,1,7,8,9,capacity-1,capacity,capacity+1,capacity*2+17,capacity*256+5])]){
  const a=alloc(length),b=alloc(length),model=Array.from({length},(_,i)=>item(i));
  for(let i=0;i<length;i++){write(a,i,model[i]);write(b,i,item(i+99));}
  copy(b,0,a,0,length);
  const check=(handle,expected)=>{for(let i=0;i<length;i++)assert(Object.is(read(handle,i),expected[i]),type+' index '+i);};
  check(b,model);
  if(length>1){copy(b,1,b,0,length-1);model.copyWithin(1,0,length-1);check(b,model);copy(b,0,b,1,length-1);model.copyWithin(0,1);check(b,model);}
  if(length>40){copy(b,17,a,3,length-20);for(let i=0;i<length-20;i++)model[i+17]=item(i+3);check(b,model);}
  copy(b,length,a,length,0);check(b,model);
  for(const [di,si,count] of [[-1,0,0],[0,-1,0],[length+1,0,0],[0,length+1,0],[0,0,-1],[0,0,2147483647],[length,0,1],[0,length,1],[2147483647,0,1]]){
   trap(()=>copy(b,di,a,si,count));check(b,model);
  }
  trap(()=>copy(b,0,0,0,0));check(b,model);
  free(a);free(b);
 }
}
const view=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=view.getUint16(p+2,true))assert.strictEqual(view.getUint16(p,true),0);
`, true)
}

export function testBulkArrayCopyValidationAndTextRoundTrip(): none {
    source := `export func copy(%a:int, %b:int, %n:int) -> int
block entry
%zero:int = const 0
array-copy %a, %zero, %b, %zero, %n, byte
%compared:int = array-compare %a, %b
return %compared
end`
    module_ := parseDoofMinus(source)!
    validateDoofMinus(module_)!
    rendered := renderDoofMinus(module_)
    Assert.equal(renderDoofMinus(parseDoofMinus(rendered)!), rendered)
    _ := encodeDoofMinus(module_)!
    Assert.equal(renderDoofMinus(module_), rendered)
    for bad of [
        "array-copy %a, %zero, %b, %zero, %n, any",
        "array-copy %a, %zero, %b, %zero, %n, none",
        "array-copy %a, %zero, %b, %zero, %n",
        "array-copy %a, %zero, %b, %zero, %n, unknown",
    ] {
        case validateDoofMinus(parseDoofMinus(source.replaceAll("array-copy %a, %zero, %b, %zero, %n, byte", bad))!) {
            failure: Failure<string> -> { Assert.isTrue(failure.error.contains("array-copy")) }
            _ -> { Assert.fail("invalid bulk array copy must fail") }
        }
    }
}

export function testInstructionValidationRetainsSourcePath(): none {
    module_ := parseDoofMinus(`func check() -> bool
block entry
%left:int = const 1
%right:long = const 1
%same:bool = eq %left, %right
return %same
end
`)!
    original := minusBlocks(module_.functions[0])[0].instructions[2]
    minusBlocks(module_.functions[0])[0].instructions[2] = MinusInstruction {
        op: original.op, args: original.args, result: original.result, line: original.line, sourcePath: "/src/input.do",
    }
    case validateDoofMinus(module_) {
        failure: Failure<string> -> { Assert.equal(failure.error, "/src/input.do: line 5: eq needs matching supported operands") }
        _ -> { Assert.fail("Invalid source instructions must retain their source location") }
    }
}

export function testGlobalInitializersAndTypedReads(): none {
    source := `global FIRST:long = initialLong
global SECOND:double = initialDouble
func initialLong() -> long
block entry
%value:long = const 9007199254740993
return %value
end
func initialDouble() -> double
block entry
%value:double = const 2.25
return %value
end
export func wide() -> long
block entry
%value:long = global-get FIRST
return %value
end
export func decimal() -> double
block entry
%value:double = global-get SECOND
return %value
end
`
    parsed := parseDoofMinus(source)!
    Assert.equal(renderDoofMinus(parsed), source)
    runWasm(source, "globals", `const fs=require('fs'),assert=require('assert');
WebAssembly.instantiate(fs.readFileSync(process.argv[1])).then(({instance})=>{
assert.strictEqual(instance.exports.wide(),9007199254740993n);assert.strictEqual(instance.exports.decimal(),2.25);
}).catch(error=>{console.error(error);process.exit(1)});`)
}

export function testInvalidGlobalDeclarationsAndReads(): none {
    initializer := `func init() -> int
block entry
%value:int = const 42
return %value
end
`
    rejected("global VALUE:int = missing\n" + initializer, "global initializer must name a private function")
    rejected("global VALUE:long = init\n" + initializer, "global initializer must name a private function")
    rejected("global VALUE:none = init\n" + initializer, "global cannot have type none")
    rejected("global VALUE:int = init\nglobal VALUE:int = init\n" + initializer, "duplicate global")
    rejected("global VALUE:int = init\nexport " + initializer, "global initializer must name a private function")
    rejected(`export func read() -> int
block entry
%value:int = global-get MISSING
return %value
end`, "unknown global MISSING")
    rejected("global VALUE:int = init\n" + initializer + `export func read() -> long
block entry
%value:long = global-get VALUE
return %value
end`, "global-get result needs int")
}

function runWasm(source: string, testName: string, script: string, debugHeap: bool = false): none {
    bytes := compileDoofMinus(source, debugHeap)!
    path := "/tmp/doof-minus-" + string(pid()) + "-" + testName + ".wasm"
    writeBlob(path, bytes.cloneReadonly())!
    result := run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
    _ := remove(path) else { panic("Could not remove temporary Wasm file") }
    if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
    Assert.equal(result.exitCode, 0)
}

function capMemoryAtOnePage(bytes: byte[]): byte[] {
    let offset = 8 // skip the Wasm magic and version
    while offset < bytes.length {
        sectionStart := offset
        id := int(bytes[offset])
        offset += 1
        let size = 0
        let multiplier = 1
        while true {
            part := int(bytes[offset])
            offset += 1
            size += (part % 128) * multiplier
            if part < 128 { break }
            multiplier *= 128
        }
        payloadStart := offset
        payloadEnd := payloadStart + size
        if id == 5 {
            Assert.equal(size, 3) // one memory with minimum one page
            let result: byte[] = []
            for index of 0..<sectionStart { result.push(bytes[index]) }
            for value of [5, 4, 1, 1, 1, 1] { result.push(byte(value)) } // min=max=1
            for index of payloadEnd..<bytes.length { result.push(bytes[index]) }
            return result
        }
        offset = payloadEnd
    }
    panic("Wasm memory section is missing")
}

function runCappedWasm(source: string, testName: string, script: string, imports: MinusImport[] = []): none {
    module_ := parseDoofMinus(source)!
    for import_ of imports { module_.imports.push(import_) }
    bytes := capMemoryAtOnePage(encodeDoofMinus(module_)!)
    path := "/tmp/doof-minus-" + string(pid()) + "-" + testName + ".wasm"
    writeBlob(path, bytes.cloneReadonly())!
    result := run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
    _ := remove(path) else { panic("Could not remove temporary Wasm file") }
    if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
    Assert.equal(result.exitCode, 0)
}

function rejected(source: string, message: string): none {
    result := compileDoofMinus(source)
    case result {
        failure: Failure<string> -> { Assert.stringContains(failure.error, message) }
        _ -> { Assert.fail("Expected a doof-- diagnostic") }
    }
}

export function testRejectsRemovedShortType(): none {
    rejected(`export func old(%value:short) -> int
block entry
%zero:int = const 0
return %zero
end`, "unknown type short")
    rejected(`class Legacy
field value:short
end`, "unknown type short")
    rejected(`export func old() -> int
block entry
%one:int = const 1
%data:int = array-alloc %one, short
return %data
end`, "unsupported array element type short")
}

export function testPrimitiveExecution(): none {
    runWasm(`
export func intSum() -> int
block entry
%a:int = const 2147483647
%b:int = const 1
%c:int = add %a, %b
return %c
end
export func floatValue() -> float
block entry
%a:float = const 1.25
%b:float = const 2.5
%c:float = add %a, %b
return %c
end
export func doubleValue() -> double
block entry
%a:double = const 1.25
%b:double = const 2.5
%c:double = add %a, %b
return %c
end
export func longValue() -> long
block entry
%a:long = const 10000000000
%b:long = const 7
%c:long = add %a, %b
return %c
end
export func byteValue() -> byte
block entry
%a:byte = const 255
%b:byte = const 1
%c:byte = add %a, %b
return %c
end
export func charValue() -> char
block entry
%a:char = const 255
return %a
end
`, "primitives", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.intSum()!==-2147483648||e.floatValue()!==3.75||e.doubleValue()!==3.75||e.longValue()!==10000000007n||e.byteValue()!==0||e.charValue()!==255)process.exit(1)`)
}

export function testTypedArrayDataOperationsAndFreeListReuse(): none {
    runWasm(`
export func run() -> int
block entry
%length:int = const 3
%bytes:int = array-alloc %length, byte
%zero:int = const 0
%value:byte = const 201
array-set %bytes, %zero, %value
%actual:byte = array-get %bytes, %zero
%count:int = array-length %bytes
array-free %bytes
return %count
end
export func onlyLength() -> int
block entry
%length:int = const 3
%bytes:int = array-alloc %length, byte
%count:int = array-length %bytes
array-free %bytes
return %count
end
export func maximum() -> int
block entry
%length:int = const 1024
%bytes:int = array-alloc %length, byte
%count:int = array-length %bytes
array-free %bytes
return %count
end
export func longArray() -> int
block entry
%length:int = const 2050
%bytes:int = array-alloc %length, byte
%zero:int = const 0
%last:int = const 2049
%value:byte = const 219
array-set %bytes, %last, %value
%actual:byte = array-get %bytes, %last
%count:int = array-length %bytes
array-free %bytes
return %count
end
`, "array-data", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;for(let i=0;i<1000;i++)if(e.onlyLength()!==3||e.run()!==3)process.exit(1);if(e.maximum()!==1024||e.longArray()!==2050)process.exit(2)`)
}

export function testTypedPrimitiveArrayWidths(): none {
    runWasm(`
export func mixed() -> int
block entry
%one:int = const 1
%zero:int = const 0
%ints:int = array-alloc %one, int
%intValue:int = const -123
array-set %ints, %zero, %intValue
%readInt:int = array-get %ints, %zero
array-free %ints
%longs:int = array-alloc %one, long
%longValue:long = const 4000000000
array-set %longs, %zero, %longValue
%readLong:long = array-get %longs, %zero
%longAsInt:int = convert %readLong
array-free %longs
%doubles:int = array-alloc %one, double
%doubleValue:double = const 3.75
array-set %doubles, %zero, %doubleValue
%readDouble:double = array-get %doubles, %zero
%doubleAsInt:int = convert %readDouble
array-free %doubles
%floats:int = array-alloc %one, float
%floatValue:float = const 1.5
array-set %floats, %zero, %floatValue
%readFloat:float = array-get %floats, %zero
%floatAsInt:int = convert %readFloat
array-free %floats
%first:int = add %readInt, %longAsInt
%sum:int = add %first, %doubleAsInt
%total:int = add %sum, %floatAsInt
return %total
end
`, "typed-array-data", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.mixed()!==-294967415)process.exit(1)`)
}

export function testChunkedArraysAcrossWidthsAndDirectoryBoundaries(): none {
    let source = "enum Kind\nend\n"
    for typeName of ["bool", "char", "byte", "int", "float", "long", "double", "Kind"] {
        source += `
export func alloc_${typeName}(%length:int) -> int
block entry
%data:int = array-alloc %length, ${typeName}
return %data
end
export func read_${typeName}(%data:int, %index:int) -> ${typeName}
block entry
%value:${typeName} = array-get %data, %index
return %value
end
export func write_${typeName}(%data:int, %index:int, %value:${typeName}) -> none
block entry
array-set %data, %index, %value
return
end
`
    }
    source += `
export func length(%data:int) -> int
block entry
%length:int = array-length %data
return %length
end
export func free(%data:int) -> none
block entry
array-free %data
return
end
`
    runWasm(source, "chunked-widths", `
const fs = require('fs'), assert = require('assert');
const bytes = fs.readFileSync(process.argv[1]);
for (const [type,width,value] of [['bool',1,1],['char',1,200],['byte',1,201],['int',4,123456789],['float',4,1.25],['long',8,9007199254740993n],['double',8,Math.PI],['Kind',4,123456789]]) {
  const e = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
  const capacity = 1024 / width;
  const lengths = [0,1,capacity-1,capacity,capacity+1,capacity*2,capacity*2+1,capacity*256+1];
  if (type === 'byte') lengths.push(capacity*65536+1);
  function trap(action) { assert.throws(action, WebAssembly.RuntimeError); }
  trap(() => e['alloc_'+type](-1));
  for (const length of lengths) {
    const data = e['alloc_'+type](length), view = new DataView(e.__doof_ffi_memory.buffer);
    assert.strictEqual(e.length(data), length);
    assert.strictEqual(view.getUint16(data,true), length <= capacity ? 30 : 29);
    if (length > capacity) {
      assert.strictEqual(view.getUint32(data+8,true), Math.ceil(length/capacity));
      const owned = new Set(); let pointer = view.getUint32(data+16,true), chunks = 0;
      while (pointer) {
        assert(!owned.has(pointer), 'ownership chain cycle'); owned.add(pointer);
        if (view.getUint16(pointer,true) === 27) chunks++;
        pointer = view.getUint32(pointer+4,true);
      }
      assert.strictEqual(chunks, Math.ceil(length/capacity));
    }
    const indexes = [...new Set([0,capacity-1,capacity,capacity+1,capacity*256-1,capacity*256,capacity*65536-1,capacity*65536,length-1])].filter(i => i >= 0 && i < length);
    const expected = new Map();
    for (const [ordinal,index] of indexes.entries()) {
      const item = type === 'bool' ? ordinal%2 : typeof value === 'bigint' ? value+BigInt(ordinal) : value+ordinal;
      e['write_'+type](data,index,item); expected.set(index,item);
    }
    for (const [index,item] of expected) assert.strictEqual(e['read_'+type](data,index),item, type+' index '+index);
    for (const index of [-1,length]) {
      trap(() => e['read_'+type](data,index));
      trap(() => e['write_'+type](data,index,value));
    }
    e.free(data);
    // Reuse the exact descriptor and block sizes, checking both leaks and cycles.
    const heapPages = e.__doof_ffi_memory.buffer.byteLength;
    for (let repeat = 0; repeat < 3; repeat++) {
      const reused = e['alloc_'+type](length);
      if (length) { e['write_'+type](reused,length-1,value); assert.strictEqual(e['read_'+type](reused,length-1),value); }
      e.free(reused);
      assert.strictEqual(e.__doof_ffi_memory.buffer.byteLength,heapPages);
    }
  }
}
`)
}

export function testReferenceArraysReplaceReleaseAndReuse(): none {
    let source = `
interface HasValue
field value:int
end
class Widget implements HasValue
field value:int
end
`
    for typeName of ["Widget", "HasValue", "any"] {
        conversion := if typeName == "Widget" then "copy %object" else if typeName == "HasValue" then "as %object" else "box %object"
        source += `
export func alloc_${typeName}(%length:int) -> int
block entry
%data:int = array-alloc %length, ${typeName}
return %data
end
export func write_${typeName}(%data:int, %index:int, %value:int) -> none
block entry
%object:Widget = new Widget(%value)
%element:${typeName} = ${conversion}
array-set %data, %index, %element
return
end
export func self_${typeName}(%data:int, %index:int) -> none
block entry
%element:${typeName} = array-get %data, %index
array-set %data, %index, %element
return
end
export func free_${typeName}(%data:int) -> none
block entry
array-free %data, ${typeName}
return
end
`
    }
    runCappedWasm(source, "reference-array-reuse", `
const fs = require('fs'), assert = require('assert');
const e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
const view = new DataView(e.__doof_ffi_memory.buffer);
function slot(data,index) {
  if (view.getUint16(data,true) === 30) return data+8+index*4;
  const chunk = Math.floor(index/256); let node = view.getUint32(data+12,true);
  node = view.getUint32(node+8+(chunk>>>16)*4,true);
  node = view.getUint32(node+8+((chunk>>>8)&255)*4,true);
  node = view.getUint32(node+8+(chunk&255)*4,true);
  return node+8+(index%256)*4;
}
for (const type of ['Widget','HasValue','any']) for (const length of [3,256,257,513]) {
  for (let repeat = 0; repeat < 100; repeat++) {
    const data = e['alloc_'+type](length), indexes = [...new Set([0,2,255,256,length-1])].filter(i => i < length);
    for (let i = 0; i < length; i++) assert.strictEqual(view.getUint32(slot(data,i),true),0);
    for (const index of indexes) e['write_'+type](data,index,42+index);
    const replaced = view.getUint32(slot(data,0),true), neighbor = view.getUint32(slot(data,2),true);
    e['self_'+type](data,0);
    assert.strictEqual(view.getUint32(replaced+4,true),1);
    e['write_'+type](data,0,99);
    assert.strictEqual(view.getUint16(replaced,true),0,'replaced element must be freed');
    assert.notStrictEqual(view.getUint16(neighbor,true),0,'neighbor must remain alive');
    const objects = [];
    for (const index of indexes) {
      const pointer = view.getUint32(slot(data,index),true); objects.push(pointer);
      assert.strictEqual(view.getUint32(pointer+4,true),1);
      if (type === 'any') objects.push(view.getUint32(pointer+16,true));
    }
    e['free_'+type](data);
    for (const pointer of objects) assert.strictEqual(view.getUint16(pointer,true),0,'array element must be freed');
  }
}
`)
}

export function testMinusDestructorFreesOwnedArrayData(): none {
    runCappedWasm(`
class Owner
destructor Owner.destroy
field handle:int
end
func Owner.destroy(%self:Owner) -> none
block entry
%handle:int = get %self.handle
array-free %handle
return
end
export func run() -> int
block entry
%length:int = const 1
%data:int = array-alloc %length, byte
%owner:Owner = new Owner(%data)
%answer:int = const 42
return %answer
end
`, "array-destructor", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;for(let i=0;i<2000;i++)if(e.run()!==42)process.exit(1)`)
}

export function testControlFlowAndConversions(): none {
    runWasm(`
export func count(%limit:int) -> long
scope done
scope loop
block entry
%zero:int = const 0
jump loop(%zero)
end-scope
loop loop
scope step
block loop(%n:int)
%again:bool = lt %n, %limit
branch %again step(%n) done(%n)
end-scope
block step(%old:int)
%one:int = const 1
%next:int = add %old, %one
jump loop(%next)
end-loop
end-scope
block done(%answer:int)
%wide:long = convert %answer
return %wide
end
`, "flow", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.count(0)!==0n||e.count(10000)!==10000n)process.exit(1)`)
}

export function testDispatchPreservesParallelReferenceTransfers(): none {
    runCappedWasm(`class Box
field value:int
end
export func rotate(%turns:int) -> int
scope done
scope cycle
block entry
%one:int = const 1
%two:int = const 2
%first:Box = new Box(%one)
%second:Box = new Box(%two)
jump cycle(%first, %second, %first, %turns)
end-scope
loop cycle
block cycle(%left:Box, %right:Box, %anchor:Box, %remaining:int)
%zero:int = const 0
%increment:int = const 1
%next:int = sub %remaining, %increment
%again:bool = lt %zero, %remaining
branch %again cycle(%right, %left, %anchor, %next) done(%left, %anchor)
end-loop
end-scope
block done(%winner:Box, %kept:Box)
%answer:int = get %winner.value
%original:int = get %kept.value
%sum:int = add %answer, %original
return %sum
end`, "parallel-reference-edges", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let repeat=0;repeat<1000;repeat++) {
 assert.strictEqual(e.rotate(0),2);assert.strictEqual(e.rotate(1),3);assert.strictEqual(e.rotate(20),2);
}
const view=new DataView(e.__doof_ffi_memory.buffer);
for(let address=1024;address<1100;address+=24)assert.strictEqual(view.getUint16(address,true),0,'reference frame released');
`)
}

export function testArrayHelpersKeepRepeatedOperationsCompact(): none {
    let source = "export func arrays() -> int\nblock entry\n%length:int = const 257\n%index:int = const 256\n%value:int = const 42\n"
    for index of 0..<100 {
        source += "%data" + string(index) + ":int = array-alloc %length, int\narray-set %data" + string(index) + ", %index, %value\n"
        source += "%read" + string(index) + ":int = array-get %data" + string(index) + ", %index\narray-free %data" + string(index) + "\n"
    }
    source += "return %read99\nend\n"
    bytes := compileDoofMinus(source)!
    Assert.isTrue(bytes.length < 10000, "Array machinery must be shared across repeated operations")
    runCappedWasm(source, "compact-array-helpers", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let repeat=0;repeat<100;repeat++)assert.strictEqual(e.arrays(),42);
`)
}

export function testUnusedBlockArgumentsKeepObservableDestructorOrder(): none {
    runCappedWasm(`class Owner
field value:int
destructor Owner.destroy
end
func Owner.destroy(%self:Owner) -> none
block entry
%value:int = get %self.value
%effect:none = call record(%value)
return
end
export func order() -> none
scope done
block entry
%one:int = const 1
%two:int = const 2
%first:Owner = new Owner(%one)
%second:Owner = new Owner(%two)
jump done(%first, %one)
end-scope
block done(%unused:Owner, %discarded:int)
return
end`, "dead-arguments-destructor-order", `
const fs=require('fs'),assert=require('assert'),events=[];
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{doof:{record:value=>events.push(value)}}).exports;
for(let repeat=0;repeat<100;repeat++) {
 e.order();assert.deepStrictEqual(events,[2,1],'unused ownership copy preserves observable destruction order');events.length=0;
}
const view=new DataView(e.__doof_ffi_memory.buffer);
assert.strictEqual(view.getUint16(1024,true),0);assert.strictEqual(view.getUint16(1048,true),0);
`, [MinusImport { name: "record", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" }])
}

export function testHundredsOfUnusedBlockArgumentsEmitNoTransfers(): none {
    let params = ""
    let args = ""
    for index of 0..<300 {
        separator := if index == 0 then "" else ", "
        params += separator + "%unused" + string(index) + ":long"
        args += separator + "%wide"
    }
    source := "export func answer(%value:int) -> int\nscope done\nblock entry\n%wide:long = const 9007199254740993\njump done(" + args + ")\nend-scope\nblock done(" + params + ")\nreturn %value\nend\n"
    Assert.isTrue((compileDoofMinus(source)!).length < 1000, "Dead arguments should allocate no locals or transfer code")
    runWasm(source, "dead-arguments-compact", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
assert.strictEqual(e.answer(42),42);assert.strictEqual(e.answer(-7),-7);
`)
}

export function testDeadReferenceForwardingCycleExecutesAndReleases(): none {
    runCappedWasm(`class Box
field value:int
end
export func cycle(%turns:int) -> int
scope done
scope loop
block entry
%value:int = const 40
%object:Box = new Box(%value)
jump loop(%object, %turns)
end-scope
loop loop
block loop(%unused:Box, %remaining:int)
%zero:int = const 0
%one:int = const 1
%next:int = sub %remaining, %one
%again:bool = lt %zero, %remaining
branch %again loop(%unused, %next) done()
end-loop
end-scope
block done
%answer:int = const 42
return %answer
end`, "dead-reference-cycle", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let repeat=0;repeat<100;repeat++) {
 assert.strictEqual(e.cycle(0),42);assert.strictEqual(e.cycle(1000),42);
 assert.strictEqual(new DataView(e.__doof_ffi_memory.buffer).getUint16(1024,true),0,'entry allocation is released exactly once');
}
`)
}

export function testPrimitiveHostBoundary(): none {
    runWasm(`
export func narrow(%value:byte) -> byte
block entry
return %value
end
export func truth(%value:bool) -> bool
block entry
return %value
end
export func character(%value:char) -> char
block entry
return %value
end
export func nothing() -> none
block entry
%empty:none = const none
return %empty
end
`, "boundary", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.narrow(65535)!==255||e.truth(7)!==1||e.character(255)!==255||e.nothing()!==undefined)process.exit(1);try{e.character(256);process.exit(2)}catch(x){if(!(x instanceof WebAssembly.RuntimeError))process.exit(3)}`)
}

export function testNumericConversionsAndComparisons(): none {
    runWasm(`
export func widen(%value:byte) -> double
block entry
%wide:long = convert %value
%single:float = convert %wide
%double:double = convert %single
return %double
end
export func narrow(%value:double) -> byte
block entry
%integer:int = convert %value
%byte:byte = convert %integer
return %byte
end
export func compare(%left:char,%right:char) -> bool
block entry
%less:bool = lt %left,%right
return %less
end
export func compareBool(%left:bool,%right:bool) -> bool
block entry
%equal:bool = eq %left,%right
return %equal
end
`, "conversions", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.widen(200)!==200||e.narrow(65535)!==255||e.compare(65,66)!==1||e.compareBool(7,1)!==1)process.exit(1)`)
}

export function testClassesInterfacesAndAny(): none {
    runWasm(`
interface HasValue
field let value:int
method get() -> int
end
class Box implements HasValue
field let value:int
end
func Box.get(%self:Box) -> int
block entry
%v:int = get %self.value
return %v
end
export func run() -> int
scope yes
scope no
block entry
%a:int = const 7
%box:Box = new Box(%a)
%i:HasValue = as %box
%v:int = get %i.value
set %i.value = %v
%m:int = call %i.get()
%x:any = box %box
%ok:bool = is %x Box
branch %ok yes(%x) no()
end-scope
block no()
%z:int = const 0
return %z
end-scope
block yes(%bx:any)
%other:Box = cast %bx Box
%r:int = get %other.value
return %r
end
`, "objects", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;for(let i=0;i<100000;i++)if(e.run()!==7)process.exit(1)`)
}

export function testAnyCheckedCastTraps(): none {
    runWasm(`
export func bad() -> int
block entry
%a:double = const 3.5
%x:any = box %a
%v:int = cast %x int
return %v
end
`, "bad-cast", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;try{e.bad();process.exit(1)}catch(x){if(!(x instanceof WebAssembly.RuntimeError))process.exit(2)}`)
}

export function testDynamicDispatchAcrossClasses(): none {
    runWasm(`
interface Readable
method get() -> int
end
class First implements Readable
field value:int
end
class Second implements Readable
field value:int
end
func First.get(%self:First) -> int
block entry
%value:int = get %self.value
return %value
end
func Second.get(%self:Second) -> int
block entry
%value:int = get %self.value
return %value
end
export func choose(%flag:bool) -> int
scope joined
scope left
scope right
block entry
%one:int = const 1
%two:int = const 2
%first:First = new First(%one)
%second:Second = new Second(%two)
%a:Readable = as %first
%b:Readable = as %second
branch %flag left(%a) right(%b)
end-scope
block right(%right:Readable)
jump joined(%right)
end-scope
block left(%left:Readable)
jump joined(%left)
end-scope
block joined(%item:Readable)
%value:int = call %item.get()
return %value
end
`, "dispatch", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.choose(1)!==1||e.choose(0)!==2)process.exit(1)`)
}

export function testSharedReleaseDispatchHandlesHolesAndWideLabelDepths(): none {
    let source = "class Scalar\nfield value:int\nend\n"
    // Two tags per cleanup shape, and more than 127 distinct label depths.
    for index of 0..<140 {
        for suffix of ["A", "B"] {
            source += "class C" + string(index) + suffix + "\n"
            for field of 0..<index { source += "field p" + string(field) + ":int\n" }
            source += "field child:any\nend\n"
        }
        source += "class Hole" + string(index) + "\nfield value:int\nend\n"
    }
    source += "export func run() -> none\nblock entry\nreturn\nend\n"
    runWasm(source, "shared-release-dispatch", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
const alloc=e.__doof_ffi_alloc,release=e.__doof_ffi_release;
const view=()=>new DataView(e.__doof_ffi_memory.buffer);
release(0);
for(let round=0;round<2;round++) {
 for(let i=0;i<140;i++) {
  for(let duplicate=0;duplicate<2;duplicate++) {
   const size=24+Math.max(0,Math.ceil((12+4*i-24)/16))*16;
   const parent=alloc(size,33+3*i+duplicate),child=alloc(24,31);
   new Uint8Array(e.__doof_ffi_memory.buffer,parent+8,size-8).fill(0);
   view().setUint32(parent+8+4*i,child,true);
   view().setUint32(parent+4,2,true);
   release(parent);
   assert.strictEqual(view().getUint32(parent+4,true),1);
   assert.strictEqual(view().getUint16(child,true),31);
   release(parent);
   assert.strictEqual(view().getUint16(parent,true),0);
   assert.strictEqual(view().getUint16(child,true),0);
  }
  const hole=alloc(24,35+3*i);release(hole);
  assert.strictEqual(view().getUint16(hole,true),0);
 }
 const scalar=alloc(24,32);release(scalar);
 assert.strictEqual(view().getUint16(scalar,true),0);
}
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=view().getUint16(p+2,true))assert.strictEqual(view().getUint16(p,true),0);
`, true)
}

export function testSharedReleaseDispatchPreservesFinalizersAndFieldOrder(): none {
    let source = ""
    for index of 0..<4 {
        name := "C" + string(index)
        source += "class " + name + "\nfield first:any\nfield second:any\ndestructor " + name + ".destroy\nend\n"
        source += "func " + name + ".destroy(%self:" + name + ") -> none\nblock entry\n"
        source += "%id:int = const " + string(index) + "\n%effect:none = call record(%id)\nreturn\nend\n"
    }
    source += "export func run() -> none\nblock entry\nreturn\nend\n"
    runCappedWasm(source, "shared-release-finalizers", `
const fs=require('fs'),assert=require('assert'),events=[];
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{doof:{record:id=>events.push(id)}}).exports;
const v=new DataView(e.__doof_ffi_memory.buffer);
const make=id=>{const p=e.__doof_ffi_alloc(24,32+id);v.setUint32(p+8,0,true);v.setUint32(p+12,0,true);return p;};
for(let round=0;round<100;round++)for(let id=0;id<4;id++) {
 const parent=make(id),first=make((id+1)%4),second=make((id+2)%4);
 v.setUint32(parent+8,first,true);v.setUint32(parent+12,second,true);
 e.__doof_ffi_release(parent);
 assert.deepStrictEqual(events,[id,(id+1)%4,(id+2)%4]);events.length=0;
 for(const p of [parent,first,second])assert.strictEqual(v.getUint16(p,true),0);
}
`, [MinusImport { name: "record", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" }])
}

export function testHeapGrowthAndRelease(): none {
    runWasm(`
class Node
field next:any
end
export func makeChain(%limit:int) -> int
scope done
scope loop
block entry
%empty:none = const none
%head:any = box %empty
%zero:int = const 0
jump loop(%zero,%head)
end-scope
loop loop
scope step
block loop(%i:int,%chain:any)
%more:bool = lt %i,%limit
branch %more step(%i,%chain) done(%i,%chain)
end-scope
block step(%old:int,%previous:any)
%node:Node = new Node(%previous)
%boxed:any = box %node
%one:int = const 1
%next:int = add %old,%one
jump loop(%next,%boxed)
end-loop
end-scope
block done(%answer:int,%last:any)
return %answer
end
`, "heap", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.makeChain(10)!==10||e.makeChain(4000)!==4000||e.makeChain(4000)!==4000)process.exit(1)`)
}

export function testSizeClassReuseThroughMaximumBlockSize(): none {
    let source = `class Small
field value:int
end
class Edge
`
    for index of 0..<62 { source += "field f" + string(index) + ":long\n" }
    source += `end
class Large
`
    for index of 0..<63 { source += "field f" + string(index) + ":long\n" }
    source += `end
class Maximum
`
    for index of 0..<128 { source += "field f" + string(index) + ":long\n" }
    source += `end
export func small() -> int
block entry
%value:int = const 42
%object:Small = new Small(%value)
%box:any = box %value
%result:int = get %object.value
return %result
end
export func edge() -> long
block entry
%value:long = const 6
%object:Edge = new Edge(`
    for index of 0..<62 {
        if index > 0 { source += "," }
        source += "%value"
    }
    source += `)
%result:long = get %object.f0
return %result
end
export func large() -> long
block entry
%value:long = const 7
%object:Large = new Large(`
    for index of 0..<63 {
        if index > 0 { source += "," }
        source += "%value"
    }
    source += `)
%result:long = get %object.f0
return %result
end
export func maximum() -> long
block entry
%value:long = const 8
%object:Maximum = new Maximum(`
    for index of 0..<128 {
        if index > 0 { source += "," }
        source += "%value"
    }
    source += `)
%result:long = get %object.f0
return %result
end
`
    runCappedWasm(source, "size-classes", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;for(let i=0;i<4000;i++){if(e.small()!==42||e.edge()!==6n||e.large()!==7n||e.maximum()!==8n)process.exit(1)}`)
}

export function testFloatingFieldsAndNoneBox(): none {
    runWasm(`
class Sample
field let value:double
field absent:none
end
export func run() -> double
scope yes
scope no
block entry
%empty:none = const none
%box:any = box %empty
%isNone:bool = is %box none
%old:double = const 1.5
%new:double = const 2.25
%sample:Sample = new Sample(%old,%empty)
set %sample.value = %new
%read:double = get %sample.value
branch %isNone yes(%read) no()
end-scope
block no()
%zero:double = const 0.0
return %zero
end-scope
block yes(%answer:double)
return %answer
end
`, "floating-fields", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.run()!==2.25)process.exit(1)`)
}

export function testPackedFieldsExecute(): none {
    runWasm(`
class Packed
field let tiny:byte
field let signed:int
field let flag:bool
field let integer:int
field let real:double
field let unit:none
field let boxed:any
end
export func run() -> int
scope bad
scope good
block entry
%small:byte = const 1
%negative:int = const -1
%true:bool = const true
%zero:int = const 0
%one:double = const 1.0
%empty:none = const none
%emptyBox:any = box %empty
%packed:Packed = new Packed(%small,%negative,%true,%zero,%one,%empty,%emptyBox)
%replacement:byte = const 42
%newSigned:int = const -10
%false:bool = const false
%number:int = const 123456
%double:double = const 2.25
%eleven:int = const 11
%box:any = box %eleven
set %packed.tiny = %replacement
set %packed.signed = %newSigned
set %packed.flag = %false
set %packed.integer = %number
set %packed.real = %double
set %packed.unit = %empty
set %packed.boxed = %box
%b:byte = get %packed.tiny
%s:int = get %packed.signed
%flag:bool = get %packed.flag
%i:int = get %packed.integer
%d:double = get %packed.real
%n:none = get %packed.unit
%x:any = get %packed.boxed
%contained:int = cast %x int
%bi:int = convert %b
%di:int = convert %d
%sum1:int = add %bi,%s
%sum2:int = add %sum1,%i
%sum3:int = add %sum2,%di
%sum4:int = add %sum3,%contained
branch %flag bad() good(%sum4)
end-scope
block good(%answer:int)
return %answer
end-scope
block bad()
%bad:int = const 0
return %bad
end
`, "packed-fields", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;for(let i=0;i<1000;i++)if(e.run()!==123501)process.exit(1)`)
}

export function testDiagnostics(): none {
    rejected(`class Box implements Missing\nend`, "unknown interface Missing")
    rejected(`interface I\nmethod get() -> int\nend\nclass Box implements I\nend`, "does not implement method")
    rejected(`export func f() -> int\nblock entry\n%a:int = const 1\n%r:int = call f(%a)\nreturn %r\nend`, "expected 0 positional arguments")
    rejected(`export func f() -> int\nblock entry\njump missing()\nend`, "unknown block missing")
    rejected(`export func f() -> int\nblock entry\n%a:int = const 1\n%x:int = cast %a int\nreturn %x\nend`, "cast needs any")
    rejected(`export func f() -> int\nblock entry\n%a:int = const 1\njump next(%a)\nblock next(%x:long)\nreturn %a\nend`, "argument 1 needs long")
    rejected(`class Box\nfield value:int\nend\nexport func f() -> int\nblock entry\n%a:int = const 1\n%b:Box = new Box(%a)\nset %b.value = %a\nreturn %a\nend`, "immutable")
    rejected(`export func f() -> char\nblock entry\n%c:char = const 256\nreturn %c\nend`, "one UTF-8 byte")
    rejected(`interface I\nmethod get() -> int\nmethod get() -> int\nend`, "duplicate interface method")
    let oversized = "class Oversized\n"
    for index of 0..<129 { oversized += "field f" + string(index) + ":long\n" }
    oversized += "end"
    rejected(oversized, "class allocation exceeds 1032 bytes")
}

export function testRemainderRejectsNonIntegerOperands(): none {
    rejected(`export func remainder(%a:double, %b:double) -> double
block entry
%result:double = rem %a, %b
return %result
end`, "rem needs integer operands")
    rejected(`export func remainder(%a:int, %b:long) -> int
block entry
%result:int = rem %a, %b
return %result
end`, "rem needs matching supported operands")
}

export function testIntegerRemainderInstructionsExecuteAcrossWidths(): none {
    runWasm(`export func byteRemainder(%a:byte, %b:byte) -> byte
block entry
%r:byte = rem %a, %b
return %r
end
export func intRemainder(%a:int, %b:int) -> int
block entry
%r:int = rem %a, %b
return %r
end
export func longRemainder(%a:long, %b:long) -> long
block entry
%r:long = rem %a, %b
return %r
end`, "integer-remainder", `
const fs=require('fs'),assert=require('assert');
WebAssembly.instantiate(fs.readFileSync(process.argv[1])).then(({instance})=>{
 const e=instance.exports;
 assert.strictEqual(e.byteRemainder(255,128),127);
 assert.strictEqual(e.intRemainder(-129,128),-1);
 assert.strictEqual(e.longRemainder(-129n,128n),-1n);
 assert.strictEqual(e.intRemainder(-2147483648,-1),0);
 assert.strictEqual(e.longRemainder(-9223372036854775808n,-1n),0n);
 assert.throws(()=>e.byteRemainder(1,0),WebAssembly.RuntimeError);
}).catch(error=>{console.error(error);process.exit(1)});
`)
}
