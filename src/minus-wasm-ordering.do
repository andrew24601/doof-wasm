import { WasmInstruction } from "./minus-wasm-instructions"
import { WasmFunctionPlan } from "./minus-wasm-functions"

// Stable counting buckets avoid comparator callbacks and quadratic sorting.
function frequentFirst(counts: int[]): int[] {
    let maximum = 0
    for count of counts { if count > maximum { maximum = count } }
    let heads: int[] = []
    let links: int[] = []
    for _ of 0..<(maximum + 1) { heads.push(-1) }
    for _ of counts { links.push(-1) }
    let index = counts.length - 1
    while index >= 0 {
        count := counts[index]
        links[index] = heads[count]; heads[count] = index
        index -= 1
    }
    let order: int[] = []
    let count = maximum
    while count >= 0 {
        let next = heads[count]
        while next >= 0 { order.push(next); next = links[next] }
        count -= 1
    }
    return order
}

function operandSize(value: int): int {
    let remaining = value
    let size = 1
    while remaining >= 128 { size += 1; remaining = remaining \ 128 }
    return size
}

// Indexes inside one LEB-width bank have identical operand cost. Keep their
// original relative order so nearby bodies and local patterns still compress.
function bankedOrder(counts: int[], first: int): int[] {
    ranked := frequentFirst(counts)
    let widths: int[] = []
    for _ of counts { widths.push(0) }
    let maximum = 1
    for index of 0..<ranked.length {
        width := operandSize(first + index)
        widths[ranked[index]] = width
        if width > maximum { maximum = width }
    }
    let result: int[] = []
    for width of 1..<(maximum + 1) {
        for index of 0..<widths.length { if widths[index] == width { result.push(index) } }
    }
    return result
}

function declarationSize(locals: int[]): int {
    let groups = 0
    let bytes = 0
    let start = 0
    while start < locals.length {
        let stop = start + 1
        while stop < locals.length && locals[stop] == locals[start] { stop += 1 }
        groups += 1; bytes += operandSize(stop - start) + 1
        start = stop
    }
    return bytes + operandSize(groups)
}

export class WasmLocalOrder {
    locals: int[]
    instructions: WasmInstruction[]
}

/** Keep parameters fixed and rank nonparameter locals by final access count.
 * Accept a permutation only when operand plus declaration bytes decrease. */
export function orderWasmLocals(parameters: int, locals: int[], instructions: WasmInstruction[]): WasmLocalOrder {
    original := WasmLocalOrder { locals, instructions }
    if parameters + locals.length <= 128 { return original }
    let counts: int[] = []
    for _ of locals { counts.push(0) }
    for instruction of instructions {
        if instruction.opcode >= 32 && instruction.opcode <= 34 && instruction.immediate >= parameters { counts[instruction.immediate - parameters] += 1 }
    }
    order := bankedOrder(counts, parameters)
    let mapping: int[] = []
    let reordered: int[] = []
    for _ of locals { mapping.push(-1) }
    let before = declarationSize(locals)
    for index of 0..<order.length {
        old := order[index]
        mapping[old] = parameters + index; reordered.push(locals[old])
        before += counts[old] * operandSize(parameters + old)
    }
    let after = declarationSize(reordered)
    for index of 0..<order.length { after += counts[order[index]] * operandSize(parameters + index) }
    if after >= before { return original }
    let code: WasmInstruction[] = []
    for instruction of instructions {
        if instruction.opcode >= 32 && instruction.opcode <= 34 && instruction.immediate >= parameters {
            code.push(WasmInstruction { opcode: instruction.opcode, immediate: mapping[instruction.immediate - parameters] })
        } else { code.push(instruction) }
    }
    return WasmLocalOrder { locals: reordered, instructions: code }
}

/** Rank surviving implementations after folding. Import indexes and logical
 * function/table identities stay fixed; only their physical mapping changes. */
export function orderWasmFunctions(input: WasmFunctionPlan, imports: int, headers: int[] = []): WasmFunctionPlan {
    if imports + input.bodies.length <= 128 { return input }
    let counts: int[] = []
    for _ of input.bodies { counts.push(0) }
    // The module writer supplies the actual table, export, and start operands.
    for index of headers {
        target := input.indexes[index]
        if target >= imports { counts[target - imports] += 1 }
    }
    for body of input.bodies {
        for value of body.code {
            if value >= 0 { continue }
            logical := -value - 1
            if logical < imports { continue }
            target := input.indexes[logical]
            if target < imports { panic("live call targets a removed function") }
            counts[target - imports] += 1
        }
    }
    order := bankedOrder(counts, imports)
    let before = 0
    let after = 0
    for index of 0..<order.length {
        before += counts[index] * operandSize(imports + index)
        after += counts[order[index]] * operandSize(imports + index)
    }
    if after >= before { return input }
    let mapping: int[] = []
    for _ of input.bodies { mapping.push(-1) }
    result := WasmFunctionPlan {}
    for index of 0..<order.length {
        mapping[order[index]] = imports + index
        result.bodies.push(input.bodies[order[index]])
    }
    for index of 0..<input.indexes.length {
        physical := input.indexes[index]
        if index < imports || physical < 0 { result.indexes.push(physical) }
        else { result.indexes.push(mapping[physical - imports]) }
    }
    return result
}
