import { minusBlocks } from "./minus-control-flow"
import { Assert } from "std/assert"
import { MinusImport, MinusValue } from "./minus-ir"
import { pruneDeadBlockArguments } from "./minus-optimize"
import { parseDoofMinus } from "./minus-parse"
import { renderDoofMinus } from "./minus-render"
import { validateDoofMinus } from "./minus-validate"
import { encodeDoofMinus, compileDoofMinus } from "./minus-wasm"

export function testPrunesForwardedCyclesAndPreservesLiveExitValues(): none {
    original := parseDoofMinus(`export func count(%limit:int) -> long
scope done
scope cycle
block entry
%zero:int = const 0
%wide:long = const 9007199254740993
jump cycle(%zero, %wide)
end-scope
loop cycle
scope step
block cycle(%remaining:int, %unused:long)
%again:bool = lt %remaining, %limit
branch %again step(%remaining, %unused) done(%remaining, %unused)
end-scope
block step(%old:int, %forwarded:long)
%one:int = const 1
%next:int = add %old, %one
jump cycle(%next, %forwarded)
end-loop
end-scope
block done(%answer:int, %discarded:long)
%result:long = convert %answer
return %result
end
`)!
    validateDoofMinus(original)!
    snapshot := renderDoofMinus(original)
    original.functions[0].exportName = "renamed"
    optimized := pruneDeadBlockArguments(original)
    validateDoofMinus(optimized)!
    function_ := optimized.functions[0]
    Assert.equal(function_.exportName, "renamed")
    for index of 1..<minusBlocks(function_).length { Assert.equal(minusBlocks(function_)[index].params.length, 1) }
    Assert.equal(minusBlocks(function_)[1].params[0].name, "%remaining")
    Assert.equal(minusBlocks(function_)[0].instructions[2].args.length, 2)
    Assert.equal(minusBlocks(function_)[1].instructions[1].args.length, 6)
    Assert.equal(minusBlocks(function_)[2].instructions[2].args.length, 2)
    Assert.equal(minusBlocks(original.functions[0])[1].params.length, 2)
    original.functions[0].exportName = ""
    Assert.equal(renderDoofMinus(original), snapshot)
    Assert.equal(renderDoofMinus(pruneDeadBlockArguments(optimized)), renderDoofMinus(optimized))
    Assert.arrayEqual((encodeDoofMinus(original)!).cloneReadonly(), (encodeDoofMinus(original)!).cloneReadonly())
}

export function testKeepsUsesInCallsEffectsConditionsAndReturns(): none {
    original := parseDoofMinus(`export func choose(%flag:bool, %value:long) -> long
scope done
scope target
block entry
jump target(%flag, %value, %value)
end-scope
block target(%condition:bool, %kept:long, %unused:long)
%effect:none = call observe(%kept)
branch %condition done(%kept, %unused) done(%kept, %unused)
end-scope
block done(%result:long, %discarded:long)
return %result
end
`)!
    original.imports.push(MinusImport { name: "observe", importName: "observe", params: [MinusValue { name: "%value", typeName: "long" }], result: "none" })
    validateDoofMinus(original)!
    optimized := pruneDeadBlockArguments(original)
    validateDoofMinus(optimized)!
    blocks := minusBlocks(optimized.functions[0])
    Assert.equal(blocks[1].params.length, 2)
    Assert.equal(blocks[2].params.length, 1)
    Assert.equal(blocks[1].instructions[0].op, "call")
    Assert.equal(blocks[1].instructions[1].args.length, 6)
}

export function testUnusedReferenceForwardingDoesNotRemoveAllocationsOrCalls(): none {
    original := parseDoofMinus(`class Box
field value:int
end
export func check() -> int
scope second
scope first
block entry
%value:int = call effect()
%object:Box = new Box(%value)
jump first(%object)
end-scope
block first(%unused:Box)
jump second(%unused)
end-scope
block second(%forwarded:Box)
%answer:int = const 42
return %answer
end
`)!
    original.imports.push(MinusImport { name: "effect", importName: "effect", result: "int" })
    validateDoofMinus(original)!
    optimized := pruneDeadBlockArguments(original)
    validateDoofMinus(optimized)!
    blocks := minusBlocks(optimized.functions[0])
    Assert.equal(blocks[0].instructions[0].op, "call")
    Assert.equal(blocks[0].instructions[1].op, "new")
    Assert.equal(blocks[1].params.length, 0)
    Assert.equal(blocks[2].params.length, 0)
    Assert.equal(blocks[0].instructions[2].args.length, 1)
}

export function testLiteralTextIsNotAParameterUseAndMetadataSurvives(): none {
    original := parseDoofMinus(`class __doof_array_char
field let data:int
end
class __doof_string
field chars:__doof_array_char
end
export func check(%value:int) -> int
scope target
block entry
jump target(%value)
end-scope
block target(%unused:int)
%literal:__doof_string = string-const %unused
return %value
end
`)!
    validateDoofMinus(original)!
    optimized := pruneDeadBlockArguments(original)
    validateDoofMinus(optimized)!
    block_ := minusBlocks(optimized.functions[0])[1]
    Assert.equal(block_.params.length, 0)
    Assert.equal(block_.line, minusBlocks(original.functions[0])[1].line)
    edge := minusBlocks(optimized.functions[0])[0].instructions[0]
    Assert.equal(edge.line, minusBlocks(original.functions[0])[0].instructions[0].line)
    Assert.equal(block_.instructions[0].args[0], "%unused")
}

export function testValidatesOriginalDeadArgumentsBeforeOptimization(): none {
    case compileDoofMinus(`export func invalid(%value:int) -> int
scope done
block entry
jump done(%value)
end-scope
block done(%unused:long)
return %value
end
`) {
        failure: Failure<string> -> { Assert.stringContains(failure.error, "needs long") }
        _ -> { Assert.fail("An unused argument with the wrong type must still be rejected") }
    }
}

export function testRetainsReferenceArgumentsForObservableDestructors(): none {
    original := parseDoofMinus(`class Owner
destructor Owner.destroy
end
func Owner.destroy(%self:Owner) -> none
block entry
%effect:none = call record()
return
end
export func check(%value:int) -> int
scope done
block entry
%object:Owner = new Owner()
jump done(%object, %value)
end-scope
block done(%unused:Owner, %discarded:int)
return %value
end
`)!
    original.imports.push(MinusImport { name: "record", importName: "record", result: "none" })
    validateDoofMinus(original)!
    optimized := pruneDeadBlockArguments(original)
    validateDoofMinus(optimized)!
    Assert.equal(minusBlocks(optimized.functions[1])[1].params.length, 1)
    Assert.equal(minusBlocks(optimized.functions[1])[1].params[0].typeName, "Owner")
}
