import { BlobBuilder } from "std/blob"

// Backend emission IR. Indexes, label depths, memory arguments, and constants
// stay as logical operands until encoding; no byte decoder is needed to edit it.
// Direct-call indexes name logical functions and are relocated after folding.
export class WasmInstruction {
    opcode: int
    immediate: int = 0
    secondary: int = 0
    targets: int[] | none = none
    integer: long = 0L
    floatValue: float = 0.0f
    doubleValue: double = 0.0
}

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

/** Encode instructions to the folding buffer. Negative direct-call operands
 * remain relocation tokens; every other entry is a final byte. */
export function encodeWasmInstructions(instructions: WasmInstruction[]): int[] {
    let bytes: int[] = []
    for instruction of instructions {
        opcode := instruction.opcode
        bytes.push(opcode)
        if opcode == 16 { bytes.push(-instruction.immediate - 1) }
        else if opcode == 14 {
            if instruction.targets != none {
                targets := instruction.targets!
                unsigned(bytes, targets.length)
                for target of targets { unsigned(bytes, target) }
            } else { unsigned(bytes, 0) }
            unsigned(bytes, instruction.immediate) // default label
        }
        else if opcode == 252 {
            // Bulk memory operations on the encoder's sole linear memory.
            if instruction.immediate != 10 && instruction.immediate != 11 { panic("unsupported bulk memory opcode") }
            unsigned(bytes, instruction.immediate); unsigned(bytes, 0)
            if instruction.immediate == 10 { unsigned(bytes, 0) }
        }
        else if opcode == 17 || (opcode >= 40 && opcode <= 62) {
            unsigned(bytes, instruction.immediate); unsigned(bytes, instruction.secondary)
        }
        else if opcode == 65 || opcode == 66 { signed(bytes, instruction.integer) }
        else if opcode == 67 || opcode == 68 {
            builder := BlobBuilder {}
            if opcode == 67 { builder.writeFloat(instruction.floatValue) }
            else { builder.writeDouble(instruction.doubleValue) }
            for value of builder.build() { bytes.push(int(value)) }
        }
        else if opcode == 2 || opcode == 3 || opcode == 4 || opcode == 6 {
            // The emitter uses empty/value block types, represented by their
            // Wasm type byte. Future signature-index block types need s33.
            if instruction.immediate < 64 || instruction.immediate > 127 { panic("unsupported Wasm block type") }
            bytes.push(instruction.immediate)
        }
        else if opcode == 7 || opcode == 8 || opcode == 9 || opcode == 12 || opcode == 13 || (opcode >= 32 && opcode <= 36) || opcode == 63 || opcode == 64 {
            unsigned(bytes, instruction.immediate)
        }
        else if !(opcode == 0 || opcode == 1 || opcode == 5 || opcode == 11 || opcode == 15 || opcode == 25 || opcode == 26 || opcode == 27 || (opcode >= 69 && opcode <= 191)) {
            panic("unsupported emitted Wasm opcode: " + string(opcode))
        }
    }
    return bytes
}
