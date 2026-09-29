import { Assert } from "std/assert"
import { WasmInstruction } from "./minus-wasm-instructions"
import { WasmFunctionBody, WasmFunctionPlan } from "./minus-wasm-functions"
import { orderWasmLocals, orderWasmFunctions } from "./minus-wasm-ordering"

export function testWasmOrderingKeepsParametersAndRemapsTypedLocals(): none {
    let locals: int[] = []
    for _ of 0..<129 { locals.push(127) }
    locals.push(126)
    let code = [WasmInstruction { opcode: 32, immediate: 0 }, WasmInstruction { opcode: 32, immediate: 1 }]
    for _ of 0..<10 { code.push(WasmInstruction { opcode: 34, immediate: 131 }) }
    ordered := orderWasmLocals(2, locals, code)
    Assert.equal(ordered.locals[125], 126)
    Assert.equal(ordered.instructions[0].immediate, 0)
    Assert.equal(ordered.instructions[1].immediate, 1)
    for index of 2..<ordered.instructions.length { Assert.equal(ordered.instructions[index].immediate, 127) }
    Assert.equal(locals[129], 126)
    Assert.equal(code[2].immediate, 131)
    again := orderWasmLocals(2, ordered.locals, ordered.instructions)
    for index of 0..<ordered.locals.length { Assert.equal(again.locals[index], ordered.locals[index]) }
}

export function testWasmOrderingRejectsExtraDeclarationOverhead(): none {
    let locals: int[] = []
    for _ of 0..<128 { locals.push(127) }
    locals.push(126); locals.push(126)
    code := [WasmInstruction { opcode: 32, immediate: 129 }]
    // Promoting one wide local saves one operand byte, but splits two compact
    // declaration groups into four, costing three declaration bytes.
    ordered := orderWasmLocals(0, locals, code)
    for index of 0..<locals.length { Assert.equal(ordered.locals[index], locals[index]) }
    for index of 0..<code.length { Assert.equal(ordered.instructions[index].immediate, code[index].immediate) }
}

export function testWasmOrderingRemapsFoldedFunctionsAndKeepsImportsAndDeadSlots(): none {
    input := WasmFunctionPlan { indexes: [0, 1] }
    for index of 0..<130 {
        input.bodies.push(WasmFunctionBody { typeIndex: 0, code: [65, index % 64, 11] })
        input.indexes.push(index + 2)
    }
    input.indexes.push(131) // another logical alias of the hot body
    input.indexes.push(-1) // a removed declaration
    for _ of 0..<10 { input.bodies[0].code.push(16); input.bodies[0].code.push(-132) }
    ordered := orderWasmFunctions(input, 2)
    Assert.equal(ordered.indexes[0], 0)
    Assert.equal(ordered.indexes[1], 1)
    Assert.equal(ordered.indexes[131], 127)
    Assert.equal(ordered.indexes[132], 127)
    Assert.equal(ordered.indexes[133], -1)
    Assert.equal(input.indexes[131], 131)
    Assert.equal(input.bodies[0].code[4], -132)
    Assert.equal(ordered.bodies[125].code[1], 129 % 64)
    // Equal weights keep original body order within each operand-width bank.
    Assert.equal(ordered.indexes[2], 2)
    Assert.equal(ordered.indexes[3], 3)
}
