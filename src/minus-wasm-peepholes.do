import { WasmInstruction } from "./minus-wasm-instructions"

/** Simplify the backend instruction stream before encoding and body folding.
 * Input instructions remain unchanged, including logical call identities. */
export function simplifyWasmInstructions(code: WasmInstruction[]): WasmInstruction[] {
    let result: WasmInstruction[] = []
    let labels: WasmInstruction[] = []
    let index = 0
    while index < code.length {
        instruction := code[index]
        opcode := instruction.opcode
        if opcode == 2 || opcode == 3 || opcode == 4 || opcode == 6 { labels.push(instruction) }
        if opcode == 11 { _ := try! labels.pop() }
        if opcode == 33 && index + 1 < code.length && code[index + 1].opcode == 32 && code[index + 1].immediate == instruction.immediate {
            result.push(WasmInstruction { opcode: 34, immediate: instruction.immediate })
            index += 2
            continue
        }
        if opcode == 12 {
            depth := instruction.immediate
            let fallsThrough = depth >= 0 && depth < labels.length
            if fallsThrough {
                target := labels[labels.length - depth - 1].opcode
                fallsThrough = target == 2 || target == 4 || target == 6
                for offset of 0..<(depth + 1) {
                    // Typed labels may require a stack value that a branch
                    // bypasses. A loop target repeats rather than falls through.
                    if labels[labels.length - offset - 1].immediate != 64 || index + offset + 1 >= code.length || code[index + offset + 1].opcode != 11 { fallsThrough = false; break }
                }
            }
            if fallsThrough { index += 1; continue }
        }
        result.push(instruction)
        index += 1
    }
    return result
}
