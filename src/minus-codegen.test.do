import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { MinusImport, MinusModule, MinusValue } from "./minus-ir"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { validateDoofMinus } from "./minus-validate"
import { encodeDoofMinusWithLayout } from "./minus-wasm"
import { simplifyMinusInstructions } from "./minus-simplify"
import { allocateWasmLocals } from "./minus-wasm-locals"
import { compileDoofWasm } from "./doof-compiler"

function assertBorrowed(module_: MinusModule, functionName: string, name: string, expected: bool): none {
    for function_ of module_.functions {
        if function_.name != functionName { continue }
        layout := allocateWasmLocals(module_, function_)
        for index of 0..<layout.table.values.length {
            if layout.table.values[index].name == name { Assert.equal(layout.borrowed[index], expected); return }
        }
    }
    Assert.fail("missing ownership value: " + functionName + " " + name)
}

export function testCodegenBorrowsImmutableFieldsAndBoxPayloadsFromStableOwners(): none {
    // The low-level host ABI admits string pointers. Use that nominal carrier
    // for raw reference-count observations; this fixture performs no string IO.
    module_ := parseDoofMinus(`class __doof_string
field value:int
destructor __doof_string.destroy
end
class Root
field boxed:any
end
func __doof_string.destroy(%self:__doof_string) -> none
block entry
%value:int = get %self.value
%event:none = call record(%value)
return
end
func make(%value:int) -> Root
block entry
%leaf:__doof_string = new __doof_string(%value)
%box:any = box %leaf
%root:Root = new Root(%box)
return %root
end
func read(%self:Root, %limit:int) -> __doof_string
scope done
scope cycle
block entry
%zero:int = const 0
%one:int = const 1
jump cycle(%zero)
end-scope
loop cycle
scope step
block cycle(%n:int)
%again:bool = lt %n, %limit
branch %again step() done()
end-scope
block step
%box:any = get %self.boxed
%leaf:__doof_string = cast %box, __doof_string
%alias:__doof_string = copy %leaf
%observed:none = call observe(%alias)
%next:int = add %n, %one
jump cycle(%next)
end-loop
end-scope
block done
%resultBox:any = get %self.boxed
%result:__doof_string = cast %resultBox, __doof_string
return %result
end
export func run(%limit:int) -> int
block entry
%root:Root = call make(%limit)
%leaf:__doof_string = call read(%root, %limit)
%returned:none = call observeReturned(%leaf)
%value:int = get %leaf.value
return %value
end
export func owned(%value:int) -> int
block entry
%leaf:__doof_string = new __doof_string(%value)
%box:any = box %leaf
%root:Root = new Root(%box)
%ownedBox:any = get %root.boxed
%ownedLeaf:__doof_string = cast %ownedBox, __doof_string
%result:int = get %ownedLeaf.value
return %result
end
func fail(%self:Root) -> none
block entry
%box:any = get %self.boxed
%leaf:__doof_string = cast %box, __doof_string
%alias:__doof_string = copy %leaf
panic %alias
end
export func crash(%value:int) -> none
block entry
%root:Root = call make(%value)
%failed:none = call fail(%root)
return
end`)!
    module_.recoverPanics = true
    module_.imports.push(MinusImport { name: "record", importModule: "host", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" })
    module_.imports.push(MinusImport { name: "observe", importModule: "host", importName: "observe", params: [MinusValue { name: "%leaf", typeName: "__doof_string" }], result: "none" })
    module_.imports.push(MinusImport { name: "observeReturned", importModule: "host", importName: "observeReturned", params: [MinusValue { name: "%leaf", typeName: "__doof_string" }], result: "none" })
    for name of ["%box", "%leaf", "%alias", "%resultBox", "%result"] { assertBorrowed(module_, "read", name, true) }
    assertBorrowed(module_, "owned", "%ownedBox", false)
    assertBorrowed(module_, "owned", "%ownedLeaf", false)
    for name of ["%box", "%leaf", "%alias"] { assertBorrowed(module_, "fail", name, true) }
    execute((encodeDoofMinusWithLayout(module_, true)!).bytes, "immutable-borrows", `
const fs=require('fs'),assert=require('assert'),events=[];let e,observations=0;
const count=p=>new DataView(e.__doof_ffi_memory.buffer).getUint32(p+4,true);
e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{record:n=>events.push(n),observe:p=>{assert.strictEqual(count(p),1);observations++;},observeReturned:p=>assert.strictEqual(count(p),2)}}).exports;
for(let n=0;n<100;n++){
 assert.strictEqual(e.run(n),n);assert.deepStrictEqual(events,[n]);events.length=0;
 assert.strictEqual(e.owned(n),n);assert.deepStrictEqual(events,[n]);events.length=0;
 let payload;try{e.crash(n);assert.fail('expected panic');}catch(error){assert(error instanceof WebAssembly.Exception);payload=error.getArg(e.__doof_panic_tag,0);}
 assert.strictEqual(count(payload),1);assert.deepStrictEqual(events,[]);
 e.__doof_ffi_release(payload);assert.deepStrictEqual(events,[n]);events.length=0;
}
assert.strictEqual(observations,4950);
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}

export function testCodegenBorrowingRejectsMutableFieldsAndRepeatingOwners(): none {
    module_ := parseDoofMinus(`interface View
field leaf:Leaf
end
class Leaf
field value:int
end
class Immutable implements View
field leaf:Leaf
end
class Mutable implements View
field let leaf:Leaf
end
func view(%self:View) -> Leaf
block entry
%leaf:Leaf = get %self.leaf
return %leaf
end
func snapshot(%self:Mutable, %replacement:Leaf) -> Leaf
block entry
%old:Leaf = get %self.leaf
set %self.leaf = %replacement
return %old
end
export func work(%limit:int) -> int
scope done
scope cycle
block entry
%zero:int = const 0
%one:int = const 1
%initial:Leaf = new Leaf(%zero)
%owner:Immutable = new Immutable(%initial)
%stable:Leaf = get %owner.leaf
jump cycle(%zero, %owner)
end-scope
loop cycle
scope step
block cycle(%n:int, %carried:Immutable)
%carriedChild:Leaf = get %carried.leaf
%carriedCopy:Immutable = copy %carried
%again:bool = lt %n, %limit
branch %again step() done(%n)
end-scope
block step
%leaf:Leaf = new Leaf(%n)
%repeated:Immutable = new Immutable(%leaf)
%child:Leaf = get %repeated.leaf
%value:int = get %child.value
%next:int = add %value, %one
jump cycle(%next, %repeated)
end-loop
end-scope
block done(%result:int)
return %result
end`)!
    assertBorrowed(module_, "view", "%leaf", false)
    assertBorrowed(module_, "snapshot", "%old", false)
    assertBorrowed(module_, "work", "%stable", true)
    assertBorrowed(module_, "work", "%child", false)
    for name of ["%carried", "%carriedChild", "%carriedCopy"] { assertBorrowed(module_, "work", name, false) }
    execute((encodeDoofMinusWithLayout(module_, true)!).bytes, "mutable-borrows", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let n=0;n<100;n++)assert.strictEqual(e.work(n),n);
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}

export function testCodegenBorrowedLoopArgumentsSwapInParallelAndCopiesKeepTheirValue(): none {
    // As above, observe the reference carrier directly through the raw ABI.
    module_ := parseDoofMinus(`class __doof_string
field value:int
destructor __doof_string.destroy
end
func __doof_string.destroy(%self:__doof_string) -> none
block entry
%value:int = get %self.value
%event:none = call record(%value)
return
end
func swap(%left:__doof_string, %right:__doof_string, %limit:int) -> __doof_string
scope done
scope cycle
block entry
%zero:int = const 0
%one:int = const 1
jump cycle(%zero, %left, %right, %left)
end-scope
loop cycle
scope step
block cycle(%n:int, %a:__doof_string, %b:__doof_string, %previous:__doof_string)
%saved:__doof_string = copy %a
%first:none = call observe(%a)
%second:none = call observe(%b)
%third:none = call observe(%previous)
%fourth:none = call observe(%saved)
%again:bool = lt %n, %limit
branch %again step() done(%saved)
end-scope
block step
%next:int = add %n, %one
jump cycle(%next, %b, %a, %saved)
end-loop
end-scope
block done(%result:__doof_string)
return %result
end
export func run(%limit:int) -> int
block entry
%one:int = const 1
%two:int = const 2
%left:__doof_string = new __doof_string(%one)
%right:__doof_string = new __doof_string(%two)
%result:__doof_string = call swap(%left, %right, %limit)
%counted:none = call observeReturned(%result)
%value:int = get %result.value
return %value
end`)!
    for name of ["observe", "observeReturned"] {
        module_.imports.push(MinusImport { name, importModule: "host", importName: name, params: [MinusValue { name: "%text", typeName: "__doof_string" }], result: "none" })
    }
    module_.imports.push(MinusImport { name: "record", importModule: "host", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" })
    for name of ["%a", "%b", "%previous", "%saved", "%result"] { assertBorrowed(module_, "swap", name, true) }
    layout := allocateWasmLocals(module_, module_.functions[1])
    let savedSlot = -1
    let aSlot = -1
    for index of 0..<layout.table.values.length {
        if layout.table.values[index].name == "%saved" { savedSlot = layout.slots[index] }
        if layout.table.values[index].name == "%a" { aSlot = layout.slots[index] }
    }
    Assert.notEqual(savedSlot, aSlot)
    execute((encodeDoofMinusWithLayout(module_, true)!).bytes, "borrowed-phis", `
const fs=require('fs'),assert=require('assert'),events=[];let e;
const count=p=>new DataView(e.__doof_ffi_memory.buffer).getUint32(p+4,true);
e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{record:n=>events.push(n),observe:p=>assert.strictEqual(count(p),1),observeReturned:p=>assert.strictEqual(count(p),2)}}).exports;
for(let n=0;n<100;n++){
 assert.strictEqual(e.run(n),n%2?2:1);assert.deepStrictEqual(events,n%2?[1,2]:[2,1]);events.length=0;
}
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}

function execute(bytes: byte[], name: string, script: string): none {
    path := "/tmp/doof-codegen-" + string(pid()) + "-" + name + ".wasm"
    writeBlob(path, bytes.cloneReadonly())!
    result := run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
    remove(path)!
    if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
    Assert.equal(result.exitCode, 0)
}

export function testCodegenPrunesPrivateCyclesAndDeadBranches(): none {
    module_ := parseDoofMinus(`class __doof_array_char
field data:int
end
class __doof_string
field chars:__doof_array_char
end
func deadText() -> __doof_string
block entry
%text:__doof_string = string-const UNIQUE_UNREACHABLE_LITERAL
return %text
end
func cycleA() -> int
block entry
%value:int = call cycleB()
return %value
end
func cycleB() -> int
block entry
%value:int = call cycleA()
return %value
end
export func answer() -> int
scope done
scope right
scope left
block entry
%flag:bool = const true
branch %flag left() right()
end-scope
block left
%value:int = const 42
jump done(%value)
end-scope
block right
%bad:int = call cycleA()
jump done(%bad)
end-scope
block done(%result:int)
return %result
end`)!
    before := renderDoofMinus(module_)
    encoded := encodeDoofMinusWithLayout(module_)!
    for index of 0..<3 { Assert.equal(encoded.functionBodies[index], -1) }
    Assert.equal(encoded.definedFunctions, 4)
    Assert.equal(renderDoofMinus(module_), before)
    execute(encoded.bytes, "dead", `
const fs=require('fs'),assert=require('assert'),bytes=fs.readFileSync(process.argv[1]);
assert(!bytes.includes(Buffer.from('UNIQUE_UNREACHABLE_LITERAL')));
const e=new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
assert.strictEqual(e.answer(),42);
`)
}

export function testCodegenConstantsWrapAndUnusedTrapsRemain(): none {
    module_ := parseDoofMinus(`export func wrap() -> int
block entry
%max:int = const 2147483647
%one:int = const 1
%wrapped:int = add %max, %one
%alias:int = copy %wrapped
%unused:int = mul %one, %one
return %alias
end
export func narrow() -> byte
block entry
%max:byte = const 255
%one:byte = const 1
%wrapped:byte = add %max, %one
return %wrapped
end
export func divide(%value:int) -> int
block entry
%zero:int = const 0
%unused:int = div %value, %zero
%answer:int = const 42
return %answer
end
export func overflow() -> int
block entry
%min:int = const -2147483648
%negative:int = const -1
%unused:int = div %min, %negative
return %min
end
export func truncate(%value:double) -> int
block entry
%unused:int = convert %value
%answer:int = const 42
return %answer
end`)!
    optimized := simplifyMinusInstructions(module_)
    validateDoofMinus(optimized)!
    text := renderDoofMinus(optimized)
    Assert.stringContains(text, "const -2147483648")
    Assert.equal(text.contains("copy "), false)
    Assert.equal(text.contains("mul "), false)
    execute((encodeDoofMinusWithLayout(module_)!).bytes, "traps", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
assert.strictEqual(e.wrap(),-2147483648);assert.strictEqual(e.narrow(),0);
assert.throws(()=>e.divide(10),WebAssembly.RuntimeError);
assert.throws(()=>e.overflow(),WebAssembly.RuntimeError);
assert.throws(()=>e.truncate(NaN),WebAssembly.RuntimeError);
assert.strictEqual(e.truncate(1.5),42);
`)
}

export function testCodegenReusesScalarSlotsAcrossParallelLoopTransfers(): none {
    module_ := parseDoofMinus(`export func swap(%limit:int, %a:long, %b:long) -> long
scope done
scope cycle
block entry
%zero:int = const 0
%one:int = const 1
jump cycle(%zero, %a, %b)
end-scope
loop cycle
scope step
block cycle(%n:int, %left:long, %right:long)
%again:bool = lt %n, %limit
branch %again step() done(%left)
end-scope
block step
%next:int = add %n, %one
jump cycle(%next, %right, %left)
end-loop
end-scope
block done(%result:long)
return %result
end
export func addPhi(%a:int, %b:int) -> int
scope target
block entry
jump target(%a, %b)
end-scope
block target(%left:int, %right:int)
%answer:int = add %left, %right
return %answer
end`)!
    layout := allocateWasmLocals(module_, module_.functions[0])
    Assert.equal(layout.locals.length < layout.table.values.length - 3, true)
    execute((encodeDoofMinusWithLayout(module_)!).bytes, "swap", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let n=0;n<100;n++)assert.strictEqual(e.swap(n,9007199254740993n,-9007199254740995n),n%2?-9007199254740995n:9007199254740993n);
assert.strictEqual(e.addPhi(7,9),16);
`)
}

export function testCodegenStackArgumentsAndMixedCarriers(): none {
    bytes := compileDoofWasm(`function combine(a: int, b: int): int => a * 100 + b
export function run(n: int): double {
    let result = 0.0
    for i of 0..<n {
        let partial = 0.0f
        for j of 0..<3 { partial += float(combine(i + 1, j + 2)) }
        result += double(partial) + double(long(i))
    }
    return result
}`)!
    execute(bytes, "mixed", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let n=0;n<30;n++){let expected=0;for(let i=0;i<n;i++)expected+=300*(i+1)+9+i;assert.strictEqual(e.run(n),expected);}
`)
}

export function testCodegenBorrowedReferencesReturnOwnershipAndDestructorOrder(): none {
    module_ := parseDoofMinus(`class Box
field value:int
destructor Box.destroy
end
func Box.destroy(%self:Box) -> none
block entry
%value:int = get %self.value
%effect:none = call record(%value)
return
end
func make(%value:int) -> Box
block entry
%object:Box = new Box(%value)
return %object
end
func alias(%object:Box) -> Box
block entry
%copy:Box = copy %object
return %copy
end
export func retained(%value:int) -> int
block entry
%object:Box = call make(%value)
%alias:Box = call alias(%object)
%result:int = get %alias.value
return %result
end
export func work() -> none
block entry
%one:int = const 1
%two:int = const 2
%first:Box = new Box(%one)
%second:Box = new Box(%two)
%copy:Box = copy %first
return
end`)!
    module_.imports.push(MinusImport { name: "record", importModule: "host", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" })
    encoded := encodeDoofMinusWithLayout(module_, true)!
    Assert.equal(encoded.functionBodies[0] >= 0, true)
    execute(encoded.bytes, "ownership", `
const fs=require('fs'),assert=require('assert'),events=[];
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{record:n=>events.push(n)}}).exports;
assert.strictEqual(e.retained(7),7);assert.deepStrictEqual(events,[7]);events.length=0;
for(let i=0;i<100;i++){e.work();assert.deepStrictEqual(events,[2,1]);events.length=0;}
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}

export function testCodegenRemovesOnlyDominatedCastChecks(): none {
    bytes := compileDoofWasm(`function safe(value: int | long): long {
    case value { wide: long -> { return wide + 1L } _ -> { return 0L } }
}

export function loop(n: int): long {
    let result = 0L
    for i of 0..<n {
        let value: int | long = if i % 2 == 0 then long(i) else i
        result += safe(value)
    }
    return result
}`)!
    execute(bytes, "casts", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let n=0;n<40;n++){let expected=0n;for(let i=0;i<n;i+=2)expected+=BigInt(i+1);assert.strictEqual(e.loop(n),expected);}
`)
    invalid := parseDoofMinus(`export func bad(%value:int) -> long
block entry
%box:any = box %value
%cast:long = cast %box, long
return %cast
end`)!
    execute((encodeDoofMinusWithLayout(invalid)!).bytes, "unchecked", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
assert.throws(()=>e.bad(7),WebAssembly.RuntimeError);
`)
}

export function testCodegenBorrowsRootedReadsAcrossLoopsAndOwnedEscapes(): none {
    module_ := parseDoofMinus(`class __doof_array_char
field data:int
end
class __doof_string
field chars:__doof_array_char
end
class Holder
field let text:__doof_string
end
global ROOT:Holder = initialize
func initialize() -> Holder
block entry
%text:__doof_string = string-const initial
%holder:Holder = new Holder(%text)
return %holder
end
export func literal() -> __doof_string
block entry
%text:__doof_string = string-const shared
return %text
end
func root() -> Holder
block entry
%holder:Holder = global-get ROOT
return %holder
end
export func rootText() -> __doof_string
block entry
%holder:Holder = call root()
%text:__doof_string = get %holder.text
return %text
end
export func work(%limit:int) -> none
scope done
scope cycle
block entry
%zero:int = const 0
%one:int = const 1
jump cycle(%zero)
end-scope
loop cycle
scope step
block cycle(%n:int)
%again:bool = lt %n, %limit
branch %again step() done()
end-scope
block step
%holder:Holder = global-get ROOT
%text:__doof_string = string-const shared
set %holder.text = %text
%next:int = add %n, %one
jump cycle(%next)
end-loop
end-scope
block done
return
end
export func snapshot() -> __doof_string
block entry
%holder:Holder = global-get ROOT
%old:__doof_string = get %holder.text
%replacement:__doof_string = string-const replacement
set %holder.text = %replacement
return %old
end`)!
    layout := allocateWasmLocals(module_, module_.functions[4])
    for index of 0..<layout.table.values.length {
        name := layout.table.values[index].name
        if name == "%holder" || name == "%text" {
            Assert.equal(layout.borrowed[index], true)
            Assert.equal(layout.repeated[index], true)
            Assert.equal(layout.moved[index], false)
        }
    }
    execute((encodeDoofMinusWithLayout(module_, true)!).bytes, "rooted", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
const count=p=>new DataView(e.__doof_ffi_memory.buffer).getUint32(p+4,true);
const roots=()=>{const v=new DataView(e.__doof_ffi_memory.buffer),a=[];for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))if(v.getUint16(p,true))a.push([p,v.getUint16(p,true),v.getUint32(p+4,true)]);return a;};
const text=e.literal();assert.strictEqual(count(text),2);e.__doof_ffi_release(text);assert.strictEqual(count(text),1);
const initial=e.rootText();assert.strictEqual(count(initial),3);e.__doof_ffi_release(initial);assert.strictEqual(count(initial),2);
e.work(1);const baseline=roots();
for(let i=0;i<100;i++){e.work(i);assert.deepStrictEqual(roots(),baseline);}
const old=e.snapshot();assert.strictEqual(old,text);assert.strictEqual(count(old),2);e.__doof_ffi_release(old);assert.strictEqual(count(old),1);
`)
}

export function testCodegenReindexesFunctionsWithoutChangingTablesStartupOrDestructors(): none {
    let source = `global ROOT:int = initialize
interface Readable
method read() -> int
end
class Box implements Readable
field value:int
destructor Box.destroy
end
func initialize() -> int
block entry
%value:int = const 777
return %value
end
func Box.read(%self:Box) -> int
block entry
%value:int = get %self.value
return %value
end
func Box.destroy(%self:Box) -> none
block entry
%value:int = get %self.value
%effect:none = call record(%value)
return
end
`
    for index of 0..<140 {
        source += "export func cold" + string(index) + "() -> int\nblock entry\n%value:int = const " + string(index) + "\nreturn %value\nend\n"
    }
    source += `func hot() -> int
block entry
%value:int = const 999
return %value
end
export func alias() -> int
block entry
%value:int = const 999
return %value
end
export func answer() -> int
block entry
%root:int = global-get ROOT
%box:Box = new Box(%root)
%reader:Readable = as %box
%read:int = call %reader.read()
`
    let previous = "%read"
    for index of 0..<10 {
        value := "%hot" + string(index)
        sum := "%sum" + string(index)
        source += value + ":int = call hot()\n" + sum + ":int = add " + previous + ", " + value + "\n"
        previous = sum
    }
    source += "return " + previous + "\nend\n"
    module_ := parseDoofMinus(source)!
    module_.imports.push(MinusImport { name: "record", importModule: "host", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" })
    before := renderDoofMinus(module_)
    encoded := encodeDoofMinusWithLayout(module_, true)!
    hot := module_.functions.length - 3
    Assert.equal(encoded.functionBodies[hot] + module_.imports.length < 128, true)
    Assert.equal(encoded.functionBodies[hot], encoded.functionBodies[hot + 1])
    Assert.equal(renderDoofMinus(module_), before)
    execute(encoded.bytes, "reindexing", `
const fs=require('fs'),assert=require('assert'),events=[];
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{record:n=>events.push(n)}}).exports;
for(let i=0;i<140;i++)assert.strictEqual(e['cold'+i](),i);
assert.strictEqual(e.alias(),999);
for(let i=0;i<30;i++){assert.strictEqual(e.answer(),10767);assert.deepStrictEqual(events,[777]);events.length=0;}
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}

export function testCodegenReindexesWideLocalsAndPreservesReferenceCleanup(): none {
    let source = `class Box
field value:int
destructor Box.destroy
end
func Box.destroy(%self:Box) -> none
block entry
%value:int = get %self.value
%effect:none = call record(%value)
return
end
export func work(%value:int) -> long
block entry
`
    for index of 0..<200 { source += "%box" + string(index) + ":Box = new Box(%value)\n" }
    source += "%wide:long = convert %value\n"
    for index of 0..<20 { source += "%effect" + string(index) + ":none = call take(%wide)\n" }
    source += "return %wide\nend\n"
    module_ := parseDoofMinus(source)!
    module_.imports.push(MinusImport { name: "record", importModule: "host", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" })
    module_.imports.push(MinusImport { name: "take", importModule: "host", importName: "take", params: [MinusValue { name: "%value", typeName: "long" }], result: "none" })
    execute((encodeDoofMinusWithLayout(module_, true)!).bytes, "wide-locals", `
const fs=require('fs'),assert=require('assert'),destroyed=[],wide=[];
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{record:n=>destroyed.push(n),take:n=>wide.push(n)}}).exports;
for(const n of [-2147483648,-7,0,9,2147483647]){
assert.strictEqual(e.work(n),BigInt(n));assert.deepStrictEqual(wide,Array(20).fill(BigInt(n)));assert.deepStrictEqual(destroyed,Array(200).fill(n));wide.length=0;destroyed.length=0;
}
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}

export function testCodegenReleaseDispatchPreservesSparseTagsBoxesAndFieldOrder(): none {
    let source = `enum Kind
end
class Leaf
field value:int
destructor Leaf.destroy
end
func Leaf.destroy(%self:Leaf) -> none
block entry
%value:int = get %self.value
%effect:none = call record(%value)
return
end
`
    for index of 0..<40 {
        owner := "Owner" + string(index)
        source += "class " + owner + "\nfield left:Leaf\nfield right:Leaf\n"
        if index % 2 == 0 { source += "destructor " + owner + ".destroy\n" }
        source += "end\nclass Scalar" + string(index) + "\nfield value:int\nend\n"
        if index % 2 == 0 {
            source += "func " + owner + ".destroy(%self:" + owner + ") -> none\nblock entry\n%value:int = const " + string(1000 + index) + "\n%effect:none = call record(%value)\nreturn\nend\n"
        }
        source += "func make" + string(index) + "() -> any\nblock entry\n%leftValue:int = const " + string(index * 2) + "\n%rightValue:int = const " + string(index * 2 + 1) + "\n%left:Leaf = new Leaf(%leftValue)\n%right:Leaf = new Leaf(%rightValue)\n%owner:" + owner + " = new " + owner + "(%left, %right)\n%boxed:any = box %owner\nreturn %boxed\nend\n"
        source += "export func work" + string(index) + "() -> none\nblock entry\n%boxed:any = call make" + string(index) + "()\nreturn\nend\n"
        source += "export func scalar" + string(index) + "() -> none\nblock entry\n%value:int = const 2147483647\n%scalar:Scalar" + string(index) + " = new Scalar" + string(index) + "(%value)\n%boxed:any = box %scalar\nreturn\nend\n"
    }
    source += `export func primitiveBoxes() -> none
block entry
%empty:none = const none
%noneBox:any = box %empty
%int:int = const 2147483647
%intBox:any = box %int
%kind:Kind = const 2147483647
%enumBox:any = box %kind
return
end
export func leafBox() -> none
block entry
%value:int = const 42
%leaf:Leaf = new Leaf(%value)
%boxed:any = box %leaf
return
end
`
    module_ := parseDoofMinus(source)!
    module_.imports.push(MinusImport { name: "record", importModule: "host", importName: "record", params: [MinusValue { name: "%value", typeName: "int" }], result: "none" })
    before := renderDoofMinus(module_)
    encoded := encodeDoofMinusWithLayout(module_, true)!
    Assert.equal(renderDoofMinus(module_), before)
    execute(encoded.bytes, "release-dispatch", `
const fs=require('fs'),assert=require('assert'),events=[];
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{host:{record:n=>events.push(n)}}).exports;
for(let repeat=0;repeat<30;repeat++){
  for(let index=0;index<40;index++){
    e['work'+index]();
    assert.deepStrictEqual(events,index%2===0?[1000+index,index*2,index*2+1]:[index*2,index*2+1]);
    events.length=0;
    e['scalar'+index]();assert.deepStrictEqual(events,[]);
  }
  e.primitiveBoxes();assert.deepStrictEqual(events,[]);
  e.leafBox();assert.deepStrictEqual(events,[42]);events.length=0;
}
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0,'released block at '+p);
`)
}

export function testCodegenReleaseDispatchWithNoClasses(): none {
    module_ := parseDoofMinus(`enum Kind
end
export func work() -> int
block entry
%value:Kind = const 2147483647
%box:any = box %value
%result:int = const 42
return %result
end`)!
    encoded := encodeDoofMinusWithLayout(module_, true)!
    execute(encoded.bytes, "release-no-classes", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let i=0;i<100;i++)assert.strictEqual(e.work(),42);
const v=new DataView(e.__doof_ffi_memory.buffer);
for(let p=1024;p<e.__doof_debug_heap_end.value;p+=v.getUint16(p+2,true))assert.strictEqual(v.getUint16(p,true),0);
`)
}
