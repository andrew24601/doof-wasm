import { Assert } from "std/assert"
import { WasmInstruction, encodeWasmInstructions } from "./minus-wasm-instructions"

function assertBytes(code: WasmInstruction[], expected: int[]): none {
    actual := encodeWasmInstructions(code)
    Assert.equal(actual.length, expected.length)
    for index of 0..<expected.length { Assert.equal(actual[index], expected[index]) }
}

export function testWasmInstructionsEncodeBranchTable(): none {
    assertBytes([WasmInstruction { opcode: 14, immediate: 16384, targets: [0, 127, 128] }],
        [14, 3, 0, 127, 128, 1, 128, 128, 1])
    assertBytes([WasmInstruction { opcode: 14, immediate: 0 }], [14, 0, 0])
}

export function testWasmInstructionsEncodeLogicalIndexesMemoryAndRelocations(): none {
    assertBytes([WasmInstruction { opcode: 32, immediate: 128 }, WasmInstruction { opcode: 35, immediate: 16384 },
        WasmInstruction { opcode: 40, immediate: 2, secondary: 16384 }, WasmInstruction { opcode: 16, immediate: 128 },
        WasmInstruction { opcode: 17, immediate: 128, secondary: 0 }],
        [32, 128, 1, 35, 128, 128, 1, 40, 2, 128, 128, 1, 16, -129, 17, 128, 1, 0])
    assertBytes([WasmInstruction { opcode: 2, immediate: 64 }, WasmInstruction { opcode: 4, immediate: 127 },
        WasmInstruction { opcode: 12, immediate: 128 }, WasmInstruction { opcode: 11 }, WasmInstruction { opcode: 11 }],
        [2, 64, 4, 127, 12, 128, 1, 11, 11])
}

export function testWasmInstructionsEncodeSignedAndFloatingConstants(): none {
    minimum := -9223372036854775807L - 1L
    assertBytes([WasmInstruction { opcode: 65, integer: -2147483648L }, WasmInstruction { opcode: 66, integer: minimum },
        WasmInstruction { opcode: 67, floatValue: 1.5f }, WasmInstruction { opcode: 68, doubleValue: -0.0 }],
        [65, 128, 128, 128, 128, 120, 66, 128, 128, 128, 128, 128, 128, 128, 128, 128, 127,
        67, 0, 0, 192, 63, 68, 0, 0, 0, 0, 0, 0, 0, 128])
}

export function testWasmInstructionsEncodeBulkMemoryAndWideComparison(): none {
    assertBytes([WasmInstruction { opcode: 252, immediate: 10 }, WasmInstruction { opcode: 252, immediate: 11 },
        WasmInstruction { opcode: 41, immediate: 0, secondary: 0 }, WasmInstruction { opcode: 133 },
        WasmInstruction { opcode: 122 }, WasmInstruction { opcode: 167 }],
        [252, 10, 0, 0, 252, 11, 0, 41, 0, 0, 133, 122, 167])
}
