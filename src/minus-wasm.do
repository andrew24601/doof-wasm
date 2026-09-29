import { minusBlocks, minusBlockIndex, analyzeMinusControlFlow } from "./minus-control-flow"
import { parseDouble, parseFloat, parseInt, parseLong } from "std/parse"
import { MinusBlock, MinusClass, MinusField, MinusFunction, MinusInstruction, MinusInterface, MinusModule, MinusRegion, MinusValue, minusModuleLookup, lookupMinusName } from "./minus-ir"
import { classFieldOffset, classSize } from "./minus-layout"
import { parseDoofMinus } from "./minus-parse"
import { validateDoofMinus } from "./minus-validate"
import { pruneDeadBlockArguments, preserveReferenceLifetimes } from "./minus-optimize"
import { WasmFunctionBody, WasmFunctionPlan, foldWasmFunctions } from "./minus-wasm-functions"
import { reachableMinusFunctions, minusValueId, minusValues, minusOperandPositions, minusCallTarget, MinusValues, MinusEffects, analyzeMinusEffects } from "./minus-analysis"
import { WasmLocals, rawWasmLocals, allocateWasmLocals } from "./minus-wasm-locals"
import { simplifyMinusInstructions } from "./minus-simplify"
import { WasmInstruction, encodeWasmInstructions } from "./minus-wasm-instructions"
import { simplifyWasmInstructions } from "./minus-wasm-peepholes"
import { orderWasmLocals, orderWasmFunctions } from "./minus-wasm-ordering"

// All class references and any boxes are i32 pointers into one Wasm memory.
// Function indices 0-2 are the allocator, retain, and release helpers.
// Runtime tag zero is reserved for free blocks. Array data is uniquely owned
// by its array and must be managed by array intrinsics, not retain/release.
readonly ARRAY_DATA_TAG = 30 // Legacy single-block arrays and strings.
readonly ARRAY_DESCRIPTOR_TAG = 29
readonly ARRAY_NODE_TAG = 28
readonly ARRAY_CHUNK_TAG = 27
readonly ARRAY_CHUNK_BYTES = 1024
readonly ANY_TAG = 31
readonly MIN_BLOCK_SIZE = 24
// The 64 free-list heads live at 256-511. Bytes 0-7 stay zero, so address 0,
// which represents `none` in an `any`, reads as a header with the none tag.
readonly FREE_LIST_BASE = 256
readonly MAX_BLOCK_SIZE = 1032

// Helpers borrow their arguments; get/pop return one owned reference. Keep
// them after source functions so host exports and method-table slots are stable.
class ArrayHelper {
    operation: string
    typeName: string
    params: MinusValue[]
    instruction: MinusInstruction
}

class WasmHelpers {
    arrays: ArrayHelper[] = []
    functionStart: int
    typeStart: int
    signatures: int[][] = []
    typeIndexes: int[] = []
    live: bool[] = []
    // Leaf wrappers whose calls are emitted as their field loads plus one
    // storage helper or pure call; see inlineWrapper.
    inlinable: bool[] = []
    let effects: MinusEffects = MinusEffects {}
}

function arrayElementType(module_: MinusModule, values: WasmLocals, instruction: MinusInstruction): string {
    args := instruction.args
    let typeName = "int"
    if instruction.op == "array-alloc" { typeName = args[1] }
    if instruction.op == "array-reserve" { typeName = args[2] }
    if instruction.op == "array-copy" { typeName = args[5] }
    if instruction.op == "array-compare" || instruction.op == "array-equal" { typeName = "byte" }
    if instruction.op == "array-free" && args.length == 2 { typeName = args[1] }
    if instruction.op == "array-get" || instruction.op == "array-peek" || instruction.op == "array-pop" { typeName = instruction.result!.typeName }
    if instruction.op == "array-set" { typeName = valueType(values, args[2]) }
    if instruction.op == "array-push" { typeName = valueType(values, args[1]) }
    if reference(module_, typeName) { return "any" }
    if arrayWidth(typeName) == 1 { return "byte" }
    if typeName == "long" || typeName == "float" || typeName == "double" { return typeName }
    return "int"
}

function addArrayHelper(helpers: WasmHelpers, operation: string, typeName: string): none {
    for helper of helpers.arrays { if helper.operation == operation && helper.typeName == typeName { return } }
    if operation == "array-copy" {
        let params: MinusValue[] = []
        let args: string[] = []
        for name of ["%destination", "%destinationIndex", "%source", "%sourceIndex", "%count"] {
            params.push(MinusValue { name, typeName: "int" }); args.push(name)
        }
        args.push(typeName)
        helpers.arrays.push(ArrayHelper { operation, typeName, params, instruction: MinusInstruction { op: operation, args } })
        return
    }
    let params = [MinusValue { name: "%handle", typeName: "int" }]
    let args = ["%handle"]
    let resultType = "none"
    if operation == "array-alloc" { args.push(typeName); resultType = "int" }
    if operation == "array-free" && typeName == "any" { args.push(typeName) }
    if operation == "array-length" { resultType = "int" }
    if operation == "array-compare" || operation == "array-equal" {
        params.push(MinusValue { name: "%other", typeName: "int" }); args.push("%other")
        resultType = if operation == "array-equal" then "bool" else "int"
    }
    if operation == "array-get" || operation == "array-peek" || operation == "array-set" || operation == "array-reserve" {
        params.push(MinusValue { name: "%index", typeName: "int" }); args.push("%index")
    }
    if operation == "array-set" || operation == "array-push" {
        params.push(MinusValue { name: "%value", typeName }); args.push("%value")
    }
    if operation == "array-reserve" { args.push(typeName) }
    if operation == "array-push" || operation == "array-reserve" { resultType = "int" }
    if operation == "array-get" || operation == "array-peek" || operation == "array-pop" { resultType = typeName }
    let result: MinusValue | none = none
    if resultType != "none" { result = MinusValue { name: "%result", typeName: resultType } }
    helpers.arrays.push(ArrayHelper { operation, typeName, params, instruction: MinusInstruction { op: operation, args, result } })
}

function collectHelpers(module_: MinusModule, live: bool[], effects: MinusEffects): WasmHelpers {
    hasInitializer := module_.globals.length > 0
    helpers := WasmHelpers {
        functionStart: module_.imports.length + module_.functions.length + 3 + (if hasInitializer then 1 else 0),
        typeStart: module_.imports.length + module_.functions.length + 3 + (if hasInitializer then 1 else 0) + (if module_.recoverPanics then 1 else 0),
        live,
    }
    for index of 0..<module_.functions.length {
        if !live[index] { continue }
        function_ := module_.functions[index]
        values := collectValues(function_)
        blocks := minusBlocks(function_)
        flow := analyzeMinusControlFlow(blocks)
        for blockIndex of 0..<blocks.length {
            if flow.positions[blockIndex] < 0 { continue }
            block_ := blocks[blockIndex]
            for instruction of block_.instructions {
                if instruction.op.startsWith("array-") { addArrayHelper(helpers, instruction.op, arrayElementType(module_, values, instruction)) }
            }
        }
    }
    // Borrowed element reads share one non-retaining pointer helper.
    for index of 0..<module_.functions.length {
        if live[index] && effects.peekable[index] { addArrayHelper(helpers, "array-peek", "any"); break }
    }
    return helpers
}

function arrayHelperIndex(helpers: WasmHelpers, operation: string, typeName: string): int {
    for index of 0..<helpers.arrays.length {
        helper := helpers.arrays[index]
        if helper.operation == operation && helper.typeName == typeName { return helpers.functionStart + index }
    }
    panic("array helper missing")
}

function helperCount(helpers: WasmHelpers): int => helpers.arrays.length
function unsigned(bytes: int[], value: int): none {
    let remaining = value
    while remaining >= 128 { bytes.push(remaining % 128 + 128); remaining = remaining \ 128 }
    bytes.push(remaining)
}

function signed(bytes: int[], value: long): none {
    let remaining = value
    while true {
        let next = remaining \ 128L
        if remaining < 0L && remaining % 128L != 0L { next -= 1L }
        low := remaining - next * 128L
        done := (next == 0L && low < 64L) || (next == -1L && low >= 64L)
        bytes.push(int(low) + if done then 0 else 128)
        if done { return }
        remaining = next
    }
}

function append(bytes: int[], source: int[]): none { for value of source { bytes.push(value) } }
function section(bytes: int[], id: int, payload: int[]): none { bytes.push(id); unsigned(bytes, payload.length); append(bytes, payload) }
function name(bytes: int[], value: string): none {
    unsigned(bytes, value.length)
    for index of 0..<value.length { bytes.push(int(value[index])) }
}

function wasmType(typeName: string): int {
    if typeName == "long" { return 126 }
    if typeName == "float" { return 125 }
    if typeName == "double" { return 124 }
    return 127
}

// Declaration lookups go through the module's hashed name indexes.
function reference(module_: MinusModule, typeName: string): bool {
    if typeName == "any" { return true }
    lookup := minusModuleLookup(module_)
    return lookupMinusName(lookup.classes, typeName) >= 0 || lookupMinusName(lookup.interfaces, typeName) >= 0
}

function tag(module_: MinusModule, typeName: string): int {
    if typeName == "none" { return 0 }
    if typeName == "bool" { return 1 }
    if typeName == "char" { return 2 }
    if typeName == "byte" { return 3 }
    if typeName == "int" { return 4 }
    if typeName == "long" { return 5 }
    if typeName == "float" { return 6 }
    if typeName == "double" { return 7 }
    lookup := minusModuleLookup(module_)
    class_ := lookupMinusName(lookup.classes, typeName)
    if class_ >= 0 { return 32 + class_ }
    // Enums keep nominal any-tags while using scalar i32 storage. Their tag
    // range follows class tags so reference management can identify classes.
    enum_ := lookupMinusName(lookup.enums, typeName)
    if enum_ >= 0 { return 32 + module_.classes.length + enum_ }
    panic("validated type tag missing")
}

function functionIndex(module_: MinusModule, name_: string): int {
    lookup := minusModuleLookup(module_)
    import_ := lookupMinusName(lookup.imports, name_)
    if import_ >= 0 { return import_ }
    function_ := lookupMinusName(lookup.functions, name_)
    if function_ >= 0 { return module_.imports.length + function_ + 3 }
    panic("validated function missing")
}

function runtimeFunctionIndex(module_: MinusModule, index: int): int => module_.imports.length + index

function interfaceType(module_: MinusModule, typeName: string): bool => lookupMinusName(minusModuleLookup(module_).interfaces, typeName) >= 0

function tableFunctionIndex(module_: MinusModule, name_: string): int {
    function_ := lookupMinusName(minusModuleLookup(module_).functions, name_)
    if function_ >= 0 { return function_ + 3 }
    panic("validated method missing from function table")
}

function classByName(module_: MinusModule, name_: string): MinusClass {
    class_ := lookupMinusName(minusModuleLookup(module_).classes, name_)
    if class_ >= 0 { return module_.classes[class_] }
    panic("validated class missing")
}

function interfaceByName(module_: MinusModule, name_: string): MinusInterface {
    interface_ := lookupMinusName(minusModuleLookup(module_).interfaces, name_)
    if interface_ >= 0 { return module_.interfaces[interface_] }
    panic("validated interface missing")
}

function valueId(values: WasmLocals, name_: string): int {
    index := minusValueId(values.table, name_)
    if index < 0 { panic("validated value missing") }
    return index
}
function valueIndex(values: WasmLocals, name_: string): int => values.slots[valueId(values, name_)]
function valueType(values: WasmLocals, name_: string): string => values.table.values[valueId(values, name_)].typeName

function fieldIndex(class_: MinusClass, fieldName: string): int {
    for index of 0..<class_.fields.length { if class_.fields[index].name == fieldName { return index } }
    panic("validated field missing")
}

function byte_(bytes: int[], value: int): none { bytes.push(value) }
function rawI32(bytes: int[], value: int): none { bytes.push(65); signed(bytes, long(value)) }
function op(code: WasmInstruction[], opcode: int): none { code.push(WasmInstruction { opcode }) }
function operand(code: WasmInstruction[], opcode: int, immediate: int, secondary: int = 0): none { code.push(WasmInstruction { opcode, immediate, secondary }) }
function localGet(code: WasmInstruction[], index: int): none { operand(code, 32, index) }
function localSet(code: WasmInstruction[], index: int): none { operand(code, 33, index) }
function globalGet(code: WasmInstruction[], index: int): none { operand(code, 35, index) }
function globalSet(code: WasmInstruction[], index: int): none { operand(code, 36, index) }
function call(code: WasmInstruction[], index: int): none { operand(code, 16, index) }
function i32(code: WasmInstruction[], value: int): none { code.push(WasmInstruction { opcode: 65, integer: long(value) }) }
function i64(code: WasmInstruction[], value: long): none { code.push(WasmInstruction { opcode: 66, integer: value }) }
function branch(code: WasmInstruction[], depth: int): none { operand(code, 12, depth) }
function branchIf(code: WasmInstruction[], depth: int): none { operand(code, 13, depth) }
function block(code: WasmInstruction[]): none { operand(code, 2, 64) }
function loop(code: WasmInstruction[]): none { operand(code, 3, 64) }
function if_(code: WasmInstruction[]): none { operand(code, 4, 64) }
function end(code: WasmInstruction[]): none { op(code, 11) }
function load(code: WasmInstruction[], typeName: string, offset: int): none {
    let opcode = 40
    if typeName == "long" { opcode = 41 }
    if typeName == "float" { opcode = 42 }
    if typeName == "double" { opcode = 43 }
    if typeName == "bool" || typeName == "byte" || typeName == "char" { opcode = 45 }
    operand(code, opcode, if typeName == "long" || typeName == "double" then 3 else if typeName == "bool" || typeName == "byte" || typeName == "char" then 0 else 2, offset)
}
function store(code: WasmInstruction[], typeName: string, offset: int): none {
    let opcode = 54
    if typeName == "long" { opcode = 55 }
    if typeName == "float" { opcode = 56 }
    if typeName == "double" { opcode = 57 }
    if typeName == "bool" || typeName == "byte" || typeName == "char" { opcode = 58 }
    operand(code, opcode, if typeName == "long" || typeName == "double" then 3 else if typeName == "bool" || typeName == "byte" || typeName == "char" then 0 else 2, offset)
}
function load32(code: WasmInstruction[], offset: int): none { load(code, "int", offset) }
function store32(code: WasmInstruction[], offset: int): none { store(code, "int", offset) }
function load16Unsigned(code: WasmInstruction[], offset: int): none { operand(code, 47, 1, offset) }
function store16(code: WasmInstruction[], offset: int): none { operand(code, 59, 1, offset) }

function emitType(bytes: int[], params: string[], result: string): none {
    byte_(bytes, 96)
    unsigned(bytes, params.length)
    for typeName of params { byte_(bytes, wasmType(typeName)) }
    if result == "none" { unsigned(bytes, 0) } else { unsigned(bytes, 1); byte_(bytes, wasmType(result)) }
}

function sameBytes(left: int[], right: int[]): bool {
    if left.length != right.length { return false }
    for index of 0..<left.length { if left[index] != right[index] { return false } }
    return true
}

function internType(helpers: WasmHelpers, params: string[], result: string): none {
    let signature: int[] = []
    emitType(signature, params, result)
    for index of 0..<helpers.signatures.length {
        if sameBytes(signature, helpers.signatures[index]) { helpers.typeIndexes.push(index); return }
    }
    helpers.typeIndexes.push(helpers.signatures.length)
    helpers.signatures.push(signature)
}

function collectFunctionTypes(module_: MinusModule, helpers: WasmHelpers): none {
    for import_ of module_.imports {
        let params: string[] = []
        for parameter of import_.params { params.push(parameter.typeName) }
        internType(helpers, params, import_.result)
    }
    internType(helpers, ["int", "int"], "int") // alloc(size, tag)
    internType(helpers, ["int"], "int")        // retain(ptr)
    internType(helpers, ["int"], "none")       // release(ptr)
    for index of 0..<module_.functions.length {
        if !helpers.live[index] { helpers.typeIndexes.push(-1); continue }
        function_ := module_.functions[index]
        let params: string[] = []
        for param of function_.params { params.push(param.typeName) }
        internType(helpers, params, function_.result)
    }
    if module_.globals.length > 0 { internType(helpers, [], "none") }
    if module_.recoverPanics { internType(helpers, ["int"], "none") }
    for helper of helpers.arrays {
        let params: string[] = []
        for param of helper.params { params.push(param.typeName) }
        internType(helpers, params, if helper.instruction.result == none then "none" else helper.instruction.result!.typeName)
    }
}

function emitAllocator(): WasmInstruction[] {
    // locals: pointer, bin-head address, next, end, spare, spare.
    // FREE_LIST_BASE holds 64 heads for sizes 24 + n * 16.
    let b: WasmInstruction[] = []
    localGet(b, 0); i32(b, MIN_BLOCK_SIZE); op(b, 72); if_(b); op(b, 0); end(b)
    localGet(b, 0); i32(b, MAX_BLOCK_SIZE); op(b, 75); if_(b); op(b, 0); end(b)
    localGet(b, 0); i32(b, MIN_BLOCK_SIZE); op(b, 107); i32(b, 15); op(b, 113)
    if_(b); op(b, 0); end(b) // every size must be 24 + n * 16
    localGet(b, 0); i32(b, MIN_BLOCK_SIZE); op(b, 107)
    i32(b, 4); op(b, 118)
    i32(b, 2); op(b, 116); localSet(b, 3) // ((size - 24) / 16) * 4
    localGet(b, 3); load32(b, FREE_LIST_BASE); localSet(b, 2)
    localGet(b, 2); op(b, 69); op(b, 69); if_(b)
    localGet(b, 2); load32(b, 4); localSet(b, 4)
    localGet(b, 3); localGet(b, 4); store32(b, FREE_LIST_BASE)
    localGet(b, 2); localGet(b, 1); store16(b, 0)
    localGet(b, 2); localGet(b, 0); store16(b, 2)
    localGet(b, 2); i32(b, 0); store32(b, 4)
    localGet(b, 1); i32(b, ARRAY_DATA_TAG); op(b, 71); if_(b)
    localGet(b, 2); i32(b, 1); store32(b, 4)
    end(b)
    localGet(b, 2); op(b, 15)
    end(b)
    globalGet(b, 0); localSet(b, 2)
    localGet(b, 2); localGet(b, 0); op(b, 106); localSet(b, 7)
    localGet(b, 7); i32(b, 65535); op(b, 106); i32(b, 16); op(b, 118) // pages needed
    operand(b, 63, 0); op(b, 75) // pages needed > current pages
    if_(b)
    localGet(b, 7); i32(b, 65535); op(b, 106); i32(b, 16); op(b, 118)
    operand(b, 63, 0); op(b, 107) // delta pages
    operand(b, 64, 0); i32(b, -1); op(b, 70); if_(b); op(b, 0); end(b)
    end(b)
    localGet(b, 7); globalSet(b, 0)
    localGet(b, 2); localGet(b, 1); store16(b, 0)
    localGet(b, 2); localGet(b, 0); store16(b, 2)
    localGet(b, 2); i32(b, 0); store32(b, 4)
    localGet(b, 1); i32(b, ARRAY_DATA_TAG); op(b, 71); if_(b)
    localGet(b, 2); i32(b, 1); store32(b, 4)
    end(b)
    localGet(b, 2)
    return b
}

function emitRetain(): WasmInstruction[] {
    let b: WasmInstruction[] = []
    localGet(b, 0); op(b, 69); if_(b); localGet(b, 0); op(b, 15); end(b)
    localGet(b, 0); load16Unsigned(b, 0); i32(b, ARRAY_DATA_TAG); op(b, 70); if_(b); op(b, 0); end(b)
    localGet(b, 0); localGet(b, 0); load32(b, 4); i32(b, 1); op(b, 106); store32(b, 4)
    localGet(b, 0)
    return b
}

function emitClassRelease(b: WasmInstruction[], module_: MinusModule, class_: MinusClass): none {
    if class_.finalizer != "" {
        // Keep the receiver alive while its normal function frame owns it.
        localGet(b, 0); localGet(b, 0); load32(b, 4); i32(b, 1); op(b, 106); store32(b, 4)
        localGet(b, 0); call(b, functionIndex(module_, class_.finalizer))
        localGet(b, 0); localGet(b, 0); load32(b, 4); i32(b, 1); op(b, 107); store32(b, 4)
    }
    for fieldIndex_ of 0..<class_.fields.length {
        if !reference(module_, class_.fields[fieldIndex_].typeName) { continue }
        localGet(b, 0); load32(b, classFieldOffset(class_, fieldIndex_)); call(b, runtimeFunctionIndex(module_, 2))
    }
}

// Dispatch only classes with cleanup. Sparse leaf tags still compare exactly,
// so scalar-only classes and runtime storage never run another class's cleanup.
function emitReleaseDispatch(b: WasmInstruction[], module_: MinusModule, classes: int[], first: int, end_: int): none {
    if end_ - first <= 3 {
        for index of first..<end_ {
            classIndex := classes[index]
            localGet(b, 1); i32(b, 32 + classIndex); op(b, 70); if_(b)
            emitClassRelease(b, module_, module_.classes[classIndex])
            end(b)
        }
        return
    }
    middle := first + (end_ - first) \ 2
    localGet(b, 1); i32(b, 32 + classes[middle]); op(b, 73); if_(b)
    emitReleaseDispatch(b, module_, classes, first, middle)
    op(b, 5)
    emitReleaseDispatch(b, module_, classes, middle, end_)
    end(b)
}

function sameReleaseCode(left: int[], right: int[]): bool {
    if left.length != right.length { return false }
    for index of 0..<left.length { if left[index] != right[index] { return false } }
    return true
}

// Dense tags select shared cleanup blocks inside this frame. Group exact
// emitted sequences, including logical finalizer calls and field order.
function emitSharedReleaseDispatch(b: WasmInstruction[], module_: MinusModule, classes: int[]): none {
    if classes.length == 0 { return }
    first := classes[0]
    span := classes[classes.length - 1] - first + 1
    if classes.length <= 3 || span > classes.length * 4 {
        emitReleaseDispatch(b, module_, classes, 0, classes.length)
        return
    }
    let bodies: WasmInstruction[][] = []
    let keys: int[][] = []
    let targets: int[] = []
    for _ of 0..<span { targets.push(-1) }
    for classIndex of classes {
        let code: WasmInstruction[] = []
        emitClassRelease(code, module_, module_.classes[classIndex])
        key := encodeWasmInstructions(code)
        let group = 0
        while group < keys.length && !sameReleaseCode(keys[group], key) { group += 1 }
        if group == keys.length { keys.push(key); bodies.push(code) }
        targets[classIndex - first] = group
    }
    for index of 0..<targets.length { if targets[index] < 0 { targets[index] = bodies.length } }
    block(b) // common free-list epilogue
    for _ of bodies { block(b) }
    localGet(b, 1); i32(b, 32 + first); op(b, 107)
    b.push(WasmInstruction { opcode: 14, immediate: bodies.length, targets })
    for index of 0..<bodies.length {
        end(b)
        for instruction of bodies[index] { b.push(instruction) }
        operand(b, 12, bodies.length - index - 1)
    }
    end(b)
}

// Release keeps one frame per level of a dying object chain: children are
// released by calling release itself, so deep chains need no more stack than
// their length. The common path is the early return after the decrement.
function emitRelease(module_: MinusModule): WasmInstruction[] {
    // local 1: runtime tag; 2: decremented count; 3: block size; 4: bin head.
    let b: WasmInstruction[] = []
    localGet(b, 0); op(b, 69); if_(b); op(b, 15); end(b)
    localGet(b, 0); load16Unsigned(b, 0); localSet(b, 1)
    localGet(b, 1); i32(b, ARRAY_DATA_TAG); op(b, 70); if_(b); op(b, 0); end(b)
    localGet(b, 0); localGet(b, 0); load32(b, 4); i32(b, 1); op(b, 107); operand(b, 34, 2); store32(b, 4)
    localGet(b, 2); if_(b); op(b, 15); end(b)
    // Boxes hold only scalars; class values in `any` are the objects themselves.
    let cleanupClasses: int[] = []
    for index of 0..<module_.classes.length {
        class_ := module_.classes[index]
        let hasReferences = false
        for field of class_.fields { if reference(module_, field.typeName) { hasReferences = true } }
        if hasReferences || class_.finalizer != "" { cleanupClasses.push(index) }
    }
    emitSharedReleaseDispatch(b, module_, cleanupClasses)
    localGet(b, 0); load16Unsigned(b, 2); localSet(b, 3)
    localGet(b, 3); i32(b, MIN_BLOCK_SIZE); op(b, 107)
    i32(b, 4); op(b, 118)
    i32(b, 2); op(b, 116); localSet(b, 4)
    localGet(b, 0); i32(b, 0); store16(b, 0)
    localGet(b, 0); localGet(b, 4); load32(b, FREE_LIST_BASE); store32(b, 4)
    localGet(b, 4); localGet(b, 0); store32(b, FREE_LIST_BASE)
    return b
}

function arrayWidth(typeName: string): int {
    if typeName == "bool" || typeName == "byte" || typeName == "char" { return 1 }
    if typeName == "long" || typeName == "double" { return 8 }
    return 4
}

function arrayLoadCode(typeName: string): int {
    if typeName == "bool" || typeName == "byte" || typeName == "char" { return 45 }
    if typeName == "long" { return 41 }
    if typeName == "float" { return 42 }
    if typeName == "double" { return 43 }
    return 40
}

function arrayStoreCode(typeName: string): int {
    if typeName == "bool" || typeName == "byte" || typeName == "char" { return 58 }
    if typeName == "long" { return 55 }
    if typeName == "float" { return 56 }
    if typeName == "double" { return 57 }
    return 54
}

function arrayHandle(code: WasmInstruction[], values: WasmLocals, handle: string, handleLocal: int): none {
    if handleLocal >= 0 { localGet(code, handleLocal) } else { getValue(code, values, handle) }
}

function arrayAddress(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, handle: string, index: string, typeName: string, scratch: int, indexLocal: int = -1, handleLocal: int = -1): none {
    width := arrayWidth(typeName)
    let indexIsLocal = indexLocal >= 0
    // Small arrays and strings retain the original contiguous representation.
    arrayHandle(code, values, handle, handleLocal); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 70); operand(code, 4, 127) // if (result i32)
    arrayHandle(code, values, handle, handleLocal); i32(code, 8); op(code, 106)
    if indexIsLocal { localGet(code, indexLocal) } else { getValue(code, values, index) }
    if width == 4 { i32(code, 2); op(code, 116) }
    if width == 8 { i32(code, 3); op(code, 116) }
    op(code, 106)
    op(code, 5)
    // Large arrays use a 3-level, 256-way radix directory. Three levels cover
    // every chunk addressable by a signed 32-bit array length. The directory
    // depth stays fixed, so random access remains O(1) as arrays grow.
    arrayHandle(code, values, handle, handleLocal); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 71); if_(code); op(code, 0); end(code)
    if indexIsLocal { localGet(code, indexLocal) } else { getValue(code, values, index) }
    i32(code, ARRAY_CHUNK_BYTES \ width); op(code, 109); localSet(code, scratch)
    arrayHandle(code, values, handle, handleLocal); load32(code, 12); localSet(code, scratch + 1)
    localGet(code, scratch + 1); i32(code, 8); op(code, 106)
    localGet(code, scratch); i32(code, 16); op(code, 117); i32(code, 2); op(code, 116); op(code, 106); load32(code, 0); localSet(code, scratch + 1)
    localGet(code, scratch + 1); i32(code, 8); op(code, 106)
    localGet(code, scratch); i32(code, 8); op(code, 117); i32(code, 255); op(code, 113); i32(code, 2); op(code, 116); op(code, 106); load32(code, 0); localSet(code, scratch + 1)
    localGet(code, scratch + 1); i32(code, 8); op(code, 106)
    localGet(code, scratch); i32(code, 255); op(code, 113); i32(code, 2); op(code, 116); op(code, 106); load32(code, 0)
    i32(code, 8); op(code, 106)
    if indexIsLocal { localGet(code, indexLocal) } else { getValue(code, values, index) }
    i32(code, ARRAY_CHUNK_BYTES \ width); op(code, 111)
    if width == 4 { i32(code, 2); op(code, 116) }
    if width == 8 { i32(code, 3); op(code, 116) }
    op(code, 106)
    end(code)
}

function checkArrayBounds(code: WasmInstruction[], values: WasmLocals, handle: string, index: string): none {
    checkArrayHandle(code, values, handle)
    // One unsigned comparison rejects both negative and too-large indexes.
    getValue(code, values, index); getValue(code, values, handle); load32(code, 4); op(code, 79); if_(code); op(code, 0); end(code)
}

function emitOwnedArrayBlock(code: WasmInstruction[], module_: MinusModule, descriptorLocal: int, resultLocal: int, zeroIndexLocal: int, blockTag: int): none {
    i32(code, 1032); i32(code, blockTag); call(code, runtimeFunctionIndex(module_, 0)); localSet(code, resultLocal)
    // Every directory slot and every reference-array slot starts empty. This
    // also makes blocks safe when they are reused from the allocator's free list.
    localGet(code, resultLocal); i32(code, 8); op(code, 106)
    i32(code, 0); i32(code, ARRAY_CHUNK_BYTES); operand(code, 252, 11)
    localGet(code, resultLocal)
    localGet(code, descriptorLocal); load32(code, 16); store32(code, 4)
    localGet(code, descriptorLocal); localGet(code, resultLocal); store32(code, 16)
}

function emitFreeArrayBlock(code: WasmInstruction[], pointerLocal: int, nextLocal: int, binAddressLocal: int, binOffset: int): none {
    localGet(code, pointerLocal); i32(code, 4); op(code, 106); load32(code, 0); localSet(code, nextLocal)
    localGet(code, pointerLocal); i32(code, 0); store16(code, 0)
    i32(code, binOffset); localSet(code, binAddressLocal)
    localGet(code, pointerLocal); localGet(code, binAddressLocal); load32(code, 0); store32(code, 4)
    localGet(code, binAddressLocal); localGet(code, pointerLocal); store32(code, 0)
}

function emitArrayChunk(code: WasmInstruction[], module_: MinusModule, scratchIndex: int): none {
    // Root slot: the high eight bits of the 24-bit chunk ordinal.
    localGet(code, scratchIndex); load32(code, 12); localSet(code, scratchIndex + 4)
    localGet(code, scratchIndex + 4); i32(code, 8); op(code, 106)
    localGet(code, scratchIndex + 3); i32(code, 16); op(code, 117); i32(code, 2); op(code, 116); op(code, 106); localSet(code, scratchIndex + 4)
    localGet(code, scratchIndex + 4); load32(code, 0); localSet(code, scratchIndex + 4)
    localGet(code, scratchIndex + 4); op(code, 69); if_(code)
    emitOwnedArrayBlock(code, module_, scratchIndex, scratchIndex + 5, scratchIndex + 7, ARRAY_NODE_TAG)
    localGet(code, scratchIndex + 5); localSet(code, scratchIndex + 4)
    localGet(code, scratchIndex); load32(code, 12); i32(code, 8); op(code, 106)
    localGet(code, scratchIndex + 3); i32(code, 16); op(code, 117); i32(code, 2); op(code, 116); op(code, 106)
    localGet(code, scratchIndex + 4); store32(code, 0)
    end(code)
    // Middle slot: the next eight bits.
    localGet(code, scratchIndex + 4); i32(code, 8); op(code, 106)
    localGet(code, scratchIndex + 3); i32(code, 8); op(code, 117); i32(code, 255); op(code, 113); i32(code, 2); op(code, 116); op(code, 106); localSet(code, scratchIndex + 5)
    localGet(code, scratchIndex + 5); load32(code, 0); localSet(code, scratchIndex + 5)
    localGet(code, scratchIndex + 5); op(code, 69); if_(code)
    emitOwnedArrayBlock(code, module_, scratchIndex, scratchIndex + 6, scratchIndex + 7, ARRAY_NODE_TAG)
    localGet(code, scratchIndex + 6); localSet(code, scratchIndex + 5)
    localGet(code, scratchIndex + 4); i32(code, 8); op(code, 106)
    localGet(code, scratchIndex + 3); i32(code, 8); op(code, 117); i32(code, 255); op(code, 113); i32(code, 2); op(code, 116); op(code, 106)
    localGet(code, scratchIndex + 5); store32(code, 0)
    end(code)
    // Leaf slot: low eight bits point to the actual element chunk.
    localGet(code, scratchIndex + 5); i32(code, 8); op(code, 106)
    localGet(code, scratchIndex + 3); i32(code, 255); op(code, 113); i32(code, 2); op(code, 116); op(code, 106); localSet(code, scratchIndex + 4)
    emitOwnedArrayBlock(code, module_, scratchIndex, scratchIndex + 6, scratchIndex + 7, ARRAY_CHUNK_TAG)
    localGet(code, scratchIndex + 4); localGet(code, scratchIndex + 6); store32(code, 0)
}

function emitArrayAllocation(code: WasmInstruction[], module_: MinusModule, scratchIndex: int, lengthLocal: int, typeName: string): none {
    width := arrayWidth(typeName)
    localGet(code, lengthLocal); i32(code, 0); op(code, 72); if_(code); op(code, 0); end(code)
    localGet(code, lengthLocal); i32(code, 1024 \ width); op(code, 76); if_(code)
    // The common small-array representation remains compact and also
    // covers the host string ABI. Larger arrays use owned radix chunks.
    localGet(code, lengthLocal); i32(code, width); op(code, 108); localSet(code, scratchIndex + 1)
    localGet(code, scratchIndex + 1); i32(code, 16); op(code, 75); if_(code)
    localGet(code, scratchIndex + 1); i32(code, 16); op(code, 107); i32(code, 15); op(code, 106); i32(code, 16); op(code, 110); i32(code, 16); op(code, 108); i32(code, 24); op(code, 106); localSet(code, scratchIndex + 1)
    op(code, 5); i32(code, 24); localSet(code, scratchIndex + 1)
    end(code)
    localGet(code, scratchIndex + 1); i32(code, ARRAY_DATA_TAG); call(code, runtimeFunctionIndex(module_, 0)); localSet(code, scratchIndex)
    localGet(code, scratchIndex); localGet(code, lengthLocal); store32(code, 4)
    if reference(module_, typeName) {
        // Reused small blocks may still contain pointers from old owners.
        localGet(code, scratchIndex); i32(code, 8); op(code, 106)
        i32(code, 0); localGet(code, lengthLocal); i32(code, 2); op(code, 116); operand(code, 252, 11)
    }
    op(code, 5)
    // descriptor: length@4, allocated chunk count@8, radix root@12,
    // ownership-chain head@16. Chunk capacity is element-width dependent.
    i32(code, 24); i32(code, ARRAY_DESCRIPTOR_TAG); call(code, runtimeFunctionIndex(module_, 0)); localSet(code, scratchIndex)
    localGet(code, scratchIndex); i32(code, 0); store32(code, 16)
    localGet(code, lengthLocal); localSet(code, scratchIndex + 1)
    localGet(code, scratchIndex); localGet(code, scratchIndex + 1); store32(code, 4)
    localGet(code, scratchIndex + 1); i32(code, ARRAY_CHUNK_BYTES \ width); op(code, 109); localSet(code, scratchIndex + 2)
    localGet(code, scratchIndex + 1); i32(code, ARRAY_CHUNK_BYTES \ width); op(code, 111); if_(code)
    localGet(code, scratchIndex + 2); i32(code, 1); op(code, 106); localSet(code, scratchIndex + 2)
    end(code)
    localGet(code, scratchIndex); localGet(code, scratchIndex + 2); store32(code, 8)
    emitOwnedArrayBlock(code, module_, scratchIndex, scratchIndex + 5, scratchIndex + 7, ARRAY_NODE_TAG)
    localGet(code, scratchIndex); localGet(code, scratchIndex + 5); store32(code, 12)
    i32(code, 0); localSet(code, scratchIndex + 3)
    block(code); loop(code)
    localGet(code, scratchIndex + 3); localGet(code, scratchIndex + 2); op(code, 78); operand(code, 13, 1)
    emitArrayChunk(code, module_, scratchIndex)
    localGet(code, scratchIndex + 3); i32(code, 1); op(code, 106); localSet(code, scratchIndex + 3)
    operand(code, 12, 0)
    end(code); end(code)
    end(code)
}

function checkArrayHandle(code: WasmInstruction[], values: WasmLocals, handle: string): none {
    // The descriptor and compact tags are adjacent: one load and one unsigned
    // range test accept exactly those two.
    getValue(code, values, handle); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 107)
    i32(code, ARRAY_DATA_TAG - ARRAY_DESCRIPTOR_TAG); op(code, 75); if_(code); op(code, 0); end(code)
}

function limitArraySpan(code: WasmInstruction[], values: WasmLocals, handle: string, indexLocal: int, spanLocal: int, spareLocal: int, width: int, backwards: bool): none {
    getValue(code, values, handle); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 70); if_(code)
    localGet(code, indexLocal); i32(code, ARRAY_CHUNK_BYTES \ width - 1); op(code, 113); localSet(code, spareLocal)
    if backwards {
        localGet(code, spareLocal); op(code, 69); if_(code); i32(code, ARRAY_CHUNK_BYTES \ width); localSet(code, spareLocal); end(code)
    } else {
        i32(code, ARRAY_CHUNK_BYTES \ width); localGet(code, spareLocal); op(code, 107); localSet(code, spareLocal)
    }
    localGet(code, spareLocal); localGet(code, spanLocal); op(code, 73); if_(code)
    localGet(code, spareLocal); localSet(code, spanLocal); end(code)
    end(code)
}

function emitArrayCopyDirection(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, scratch: int, instruction: MinusInstruction, backwards: bool): none {
    args := instruction.args
    width := arrayWidth(args[5])
    getValue(code, values, args[1]); localSet(code, scratch)
    getValue(code, values, args[3]); localSet(code, scratch + 1)
    getValue(code, values, args[4]); localSet(code, scratch + 2)
    if backwards {
        localGet(code, scratch); localGet(code, scratch + 2); op(code, 106); localSet(code, scratch)
        localGet(code, scratch + 1); localGet(code, scratch + 2); op(code, 106); localSet(code, scratch + 1)
    }
    block(code); loop(code)
    localGet(code, scratch + 2); op(code, 69); branchIf(code, 1)
    localGet(code, scratch + 2); localSet(code, scratch + 3)
    limitArraySpan(code, values, args[0], scratch, scratch + 3, scratch + 6, width, backwards)
    limitArraySpan(code, values, args[2], scratch + 1, scratch + 3, scratch + 6, width, backwards)
    if backwards {
        localGet(code, scratch); localGet(code, scratch + 3); op(code, 107); localSet(code, scratch)
        localGet(code, scratch + 1); localGet(code, scratch + 3); op(code, 107); localSet(code, scratch + 1)
    }
    arrayAddress(code, module_, values, args[0], "", args[5], scratch + 6, scratch); localSet(code, scratch + 4)
    arrayAddress(code, module_, values, args[2], "", args[5], scratch + 6, scratch + 1); localSet(code, scratch + 5)
    localGet(code, scratch + 4); localGet(code, scratch + 5)
    localGet(code, scratch + 3); i32(code, width); op(code, 108); operand(code, 252, 10)
    if !backwards {
        localGet(code, scratch); localGet(code, scratch + 3); op(code, 106); localSet(code, scratch)
        localGet(code, scratch + 1); localGet(code, scratch + 3); op(code, 106); localSet(code, scratch + 1)
    }
    localGet(code, scratch + 2); localGet(code, scratch + 3); op(code, 107); localSet(code, scratch + 2)
    branch(code, 0); end(code); end(code)
}

function emitArrayCopy(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, scratch: int, instruction: MinusInstruction): none {
    args := instruction.args
    // Validate both whole ranges before writing anything. Subtraction after
    // checking the start prevents overflow in index + count, including zero.
    getValue(code, values, args[4]); i32(code, 0); op(code, 72); if_(code); op(code, 0); end(code)
    for offset of [0, 2] {
        checkArrayHandle(code, values, args[offset])
        getValue(code, values, args[offset + 1]); getValue(code, values, args[offset]); load32(code, 4); op(code, 75); if_(code); op(code, 0); end(code)
        getValue(code, values, args[4]); getValue(code, values, args[offset]); load32(code, 4)
        getValue(code, values, args[offset + 1]); op(code, 107); op(code, 75); if_(code); op(code, 0); end(code)
    }
    // Two compact arrays are contiguous: one memory.copy, which also handles
    // overlap within the same array.
    width := arrayWidth(args[5])
    getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 70)
    getValue(code, values, args[2]); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 70); op(code, 113); if_(code)
    for offset of [0, 2] {
        getValue(code, values, args[offset]); i32(code, 8); op(code, 106)
        getValue(code, values, args[offset + 1])
        if width > 1 { i32(code, width); op(code, 108) }
        op(code, 106)
    }
    getValue(code, values, args[4])
    if width > 1 { i32(code, width); op(code, 108) }
    operand(code, 252, 10)
    op(code, 5)
    // memory.copy handles overlap inside a span. Across chunks, copy from the
    // end for a same-handle right shift so no later source span is overwritten.
    getValue(code, values, args[0]); getValue(code, values, args[2]); op(code, 70)
    getValue(code, values, args[1]); getValue(code, values, args[3]); op(code, 75); op(code, 113); if_(code)
    emitArrayCopyDirection(code, module_, values, scratch, instruction, true)
    op(code, 5)
    emitArrayCopyDirection(code, module_, values, scratch, instruction, false)
    end(code)
    end(code)
}

function compareArrayBytes(code: WasmInstruction[], leftLocal: int, rightLocal: int, offsetLocal: int, equality: bool = false): none {
    // Equality needs no ordering: any differing byte means unequal.
    if equality { i32(code, 0); op(code, 15); return }
    localGet(code, leftLocal); localGet(code, offsetLocal); op(code, 106); load(code, "byte", 0)
    localGet(code, rightLocal); localGet(code, offsetLocal); op(code, 106); load(code, "byte", 0)
    op(code, 73); operand(code, 4, 127); i32(code, -1); op(code, 5); i32(code, 1); end(code); op(code, 15)
}

function compareArrayWord(code: WasmInstruction[], leftLocal: int, rightLocal: int, offsetLocal: int, opcode: int): none {
    // Alignment zero allows the span to begin at any byte address.
    localGet(code, leftLocal); localGet(code, offsetLocal); op(code, 106); operand(code, 41, 0, 0)
    localGet(code, rightLocal); localGet(code, offsetLocal); op(code, 106); operand(code, 41, 0, 0)
    op(code, opcode)
}

// Most equality tests fail on length, and most strings are compact: settle
// identity and length first, then scan compact storage directly.
function emitCompactEquality(code: WasmInstruction[], values: WasmLocals, scratch: int, args: string[]): none {
    getValue(code, values, args[0]); getValue(code, values, args[1]); op(code, 70); if_(code); i32(code, 1); op(code, 15); end(code)
    getValue(code, values, args[0]); load32(code, 4); localSet(code, scratch + 9)
    localGet(code, scratch + 9); getValue(code, values, args[1]); load32(code, 4); op(code, 71); if_(code); i32(code, 0); op(code, 15); end(code)
    getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 70)
    getValue(code, values, args[1]); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 70); op(code, 113); if_(code)
    getValue(code, values, args[0]); i32(code, 8); op(code, 106); localSet(code, scratch + 3)
    getValue(code, values, args[1]); i32(code, 8); op(code, 106); localSet(code, scratch + 4)
    i32(code, 0); localSet(code, scratch + 5)
    block(code); loop(code)
    localGet(code, scratch + 5); i32(code, 8); op(code, 106); localGet(code, scratch + 9); op(code, 75); branchIf(code, 1)
    compareArrayWord(code, scratch + 3, scratch + 4, scratch + 5, 82); if_(code); i32(code, 0); op(code, 15); end(code)
    localGet(code, scratch + 5); i32(code, 8); op(code, 106); localSet(code, scratch + 5)
    branch(code, 0); end(code); end(code)
    block(code); loop(code)
    localGet(code, scratch + 5); localGet(code, scratch + 9); op(code, 79); branchIf(code, 1)
    localGet(code, scratch + 3); localGet(code, scratch + 5); op(code, 106); load(code, "byte", 0)
    localGet(code, scratch + 4); localGet(code, scratch + 5); op(code, 106); load(code, "byte", 0)
    op(code, 71); if_(code); i32(code, 0); op(code, 15); end(code)
    localGet(code, scratch + 5); i32(code, 1); op(code, 106); localSet(code, scratch + 5)
    branch(code, 0); end(code); end(code)
    i32(code, 1); op(code, 15)
    end(code)
}

function emitArrayCompare(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, scratch: int, instruction: MinusInstruction, equality: bool = false): none {
    args := instruction.args
    if equality { emitCompactEquality(code, values, scratch, args) }
    for index of 0..<2 {
        checkArrayHandle(code, values, args[index])
        getValue(code, values, args[index]); load32(code, 4); localSet(code, scratch + 9 + index)
    }
    getValue(code, values, args[0]); getValue(code, values, args[1]); op(code, 70); if_(code); i32(code, if equality then 1 else 0); op(code, 15); end(code)
    if equality {
        // Unequal lengths decide equality before any storage is scanned.
        localGet(code, scratch + 9); localGet(code, scratch + 10); op(code, 71); if_(code); i32(code, 0); op(code, 15); end(code)
    }
    localGet(code, scratch + 9); localSet(code, scratch + 1)
    localGet(code, scratch + 10); localGet(code, scratch + 1); op(code, 73); if_(code)
    localGet(code, scratch + 10); localSet(code, scratch + 1); end(code)
    i32(code, 0); localSet(code, scratch)
    block(code); loop(code)
    localGet(code, scratch); localGet(code, scratch + 1); op(code, 79); branchIf(code, 1)
    i32(code, ARRAY_CHUNK_BYTES); localGet(code, scratch); i32(code, ARRAY_CHUNK_BYTES - 1); op(code, 113); op(code, 107); localSet(code, scratch + 2)
    localGet(code, scratch + 1); localGet(code, scratch); op(code, 107); localSet(code, scratch + 8)
    localGet(code, scratch + 8); localGet(code, scratch + 2); op(code, 73); if_(code)
    localGet(code, scratch + 8); localSet(code, scratch + 2); end(code)
    arrayAddress(code, module_, values, args[0], "", "byte", scratch + 6, scratch); localSet(code, scratch + 3)
    arrayAddress(code, module_, values, args[1], "", "byte", scratch + 6, scratch); localSet(code, scratch + 4)
    i32(code, 0); localSet(code, scratch + 5)
    block(code); loop(code)
    localGet(code, scratch + 5); i32(code, 8); op(code, 106); localGet(code, scratch + 2); op(code, 75); branchIf(code, 1)
    compareArrayWord(code, scratch + 3, scratch + 4, scratch + 5, 81); op(code, 69); if_(code)
    if equality { i32(code, 0); op(code, 15) } else {
    // Wasm loads little endian. XOR's trailing-zero count locates the first
    // differing byte; comparing numeric i64 values would order bytes wrongly.
    compareArrayWord(code, scratch + 3, scratch + 4, scratch + 5, 133)
    op(code, 122); op(code, 167); i32(code, 3); op(code, 118)
    localGet(code, scratch + 5); op(code, 106); localSet(code, scratch + 11)
    compareArrayBytes(code, scratch + 3, scratch + 4, scratch + 11) }
    end(code)
    localGet(code, scratch + 5); i32(code, 8); op(code, 106); localSet(code, scratch + 5)
    branch(code, 0); end(code); end(code)
    block(code); loop(code)
    localGet(code, scratch + 5); localGet(code, scratch + 2); op(code, 79); branchIf(code, 1)
    localGet(code, scratch + 3); localGet(code, scratch + 5); op(code, 106); load(code, "byte", 0)
    localGet(code, scratch + 4); localGet(code, scratch + 5); op(code, 106); load(code, "byte", 0)
    op(code, 71); if_(code); compareArrayBytes(code, scratch + 3, scratch + 4, scratch + 5, equality); end(code)
    localGet(code, scratch + 5); i32(code, 1); op(code, 106); localSet(code, scratch + 5)
    branch(code, 0); end(code); end(code)
    localGet(code, scratch); localGet(code, scratch + 2); op(code, 106); localSet(code, scratch)
    branch(code, 0); end(code); end(code)
    if equality { i32(code, 1); setResult(code, module_, values, instruction); return }
    localGet(code, scratch + 9); localGet(code, scratch + 10); op(code, 70)
    operand(code, 4, 127); i32(code, 0); op(code, 5)
    localGet(code, scratch + 9); localGet(code, scratch + 10); op(code, 73)
    operand(code, 4, 127); i32(code, -1); op(code, 5); i32(code, 1); end(code); end(code)
    setResult(code, module_, values, instruction)
}

function emitArrayInstruction(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, scratchIndex: int, instruction: MinusInstruction): none {
    args := instruction.args
    if instruction.op == "array-copy" { emitArrayCopy(code, module_, values, scratchIndex, instruction); return }
    if instruction.op == "array-compare" { emitArrayCompare(code, module_, values, scratchIndex, instruction); return }
    if instruction.op == "array-equal" { emitArrayCompare(code, module_, values, scratchIndex, instruction, true); return }
    if instruction.op == "array-alloc" {
        emitArrayAllocation(code, module_, scratchIndex, valueIndex(values, args[0]), args[1])
        localGet(code, scratchIndex); setResult(code, module_, values, instruction)
        return
    }
    if instruction.op == "array-push" || instruction.op == "array-reserve" {
        reserving := instruction.op == "array-reserve"
        typeName := if reserving then args[2] else valueType(values, args[1])
        width := arrayWidth(typeName)
        getValue(code, values, args[0]); localSet(code, scratchIndex + 9)
        localGet(code, scratchIndex + 9); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 71)
        localGet(code, scratchIndex + 9); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 71); op(code, 113); if_(code); op(code, 0); end(code)
        localGet(code, scratchIndex + 9); load32(code, 4); localSet(code, scratchIndex + 10)
        if reserving {
            // Native reserve treats nonpositive capacities as a no-op.
            getValue(code, values, args[1]); localSet(code, scratchIndex + 8)
            localGet(code, scratchIndex + 8); localGet(code, scratchIndex + 10); op(code, 72); if_(code)
            localGet(code, scratchIndex + 10); localSet(code, scratchIndex + 8); end(code)
        } else {
            localGet(code, scratchIndex + 10); i32(code, 2147483647); op(code, 70); if_(code); op(code, 0); end(code)
            localGet(code, scratchIndex + 10); i32(code, 1); op(code, 106); localSet(code, scratchIndex + 8)
        }
        localGet(code, scratchIndex + 9); localSet(code, scratchIndex)
        localGet(code, scratchIndex); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 70); if_(code)
        // Small blocks grow geometrically, then migrate once to radix chunks.
        localGet(code, scratchIndex + 8)
        localGet(code, scratchIndex); load16Unsigned(code, 2); i32(code, 8); op(code, 107); i32(code, width); op(code, 110); op(code, 75); if_(code)
        localGet(code, scratchIndex + 8); i32(code, 1024 \ width); op(code, 76); if_(code)
        localGet(code, scratchIndex + 9); load16Unsigned(code, 2); i32(code, 8); op(code, 107); i32(code, 2); op(code, 108); localSet(code, scratchIndex + 1)
        localGet(code, scratchIndex + 1); i32(code, 1024); op(code, 75); if_(code); i32(code, 1024); localSet(code, scratchIndex + 1); end(code)
        localGet(code, scratchIndex + 1); i32(code, width); op(code, 110); localSet(code, scratchIndex + 11)
        localGet(code, scratchIndex + 11); localGet(code, scratchIndex + 8); op(code, 72); if_(code)
        localGet(code, scratchIndex + 8); localSet(code, scratchIndex + 11); end(code)
        emitArrayAllocation(code, module_, scratchIndex, scratchIndex + 11, typeName)
        op(code, 5)
        emitArrayAllocation(code, module_, scratchIndex, scratchIndex + 8, typeName)
        end(code)
        localGet(code, scratchIndex); localSet(code, scratchIndex + 11)
        // The old compact payload fits in the first destination chunk.
        // Transfer its bytes without changing reference-element ownership.
        i32(code, 0); localSet(code, scratchIndex + 3)
        arrayAddress(code, module_, values, "", "", typeName, scratchIndex + 4, scratchIndex + 3, scratchIndex + 11); localSet(code, scratchIndex + 2)
        localGet(code, scratchIndex + 2)
        localGet(code, scratchIndex + 9); i32(code, 8); op(code, 106)
        localGet(code, scratchIndex + 10); i32(code, width); op(code, 108); operand(code, 252, 10)
        // Only the old raw block is freed: references moved into the new block.
        localGet(code, scratchIndex + 9); load16Unsigned(code, 2); i32(code, MIN_BLOCK_SIZE); op(code, 107); i32(code, 4); op(code, 118); i32(code, 2); op(code, 116); localSet(code, scratchIndex + 1)
        localGet(code, scratchIndex + 9); i32(code, 0); store16(code, 0)
        localGet(code, scratchIndex + 9); localGet(code, scratchIndex + 1); load32(code, FREE_LIST_BASE); store32(code, 4)
        localGet(code, scratchIndex + 1); localGet(code, scratchIndex + 9); store32(code, FREE_LIST_BASE)
        localGet(code, scratchIndex + 11); localSet(code, scratchIndex)
        end(code)
        op(code, 5)
        // Length may be smaller than allocated capacity after reserve or pop.
        // Compute ceil(capacity/chunk) without overflowing signed element counts.
        localGet(code, scratchIndex + 8); i32(code, ARRAY_CHUNK_BYTES \ width); op(code, 110); localSet(code, scratchIndex + 2)
        localGet(code, scratchIndex + 8); i32(code, ARRAY_CHUNK_BYTES \ width); op(code, 112); if_(code)
        localGet(code, scratchIndex + 2); i32(code, 1); op(code, 106); localSet(code, scratchIndex + 2); end(code)
        block(code); loop(code)
        localGet(code, scratchIndex); load32(code, 8); localSet(code, scratchIndex + 3)
        localGet(code, scratchIndex + 3); localGet(code, scratchIndex + 2); op(code, 79); branchIf(code, 1)
        emitArrayChunk(code, module_, scratchIndex)
        localGet(code, scratchIndex); localGet(code, scratchIndex + 3); i32(code, 1); op(code, 106); store32(code, 8)
        branch(code, 0); end(code); end(code)
        end(code)
        localGet(code, scratchIndex); localGet(code, if reserving then scratchIndex + 10 else scratchIndex + 8); store32(code, 4)
        localGet(code, scratchIndex); localSet(code, scratchIndex + 11)
        if !reserving {
            if reference(module_, typeName) { getValue(code, values, args[1]); call(code, runtimeFunctionIndex(module_, 1)); op(code, 26) }
            arrayAddress(code, module_, values, "", "", typeName, scratchIndex + 4, scratchIndex + 10, scratchIndex + 11)
            getValue(code, values, args[1]); store(code, typeName, 0)
        }
        localGet(code, scratchIndex + 11); setResult(code, module_, values, instruction)
        return
    }
    if instruction.op == "array-pop" {
        typeName := instruction.result!.typeName
        // The raw IR operation traps on empty storage. Source lowering handles
        // that case first and returns Failure instead.
        getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 71)
        getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 71); op(code, 113); if_(code); op(code, 0); end(code)
        getValue(code, values, args[0]); load32(code, 4); localSet(code, scratchIndex + 10)
        localGet(code, scratchIndex + 10); i32(code, 0); op(code, 76); if_(code); op(code, 0); end(code)
        localGet(code, scratchIndex + 10); i32(code, 1); op(code, 107); localSet(code, scratchIndex + 10)
        arrayAddress(code, module_, values, args[0], "", typeName, scratchIndex, scratchIndex + 10); localSet(code, scratchIndex + 9)
        localGet(code, scratchIndex + 9); load(code, typeName, 0)
        // Transfer the array's reference into the owned SSA result. No retain
        // or release is needed; clearing the slot prevents stale ownership.
        setResult(code, module_, values, instruction)
        if reference(module_, typeName) { localGet(code, scratchIndex + 9); i32(code, 0); store32(code, 0) }
        getValue(code, values, args[0]); localGet(code, scratchIndex + 10); store32(code, 4)
        return
    }
    if instruction.op == "array-free" {
        getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DATA_TAG); op(code, 71)
        getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 71); op(code, 113); if_(code); op(code, 0); end(code)
        getValue(code, values, args[0]); load16Unsigned(code, 0); i32(code, ARRAY_DESCRIPTOR_TAG); op(code, 70); if_(code)
        if args.length == 2 && reference(module_, args[1]) {
            i32(code, 0); localSet(code, scratchIndex + 3)
            block(code); loop(code)
            localGet(code, scratchIndex + 3); getValue(code, values, args[0]); load32(code, 4); op(code, 78); operand(code, 13, 1)
            arrayAddress(code, module_, values, args[0], "", args[1], scratchIndex + 4, scratchIndex + 3)
            operand(code, arrayLoadCode(args[1]), if args[1] == "long" || args[1] == "double" then 3 else if args[1] == "byte" || args[1] == "bool" || args[1] == "char" then 0 else 2, 0); call(code, runtimeFunctionIndex(module_, 2))
            localGet(code, scratchIndex + 3); i32(code, 1); op(code, 106); localSet(code, scratchIndex + 3)
            operand(code, 12, 0)
            end(code); end(code)
        }
        getValue(code, values, args[0]); load32(code, 16); localSet(code, scratchIndex + 1)
        block(code); loop(code)
        localGet(code, scratchIndex + 1); op(code, 69); operand(code, 13, 1)
        emitFreeArrayBlock(code, scratchIndex + 1, scratchIndex + 2, scratchIndex + 6, FREE_LIST_BASE + 252)
        localGet(code, scratchIndex + 2); localSet(code, scratchIndex + 1)
        operand(code, 12, 0)
        end(code); end(code)
        // Return the fixed-size descriptor to size class zero.
        getValue(code, values, args[0]); i32(code, 0); store16(code, 0)
        getValue(code, values, args[0]); i32(code, 0); load32(code, FREE_LIST_BASE); store32(code, 4)
        i32(code, 0); getValue(code, values, args[0]); store32(code, FREE_LIST_BASE)
        op(code, 5)
        if args.length == 2 && reference(module_, args[1]) {
            i32(code, 0); localSet(code, scratchIndex)
            block(code); loop(code)
            localGet(code, scratchIndex); getValue(code, values, args[0]); load32(code, 4); op(code, 78); operand(code, 13, 1)
            getValue(code, values, args[0]); i32(code, 8); op(code, 106)
            localGet(code, scratchIndex); i32(code, 2); op(code, 116); op(code, 106); load32(code, 0); call(code, runtimeFunctionIndex(module_, 2))
            localGet(code, scratchIndex); i32(code, 1); op(code, 106); localSet(code, scratchIndex)
            operand(code, 12, 0)
            end(code); end(code)
        }
        getValue(code, values, args[0]); load16Unsigned(code, 2); i32(code, MIN_BLOCK_SIZE); op(code, 107); i32(code, 4); op(code, 118); i32(code, 2); op(code, 116); localSet(code, scratchIndex)
        getValue(code, values, args[0]); i32(code, 0); store16(code, 0)
        getValue(code, values, args[0]); localGet(code, scratchIndex); load32(code, FREE_LIST_BASE); store32(code, 4)
        localGet(code, scratchIndex); getValue(code, values, args[0]); store32(code, FREE_LIST_BASE)
        end(code)
        return
    }
    if instruction.op == "array-length" {
        checkArrayHandle(code, values, args[0])
        getValue(code, values, args[0]); load32(code, 4); setResult(code, module_, values, instruction)
        return
    }
    reading := instruction.op == "array-get" || instruction.op == "array-peek"
    typeName := if reading then instruction.result!.typeName else valueType(values, args[2])
    checkArrayBounds(code, values, args[0], args[1])
    if reading {
        arrayAddress(code, module_, values, args[0], args[1], typeName, scratchIndex)
        operand(code, arrayLoadCode(typeName), if typeName == "long" || typeName == "double" then 3 else if typeName == "byte" || typeName == "bool" || typeName == "char" then 0 else 2, 0)
        // A peek borrows the slot's reference for a proven short window.
        if instruction.op == "array-get" { retainTop(code, module_, typeName) }
        setResult(code, module_, values, instruction)
        return
    }
    if reference(module_, typeName) {
        // Retain first so replacing a slot with the same object is safe.
        getValue(code, values, args[2]); call(code, runtimeFunctionIndex(module_, 1)); op(code, 26)
        arrayAddress(code, module_, values, args[0], args[1], typeName, scratchIndex)
        operand(code, arrayLoadCode(typeName), 2, 0); call(code, runtimeFunctionIndex(module_, 2))
    }
    arrayAddress(code, module_, values, args[0], args[1], typeName, scratchIndex)
    getValue(code, values, args[2])
    operand(code, arrayStoreCode(typeName), if typeName == "long" || typeName == "double" then 3 else if typeName == "byte" || typeName == "bool" || typeName == "char" then 0 else 2, 0)
}

function body(inputLocals: int[], inputInstructions: WasmInstruction[], parameters: int): int[] {
    ordered := orderWasmLocals(parameters, inputLocals, simplifyWasmInstructions(inputInstructions))
    locals := ordered.locals
    instructions := ordered.instructions
    let result: int[] = []
    let groups = 0
    for index of 0..<locals.length { if index == 0 || locals[index] != locals[index - 1] { groups += 1 } }
    unsigned(result, groups)
    let index = 0
    while index < locals.length {
        let stop = index + 1
        while stop < locals.length && locals[stop] == locals[index] { stop += 1 }
        unsigned(result, stop - index); byte_(result, locals[index])
        index = stop
    }
    append(result, encodeWasmInstructions(instructions))
    byte_(result, 11)
    return result
}

function moduleHeader(module_: MinusModule, constants: string[], literals: LiteralData, helpers: WasmHelpers, plan: WasmFunctionPlan, debugHeap: bool = false): int[] {
    let bytes: int[] = [0, 97, 115, 109, 1, 0, 0, 0]
    hasModuleInitializer := module_.globals.length > 0
    let types: int[] = []
    unsigned(types, helpers.signatures.length)
    for signature of helpers.signatures { append(types, signature) }
    section(bytes, 1, types)
    if module_.imports.length > 0 {
        let imports: int[] = []
        unsigned(imports, module_.imports.length)
        for index of 0..<module_.imports.length {
            import_ := module_.imports[index]
            name(imports, import_.importModule)
            name(imports, import_.importName)
            byte_(imports, 0)
            unsigned(imports, helpers.typeIndexes[index])
        }
        section(bytes, 2, imports)
    }
    let functions: int[] = []
    unsigned(functions, plan.bodies.length)
    for body_ of plan.bodies { unsigned(functions, body_.typeIndex) }
    section(bytes, 3, functions)
    let table: int[] = [1, 112, 0]
    unsigned(table, module_.functions.length + 3)
    section(bytes, 4, table)
    let memory: int[] = [1, 0]
    unsigned(memory, (1024 + literals.bytes.length + 65535) \ 65536)
    section(bytes, 5, memory) // enough pages for the complete static heap
    if module_.recoverPanics {
        let tags: int[] = [1, 0]
        unsigned(tags, helpers.typeIndexes[module_.imports.length + module_.functions.length + 3 + if hasModuleInitializer then 1 else 0])
        section(bytes, 13, tags)
    }
    let globals: int[] = []
    unsigned(globals, constants.length + module_.globals.length + 1)
    byte_(globals, 127); byte_(globals, 1); rawI32(globals, 1024 + literals.bytes.length); byte_(globals, 11) // heap cursor
    for pointer of literals.pointers {
        byte_(globals, 127); byte_(globals, 1); rawI32(globals, pointer); byte_(globals, 11)
    }
    for global_ of module_.globals {
        byte_(globals, wasmType(global_.typeName)); byte_(globals, 1)
        let initial: WasmInstruction[] = []
        emitConstant(initial, MinusInstruction { op: "const", result: MinusValue { name: "%zero", typeName: global_.typeName }, args: ["0"] })
        append(globals, encodeWasmInstructions(initial)); byte_(globals, 11)
    }
    section(bytes, 6, globals)
    let exports: int[] = []
    let count = 0
    for function_ of module_.functions { if function_.exported { count += 1 } }
    unsigned(exports, count + 3 + (if debugHeap then 1 else 0) + (if module_.recoverPanics then 1 else 0))
    for index of 0..<module_.functions.length {
        function_ := module_.functions[index]
        if !function_.exported { continue }
        name(exports, if function_.exportName == "" then function_.name else function_.exportName)
        byte_(exports, 0)
        unsigned(exports, plan.indexes[module_.imports.length + index + 3])
    }
    name(exports, "__doof_ffi_alloc"); byte_(exports, 0); unsigned(exports, plan.indexes[runtimeFunctionIndex(module_, 0)])
    name(exports, "__doof_ffi_release"); byte_(exports, 0); unsigned(exports, plan.indexes[runtimeFunctionIndex(module_, 2)])
    name(exports, "__doof_ffi_memory"); byte_(exports, 2); unsigned(exports, 0)
    if module_.recoverPanics { name(exports, "__doof_panic_tag"); byte_(exports, 4); unsigned(exports, 0) }
    if debugHeap {
        name(exports, "__doof_debug_heap_end"); byte_(exports, 3); unsigned(exports, 0)
    }
    section(bytes, 7, exports)
    if hasModuleInitializer {
        let start: int[] = []
        unsigned(start, plan.indexes[module_.imports.length + module_.functions.length + 3])
        section(bytes, 8, start)
    }
    // Leave unreachable slots null, preserving all live logical table identities.
    let segments: int[] = []
    let segmentCount = 0
    let slot = 0
    while slot < module_.functions.length + 3 {
        if plan.indexes[module_.imports.length + slot] < 0 { slot += 1; continue }
        start := slot
        while slot < module_.functions.length + 3 && plan.indexes[module_.imports.length + slot] >= 0 { slot += 1 }
        unsigned(segments, 0); rawI32(segments, start); byte_(segments, 11)
        unsigned(segments, slot - start)
        for index of start..<slot { unsigned(segments, plan.indexes[module_.imports.length + index]) }
        segmentCount += 1
    }
    let elements: int[] = []
    unsigned(elements, segmentCount); append(elements, segments)
    section(bytes, 9, elements)
    return bytes
}

function collectValues(function_: MinusFunction): WasmLocals {
    let values: MinusValue[] = []
    for value of function_.params { values.push(value) }
    for block_ of minusBlocks(function_) {
        for value of block_.params { values.push(value) }
        for instruction of block_.instructions { if instruction.result != none { values.push(instruction.result!) } }
    }
    return rawWasmLocals(values)
}

function resultIndex(values: WasmLocals, instruction: MinusInstruction): int => valueIndex(values, instruction.result!.name)
function getValue(code: WasmInstruction[], values: WasmLocals, name_: string): none {
    id := valueId(values, name_)
    if values.stack[id] { return }
    if values.slots[id] < 0 { panic("used value has no Wasm local") }
    localGet(code, values.slots[id])
}

function stringConstants(module_: MinusModule, live: bool[]): string[] {
    let result: string[] = []
    for index of 0..<module_.functions.length {
        if !live[index] { continue }
        function_ := module_.functions[index]
        blocks := minusBlocks(function_)
        flow := analyzeMinusControlFlow(blocks)
        for blockIndex of 0..<blocks.length {
            if flow.positions[blockIndex] < 0 { continue }
            block_ := blocks[blockIndex]
            for instruction of block_.instructions {
                if instruction.op == "string-const" && instruction.args.length == 1 && !result.contains(instruction.args[0]) {
                    result.push(instruction.args[0])
                }
            }
        }
    }
    return result
}

function stringConstantIndex(constants: string[], value: string): int {
    for index of 0..<constants.length { if constants[index] == value { return index } }
    panic("validated string constant missing from pool")
}

// The active segment is a valid heap prefix, including headers, ownership
// links and radix directories. The allocator starts immediately after it.
class LiteralData {
    bytes: int[] = []
    pointers: int[] = []
}

function writeLiteralWord(data: LiteralData, address: int, value: int, width: int = 4): none {
    let remaining = value
    for index of 0..<width {
        data.bytes[address - 1024 + index] = remaining % 256
        remaining = remaining \ 256
    }
}

function readLiteralWord(data: LiteralData, address: int): int {
    let value = 0
    let factor = 1
    for index of 0..<4 {
        value += data.bytes[address - 1024 + index] * factor
        if index < 3 { factor *= 256 }
    }
    return value
}

function literalBlock(data: LiteralData, size: int, typeTag: int, ownership: int): int {
    pointer := 1024 + data.bytes.length
    for _ of 0..<size { data.bytes.push(0) }
    writeLiteralWord(data, pointer, typeTag, 2)
    writeLiteralWord(data, pointer + 2, size, 2)
    writeLiteralWord(data, pointer + 4, ownership)
    return pointer
}

function literalOwnedBlock(data: LiteralData, descriptor: int, typeTag: int): int {
    pointer := literalBlock(data, MAX_BLOCK_SIZE, typeTag, readLiteralWord(data, descriptor + 16))
    writeLiteralWord(data, descriptor + 16, pointer)
    return pointer
}

function literalCharacters(data: LiteralData, value: string): int {
    if value.length <= ARRAY_CHUNK_BYTES {
        size := if value.length <= 16 then MIN_BLOCK_SIZE else MIN_BLOCK_SIZE + ((value.length - 16 + 15) \ 16) * 16
        pointer := literalBlock(data, size, ARRAY_DATA_TAG, value.length)
        for index of 0..<value.length { data.bytes[pointer - 1024 + 8 + index] = int(value[index]) }
        return pointer
    }
    chunks := value.length \ ARRAY_CHUNK_BYTES + if value.length % ARRAY_CHUNK_BYTES == 0 then 0 else 1
    descriptor := literalBlock(data, MIN_BLOCK_SIZE, ARRAY_DESCRIPTOR_TAG, value.length)
    writeLiteralWord(data, descriptor + 8, chunks)
    root := literalOwnedBlock(data, descriptor, ARRAY_NODE_TAG)
    writeLiteralWord(data, descriptor + 12, root)
    for ordinal of 0..<chunks {
        rootSlot := root + 8 + (ordinal \ 65536) * 4
        let middle = readLiteralWord(data, rootSlot)
        if middle == 0 {
            middle = literalOwnedBlock(data, descriptor, ARRAY_NODE_TAG)
            writeLiteralWord(data, rootSlot, middle)
        }
        middleSlot := middle + 8 + ((ordinal \ 256) % 256) * 4
        let leaf = readLiteralWord(data, middleSlot)
        if leaf == 0 {
            leaf = literalOwnedBlock(data, descriptor, ARRAY_NODE_TAG)
            writeLiteralWord(data, middleSlot, leaf)
        }
        chunk := literalOwnedBlock(data, descriptor, ARRAY_CHUNK_TAG)
        writeLiteralWord(data, leaf + 8 + (ordinal % 256) * 4, chunk)
        start := ordinal * ARRAY_CHUNK_BYTES
        count := if value.length - start < ARRAY_CHUNK_BYTES then value.length - start else ARRAY_CHUNK_BYTES
        for index of 0..<count { data.bytes[chunk - 1024 + 8 + index] = int(value[start + index]) }
    }
    return descriptor
}

function stringData(module_: MinusModule, constants: string[]): LiteralData {
    data := LiteralData {}
    if constants.length == 0 { return data }
    charArray := classByName(module_, "__doof_array_char")
    stringClass := classByName(module_, "__doof_string")
    for value of constants {
        characters := literalCharacters(data, value)
        wrapper := literalBlock(data, classSize(charArray), tag(module_, charArray.name), 1)
        writeLiteralWord(data, wrapper + classFieldOffset(charArray, fieldIndex(charArray, "data")), characters)
        pointer := literalBlock(data, classSize(stringClass), tag(module_, stringClass.name), 1)
        writeLiteralWord(data, pointer + classFieldOffset(stringClass, fieldIndex(stringClass, "chars")), wrapper)
        data.pointers.push(pointer)
    }
    return data
}

function emitModuleInitializer(module_: MinusModule, constants: string[]): WasmInstruction[] {
    let code: WasmInstruction[] = []
    // Static string roots already exist when the module start function runs.
    for index of 0..<module_.globals.length {
        call(code, functionIndex(module_, module_.globals[index].initializer))
        globalSet(code, constants.length + index + 1)
    }
    return code
}

function setResult(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, instruction: MinusInstruction): none {
    id := valueId(values, instruction.result!.name)
    if values.stack[id] { return }
    index := values.slots[id]
    if index < 0 { op(code, 26); return }
    if reference(module_, instruction.result!.typeName) && values.repeated[id] && !values.borrowed[id] && !values.moved[id] && !values.cleared[id] { localGet(code, index); call(code, runtimeFunctionIndex(module_, 2)) }
    localSet(code, index)
}

function retainTop(code: WasmInstruction[], module_: MinusModule, typeName: string): none {
    if reference(module_, typeName) { call(code, runtimeFunctionIndex(module_, 1)) }
}

function normalize(code: WasmInstruction[], typeName: string): none {
    if typeName == "byte" { i32(code, 255); op(code, 113) }
}

function emitConstant(code: WasmInstruction[], instruction: MinusInstruction): none {
    typeName := instruction.result!.typeName
    value := instruction.args[0]
    if typeName == "long" { i64(code, parseLong(value)!) }
    else if typeName == "float" { code.push(WasmInstruction { opcode: 67, floatValue: parseFloat(value)! }) }
    else if typeName == "double" { code.push(WasmInstruction { opcode: 68, doubleValue: parseDouble(value)! }) }
    else if typeName == "none" { i32(code, 0) }
    else if typeName == "bool" { i32(code, if value == "true" then 1 else 0) }
    else { i32(code, parseInt(value)!) }
}

function arithmeticCode(typeName: string, operation: string): int {
    if typeName == "long" {
        if operation == "add" { return 124 }
        if operation == "sub" { return 125 }
        if operation == "mul" { return 126 }
        if operation == "div" { return 127 }
        if operation == "rem" { return 129 }
        if operation == "eq" { return 81 }
        return 83
    }
    if typeName == "float" {
        if operation == "add" { return 146 }
        if operation == "sub" { return 147 }
        if operation == "mul" { return 148 }
        if operation == "div" { return 149 }
        if operation == "eq" { return 91 }
        return 93
    }
    if typeName == "double" {
        if operation == "add" { return 160 }
        if operation == "sub" { return 161 }
        if operation == "mul" { return 162 }
        if operation == "div" { return 163 }
        if operation == "eq" { return 97 }
        return 99
    }
    if operation == "add" { return 106 }
    if operation == "sub" { return 107 }
    if operation == "mul" { return 108 }
    if operation == "div" { return if typeName == "byte" then 110 else 109 }
    if operation == "rem" { return if typeName == "byte" then 112 else 111 }
    if operation == "eq" { return 70 }
    return if typeName == "byte" || typeName == "char" then 73 else 72
}

function emitNumericConversion(code: WasmInstruction[], source: string, target: string): none {
    sourceWasm := wasmType(source)
    targetWasm := wasmType(target)
    if sourceWasm != targetWasm {
        let opcode = 0
        if sourceWasm == 127 {
            if targetWasm == 126 { opcode = if source == "byte" then 173 else 172 }
            if targetWasm == 125 { opcode = if source == "byte" then 179 else 178 }
            if targetWasm == 124 { opcode = if source == "byte" then 184 else 183 }
        }
        if sourceWasm == 126 {
            if targetWasm == 127 { opcode = 167 }
            if targetWasm == 125 { opcode = 180 }
            if targetWasm == 124 { opcode = 185 }
        }
        if sourceWasm == 125 {
            if targetWasm == 127 { opcode = 168 }
            if targetWasm == 126 { opcode = 174 }
            if targetWasm == 124 { opcode = 187 }
        }
        if sourceWasm == 124 {
            if targetWasm == 127 { opcode = 170 }
            if targetWasm == 126 { opcode = 176 }
            if targetWasm == 125 { opcode = 182 }
        }
        op(code, opcode)
    }
    normalize(code, target)
}

function emitReleaseLocals(code: WasmInstruction[], module_: MinusModule, values: WasmLocals): none {
    for index of 0..<values.table.values.length {
        if values.slots[index] >= 0 && !values.borrowed[index] && !values.moved[index] && reference(module_, values.table.values[index].typeName) {
            localGet(code, values.slots[index]); call(code, runtimeFunctionIndex(module_, 2))
        }
    }
}

function sameEdgeSlot(values: WasmLocals, source: string, target: string): bool {
    if source == target { return true }
    sourceSlot := valueIndex(values, source)
    return sourceSlot >= 0 && sourceSlot == valueIndex(values, target)
}

function emitEdge(code: WasmInstruction[], module_: MinusModule, blocks: MinusBlock[], values: WasmLocals, target: string, arguments: string[], labels: string[]): none {
    block_ := blocks[minusBlockIndex(blocks, target)]
    // Retain owned incoming references before overwriting any block parameter.
    // Proven borrowed parameters keep the same parallel pointer transfer.
    for index of 0..<arguments.length {
        if sameEdgeSlot(values, arguments[index], block_.params[index].name) { continue }
        getValue(code, values, arguments[index])
        if !values.borrowed[valueId(values, block_.params[index].name)] && !values.transfers[valueId(values, arguments[index])] { retainTop(code, module_, valueType(values, arguments[index])) }
    }
    for index of 0..<block_.params.length {
        if sameEdgeSlot(values, arguments[index], block_.params[index].name) { continue }
        param := block_.params[index]
        id := valueId(values, param.name)
        if reference(module_, param.typeName) && values.repeated[id] && !values.borrowed[id] && !values.cleared[id] { localGet(code, valueIndex(values, param.name)); call(code, runtimeFunctionIndex(module_, 2)) }
    }
    let index = block_.params.length - 1
    while index >= 0 {
        if !sameEdgeSlot(values, arguments[index], block_.params[index].name) { localSet(code, valueIndex(values, block_.params[index].name)) }
        index -= 1
    }
    // A moved reference now belongs to its parameter; empty the source slot.
    for moved of 0..<arguments.length {
        if sameEdgeSlot(values, arguments[moved], block_.params[moved].name) || !values.transfers[valueId(values, arguments[moved])] { continue }
        slot := valueIndex(values, arguments[moved])
        if slot >= 0 { i32(code, 0); localSet(code, slot) }
    }
    let index_ = labels.length - 1
    while index_ >= 0 {
        if labels[index_] == target { branch(code, labels.length - index_ - 1); return }
        index_ -= 1
    }
    panic("validated lexical branch target missing")
}

function emitReturn(code: WasmInstruction[], module_: MinusModule, function_: MinusFunction, values: WasmLocals, instruction: MinusInstruction, returnIndex: int, branchDepth: int): none {
    if instruction.args.length > 0 && function_.result != "none" {
        if !values.moved[valueId(values, instruction.args[0])] {
            getValue(code, values, instruction.args[0])
            retainTop(code, module_, function_.result)
            localSet(code, returnIndex)
        }
    }
    // Exit the function body to one cleanup epilogue. Duplicating every
    // reference release at every source return creates enormous functions.
    branch(code, branchDepth)
}

function emitDynamicField(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, instruction: MinusInstruction, ownerType: string): none {
    // A block around the cases gives every successful case one exit target.
    block(code)
    let cases = 0
    for class_ of module_.classes {
        if !class_.interfaces.contains(ownerType) { continue }
        cases += 1
        getValue(code, values, instruction.args[0]); load16Unsigned(code, 0)
        i32(code, tag(module_, class_.name)); op(code, 70); if_(code)
        offset := classFieldOffset(class_, fieldIndex(class_, instruction.args[1]))
        if instruction.op == "get" {
            if instruction.result!.typeName == "none" { i32(code, 0) }
            else { getValue(code, values, instruction.args[0]); load(code, instruction.result!.typeName, offset) }
            if !values.borrowed[valueId(values, instruction.result!.name)] { retainTop(code, module_, instruction.result!.typeName) }
            setResult(code, module_, values, instruction)
        } else {
            fieldType := valueType(values, instruction.args[2])
            if reference(module_, fieldType) {
                getValue(code, values, instruction.args[0]); load32(code, offset); call(code, runtimeFunctionIndex(module_, 2))
            }
            if fieldType != "none" {
                getValue(code, values, instruction.args[0]); getValue(code, values, instruction.args[2])
                retainTop(code, module_, fieldType)
                store(code, fieldType, offset)
            }
        }
        branch(code, 1); end(code)
    }
    if cases == 0 { op(code, 0) } else { op(code, 0) }
    end(code)
}

function emitField(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, instruction: MinusInstruction): none {
    ownerType := valueType(values, instruction.args[0])
    let interface_ = false
    for item of module_.interfaces { if item.name == ownerType { interface_ = true } }
    if interface_ { emitDynamicField(code, module_, values, instruction, ownerType); return }
    class_ := classByName(module_, ownerType)
    offset := classFieldOffset(class_, fieldIndex(class_, instruction.args[1]))
    if instruction.op == "get" {
        if instruction.result!.typeName == "none" { i32(code, 0) }
        else { getValue(code, values, instruction.args[0]); load(code, instruction.result!.typeName, offset) }
        if !values.borrowed[valueId(values, instruction.result!.name)] { retainTop(code, module_, instruction.result!.typeName) }
        setResult(code, module_, values, instruction)
    } else {
        fieldType := valueType(values, instruction.args[2])
        if reference(module_, fieldType) { getValue(code, values, instruction.args[0]); load32(code, offset); call(code, runtimeFunctionIndex(module_, 2)) }
        if fieldType != "none" {
            getValue(code, values, instruction.args[0]); getValue(code, values, instruction.args[2])
            retainTop(code, module_, fieldType)
            store(code, fieldType, offset)
        }
    }
}

function emitCall(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, scratchIndex: int, instruction: MinusInstruction, helpers: WasmHelpers): none {
    args := instruction.args
    if instruction.op == "call" && inlineWrapper(code, module_, values, helpers, args[0], instruction) { return }
    if instruction.op == "call" {
        for index of 1..<args.length { getValue(code, values, args[index]) }
        call(code, functionIndex(module_, args[0]))
        if instruction.result!.typeName == "none" && values.uses[valueId(values, instruction.result!.name)] == 0 { return }
        if instruction.result!.typeName == "none" { i32(code, 0) }
        setResult(code, module_, values, instruction)
        return
    }
    ownerType := valueType(values, args[0])
    let interface_ = false
    for item of module_.interfaces { if item.name == ownerType { interface_ = true } }
    if !interface_ && values.peek[valueId(values, instruction.result!.name)] {
        // Inline the array wrapper's storage read; the helper checks bounds.
        class_ := classByName(module_, ownerType)
        getValue(code, values, args[0]); load32(code, classFieldOffset(class_, fieldIndex(class_, "data")))
        getValue(code, values, args[2])
        call(code, arrayHelperIndex(helpers, "array-peek", "any"))
        setResult(code, module_, values, instruction)
        return
    }
    if !interface_ && inlineWrapper(code, module_, values, helpers, ownerType + "." + args[1], instruction) { return }
    if !interface_ {
        getValue(code, values, args[0])
        for index of 2..<args.length { getValue(code, values, args[index]) }
        call(code, functionIndex(module_, ownerType + "." + args[1]))
        if instruction.result!.typeName == "none" && values.uses[valueId(values, instruction.result!.name)] == 0 { return }
        if instruction.result!.typeName == "none" { i32(code, 0) }
        setResult(code, module_, values, instruction)
        return
    }
    i32(code, -1); localSet(code, scratchIndex)
    let signatureIndex = -1
    for class_ of module_.classes {
        if !class_.interfaces.contains(ownerType) { continue }
        methodIndex := tableFunctionIndex(module_, class_.name + "." + args[1])
        // Imports precede defined functions in the type section, but are not
        // entries in the indirect-call table.
        if signatureIndex < 0 { signatureIndex = helpers.typeIndexes[module_.imports.length + methodIndex] }
        getValue(code, values, args[0]); load16Unsigned(code, 0)
        i32(code, tag(module_, class_.name)); op(code, 70); if_(code)
        i32(code, methodIndex); localSet(code, scratchIndex)
        end(code)
    }
    if signatureIndex < 0 { op(code, 0); return }
    getValue(code, values, args[0])
    for index of 2..<args.length { getValue(code, values, args[index]) }
    localGet(code, scratchIndex)
    operand(code, 17, signatureIndex, 0)
    if instruction.result!.typeName == "none" && values.uses[valueId(values, instruction.result!.name)] == 0 { return }
    if instruction.result!.typeName == "none" { i32(code, 0) }
    setResult(code, module_, values, instruction)
}

function emitNew(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, instruction: MinusInstruction): none {
    class_ := classByName(module_, instruction.args[0])
    i32(code, classSize(class_))
    i32(code, tag(module_, class_.name))
    call(code, runtimeFunctionIndex(module_, 0))
    setResult(code, module_, values, instruction)
    for index of 0..<class_.fields.length {
        typeName := class_.fields[index].typeName
        if typeName == "none" { continue }
        localGet(code, resultIndex(values, instruction))
        getValue(code, values, instruction.args[index + 1])
        retainTop(code, module_, typeName)
        store(code, typeName, classFieldOffset(class_, index))
    }
}

// An `any` holding a class or interface value is the object pointer itself:
// its header tag already names the class. `none` is the zero pointer, whose
// "header" (the permanently zero bytes 0-7) reads as the none tag. Only
// primitives and enums are boxed, in a 24-byte block tagged ANY_TAG with the
// value's tag at offset 8 and the value at offset 16.
function classValue(module_: MinusModule, typeName: string): bool => typeName != "none" && typeName != "any" && reference(module_, typeName)

function emitBox(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, instruction: MinusInstruction): none {
    if instruction.args.length == 2 {
        emitNew(code, module_, values, instruction)
        return
    }
    sourceType := valueType(values, instruction.args[0])
    if classValue(module_, sourceType) {
        getValue(code, values, instruction.args[0])
        retainTop(code, module_, sourceType)
        setResult(code, module_, values, instruction)
        return
    }
    // `none` in an `any` is the zero pointer; retain and release ignore it.
    if sourceType == "none" { i32(code, 0); setResult(code, module_, values, instruction); return }
    i32(code, 24); i32(code, ANY_TAG); call(code, runtimeFunctionIndex(module_, 0))
    setResult(code, module_, values, instruction)
    localGet(code, resultIndex(values, instruction))
    i32(code, tag(module_, sourceType))
    store16(code, 8)
    localGet(code, resultIndex(values, instruction))
    getValue(code, values, instruction.args[0])
    store(code, sourceType, 16)
}

// Test whether the any value holds the target type, leaving an i32 flag.
function emitAnyTest(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, value: string, target: string): none {
    if interfaceType(module_, target) {
        i32(code, 0)
        for class_ of module_.classes {
            if !class_.interfaces.contains(target) { continue }
            getValue(code, values, value); load16Unsigned(code, 0)
            i32(code, tag(module_, class_.name)); op(code, 70); op(code, 114)
        }
        return
    }
    if classValue(module_, target) {
        getValue(code, values, value); load16Unsigned(code, 0); i32(code, tag(module_, target)); op(code, 70)
        return
    }
    if target == "none" { getValue(code, values, value); op(code, 69); return }
    // Every block is at least 24 bytes, so reading offset 8 of an object is
    // harmless; only a box can match both tests.
    getValue(code, values, value); load16Unsigned(code, 0); i32(code, ANY_TAG); op(code, 70)
    getValue(code, values, value); load16Unsigned(code, 8); i32(code, tag(module_, target)); op(code, 70)
    op(code, 113)
}

function emitTagOperation(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, instruction: MinusInstruction): none {
    checked := instruction.op == "cast" && values.checkedCasts[valueId(values, instruction.result!.name)]
    if !checked { emitAnyTest(code, module_, values, instruction.args[0], instruction.args[1]) }
    if instruction.op == "is" { setResult(code, module_, values, instruction); return }
    if !checked { op(code, 69); if_(code); op(code, 0); end(code) }
    target := instruction.result!.typeName
    if target == "none" { i32(code, 0) }
    else if classValue(module_, target) {
        getValue(code, values, instruction.args[0])
        if !values.borrowed[valueId(values, instruction.result!.name)] { retainTop(code, module_, target) }
    } else {
        getValue(code, values, instruction.args[0])
        load(code, target, 16)
    }
    setResult(code, module_, values, instruction)
}

// The nominal tag of an any value: the box's stored tag, or an object's header.
function emitAnyTag(code: WasmInstruction[], values: WasmLocals, value: string, local: int): none {
    getValue(code, values, value); load16Unsigned(code, 0); localSet(code, local)
    localGet(code, local); i32(code, ANY_TAG); op(code, 70); operand(code, 4, 127)
    getValue(code, values, value); load16Unsigned(code, 8)
    op(code, 5); localGet(code, local); end(code)
    localSet(code, local)
}

// Equal nominal tags, then: objects by identity (strings by contents) and
// boxed scalars by value.
function emitAnyEquality(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, left: string, right: string, scratch: int): none {
    getValue(code, values, left); getValue(code, values, right); op(code, 70)
    operand(code, 4, 127)
    i32(code, 1)
    op(code, 5)
    getValue(code, values, left); op(code, 69)
    getValue(code, values, right); op(code, 69); op(code, 114)
    operand(code, 4, 127)
    i32(code, 0)
    op(code, 5)
    emitAnyTag(code, values, left, scratch)
    emitAnyTag(code, values, right, scratch + 1)
    localGet(code, scratch); localGet(code, scratch + 1); op(code, 71)
    operand(code, 4, 127)
    i32(code, 0)
    op(code, 5)
    let stringTag = -1
    for index of 0..<module_.classes.length { if module_.classes[index].name == "__doof_string" { stringTag = 32 + index } }
    if stringTag >= 0 {
        localGet(code, scratch); i32(code, stringTag); op(code, 70)
        operand(code, 4, 127)
        getValue(code, values, left); getValue(code, values, right)
        call(code, functionIndex(module_, "__doof_string.compare")); op(code, 69)
        op(code, 5)
    }
    // Distinct objects of any other class are unequal.
    getValue(code, values, left); load16Unsigned(code, 0); i32(code, ANY_TAG); op(code, 71)
    operand(code, 4, 127)
    i32(code, 0)
    op(code, 5)
    let types: string[] = ["none", "bool", "char", "byte", "int", "long", "float", "double"]
    for enum_ of module_.enums { types.push(enum_.name) }
    for typeName of types {
        localGet(code, scratch); i32(code, tag(module_, typeName)); op(code, 70)
        operand(code, 4, 127)
        if typeName == "none" { i32(code, 1) }
        else {
            getValue(code, values, left); load(code, typeName, 16)
            getValue(code, values, right); load(code, typeName, 16)
            op(code, arithmeticCode(typeName, "eq"))
        }
        op(code, 5)
    }
    i32(code, 0)
    for _ of types { end(code) }
    end(code); end(code); end(code); end(code)
    if stringTag >= 0 { end(code) }
}

function emitInstruction(code: WasmInstruction[], module_: MinusModule, function_: MinusFunction, values: WasmLocals, frameIndex: int, scratchIndex: int, instruction: MinusInstruction, constants: string[], helpers: WasmHelpers, blocks: MinusBlock[], labels: string[]): none {
    operation := instruction.op
    args := instruction.args
    if operation == "panic" {
        if !module_.recoverPanics || args.length == 0 { op(code, 0); return }
        getValue(code, values, args[0]); call(code, runtimeFunctionIndex(module_, 1))
        operand(code, 8, 0)
        return
    }
    if operation == "string-const" {
        globalGet(code, stringConstantIndex(constants, args[0]) + 1)
        setResult(code, module_, values, instruction)
        return
    }
    if operation == "global-get" {
        for index of 0..<module_.globals.length {
            if module_.globals[index].name != args[0] { continue }
            globalGet(code, constants.length + index + 1)
            setResult(code, module_, values, instruction)
            return
        }
    }
    if operation == "const" { emitConstant(code, instruction); setResult(code, module_, values, instruction); return }
    if operation == "eq" && valueType(values, args[0]) == "any" {
        emitAnyEquality(code, module_, values, args[0], args[1], scratchIndex)
        setResult(code, module_, values, instruction)
        return
    }
    if (operation == "add" || operation == "sub" || operation == "mul" || operation == "div" || operation == "rem" || operation == "eq" || operation == "lt") {
        getValue(code, values, args[0]); getValue(code, values, args[1])
        typeName := valueType(values, args[0])
        op(code, arithmeticCode(typeName, operation))
        if operation != "eq" && operation != "lt" { normalize(code, typeName) }
        setResult(code, module_, values, instruction)
        return
    }
    if operation == "convert" {
        getValue(code, values, args[0])
        emitNumericConversion(code, valueType(values, args[0]), instruction.result!.typeName)
        setResult(code, module_, values, instruction)
        return
    }
    if operation == "copy" || operation == "as" {
        if sameEdgeSlot(values, args[0], instruction.result!.name) { return }
        getValue(code, values, args[0])
        if !values.borrowed[valueId(values, instruction.result!.name)] { retainTop(code, module_, instruction.result!.typeName) }
        setResult(code, module_, values, instruction)
        return
    }
    if operation == "new" { emitNew(code, module_, values, instruction); return }
    if operation.startsWith("array-") {
        argumentCount := if operation == "array-alloc" || operation == "array-free" then 1 else if operation == "array-reserve" then 2 else if operation == "array-copy" then 5 else args.length
        for index of 0..<argumentCount { getValue(code, values, args[index]) }
        call(code, arrayHelperIndex(helpers, operation, arrayElementType(module_, values, instruction)))
        if instruction.result != none { setResult(code, module_, values, instruction) }
        return
    }
    if operation == "get" || operation == "set" { emitField(code, module_, values, instruction); return }
    if operation == "call" || operation == "call-method" { emitCall(code, module_, values, scratchIndex, instruction, helpers); return }
    if operation == "box" { emitBox(code, module_, values, instruction); return }
    if operation == "is" || operation == "cast" { emitTagOperation(code, module_, values, instruction); return }
    if operation == "return" { emitReturn(code, module_, function_, values, instruction, frameIndex + 4, labels.length - 1); return }
    if operation == "jump" {
        let edgeArgs: string[] = []
        for index of 1..<args.length { edgeArgs.push(args[index]) }
        emitEdge(code, module_, blocks, values, args[0], edgeArgs, labels)
        return
    }
    if operation == "branch" {
        let split = 0
        for index of 0..<args.length { if args[index] == "|" { split = index; break } }
        let thenArgs: string[] = []
        for index of 2..<split { thenArgs.push(args[index]) }
        let elseArgs: string[] = []
        for index of (split + 2)..<args.length { elseArgs.push(args[index]) }
        getValue(code, values, args[0]); if_(code)
        labels.push("")
        emitEdge(code, module_, blocks, values, args[1], thenArgs, labels)
        op(code, 5)
        emitEdge(code, module_, blocks, values, args[split + 1], elseArgs, labels)
        _ := try! labels.pop()
        end(code)
        return
    }
}

function emitRegion(code: WasmInstruction[], module_: MinusModule, function_: MinusFunction, region: MinusRegion, values: WasmLocals, constants: string[], helpers: WasmHelpers, blocks: MinusBlock[], labels: string[]): none {
    if region.code != none {
        if !values.liveBlocks[minusBlockIndex(blocks, region.code!.name)] { return }
        for instruction of region.code!.instructions {
            emitInstruction(code, module_, function_, values, values.scratch, values.scratch, instruction, constants, helpers, blocks, labels)
        }
        return
    }
    if region.kind != "sequence" {
        if region.kind == "loop" { loop(code) } else { block(code) }
        labels.push(region.label)
    }
    for child of region.children { emitRegion(code, module_, function_, child, values, constants, helpers, blocks, labels) }
    if region.kind != "sequence" { _ := try! labels.pop(); end(code) }
}

function emitUserFunction(module_: MinusModule, function_: MinusFunction, constants: string[], helpers: WasmHelpers, values: WasmLocals): WasmInstruction[] {
    frameIndex := values.scratch
    scratchIndex := frameIndex
    panicIndex := frameIndex + 4 + (if function_.result != "none" then 1 else 0)
    let code: WasmInstruction[] = []
    for index of 0..<function_.params.length {
        typeName := function_.params[index].typeName
        if typeName == "byte" {
            localGet(code, index); normalize(code, typeName); localSet(code, index)
        }
        if typeName == "bool" {
            localGet(code, index); op(code, 69); op(code, 69); localSet(code, index)
        }
        if typeName == "none" { i32(code, 0); localSet(code, index) }
        if typeName == "char" { localGet(code, index); i32(code, 255); op(code, 75); if_(code); op(code, 0); end(code) }
    }
    if module_.recoverPanics { operand(code, 6, 64) }
    block(code) // one shared cleanup exit
    emitRegion(code, module_, function_, function_.body, values, constants, helpers, minusBlocks(function_), [""])
    end(code)
    if module_.recoverPanics {
        operand(code, 7, 0)
        localSet(code, panicIndex)
        i32(code, 1); localSet(code, panicIndex + 1)
        end(code)
    }
    // Normal and language-panic exits converge before releasing the frame.
    // The flag is independent of the payload so even a zero payload is caught.
    emitReleaseLocals(code, module_, values)
    if module_.recoverPanics {
        localGet(code, panicIndex + 1); if_(code)
        if reference(module_, function_.result) { localGet(code, frameIndex + 4); call(code, runtimeFunctionIndex(module_, 2)) }
        if function_.capturePanics {
            // Transfer the exception's owned string into Failure<string>. Class
            // values in `any` are the objects themselves, so no boxes are needed.
            failure := classByName(module_, "__doof_result_failure")
            i32(code, classSize(failure)); i32(code, tag(module_, failure.name)); call(code, runtimeFunctionIndex(module_, 0)); localSet(code, scratchIndex + 2)
            localGet(code, scratchIndex + 2); localGet(code, panicIndex); store32(code, classFieldOffset(failure, 0))
            localGet(code, scratchIndex + 2); op(code, 15)
        } else { localGet(code, panicIndex); operand(code, 8, 0) }
        end(code)
    }
    if function_.result != "none" { localGet(code, frameIndex + 4) }
    return code
}

// Layout is useful for attributing emitted bodies after implementation folding.
export class WasmEncoding {
    bytes: byte[]
    functionBodies: int[]
    definedFunctions: int
    typeCount: int
}

export function encodeDoofMinusWithLayout(input: MinusModule, debugHeap: bool = false, validated: bool = false): Result<WasmEncoding, string> {
    // Source lowering validates its own output; other callers are checked here.
    if !validated { try validateDoofMinus(input) }
    module_ := simplifyMinusInstructions(pruneDeadBlockArguments(input))
    // Keep pool order stable and reuse it throughout this encoding call.
    // Rebuilding it for every literal/global read rescans the entire module.
    live := reachableMinusFunctions(module_)
    constants := stringConstants(module_, live)
    literals := stringData(module_, constants)
    effects := analyzeMinusEffects(module_, live)
    effects.preserve = preserveReferenceLifetimes(module_)
    helpers := collectHelpers(module_, live, effects)
    helpers.effects = effects
    for index of 0..<module_.functions.length { helpers.inlinable.push(live[index] && wrapperShape(module_, effects, module_.functions[index])) }
    collectFunctionTypes(module_, helpers)
    let bodies: WasmFunctionBody[] = []
    bodies.push(WasmFunctionBody { typeIndex: helpers.typeIndexes[runtimeFunctionIndex(module_, 0)], code: body([127, 127, 127, 127, 127, 127], emitAllocator(), 2) })
    bodies.push(WasmFunctionBody { typeIndex: helpers.typeIndexes[runtimeFunctionIndex(module_, 1)], code: body([], emitRetain(), 1) })
    bodies.push(WasmFunctionBody { typeIndex: helpers.typeIndexes[runtimeFunctionIndex(module_, 2)], code: body([127, 127, 127, 127], emitRelease(module_), 1) })
    for index of 0..<module_.functions.length {
        if !live[index] { bodies.push(WasmFunctionBody { typeIndex: -1, code: [], live: false }); continue }
        function_ := module_.functions[index]
        values := allocateWasmLocals(module_, function_, effects)
        let locals: int[] = []
        for carrier of values.locals { locals.push(carrier) }
        for _ of 0..<4 { locals.push(127) } // indirect-call and panic-capture scratch
        if function_.result != "none" { locals.push(wasmType(function_.result)) } // retained return value
        if module_.recoverPanics { locals.push(127); locals.push(127) } // panic payload and flag
        bodies.push(WasmFunctionBody { typeIndex: helpers.typeIndexes[module_.imports.length + index + 3], code: body(locals, emitUserFunction(module_, function_, constants, helpers, values), function_.params.length) })
    }
    if module_.globals.length > 0 {
        bodies.push(WasmFunctionBody { typeIndex: helpers.typeIndexes[module_.imports.length + module_.functions.length + 3], code: body([], emitModuleInitializer(module_, constants), 0) })
    }
    for index of 0..<helpers.arrays.length {
        helper := helpers.arrays[index]
        let helperValues: MinusValue[] = []
        for param of helper.params { helperValues.push(param) }
        let locals: int[] = []
        if helper.instruction.result != none { helperValues.push(helper.instruction.result!); locals.push(wasmType(helper.instruction.result!.typeName)) }
        values := rawWasmLocals(helperValues)
        for _ of 0..<12 { locals.push(127) }
        let instructions: WasmInstruction[] = []
        emitArrayInstruction(instructions, module_, values, values.table.values.length, helper.instruction)
        if helper.instruction.result != none { getValue(instructions, values, "%result") }
        bodies.push(WasmFunctionBody { typeIndex: helpers.typeIndexes[helpers.typeStart + index], code: body(locals, instructions, helper.params.length) })
    }
    folded := foldWasmFunctions(bodies, module_.imports.length)
    let headers: int[] = []
    // Physical indexes appear in table elements, exports, and the start section.
    for slot of 0..<(module_.functions.length + 3) {
        logical := module_.imports.length + slot
        if folded.indexes[logical] >= 0 { headers.push(logical) }
    }
    for index of 0..<module_.functions.length {
        if module_.functions[index].exported { headers.push(module_.imports.length + index + 3) }
    }
    headers.push(runtimeFunctionIndex(module_, 0)); headers.push(runtimeFunctionIndex(module_, 2))
    if module_.globals.length > 0 { headers.push(module_.imports.length + module_.functions.length + 3) }
    plan := orderWasmFunctions(folded, module_.imports.length, headers)
    let bytes = moduleHeader(module_, constants, literals, helpers, plan, debugHeap)
    let code: int[] = []
    unsigned(code, plan.bodies.length)
    for body_ of plan.bodies {
        let resolved: int[] = []
        for value of body_.code {
            if value < 0 {
                target := plan.indexes[-value - 1]
                if target < 0 { panic("live Wasm call targets a removed function") }
                unsigned(resolved, target)
            }
            else { resolved.push(value) }
        }
        unsigned(code, resolved.length); append(code, resolved)
    }
    section(bytes, 10, code)
    if constants.length > 0 {
        let payload: int[] = [1, 0] // one active segment in memory zero
        rawI32(payload, 1024); byte_(payload, 11)
        unsigned(payload, literals.bytes.length); append(payload, literals.bytes)
        section(bytes, 11, payload)
    }
    let result: byte[] = []
    for value of bytes { result.push(byte(value)) }
    let functionBodies: int[] = []
    for index of 0..<module_.functions.length {
        physical := plan.indexes[module_.imports.length + index + 3]
        functionBodies.push(if physical < 0 then -1 else physical - module_.imports.length)
    }
    return Success(WasmEncoding { bytes: result, functionBodies, definedFunctions: plan.bodies.length, typeCount: helpers.signatures.length })
}

export function encodeDoofMinus(input: MinusModule, debugHeap: bool = false): Result<byte[], string> {
    try encoded := encodeDoofMinusWithLayout(input, debugHeap)
    return Success(encoded.bytes)
}

/** Encode a module that `validateDoofMinus` has already accepted, such as the
 * result of `lowerDoofWasmSources`, without validating it again. */
export function encodeValidatedDoofMinus(input: MinusModule, debugHeap: bool = false): Result<byte[], string> {
    try encoded := encodeDoofMinusWithLayout(input, debugHeap, true)
    return Success(encoded.bytes)
}

export function compileDoofMinus(source: string, debugHeap: bool = false): Result<byte[], string> {
    try module_ := parseDoofMinus(source)
    return encodeDoofMinus(module_, debugHeap)
}

// A leaf wrapper is one block: static-class field reads, each used once, that
// feed one non-mutating storage operation or one call to a pure function,
// whose result is returned. The wrapper's call and its reference bookkeeping
// add nothing: the loads cannot outlive the caller's borrowed arguments.
function wrapperShape(module_: MinusModule, effects: MinusEffects, function_: MinusFunction): bool {
    blocks := minusBlocks(function_)
    if blocks.length != 1 { return false }
    code := blocks[0].instructions
    if code.length < 2 || code.length > 8 { return false }
    last := code[code.length - 1]
    body := code[code.length - 2]
    if last.op != "return" || last.args.length != 1 || body.result == none || last.args[0] != body.result!.name { return false }
    if body.result!.typeName == "none" { return false }
    table := minusValues(function_)
    if body.op == "call" || body.op == "call-method" {
        target := minusCallTarget(effects, table, body)
        if target < 0 || effects.states[target] != 0 { return false }
    } else if body.op != "array-length" && body.op != "array-get" && body.op != "array-equal" && body.op != "array-compare" { return false }
    let uses: int[] = []
    for _ of table.values { uses.push(0) }
    for instruction of code { for operand of minusOperandPositions(instruction) { uses[minusValueId(table, instruction.args[operand])] += 1 } }
    for index of 0..<(code.length - 2) {
        instruction := code[index]
        if instruction.op != "get" || instruction.result == none { return false }
        if uses[minusValueId(table, instruction.result!.name)] != 1 { return false }
        owner := table.values[minusValueId(table, instruction.args[0])].typeName
        if minusValueId(effects.classes, owner) < 0 { return false }
    }
    return true
}

function inlineOperand(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, callee: MinusFunction, calleeCode: MinusInstruction[], table: MinusValues, arguments: string[], name_: string): none {
    for index of 0..<callee.params.length {
        if callee.params[index].name == name_ { getValue(code, values, arguments[index]); return }
    }
    for instruction of calleeCode {
        if instruction.result == none || instruction.result!.name != name_ { continue }
        inlineOperand(code, module_, values, callee, calleeCode, table, arguments, instruction.args[0])
        class_ := classByName(module_, table.values[minusValueId(table, instruction.args[0])].typeName)
        load(code, instruction.result!.typeName, classFieldOffset(class_, fieldIndex(class_, instruction.args[1])))
        return
    }
    panic("validated wrapper operand missing")
}

function inlineWrapper(code: WasmInstruction[], module_: MinusModule, values: WasmLocals, helpers: WasmHelpers, name_: string, instruction: MinusInstruction): bool {
    target := minusValueId(helpers.effects.functions, name_)
    if target < 0 || !helpers.inlinable[target] { return false }
    callee := module_.functions[target]
    calleeCode := minusBlocks(callee)[0].instructions
    body := calleeCode[calleeCode.length - 2]
    table := minusValues(callee)
    // Caller arguments in callee parameter order.
    let arguments: string[] = []
    start := if instruction.op == "call" then 1 else 0
    for index of start..<instruction.args.length {
        if instruction.op == "call-method" && index == 1 { continue }
        arguments.push(instruction.args[index])
    }
    for operand of minusOperandPositions(body) { inlineOperand(code, module_, values, callee, calleeCode, table, arguments, body.args[operand]) }
    if body.op == "call" { call(code, functionIndex(module_, body.args[0])) }
    else if body.op == "call-method" { call(code, functionIndex(module_, table.values[minusValueId(table, body.args[0])].typeName + "." + body.args[1])) }
    else { call(code, arrayHelperIndex(helpers, body.op, arrayElementType(module_, collectValues(callee), body))) }
    setResult(code, module_, values, instruction)
    return true
}
