import { BlobBuilder } from "std/blob"
import { Call, Drop, FuncType, F32Add, F32Const, F64Add, F64Const, I32Add, I32Const, I64Add, I64Const, Instruction, LocalGet, Module, ValueType } from "./ir"
import { validateModule } from "./validate"

// Emits a standard WebAssembly binary module. The returned bytes may be
// written directly to a .wasm file or passed to a native embedding host.
export function encodeModule(module_: Module): Result<byte[], string> {
    try validateModule(module_)
    let bytes: int[] = [0, 97, 115, 109, 1, 0, 0, 0]

    if module_.imports.length + module_.functions.length > 0 {
        let section: int[] = []
        unsignedLeb(section, module_.imports.length + module_.functions.length)
        for import_ of module_.imports { encodeType(section, import_.type_) }
        for function_ of module_.functions { encodeType(section, function_.type_) }
        appendSection(bytes, 1, section)
    }

    if module_.imports.length > 0 {
        let section: int[] = []
        unsignedLeb(section, module_.imports.length)
        for index of 0..<module_.imports.length {
            import_ := module_.imports[index]
            encodeName(section, import_.module)
            encodeName(section, import_.name)
            section.push(0) // function import
            unsignedLeb(section, index)
        }
        appendSection(bytes, 2, section)
    }

    if module_.functions.length > 0 {
        let section: int[] = []
        unsignedLeb(section, module_.functions.length)
        for index of 0..<module_.functions.length {
            unsignedLeb(section, module_.imports.length + index)
        }
        appendSection(bytes, 3, section)
    }

    if module_.exports.length > 0 {
        let section: int[] = []
        unsignedLeb(section, module_.exports.length)
        for export_ of module_.exports {
            encodeName(section, export_.name)
            section.push(0) // function export
            unsignedLeb(section, export_.functionIndex)
        }
        appendSection(bytes, 7, section)
    }

    if module_.functions.length > 0 {
        let section: int[] = []
        unsignedLeb(section, module_.functions.length)
        for function_ of module_.functions {
            let body: int[] = []
            // One local declaration per local keeps the object model simple.
            unsignedLeb(body, function_.locals.length)
            for local of function_.locals {
                unsignedLeb(body, 1)
                body.push(typeByte(local))
            }
            for instruction of function_.body { encodeInstruction(body, instruction) }
            body.push(11) // end
            unsignedLeb(section, body.length)
            append(section, body)
        }
        appendSection(bytes, 10, section)
    }

    let result: byte[] = []
    for value of bytes { result.push(byte(value)) }
    return Success(result)
}

function typeByte(type_: ValueType): int {
    case type_ {
        .I32 -> { return 127 }
        .I64 -> { return 126 }
        .F32 -> { return 125 }
        .F64 -> { return 124 }
    }
}

function encodeType(bytes: int[], type_: FuncType): none {
    bytes.push(96)
    unsignedLeb(bytes, type_.params.length)
    for param of type_.params { bytes.push(typeByte(param)) }
    unsignedLeb(bytes, type_.results.length)
    for result of type_.results { bytes.push(typeByte(result)) }
}

function encodeInstruction(bytes: int[], instruction: Instruction): none {
    case instruction {
        value: I32Const -> { bytes.push(65); signedLeb(bytes, long(value.value)) }
        value: I64Const -> { bytes.push(66); signedLeb(bytes, value.value) }
        value: F32Const -> {
            bytes.push(67)
            builder := BlobBuilder {}
            builder.writeFloat(value.value)
            for item of builder.build() { bytes.push(int(item)) }
        }
        value: F64Const -> {
            bytes.push(68)
            builder := BlobBuilder {}
            builder.writeDouble(value.value)
            for item of builder.build() { bytes.push(int(item)) }
        }
        local: LocalGet -> { bytes.push(32); unsignedLeb(bytes, local.index) }
        call: Call -> { bytes.push(16); unsignedLeb(bytes, call.functionIndex) }
        add: I32Add -> { bytes.push(106) }
        add: I64Add -> { bytes.push(124) }
        add: F32Add -> { bytes.push(146) }
        add: F64Add -> { bytes.push(160) }
        drop: Drop -> { bytes.push(26) }
    }
}

function encodeName(bytes: int[], name: string): none {
    unsignedLeb(bytes, name.length)
    for index of 0..<name.length { bytes.push(int(name[index])) }
}

function appendSection(bytes: int[], id: int, payload: int[]): none {
    bytes.push(id)
    unsignedLeb(bytes, payload.length)
    append(bytes, payload)
}

function append(bytes: int[], values: int[]): none {
    for value of values { bytes.push(value) }
}

function unsignedLeb(bytes: int[], value: int): none {
    let remaining = value
    while remaining >= 128 {
        bytes.push(remaining % 128 + 128)
        remaining = remaining \ 128
    }
    bytes.push(remaining)
}

function signedLeb(bytes: int[], value: long): none {
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
