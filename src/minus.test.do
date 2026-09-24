import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { compileDoofMinus } from "./minus-wasm"

function runWasm(source: string, testName: string, script: string): none {
    bytes := try! compileDoofMinus(source)
    path := "/tmp/doof-minus-" + string(pid()) + "-" + testName + ".wasm"
    try! writeBlob(path, bytes.cloneReadonly())
    result := try! run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
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

function runCappedWasm(source: string, testName: string, script: string): none {
    bytes := capMemoryAtOnePage(try! compileDoofMinus(source))
    path := "/tmp/doof-minus-" + string(pid()) + "-" + testName + ".wasm"
    try! writeBlob(path, bytes.cloneReadonly())
    result := try! run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
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

export function testPrimitiveExecution(): none {
    runWasm(`
export func shortSum() -> short
block entry
%a:short = const 32767
%b:short = const 1
%c:short = add %a, %b
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
%a:char = const 128512
return %a
end
`, "primitives", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.shortSum()!==-32768||e.floatValue()!==3.75||e.doubleValue()!==3.75||e.longValue()!==10000000007n||e.byteValue()!==0||e.charValue()!==128512)process.exit(1)`)
}

export function testControlFlowAndConversions(): none {
    runWasm(`
export func count(%limit:int) -> long
block entry
%zero:int = const 0
jump loop(%zero)
block loop(%n:int)
%again:bool = lt %n, %limit
branch %again step(%n) done(%n)
block step(%old:int)
%one:int = const 1
%next:int = add %old, %one
jump loop(%next)
block done(%answer:int)
%wide:long = convert %answer
return %wide
end
`, "flow", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.count(0)!==0n||e.count(10000)!==10000n)process.exit(1)`)
}

export function testPrimitiveHostBoundary(): none {
    runWasm(`
export func narrow(%value:short) -> short
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
`, "boundary", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.narrow(65535)!==-1||e.truth(7)!==1||e.character(128512)!==128512||e.nothing()!==undefined)process.exit(1);try{e.character(55296);process.exit(2)}catch(x){if(!(x instanceof WebAssembly.RuntimeError))process.exit(3)}`)
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
export func narrow(%value:double) -> short
block entry
%integer:int = convert %value
%short:short = convert %integer
return %short
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
`, "conversions", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.widen(200)!==200||e.narrow(65535)!==-1||e.compare(65,66)!==1||e.compareBool(7,1)!==1)process.exit(1)`)
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
block yes(%bx:any)
%other:Box = cast %bx Box
%r:int = get %other.value
return %r
block no()
%z:int = const 0
return %z
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
block entry
%one:int = const 1
%two:int = const 2
%first:First = new First(%one)
%second:Second = new Second(%two)
%a:Readable = as %first
%b:Readable = as %second
branch %flag left(%a) right(%b)
block left(%left:Readable)
jump joined(%left)
block right(%right:Readable)
jump joined(%right)
block joined(%item:Readable)
%value:int = call %item.get()
return %value
end
`, "dispatch", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.choose(1)!==1||e.choose(0)!==2)process.exit(1)`)
}

export function testHeapGrowthAndRelease(): none {
    runWasm(`
class Node
field next:any
end
export func makeChain(%limit:int) -> int
block entry
%empty:none = const none
%head:any = box %empty
%zero:int = const 0
jump loop(%zero,%head)
block loop(%i:int,%chain:any)
%more:bool = lt %i,%limit
branch %more step(%i,%chain) done(%i,%chain)
block step(%old:int,%previous:any)
%node:Node = new Node(%previous)
%boxed:any = box %node
%one:int = const 1
%next:int = add %old,%one
jump loop(%next,%boxed)
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
block yes(%answer:double)
return %answer
block no()
%zero:double = const 0.0
return %zero
end
`, "floating-fields", `const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;if(e.run()!==2.25)process.exit(1)`)
}

export function testPackedFieldsExecute(): none {
    runWasm(`
class Packed
field let tiny:byte
field let signed:short
field let flag:bool
field let integer:int
field let real:double
field let unit:none
field let boxed:any
end
export func run() -> int
block entry
%small:byte = const 1
%negative:short = const -1
%true:bool = const true
%zero:int = const 0
%one:double = const 1.0
%empty:none = const none
%emptyBox:any = box %empty
%packed:Packed = new Packed(%small,%negative,%true,%zero,%one,%empty,%emptyBox)
%replacement:byte = const 42
%newSigned:short = const -10
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
%s:short = get %packed.signed
%flag:bool = get %packed.flag
%i:int = get %packed.integer
%d:double = get %packed.real
%n:none = get %packed.unit
%x:any = get %packed.boxed
%contained:int = cast %x int
%bi:int = convert %b
%si:int = convert %s
%di:int = convert %d
%sum1:int = add %bi,%si
%sum2:int = add %sum1,%i
%sum3:int = add %sum2,%di
%sum4:int = add %sum3,%contained
branch %flag bad() good(%sum4)
block bad()
%bad:int = const 0
return %bad
block good(%answer:int)
return %answer
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
    rejected(`export func f() -> char\nblock entry\n%c:char = const 55296\nreturn %c\nend`, "Unicode scalar")
    rejected(`interface I\nmethod get() -> int\nmethod get() -> int\nend`, "duplicate interface method")
    let oversized = "class Oversized\n"
    for index of 0..<129 { oversized += "field f" + string(index) + ":long\n" }
    oversized += "end"
    rejected(oversized, "class allocation exceeds 1032 bytes")
}
