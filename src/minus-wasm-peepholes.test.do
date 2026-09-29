import { Assert } from "std/assert"
import { WasmInstruction, encodeWasmInstructions } from "./minus-wasm-instructions"
import { simplifyWasmInstructions } from "./minus-wasm-peepholes"

function instruction(opcode: int, immediate: int = 0): WasmInstruction => WasmInstruction { opcode, immediate }
function assertBytes(actual: int[], expected: int[]): none {
    Assert.equal(actual.length, expected.length)
    for index of 0..<expected.length { Assert.equal(actual[index], expected[index]) }
}
function assertCode(code: WasmInstruction[], expected: WasmInstruction[]): none {
    before := encodeWasmInstructions(code)
    simplified := simplifyWasmInstructions(code)
    assertBytes(encodeWasmInstructions(simplified), encodeWasmInstructions(expected))
    assertBytes(encodeWasmInstructions(code), before)
    assertBytes(encodeWasmInstructions(simplifyWasmInstructions(simplified)), encodeWasmInstructions(expected))
}

export function testWasmPeepholesFuseOnlyMatchingAdjacentLocals(): none {
    assertCode([instruction(33, 0), instruction(32, 0)], [instruction(34, 0)])
    assertCode([instruction(33, 128), instruction(32, 128)], [instruction(34, 128)])
    different := [instruction(33, 128), instruction(32, 129)]
    assertCode(different, different)
    separated := [instruction(33, 1), instruction(1), instruction(32, 1)]
    assertCode(separated, separated)
}

export function testWasmPeepholesPreserveTypedOperandsAndCallIdentities(): none {
    constants := [WasmInstruction { opcode: 65, integer: 33L }, WasmInstruction { opcode: 66, integer: 4129L },
        WasmInstruction { opcode: 67, floatValue: 33.0f }, WasmInstruction { opcode: 68, doubleValue: 32.0 },
        WasmInstruction { opcode: 40, immediate: 2, secondary: 16384 }, instruction(16, 33),
        WasmInstruction { opcode: 17, immediate: 128, secondary: 0 }]
    assertCode(constants, constants)
    paired := [instruction(16, 128), instruction(33, 16384), instruction(32, 16384)]
    assertCode(paired, [instruction(16, 128), instruction(34, 16384)])
}

export function testWasmPeepholesRemoveOnlyEmptyFallthroughExits(): none {
    assertCode([instruction(2, 64), instruction(12, 0), instruction(11)], [instruction(2, 64), instruction(11)])
    assertCode([instruction(2, 64), instruction(3, 64), instruction(12, 1), instruction(11), instruction(11)], [instruction(2, 64), instruction(3, 64), instruction(11), instruction(11)])
    backEdge := [instruction(3, 64), instruction(12, 0), instruction(11)]
    assertCode(backEdge, backEdge)
    workAfterExit := [instruction(2, 64), instruction(12, 0), instruction(1), instruction(11)]
    assertCode(workAfterExit, workAfterExit)
    conditional := [instruction(2, 64), instruction(4, 64), instruction(12, 1), instruction(5), instruction(12, 1), instruction(11), instruction(11)]
    assertCode(conditional, [instruction(2, 64), instruction(4, 64), instruction(12, 1), instruction(5), instruction(11), instruction(11)])
    typed := [instruction(2, 64), instruction(2, 127), instruction(12, 1), instruction(11), instruction(11)]
    assertCode(typed, typed)
    typedTarget := [instruction(2, 127), WasmInstruction { opcode: 65, integer: 42L }, instruction(12, 0), instruction(11)]
    assertCode(typedTarget, typedTarget)
    exception := [instruction(6, 64), instruction(2, 64), instruction(12, 0), instruction(11), instruction(7, 0), instruction(26), instruction(11)]
    assertCode(exception, [instruction(6, 64), instruction(2, 64), instruction(11), instruction(7, 0), instruction(26), instruction(11)])
}
