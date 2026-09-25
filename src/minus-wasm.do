import { BlobBuilder } from "std/blob"
import { parseDouble, parseFloat, parseInt, parseLong } from "std/parse"
import { MinusBlock, MinusClass, MinusField, MinusFunction, MinusInstruction, MinusInterface, MinusModule, MinusValue } from "./minus-ir"
import { classFieldOffset, classSize } from "./minus-layout"
import { parseDoofMinus } from "./minus-parse"
import { validateDoofMinus } from "./minus-validate"

// All class references and any boxes are i32 pointers into one Wasm memory.
// Function indices 0-2 are the allocator, retain, and release helpers.
// Runtime tag zero is reserved for free blocks. Array data is uniquely owned
// by its array and must be managed by array intrinsics, not retain/release.
readonly ARRAY_DATA_TAG = 30
readonly ANY_TAG = 31
readonly MIN_BLOCK_SIZE = 24
readonly MAX_BLOCK_SIZE = 1032
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

function reference(module_: MinusModule, typeName: string): bool {
    if typeName == "any" { return true }
    for class_ of module_.classes { if class_.name == typeName { return true } }
    for interface_ of module_.interfaces { if interface_.name == typeName { return true } }
    return false
}

function tag(module_: MinusModule, typeName: string): int {
    let names: string[] = ["none", "bool", "char", "byte", "short", "int", "long", "float", "double"]
    for index of 0..<names.length { if names[index] == typeName { return index } }
    for index of 0..<module_.classes.length { if module_.classes[index].name == typeName { return 32 + index } }
    // Enums keep nominal any-tags while using scalar i32 storage. Their tag
    // range follows class tags so reference management can identify classes.
    for index of 0..<module_.enums.length { if module_.enums[index].name == typeName { return 32 + module_.classes.length + index } }
    panic("validated type tag missing")
}

function functionIndex(module_: MinusModule, name_: string): int {
    for index of 0..<module_.imports.length { if module_.imports[index].name == name_ { return index } }
    for index of 0..<module_.functions.length { if module_.functions[index].name == name_ { return module_.imports.length + index + 3 } }
    panic("validated function missing")
}

function runtimeFunctionIndex(module_: MinusModule, index: int): int => module_.imports.length + index

function tableFunctionIndex(module_: MinusModule, name_: string): int {
    for index of 0..<module_.functions.length { if module_.functions[index].name == name_ { return index + 3 } }
    panic("validated method missing from function table")
}

function classByName(module_: MinusModule, name_: string): MinusClass {
    for class_ of module_.classes { if class_.name == name_ { return class_ } }
    panic("validated class missing")
}

function interfaceByName(module_: MinusModule, name_: string): MinusInterface {
    for interface_ of module_.interfaces { if interface_.name == name_ { return interface_ } }
    panic("validated interface missing")
}

function valueIndex(values: MinusValue[], name_: string): int {
    for index of 0..<values.length { if values[index].name == name_ { return index } }
    panic("validated value missing")
}

function valueType(values: MinusValue[], name_: string): string => values[valueIndex(values, name_)].typeName

function blockIndex(function_: MinusFunction, name_: string): int {
    for index of 0..<function_.blocks.length { if function_.blocks[index].name == name_ { return index } }
    panic("validated block missing")
}

function fieldIndex(class_: MinusClass, fieldName: string): int {
    for index of 0..<class_.fields.length { if class_.fields[index].name == fieldName { return index } }
    panic("validated field missing")
}

function op(bytes: int[], code: int): none { bytes.push(code) }
function localGet(bytes: int[], index: int): none { op(bytes, 32); unsigned(bytes, index) }
function localSet(bytes: int[], index: int): none { op(bytes, 33); unsigned(bytes, index) }
function globalGet(bytes: int[], index: int): none { op(bytes, 35); unsigned(bytes, index) }
function globalSet(bytes: int[], index: int): none { op(bytes, 36); unsigned(bytes, index) }
function call(bytes: int[], index: int): none { op(bytes, 16); unsigned(bytes, index) }
function i32(bytes: int[], value: int): none { op(bytes, 65); signed(bytes, long(value)) }
function i64(bytes: int[], value: long): none { op(bytes, 66); signed(bytes, value) }
function branch(bytes: int[], depth: int): none { op(bytes, 12); unsigned(bytes, depth) }
function branchIf(bytes: int[], depth: int): none { op(bytes, 13); unsigned(bytes, depth) }
function block(bytes: int[]): none { op(bytes, 2); op(bytes, 64) }
function loop(bytes: int[]): none { op(bytes, 3); op(bytes, 64) }
function if_(bytes: int[]): none { op(bytes, 4); op(bytes, 64) }
function end(bytes: int[]): none { op(bytes, 11) }
function load(bytes: int[], typeName: string, offset: int): none {
    let code = 40
    if typeName == "long" { code = 41 }
    if typeName == "float" { code = 42 }
    if typeName == "double" { code = 43 }
    if typeName == "bool" || typeName == "byte" || typeName == "char" { code = 45 }
    if typeName == "short" { code = 46 }
    op(bytes, code)
    unsigned(bytes, if typeName == "long" || typeName == "double" then 3 else if typeName == "short" then 1 else if typeName == "bool" || typeName == "byte" || typeName == "char" then 0 else 2)
    unsigned(bytes, offset)
}
function store(bytes: int[], typeName: string, offset: int): none {
    let code = 54
    if typeName == "long" { code = 55 }
    if typeName == "float" { code = 56 }
    if typeName == "double" { code = 57 }
    if typeName == "bool" || typeName == "byte" || typeName == "char" { code = 58 }
    if typeName == "short" { code = 59 }
    op(bytes, code)
    unsigned(bytes, if typeName == "long" || typeName == "double" then 3 else if typeName == "short" then 1 else if typeName == "bool" || typeName == "byte" || typeName == "char" then 0 else 2)
    unsigned(bytes, offset)
}
function load32(bytes: int[], offset: int): none { load(bytes, "int", offset) }
function store32(bytes: int[], offset: int): none { store(bytes, "int", offset) }
function load16Unsigned(bytes: int[], offset: int): none {
    op(bytes, 47)
    unsigned(bytes, 1)
    unsigned(bytes, offset)
}
function store16(bytes: int[], offset: int): none {
    op(bytes, 59)
    unsigned(bytes, 1)
    unsigned(bytes, offset)
}

function emitFloat(bytes: int[], value: float): none {
    builder := BlobBuilder {}
    builder.writeFloat(value)
    for item of builder.build() { bytes.push(int(item)) }
}
function emitDouble(bytes: int[], value: double): none {
    builder := BlobBuilder {}
    builder.writeDouble(value)
    for item of builder.build() { bytes.push(int(item)) }
}

function emitType(bytes: int[], params: string[], result: string): none {
    op(bytes, 96)
    unsigned(bytes, params.length)
    for typeName of params { op(bytes, wasmType(typeName)) }
    if result == "none" { unsigned(bytes, 0) } else { unsigned(bytes, 1); op(bytes, wasmType(result)) }
}

function functionTypes(module_: MinusModule): int[] {
    let bytes: int[] = []
    let constants = stringConstants(module_)
    unsigned(bytes, module_.imports.length + module_.functions.length + 3 + if constants.length > 0 then 1 else 0)
    for import_ of module_.imports {
        let params: string[] = []
        for parameter of import_.params { params.push(parameter.typeName) }
        emitType(bytes, params, import_.result)
    }
    emitType(bytes, ["int", "int"], "int") // alloc(size, tag)
    emitType(bytes, ["int"], "int")        // retain(ptr)
    emitType(bytes, ["int"], "none")       // release(ptr)
    for function_ of module_.functions {
        let params: string[] = []
        for param of function_.params { params.push(param.typeName) }
        emitType(bytes, params, function_.result)
    }
    if constants.length > 0 { emitType(bytes, [], "none") }
    return bytes
}

function emitAllocator(): int[] {
    // locals: pointer, bin-head address, next, end, spare, spare.
    // The first 256 memory bytes contain 64 heads for sizes 24 + n * 16.
    let b: int[] = []
    localGet(b, 0); i32(b, MIN_BLOCK_SIZE); op(b, 72); if_(b); op(b, 0); end(b)
    localGet(b, 0); i32(b, MAX_BLOCK_SIZE); op(b, 75); if_(b); op(b, 0); end(b)
    localGet(b, 0); i32(b, MIN_BLOCK_SIZE); op(b, 107); i32(b, 15); op(b, 113)
    if_(b); op(b, 0); end(b) // every size must be 24 + n * 16
    localGet(b, 0); i32(b, MIN_BLOCK_SIZE); op(b, 107)
    i32(b, 4); op(b, 118)
    i32(b, 2); op(b, 116); localSet(b, 3) // ((size - 24) / 16) * 4
    localGet(b, 3); load32(b, 0); localSet(b, 2)
    localGet(b, 2); op(b, 69); op(b, 69); if_(b)
    localGet(b, 2); load32(b, 4); localSet(b, 4)
    localGet(b, 3); localGet(b, 4); store32(b, 0)
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
    op(b, 63); op(b, 0); op(b, 75) // pages needed > current pages
    if_(b)
    localGet(b, 7); i32(b, 65535); op(b, 106); i32(b, 16); op(b, 118)
    op(b, 63); op(b, 0); op(b, 107) // delta pages
    op(b, 64); op(b, 0); i32(b, -1); op(b, 70); if_(b); op(b, 0); end(b)
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

function emitRetain(): int[] {
    let b: int[] = []
    localGet(b, 0); op(b, 69); if_(b); localGet(b, 0); op(b, 15); end(b)
    localGet(b, 0); load16Unsigned(b, 0); i32(b, ARRAY_DATA_TAG); op(b, 70); if_(b); op(b, 0); end(b)
    localGet(b, 0); localGet(b, 0); load32(b, 4); i32(b, 1); op(b, 106); store32(b, 4)
    localGet(b, 0)
    return b
}

function emitRelease(module_: MinusModule): int[] {
    // local 1: runtime tag; 2: wrapped class tag; 3: block size; 4: bin head.
    let b: int[] = []
    localGet(b, 0); op(b, 69); if_(b); op(b, 15); end(b)
    localGet(b, 0); load16Unsigned(b, 0); localSet(b, 1)
    localGet(b, 1); i32(b, ARRAY_DATA_TAG); op(b, 70); if_(b); op(b, 0); end(b)
    localGet(b, 0); localGet(b, 0); load32(b, 4); i32(b, 1); op(b, 107); store32(b, 4)
    localGet(b, 0); load32(b, 4); op(b, 69); op(b, 69); if_(b); op(b, 15); end(b)
    localGet(b, 1); i32(b, ANY_TAG); op(b, 70); if_(b)
    localGet(b, 0); load16Unsigned(b, 8); localSet(b, 2)
    for index of 0..<module_.classes.length {
        localGet(b, 2); i32(b, 32 + index); op(b, 70); if_(b)
        localGet(b, 0); load32(b, 16); call(b, runtimeFunctionIndex(module_, 2))
        end(b)
    }
    end(b)
    for index of 0..<module_.classes.length {
        class_ := module_.classes[index]
        let hasReferences = false
        for field of class_.fields { if reference(module_, field.typeName) { hasReferences = true } }
        if !hasReferences && class_.finalizer == "" { continue }
        localGet(b, 1); i32(b, 32 + index); op(b, 70); if_(b)
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
        end(b)
    }
    localGet(b, 0); load16Unsigned(b, 2); localSet(b, 3)
    localGet(b, 3); i32(b, MIN_BLOCK_SIZE); op(b, 107)
    i32(b, 4); op(b, 118)
    i32(b, 2); op(b, 116); localSet(b, 4)
    localGet(b, 0); i32(b, 0); store16(b, 0)
    localGet(b, 0); localGet(b, 4); load32(b, 0); store32(b, 4)
    localGet(b, 4); localGet(b, 0); store32(b, 0)
    return b
}

function arrayWidth(typeName: string): int {
    if typeName == "bool" || typeName == "byte" || typeName == "char" { return 1 }
    if typeName == "short" { return 2 }
    if typeName == "long" || typeName == "double" { return 8 }
    return 4
}

function arrayLoadCode(typeName: string): int {
    if typeName == "bool" || typeName == "byte" || typeName == "char" { return 45 }
    if typeName == "short" { return 46 }
    if typeName == "long" { return 41 }
    if typeName == "float" { return 42 }
    if typeName == "double" { return 43 }
    return 40
}

function arrayStoreCode(typeName: string): int {
    if typeName == "bool" || typeName == "byte" || typeName == "char" { return 58 }
    if typeName == "short" { return 59 }
    if typeName == "long" { return 55 }
    if typeName == "float" { return 56 }
    if typeName == "double" { return 57 }
    return 54
}

function arrayAddress(bytes: int[], values: MinusValue[], handle: string, index: string, typeName: string): none {
    getValue(bytes, values, handle)
    i32(bytes, 8); op(bytes, 106)
    getValue(bytes, values, index)
    width := arrayWidth(typeName)
    if width == 2 { i32(bytes, 1); op(bytes, 116) }
    if width == 4 { i32(bytes, 2); op(bytes, 116) }
    if width == 8 { i32(bytes, 3); op(bytes, 116) }
    op(bytes, 106)
}

function checkArrayBounds(bytes: int[], values: MinusValue[], handle: string, index: string): none {
    getValue(bytes, values, handle); load16Unsigned(bytes, 0); i32(bytes, ARRAY_DATA_TAG); op(bytes, 71); if_(bytes); op(bytes, 0); end(bytes)
    getValue(bytes, values, index); i32(bytes, 0); op(bytes, 72); if_(bytes); op(bytes, 0); end(bytes)
    getValue(bytes, values, index); getValue(bytes, values, handle); load32(bytes, 4); op(bytes, 78); if_(bytes); op(bytes, 0); end(bytes)
}

function emitArrayInstruction(bytes: int[], module_: MinusModule, values: MinusValue[], scratchIndex: int, instruction: MinusInstruction): none {
    args := instruction.args
    if instruction.op == "array-alloc" {
        typeName := args[1]
        width := arrayWidth(typeName)
        getValue(bytes, values, args[0]); i32(bytes, 0); op(bytes, 72); if_(bytes); op(bytes, 0); end(bytes)
        getValue(bytes, values, args[0]); i32(bytes, 1024 \ width); op(bytes, 74); if_(bytes); op(bytes, 0); end(bytes)
        getValue(bytes, values, args[0]); i32(bytes, width); op(bytes, 108); localSet(bytes, scratchIndex)
        localGet(bytes, scratchIndex); i32(bytes, 16); op(bytes, 75); if_(bytes)
        localGet(bytes, scratchIndex); i32(bytes, 16); op(bytes, 107); i32(bytes, 15); op(bytes, 106); i32(bytes, 16); op(bytes, 110); i32(bytes, 16); op(bytes, 108); i32(bytes, 24); op(bytes, 106); localSet(bytes, scratchIndex)
        op(bytes, 5); i32(bytes, 24); localSet(bytes, scratchIndex)
        end(bytes)
        localGet(bytes, scratchIndex); i32(bytes, ARRAY_DATA_TAG); call(bytes, runtimeFunctionIndex(module_, 0)); localSet(bytes, scratchIndex)
        localGet(bytes, scratchIndex); getValue(bytes, values, args[0]); store32(bytes, 4)
        localGet(bytes, scratchIndex); setResult(bytes, module_, values, instruction)
        return
    }
    if instruction.op == "array-free" {
        getValue(bytes, values, args[0]); load16Unsigned(bytes, 0); i32(bytes, ARRAY_DATA_TAG); op(bytes, 71); if_(bytes); op(bytes, 0); end(bytes)
        getValue(bytes, values, args[0]); load16Unsigned(bytes, 2); i32(bytes, MIN_BLOCK_SIZE); op(bytes, 107); i32(bytes, 4); op(bytes, 118); i32(bytes, 2); op(bytes, 116); localSet(bytes, scratchIndex)
        getValue(bytes, values, args[0]); i32(bytes, 0); store16(bytes, 0)
        getValue(bytes, values, args[0]); localGet(bytes, scratchIndex); load32(bytes, 0); store32(bytes, 4)
        localGet(bytes, scratchIndex); getValue(bytes, values, args[0]); store32(bytes, 0)
        return
    }
    if instruction.op == "array-length" {
        getValue(bytes, values, args[0]); load16Unsigned(bytes, 0); i32(bytes, ARRAY_DATA_TAG); op(bytes, 71); if_(bytes); op(bytes, 0); end(bytes)
        getValue(bytes, values, args[0]); load32(bytes, 4); setResult(bytes, module_, values, instruction)
        return
    }
    typeName := if instruction.op == "array-get" then instruction.result!.typeName else valueType(values, args[2])
    checkArrayBounds(bytes, values, args[0], args[1])
    if instruction.op == "array-get" {
        arrayAddress(bytes, values, args[0], args[1], typeName)
        op(bytes, arrayLoadCode(typeName)); unsigned(bytes, if typeName == "long" || typeName == "double" then 3 else if typeName == "short" then 1 else if typeName == "byte" || typeName == "bool" || typeName == "char" then 0 else 2); unsigned(bytes, 8)
        setResult(bytes, module_, values, instruction)
        return
    }
    arrayAddress(bytes, values, args[0], args[1], typeName)
    getValue(bytes, values, args[2])
    op(bytes, arrayStoreCode(typeName)); unsigned(bytes, if typeName == "long" || typeName == "double" then 3 else if typeName == "short" then 1 else if typeName == "byte" || typeName == "bool" || typeName == "char" then 0 else 2); unsigned(bytes, 8)
}

function body(bytes: int[], locals: int[], instructions: int[]): none {
    let result: int[] = []
    unsigned(result, locals.length)
    for typeCode of locals { unsigned(result, 1); op(result, typeCode) }
    append(result, instructions)
    end(result)
    unsigned(bytes, result.length)
    append(bytes, result)
}

function moduleHeader(module_: MinusModule, debugHeap: bool = false): int[] {
    let bytes: int[] = [0, 97, 115, 109, 1, 0, 0, 0]
    constants := stringConstants(module_)
    let hasStringInitializer = constants.length > 0
    section(bytes, 1, functionTypes(module_))
    if module_.imports.length > 0 {
        let imports: int[] = []
        unsigned(imports, module_.imports.length)
        for index of 0..<module_.imports.length {
            import_ := module_.imports[index]
            name(imports, import_.importModule)
            name(imports, import_.importName)
            op(imports, 0)
            unsigned(imports, index)
        }
        section(bytes, 2, imports)
    }
    let functions: int[] = []
    unsigned(functions, module_.functions.length + 3 + if hasStringInitializer then 1 else 0)
    for index of 0..<(module_.functions.length + 3) { unsigned(functions, module_.imports.length + index) }
    if hasStringInitializer { unsigned(functions, module_.imports.length + module_.functions.length + 3) }
    section(bytes, 3, functions)
    let table: int[] = [1, 112, 0]
    unsigned(table, module_.functions.length + 3)
    section(bytes, 4, table)
    section(bytes, 5, [1, 0, 1]) // one memory, minimum one page
    let globals: int[] = []
    unsigned(globals, constants.length + 1)
    op(globals, 127); op(globals, 1); i32(globals, 1024); end(globals) // heap cursor
    for _ of constants {
        op(globals, 127); op(globals, 1); i32(globals, 0); end(globals)
    }
    section(bytes, 6, globals)
    let exports: int[] = []
    let count = 0
    for function_ of module_.functions { if function_.exported { count += 1 } }
    unsigned(exports, count + 3 + if debugHeap then 1 else 0)
    for index of 0..<module_.functions.length {
        function_ := module_.functions[index]
        if !function_.exported { continue }
        name(exports, if function_.exportName == "" then function_.name else function_.exportName)
        op(exports, 0)
        unsigned(exports, module_.imports.length + index + 3)
    }
    name(exports, "__doof_ffi_alloc"); op(exports, 0); unsigned(exports, runtimeFunctionIndex(module_, 0))
    name(exports, "__doof_ffi_release"); op(exports, 0); unsigned(exports, runtimeFunctionIndex(module_, 2))
    name(exports, "__doof_ffi_memory"); op(exports, 2); unsigned(exports, 0)
    if debugHeap {
        name(exports, "__doof_debug_heap_end"); op(exports, 3); unsigned(exports, 0)
    }
    section(bytes, 7, exports)
    if hasStringInitializer {
        let start: int[] = []
        unsigned(start, module_.imports.length + module_.functions.length + 3)
        section(bytes, 8, start)
    }
    let elements: int[] = [1, 0]
    i32(elements, 0); end(elements)
    unsigned(elements, module_.functions.length + 3)
    for index of 0..<(module_.functions.length + 3) { unsigned(elements, module_.imports.length + index) }
    section(bytes, 9, elements)
    return bytes
}

function collectValues(function_: MinusFunction): MinusValue[] {
    let values: MinusValue[] = []
    for value of function_.params { values.push(value) }
    for block_ of function_.blocks {
        for value of block_.params { values.push(value) }
        for instruction of block_.instructions { if instruction.result != none { values.push(instruction.result!) } }
    }
    return values
}

function resultIndex(values: MinusValue[], instruction: MinusInstruction): int => valueIndex(values, instruction.result!.name)
function getValue(bytes: int[], values: MinusValue[], name_: string): none { localGet(bytes, valueIndex(values, name_)) }

function stringConstants(module_: MinusModule): string[] {
    let result: string[] = []
    for function_ of module_.functions {
        for block_ of function_.blocks {
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

function arrayDataBlockSize(length: int): int {
    let size = 24
    if length > 16 { size = 24 + ((length - 16 + 15) \ 16) * 16 }
    return size
}

function emitStringPoolInitializer(module_: MinusModule, constants: string[]): int[] {
    let bytes: int[] = []
    let charArray = classByName(module_, "__doof_array_char")
    let stringClass = classByName(module_, "__doof_string")
    let charDataField = fieldIndex(charArray, "data")
    let stringCharsField = fieldIndex(stringClass, "chars")
    for index of 0..<constants.length {
        value := constants[index]
        // Build the char[] backing block. Array-data blocks keep their length
        // in the header and their elements immediately after the 8-byte header.
        i32(bytes, arrayDataBlockSize(value.length)); i32(bytes, ARRAY_DATA_TAG); call(bytes, runtimeFunctionIndex(module_, 0)); localSet(bytes, 0)
        localGet(bytes, 0); i32(bytes, value.length); store32(bytes, 4)
        for charIndex of 0..<value.length {
            localGet(bytes, 0); i32(bytes, int(value[charIndex])); store(bytes, "char", 8 + charIndex)
        }

        // The char[] wrapper takes ownership of the backing data block.
        i32(bytes, classSize(charArray)); i32(bytes, tag(module_, charArray.name)); call(bytes, runtimeFunctionIndex(module_, 0)); localSet(bytes, 1)
        localGet(bytes, 1); i32(bytes, 1); store32(bytes, 4)
        localGet(bytes, 1); localGet(bytes, 0); store(bytes, "int", classFieldOffset(charArray, charDataField))

        // Construct the string wrapper. Its chars field owns a retained ref;
        // release the initializer's temporary wrapper ref after storing it.
        i32(bytes, classSize(stringClass)); i32(bytes, tag(module_, stringClass.name)); call(bytes, runtimeFunctionIndex(module_, 0)); localSet(bytes, 2)
        localGet(bytes, 2); i32(bytes, 1); store32(bytes, 4)
        localGet(bytes, 1); call(bytes, runtimeFunctionIndex(module_, 1)); op(bytes, 26)
        localGet(bytes, 2); localGet(bytes, 1); store(bytes, stringClass.fields[stringCharsField].typeName, classFieldOffset(stringClass, stringCharsField))
        localGet(bytes, 2); globalSet(bytes, index + 1)
        localGet(bytes, 1); call(bytes, runtimeFunctionIndex(module_, 2))
    }
    return bytes
}

function setResult(bytes: int[], module_: MinusModule, values: MinusValue[], instruction: MinusInstruction): none {
    index := resultIndex(values, instruction)
    if reference(module_, instruction.result!.typeName) { localGet(bytes, index); call(bytes, runtimeFunctionIndex(module_, 2)) }
    localSet(bytes, index)
}

function retainTop(bytes: int[], module_: MinusModule, typeName: string): none {
    if reference(module_, typeName) { call(bytes, runtimeFunctionIndex(module_, 1)) }
}

function normalize(bytes: int[], typeName: string): none {
    if typeName == "byte" { i32(bytes, 255); op(bytes, 113) }
    if typeName == "short" { i32(bytes, 16); op(bytes, 116); i32(bytes, 16); op(bytes, 117) }
}

function emitConstant(bytes: int[], instruction: MinusInstruction): none {
    typeName := instruction.result!.typeName
    value := instruction.args[0]
    if typeName == "long" { i64(bytes, parseLong(value)!) }
    else if typeName == "float" { op(bytes, 67); emitFloat(bytes, parseFloat(value)!) }
    else if typeName == "double" { op(bytes, 68); emitDouble(bytes, parseDouble(value)!) }
    else if typeName == "none" { i32(bytes, 0) }
    else if typeName == "bool" { i32(bytes, if value == "true" then 1 else 0) }
    else { i32(bytes, parseInt(value)!) }
}

function arithmeticCode(typeName: string, operation: string): int {
    if typeName == "long" {
        if operation == "add" { return 124 }
        if operation == "sub" { return 125 }
        if operation == "mul" { return 126 }
        if operation == "div" { return 127 }
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
    if operation == "eq" { return 70 }
    return if typeName == "byte" || typeName == "char" then 73 else 72
}

function emitNumericConversion(bytes: int[], source: string, target: string): none {
    sourceWasm := wasmType(source)
    targetWasm := wasmType(target)
    if sourceWasm != targetWasm {
        let code = 0
        if sourceWasm == 127 {
            if targetWasm == 126 { code = if source == "byte" then 173 else 172 }
            if targetWasm == 125 { code = if source == "byte" then 179 else 178 }
            if targetWasm == 124 { code = if source == "byte" then 184 else 183 }
        }
        if sourceWasm == 126 {
            if targetWasm == 127 { code = 167 }
            if targetWasm == 125 { code = 180 }
            if targetWasm == 124 { code = 185 }
        }
        if sourceWasm == 125 {
            if targetWasm == 127 { code = 168 }
            if targetWasm == 126 { code = 174 }
            if targetWasm == 124 { code = 187 }
        }
        if sourceWasm == 124 {
            if targetWasm == 127 { code = 170 }
            if targetWasm == 126 { code = 176 }
            if targetWasm == 125 { code = 182 }
        }
        op(bytes, code)
    }
    normalize(bytes, target)
}

function emitReleaseLocals(bytes: int[], module_: MinusModule, values: MinusValue[]): none {
    for index of 0..<values.length {
        if reference(module_, values[index].typeName) { localGet(bytes, index); call(bytes, runtimeFunctionIndex(module_, 2)) }
    }
}

function emitEdge(bytes: int[], module_: MinusModule, function_: MinusFunction, values: MinusValue[], target: string, arguments: string[], pcIndex: int, branchDepth: int): none {
    block_ := function_.blocks[blockIndex(function_, target)]
    // Retain all incoming references before overwriting any block parameter.
    for arg of arguments {
        getValue(bytes, values, arg)
        retainTop(bytes, module_, valueType(values, arg))
    }
    for param of block_.params {
        if reference(module_, param.typeName) { localGet(bytes, valueIndex(values, param.name)); call(bytes, runtimeFunctionIndex(module_, 2)) }
    }
    let index = block_.params.length - 1
    while index >= 0 { localSet(bytes, valueIndex(values, block_.params[index].name)); index -= 1 }
    i32(bytes, blockIndex(function_, target)); localSet(bytes, pcIndex)
    branch(bytes, branchDepth)
}

function emitReturn(bytes: int[], module_: MinusModule, function_: MinusFunction, values: MinusValue[], instruction: MinusInstruction): none {
    if instruction.args.length > 0 && function_.result != "none" {
        getValue(bytes, values, instruction.args[0])
        retainTop(bytes, module_, function_.result)
    }
    emitReleaseLocals(bytes, module_, values)
    op(bytes, 15)
}

function emitDynamicField(bytes: int[], module_: MinusModule, values: MinusValue[], instruction: MinusInstruction, ownerType: string): none {
    // A block around the cases gives every successful case one exit target.
    block(bytes)
    let cases = 0
    for class_ of module_.classes {
        if !class_.interfaces.contains(ownerType) { continue }
        cases += 1
        getValue(bytes, values, instruction.args[0]); load16Unsigned(bytes, 0)
        i32(bytes, tag(module_, class_.name)); op(bytes, 70); if_(bytes)
        offset := classFieldOffset(class_, fieldIndex(class_, instruction.args[1]))
        if instruction.op == "get" {
            if instruction.result!.typeName == "none" { i32(bytes, 0) }
            else { getValue(bytes, values, instruction.args[0]); load(bytes, instruction.result!.typeName, offset) }
            retainTop(bytes, module_, instruction.result!.typeName)
            setResult(bytes, module_, values, instruction)
        } else {
            fieldType := valueType(values, instruction.args[2])
            if reference(module_, fieldType) {
                getValue(bytes, values, instruction.args[0]); load32(bytes, offset); call(bytes, runtimeFunctionIndex(module_, 2))
            }
            if fieldType != "none" {
                getValue(bytes, values, instruction.args[0]); getValue(bytes, values, instruction.args[2])
                retainTop(bytes, module_, fieldType)
                store(bytes, fieldType, offset)
            }
        }
        branch(bytes, 1); end(bytes)
    }
    if cases == 0 { op(bytes, 0) } else { op(bytes, 0) }
    end(bytes)
}

function emitField(bytes: int[], module_: MinusModule, values: MinusValue[], instruction: MinusInstruction): none {
    ownerType := valueType(values, instruction.args[0])
    let interface_ = false
    for item of module_.interfaces { if item.name == ownerType { interface_ = true } }
    if interface_ { emitDynamicField(bytes, module_, values, instruction, ownerType); return }
    class_ := classByName(module_, ownerType)
    offset := classFieldOffset(class_, fieldIndex(class_, instruction.args[1]))
    if instruction.op == "get" {
        if instruction.result!.typeName == "none" { i32(bytes, 0) }
        else { getValue(bytes, values, instruction.args[0]); load(bytes, instruction.result!.typeName, offset) }
        retainTop(bytes, module_, instruction.result!.typeName)
        setResult(bytes, module_, values, instruction)
    } else {
        fieldType := valueType(values, instruction.args[2])
        if reference(module_, fieldType) { getValue(bytes, values, instruction.args[0]); load32(bytes, offset); call(bytes, runtimeFunctionIndex(module_, 2)) }
        if fieldType != "none" {
            getValue(bytes, values, instruction.args[0]); getValue(bytes, values, instruction.args[2])
            retainTop(bytes, module_, fieldType)
            store(bytes, fieldType, offset)
        }
    }
}

function emitCall(bytes: int[], module_: MinusModule, values: MinusValue[], scratchIndex: int, instruction: MinusInstruction): none {
    args := instruction.args
    if instruction.op == "call" {
        for index of 1..<args.length { getValue(bytes, values, args[index]) }
        call(bytes, functionIndex(module_, args[0]))
        if instruction.result!.typeName == "none" { i32(bytes, 0) }
        setResult(bytes, module_, values, instruction)
        return
    }
    ownerType := valueType(values, args[0])
    let interface_ = false
    for item of module_.interfaces { if item.name == ownerType { interface_ = true } }
    if !interface_ {
        getValue(bytes, values, args[0])
        for index of 2..<args.length { getValue(bytes, values, args[index]) }
        call(bytes, functionIndex(module_, ownerType + "." + args[1]))
        if instruction.result!.typeName == "none" { i32(bytes, 0) }
        setResult(bytes, module_, values, instruction)
        return
    }
    i32(bytes, -1); localSet(bytes, scratchIndex)
    let signatureIndex = -1
    for class_ of module_.classes {
        if !class_.interfaces.contains(ownerType) { continue }
        methodIndex := tableFunctionIndex(module_, class_.name + "." + args[1])
        if signatureIndex < 0 { signatureIndex = methodIndex }
        getValue(bytes, values, args[0]); load16Unsigned(bytes, 0)
        i32(bytes, tag(module_, class_.name)); op(bytes, 70); if_(bytes)
        i32(bytes, methodIndex); localSet(bytes, scratchIndex)
        end(bytes)
    }
    if signatureIndex < 0 { op(bytes, 0); return }
    getValue(bytes, values, args[0])
    for index of 2..<args.length { getValue(bytes, values, args[index]) }
    localGet(bytes, scratchIndex)
    op(bytes, 17); unsigned(bytes, signatureIndex); unsigned(bytes, 0)
    if instruction.result!.typeName == "none" { i32(bytes, 0) }
    setResult(bytes, module_, values, instruction)
}

function emitNew(bytes: int[], module_: MinusModule, values: MinusValue[], instruction: MinusInstruction): none {
    class_ := classByName(module_, instruction.args[0])
    i32(bytes, classSize(class_))
    i32(bytes, tag(module_, class_.name))
    call(bytes, runtimeFunctionIndex(module_, 0))
    setResult(bytes, module_, values, instruction)
    for index of 0..<class_.fields.length {
        typeName := class_.fields[index].typeName
        if typeName == "none" { continue }
        localGet(bytes, resultIndex(values, instruction))
        getValue(bytes, values, instruction.args[index + 1])
        retainTop(bytes, module_, typeName)
        store(bytes, typeName, classFieldOffset(class_, index))
    }
}

function emitBox(bytes: int[], module_: MinusModule, values: MinusValue[], instruction: MinusInstruction): none {
    sourceType := valueType(values, instruction.args[0])
    i32(bytes, 24); i32(bytes, ANY_TAG); call(bytes, runtimeFunctionIndex(module_, 0))
    setResult(bytes, module_, values, instruction)
    localGet(bytes, resultIndex(values, instruction)); i32(bytes, tag(module_, sourceType)); store16(bytes, 8)
    if sourceType != "none" {
        localGet(bytes, resultIndex(values, instruction))
        getValue(bytes, values, instruction.args[0])
        retainTop(bytes, module_, sourceType)
        store(bytes, sourceType, 16)
    }
}

function emitTagOperation(bytes: int[], module_: MinusModule, values: MinusValue[], instruction: MinusInstruction): none {
    getValue(bytes, values, instruction.args[0]); load16Unsigned(bytes, 8)
    i32(bytes, tag(module_, instruction.args[1])); op(bytes, 70)
    if instruction.op == "is" { setResult(bytes, module_, values, instruction); return }
    op(bytes, 69); if_(bytes); op(bytes, 0); end(bytes) // checked cast
    if instruction.result!.typeName == "none" { i32(bytes, 0) }
    else {
        getValue(bytes, values, instruction.args[0])
        load(bytes, instruction.result!.typeName, 16)
        retainTop(bytes, module_, instruction.result!.typeName)
    }
    setResult(bytes, module_, values, instruction)
}

function emitInstruction(bytes: int[], module_: MinusModule, function_: MinusFunction, values: MinusValue[], pcIndex: int, scratchIndex: int, instruction: MinusInstruction): none {
    operation := instruction.op
    args := instruction.args
    if operation == "panic" { op(bytes, 0); return }
    if operation == "string-const" {
        constants := stringConstants(module_)
        globalGet(bytes, stringConstantIndex(constants, args[0]) + 1)
        call(bytes, runtimeFunctionIndex(module_, 1))
        setResult(bytes, module_, values, instruction)
        return
    }
    if operation == "const" { emitConstant(bytes, instruction); setResult(bytes, module_, values, instruction); return }
    if ["add", "sub", "mul", "div", "eq", "lt"].contains(operation) {
        getValue(bytes, values, args[0]); getValue(bytes, values, args[1])
        typeName := valueType(values, args[0])
        op(bytes, arithmeticCode(typeName, operation))
        if operation != "eq" && operation != "lt" { normalize(bytes, typeName) }
        setResult(bytes, module_, values, instruction)
        return
    }
    if operation == "convert" {
        getValue(bytes, values, args[0])
        emitNumericConversion(bytes, valueType(values, args[0]), instruction.result!.typeName)
        setResult(bytes, module_, values, instruction)
        return
    }
    if operation == "copy" || operation == "as" {
        getValue(bytes, values, args[0])
        retainTop(bytes, module_, instruction.result!.typeName)
        setResult(bytes, module_, values, instruction)
        return
    }
    if operation == "new" { emitNew(bytes, module_, values, instruction); return }
    if ["array-alloc", "array-free", "array-length", "array-get", "array-set"].contains(operation) { emitArrayInstruction(bytes, module_, values, scratchIndex, instruction); return }
    if operation == "get" || operation == "set" { emitField(bytes, module_, values, instruction); return }
    if operation == "call" || operation == "call-method" { emitCall(bytes, module_, values, scratchIndex, instruction); return }
    if operation == "box" { emitBox(bytes, module_, values, instruction); return }
    if operation == "is" || operation == "cast" { emitTagOperation(bytes, module_, values, instruction); return }
    if operation == "return" { emitReturn(bytes, module_, function_, values, instruction); return }
    if operation == "jump" { emitEdge(bytes, module_, function_, values, args[0], args.slice(1, args.length), pcIndex, 1); return }
    if operation == "branch" {
        let split = 0
        for index of 0..<args.length { if args[index] == "|" { split = index; break } }
        let thenArgs: string[] = []
        for index of 2..<split { thenArgs.push(args[index]) }
        let elseArgs: string[] = []
        for index of (split + 2)..<args.length { elseArgs.push(args[index]) }
        getValue(bytes, values, args[0]); if_(bytes)
        emitEdge(bytes, module_, function_, values, args[1], thenArgs, pcIndex, 2)
        op(bytes, 5)
        emitEdge(bytes, module_, function_, values, args[split + 1], elseArgs, pcIndex, 2)
        end(bytes)
        return
    }
}

function emitUserFunction(module_: MinusModule, function_: MinusFunction): int[] {
    values := collectValues(function_)
    pcIndex := values.length
    scratchIndex := pcIndex + 1
    let bytes: int[] = []
    for index of 0..<function_.params.length {
        typeName := function_.params[index].typeName
        if reference(module_, typeName) { localGet(bytes, index); call(bytes, runtimeFunctionIndex(module_, 1)); localSet(bytes, index) }
        if typeName == "byte" || typeName == "short" {
            localGet(bytes, index); normalize(bytes, typeName); localSet(bytes, index)
        }
        if typeName == "bool" {
            localGet(bytes, index); op(bytes, 69); op(bytes, 69); localSet(bytes, index)
        }
        if typeName == "none" { i32(bytes, 0); localSet(bytes, index) }
        if typeName == "char" { localGet(bytes, index); i32(bytes, 255); op(bytes, 75); if_(bytes); op(bytes, 0); end(bytes) }
    }
    i32(bytes, 0); localSet(bytes, pcIndex)
    block(bytes); loop(bytes)
    for index of 0..<function_.blocks.length {
        block_ := function_.blocks[index]
        localGet(bytes, pcIndex); i32(bytes, index); op(bytes, 70); if_(bytes)
        for instruction of block_.instructions { emitInstruction(bytes, module_, function_, values, pcIndex, scratchIndex, instruction) }
        end(bytes)
    }
    op(bytes, 0) // invalid program counter
    end(bytes); end(bytes)
    op(bytes, 0)
    return bytes
}

export function encodeDoofMinus(module_: MinusModule, debugHeap: bool = false): Result<byte[], string> {
    try validateDoofMinus(module_)
    let bytes = moduleHeader(module_, debugHeap)
    constants := stringConstants(module_)
    let code: int[] = []
    unsigned(code, module_.functions.length + 3 + if constants.length > 0 then 1 else 0)
    body(code, [127, 127, 127, 127, 127, 127], emitAllocator())
    body(code, [], emitRetain())
    body(code, [127, 127, 127, 127], emitRelease(module_))
    for function_ of module_.functions {
        values := collectValues(function_)
        let locals: int[] = []
        for index of function_.params.length..<values.length { locals.push(wasmType(values[index].typeName)) }
        locals.push(127) // program counter
        locals.push(127) // indirect-call table index
        body(code, locals, emitUserFunction(module_, function_))
    }
    if constants.length > 0 { body(code, [127, 127, 127], emitStringPoolInitializer(module_, constants)) }
    section(bytes, 10, code)
    let result: byte[] = []
    for value of bytes { result.push(byte(value)) }
    return Success(result)
}

export function compileDoofMinus(source: string, debugHeap: bool = false): Result<byte[], string> {
    try module_ := parseDoofMinus(source)
    return encodeDoofMinus(module_, debugHeap)
}
