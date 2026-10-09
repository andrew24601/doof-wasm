import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { compileDoofWasm, lowerDoofWasmSource } from "./doof-compiler"
import { minusBlocks } from "./minus-control-flow"
import { compileDoofMinus } from "./minus-wasm"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { validateDoofMinus } from "./minus-validate"
import { pruneDeadBlockArguments } from "./minus-optimize"

function execute(bytes: byte[], name: string, script: string): none {
    path := "/tmp/doof-structured-" + string(pid()) + "-" + name + ".wasm"
    writeBlob(path, bytes.cloneReadonly())!
    result := run("node", ["-e", script, path], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
    _ := remove(path) else { panic("Could not remove structured Wasm fixture") }
    if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
    Assert.equal(result.exitCode, 0)
}

function rejected(source: string, message: string): none {
    case compileDoofMinus(source) {
        failure: Failure<string> -> { Assert.stringContains(failure.error, message) }
        _ -> { Assert.fail("Expected a structured IR diagnostic") }
    }
}

export function testStructuredLoopRoundTripAndDominatingValues(): none {
    source := `export func count(%limit:int) -> int
scope done
scope header
block entry
%zero:int = const 0
%one:int = const 1
jump header(%zero)
end-scope
loop header
scope step
block header(%n:int)
%again:bool = lt %n, %limit
branch %again step() done(%n)
end-scope
block step
%next:int = add %n, %one
jump header(%next)
end-loop
end-scope
block done(%answer:int)
return %answer
end
`
    module_ := parseDoofMinus(source)!
    validateDoofMinus(module_)!
    Assert.equal(renderDoofMinus(module_), source)
    optimized := pruneDeadBlockArguments(module_)
    validateDoofMinus(optimized)!
    Assert.equal(minusBlocks(optimized.functions[0])[1].params.length, 1)
    execute(compileDoofMinus(source)!, "dominators", `
const fs=require('fs'),assert=require('assert');
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;
for(let n=0;n<100;n++)assert.strictEqual(e.count(n),n);
`)
}

export function testStructuredRejectsUnscopedGraphEdges(): none {
    rejected(`export func invalid() -> int
block entry
jump done()
block done
%value:int = const 1
return %value
end`, "branches must target an enclosing scope or loop")
    rejected(`export func invalid() -> int
scope done
block entry
jump done()
end-scope
block other
%value:int = const 1
return %value
block done
%other:int = const 2
return %other
end`, "invalid structured control flow")
}

export function testStructuredRejectsSiblingAndForwardDefinitions(): none {
    rejected(`export func invalid(%flag:bool) -> int
scope right
scope left
block entry
branch %flag left() right()
end-scope
block left
%onlyLeft:int = const 42
return %onlyLeft
end-scope
block right
return %onlyLeft
end`, "unknown or out-of-block value %onlyLeft")
    rejected(`export func invalid() -> int
block entry
%value:int = add %later, %later
%later:int = const 1
return %value
end`, "unknown or out-of-block value %later")
}

export function testStructuredRejectsMalformedLoopsAndRegionEnds(): none {
    rejected(`export func invalid() -> none
loop entry
block wrong
return
end-loop
end`, "invalid structured control flow")
    rejected(`export func invalid() -> none
loop entry
block entry
return
end-scope
end`, "mismatched control region end")
    rejected(`export func invalid() -> none
loop entry
block entry
return
end`, "unterminated control region")
}

export function testSourceLoweringInheritsImmutableBindings(): none {
    module_ := lowerDoofWasmSource(`export function count(limit: int): int {
        increment := 2
        let n = 0
        while n < limit { n += increment }
        return n
    }`)!
    function_ := module_.functions[0]
    let parameters = 0
    for block_ of minusBlocks(function_) { parameters += block_.params.length }
    // Header, body, and exit carry n. increment remains a dominating value.
    Assert.equal(parameters, 3)
    Assert.stringContains(renderDoofMinus(module_), "loop while_cond")
}

export function testNestedSourceLoopsEmitNoDispatchTables(): none {
    bytes := compileDoofWasm(`export function nested(limit: int): int {
        stride := 3
        let sum = 0
        for let i = 0; i < limit; i += 1 {
            let j = 0
            while j < stride {
                j += 1
                if j == 2 { continue }
                if i == 4 { break }
                sum += i + j
            }
        }
        return sum
    }`)!
    execute(bytes, "no-dispatch", `
const fs=require('fs'),assert=require('assert'),b=fs.readFileSync(process.argv[1]);
const e=new WebAssembly.Instance(new WebAssembly.Module(b)).exports;
for(let n=0;n<12;n++){
 let sum=0;for(let i=0;i<n;i++)for(let j=1;j<=3;j++){if(j===2)continue;if(i===4)break;sum+=i+j;}
 assert.strictEqual(e.nested(n),sum);
}
// Decode instructions, rather than searching immediate/data bytes for 0x0e.
let p=8,tables=0;
function leb(){let v=0,s=0,x;do{x=b[p++];v+=(x&127)*2**s;s+=7;}while(x&128);return v;}
while(p<b.length){const id=b[p++],size=leb(),stop=p+size;if(id!==10){p=stop;continue;}
 const count=leb();for(let f=0;f<count;f++){
  const length=leb(),end=p+length,groups=leb();for(let g=0;g<groups;g++){leb();p++;}
  while(p<end){const op=b[p++];
   assert.notStrictEqual(op,14,'structured functions must not contain br_table');
   if([2,3,4,6,7,8,12,13,16,32,33,34,35,36,63,64].includes(op))leb();
   else if(op===17){leb();leb();}
   else if(op>=40&&op<=62){leb();leb();}
   else if(op===65||op===66)leb();
   else if(op===67)p+=4;else if(op===68)p+=8;
  }
  assert.strictEqual(p,end);
 }
 assert.strictEqual(p,stop);
}
`)
}
