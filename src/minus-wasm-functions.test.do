import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { MinusImport, MinusValue } from "./minus-ir"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { encodeDoofMinusWithLayout } from "./minus-wasm"

function execute(bytes: byte[], name: string, script: string): none {
    path := "/tmp/doof-folding-" + string(pid()) + "-" + name + ".wasm"
    try! writeBlob(path, bytes.cloneReadonly())
    result := try! run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
    try! remove(path)
    if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
    Assert.equal(result.exitCode, 0)
}

export function testFoldsBodiesAndCallersWhilePreservingExports(): none {
    module_ := try! parseDoofMinus(`func first(%value:int) -> int
block entry
%one:int = const 1
%answer:int = add %value, %one
return %answer
end
func second(%other:int) -> int
block entry
%increment:int = const 1
%result:int = add %other, %increment
return %result
end
export func left(%value:int) -> int
block entry
%answer:int = call first(%value)
return %answer
end
export func right(%value:int) -> int
block entry
%answer:int = call second(%value)
return %answer
end
export func both(%value:int) -> int
block entry
%left:int = call left(%value)
%right:int = call right(%value)
%sum:int = add %left, %right
return %sum
end`)
    module_.functions[2].exportName = "renamed"
    original := renderDoofMinus(module_)
    encoded := try! encodeDoofMinusWithLayout(module_)
    Assert.equal(encoded.definedFunctions, 6)
    Assert.equal(encoded.typeCount, 3)
    Assert.equal(encoded.functionBodies[0], encoded.functionBodies[1])
    Assert.equal(encoded.functionBodies[2], encoded.functionBodies[3])
    Assert.notEqual(encoded.functionBodies[0], encoded.functionBodies[2])
    Assert.equal(renderDoofMinus(module_), original)
    Assert.arrayEqual(encoded.bytes.cloneReadonly(), (try! encodeDoofMinusWithLayout(module_)).bytes.cloneReadonly())
    execute(encoded.bytes, "calls", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
assert.strictEqual(e.renamed,e.right,'exports refer to one implementation');
for(const n of [-100,0,41,1000]) {
 assert.strictEqual(e.renamed(n),n+1);assert.strictEqual(e.right(n),n+1);
 assert.strictEqual(e.both(n),2*(n+1));
}
`)
}

export function testSignaturesAndScalarNormalizationPreventUnsafeFolding(): none {
    module_ := try! parseDoofMinus(`export func dropInt(%value:int) -> none
block entry
return
end
export func dropLong(%value:long) -> none
block entry
return
end
export func dropFloat(%value:float) -> none
block entry
return
end
export func dropDouble(%value:double) -> none
block entry
return
end
export func integer(%value:int) -> int
block entry
return %value
end
export func boolean(%value:bool) -> bool
block entry
return %value
end
export func narrow(%value:byte) -> byte
block entry
return %value
end`)
    encoded := try! encodeDoofMinusWithLayout(module_)
    Assert.equal(encoded.typeCount, 6)
    for left of 0..<module_.functions.length {
        for right of (left + 1)..<module_.functions.length { Assert.notEqual(encoded.functionBodies[left], encoded.functionBodies[right]) }
    }
    execute(encoded.bytes, "signatures", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
e.dropInt(42);e.dropLong(9007199254740993n);e.dropFloat(1.5);e.dropDouble(2.25);
assert.strictEqual(e.integer(-1),-1);assert.strictEqual(e.boolean(-1),1);assert.strictEqual(e.narrow(-1),255);
`)
}

export function testDistinctImportsStayDistinctAndCallsAreRelocated(): none {
    module_ := try! parseDoofMinus(`export func left(%value:int) -> int
block entry
%answer:int = call externalLeft(%value)
return %answer
end
export func right(%value:int) -> int
block entry
%answer:int = call externalRight(%value)
return %answer
end`)
    for name of ["externalLeft", "externalRight"] {
        module_.imports.push(MinusImport { name, importModule: "host", importName: name, params: [MinusValue { name: "%value", typeName: "int" }], result: "int" })
    }
    encoded := try! encodeDoofMinusWithLayout(module_)
    Assert.equal(encoded.typeCount, 3)
    Assert.notEqual(encoded.functionBodies[0], encoded.functionBodies[1])
    execute(encoded.bytes, "imports", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{externalLeft:n=>n+1,externalRight:n=>n+2}}).exports;
assert.strictEqual(e.left(40),41);assert.strictEqual(e.right(40),42);
`)
}

export function testFoldedMethodsPreserveIndirectDispatchAndOwnership(): none {
    module_ := try! parseDoofMinus(`interface Readable
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
export func readFirst() -> int
block entry
%one:int = const 1
%object:First = new First(%one)
%reader:Readable = as %object
%result:int = call %reader.get()
return %result
end
export func readSecond() -> int
block entry
%two:int = const 2
%object:Second = new Second(%two)
%reader:Readable = as %object
%result:int = call %reader.get()
return %result
end`)
    encoded := try! encodeDoofMinusWithLayout(module_, true)
    Assert.equal(encoded.functionBodies[0], encoded.functionBodies[1])
    execute(encoded.bytes, "methods", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let i=0;i<100;i++){assert.strictEqual(e.readFirst(),1);assert.strictEqual(e.readSecond(),2);}
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0,'owned method receivers are released');
`)
}

export function testFoldedGlobalInitializersRemainValidStartCalls(): none {
    module_ := try! parseDoofMinus(`global FIRST:int = first
global SECOND:int = second
func first() -> int
block entry
%value:int = const 21
return %value
end
func second() -> int
block entry
%value:int = const 21
return %value
end
export func answer() -> int
block entry
%left:int = global-get FIRST
%right:int = global-get SECOND
%sum:int = add %left, %right
return %sum
end`)
    encoded := try! encodeDoofMinusWithLayout(module_)
    Assert.equal(encoded.functionBodies[0], encoded.functionBodies[1])
    execute(encoded.bytes, "globals", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
assert.strictEqual(e.answer(),42);
`)
}
