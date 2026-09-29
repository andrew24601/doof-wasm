import { parseLong } from "std/parse"
import { MinusBlock, MinusFunction, MinusInstruction, MinusModule, MinusRegion } from "./minus-ir"
import { minusBlocks, minusBranchSplit } from "./minus-control-flow"
import { MinusValues, minusValues, minusValueId, minusOperandPositions, minusReferenceType } from "./minus-analysis"
import { pruneDeadBlockArguments } from "./minus-optimize"

function integerType(typeName: string): bool => (typeName == "int" || typeName == "byte" || typeName == "char" || typeName == "bool" || typeName == "long" || typeName == "none")

function constantValue(literal: string, typeName: string): long {
    if typeName == "bool" { return if literal == "true" then 1L else 0L }
    if typeName == "none" { return 0L }
    return try! parseLong(literal)
}

function foldConstant(instruction: MinusInstruction, table: MinusValues, constants: string[]): MinusInstruction {
    if instruction.result == none || instruction.args.length == 0 { return instruction }
    op := instruction.op
    if !(op == "add" || op == "sub" || op == "mul" || op == "div" || op == "rem" || op == "eq" || op == "lt" || op == "convert") { return instruction }
    left := minusValueId(table, instruction.args[0])
    sourceType := table.values[left].typeName
    if !integerType(sourceType) || constants[left] == "" { return instruction }
    a := constantValue(constants[left], sourceType)
    let value = a
    if op != "convert" {
        right := minusValueId(table, instruction.args[1])
        if constants[right] == "" { return instruction }
        b := constantValue(constants[right], sourceType)
        if op == "eq" || op == "lt" {
            condition := if op == "eq" then a == b else a < b
            return MinusInstruction { op: "const", args: [if condition then "true" else "false"], result: instruction.result, line: instruction.line, sourcePath: instruction.sourcePath }
        }
        // Leave wide arithmetic to Wasm; folding must never overflow natively.
        if sourceType == "long" { return instruction }
        if (op == "div" || op == "rem") && b == 0L { return instruction }
        if op == "div" && sourceType == "int" && a == -2147483648L && b == -1L { return instruction }
        if op == "add" { value = a + b }
        if op == "sub" { value = a - b }
        if op == "mul" { value = a * b }
        if op == "div" { value = a \ b }
        if op == "rem" { value = a % b }
    }
    targetType := instruction.result!.typeName
    if !integerType(targetType) { return instruction }
    if targetType == "byte" { value = (value % 256L + 256L) % 256L }
    if targetType == "int" { value = long(int(value)) }
    return MinusInstruction { op: "const", args: [string(value)], result: instruction.result, line: instruction.line, sourcePath: instruction.sourcePath }
}

function pureScalar(module_: MinusModule, instruction: MinusInstruction, table: MinusValues): bool {
    if instruction.result == none || minusReferenceType(module_, instruction.result!.typeName) { return false }
    if (instruction.op == "const" || instruction.op == "copy" || instruction.op == "add" || instruction.op == "sub" || instruction.op == "mul") { return true }
    if instruction.op == "eq" || instruction.op == "lt" {
        return !minusReferenceType(module_, table.values[minusValueId(table, instruction.args[0])].typeName)
    }
    if instruction.op == "convert" {
        source := table.values[minusValueId(table, instruction.args[0])].typeName
        target := instruction.result!.typeName
        return !((source == "float" || source == "double") && (target == "int" || target == "byte" || target == "long"))
    }
    return false
}

function rebuild(region: MinusRegion, blocks: MinusBlock[]): MinusRegion {
    let children: MinusRegion[] = []
    for child of region.children { children.push(rebuild(child, blocks)) }
    let code: MinusBlock | none = none
    if region.code != none { for block_ of blocks { if block_.name == region.label { code = block_; break } } }
    return MinusRegion { kind: region.kind, label: region.label, code, children }
}

function simplifyFunction(module_: MinusModule, function_: MinusFunction): MinusFunction {
    table := minusValues(function_)
    let aliases: int[] = []
    let constants: string[] = []
    for index of 0..<table.values.length { aliases.push(index); constants.push("") }
    let blocks: MinusBlock[] = []
    let flat: MinusInstruction[] = []
    let definitions: int[] = []
    for _ of table.values { definitions.push(-1) }
    for original of minusBlocks(function_) {
        let instructions: MinusInstruction[] = []
        for originalInstruction of original.instructions {
            let args: string[] = []
            for arg of originalInstruction.args { args.push(arg) }
            for position of minusOperandPositions(originalInstruction) {
                id := minusValueId(table, args[position])
                args[position] = table.values[aliases[id]].name
            }
            let instruction = MinusInstruction { op: originalInstruction.op, args, result: originalInstruction.result, line: originalInstruction.line, sourcePath: originalInstruction.sourcePath }
            if instruction.op == "copy" && !minusReferenceType(module_, instruction.result!.typeName) {
                aliases[minusValueId(table, instruction.result!.name)] = aliases[minusValueId(table, args[0])]
                continue
            }
            instruction = foldConstant(instruction, table, constants)
            if instruction.op == "const" { constants[minusValueId(table, instruction.result!.name)] = instruction.args[0] }
            if instruction.op == "branch" {
                condition := minusValueId(table, instruction.args[0])
                if constants[condition] != "" {
                    split := minusBranchSplit(instruction)
                    start := if constants[condition] == "true" then 1 else split + 1
                    stop := if start == 1 then split else instruction.args.length
                    let edge: string[] = []
                    for index of start..<stop { edge.push(instruction.args[index]) }
                    instruction = MinusInstruction { op: "jump", args: edge, line: instruction.line, sourcePath: instruction.sourcePath }
                }
            }
            if instruction.result != none { definitions[minusValueId(table, instruction.result!.name)] = flat.length }
            flat.push(instruction); instructions.push(instruction)
        }
        blocks.push(MinusBlock { name: original.name, params: original.params, instructions, line: original.line, sourcePath: original.sourcePath })
    }
    let live: bool[] = []
    let queue: int[] = []
    for _ of table.values { live.push(false) }
    for instruction of flat {
        if pureScalar(module_, instruction, table) { continue }
        for position of minusOperandPositions(instruction) {
            id := minusValueId(table, instruction.args[position])
            if !live[id] { live[id] = true; queue.push(id) }
        }
    }
    let cursor = 0
    while cursor < queue.length {
        definition := definitions[queue[cursor]]
        if definition >= 0 {
            for position of minusOperandPositions(flat[definition]) {
                id := minusValueId(table, flat[definition].args[position])
                if !live[id] { live[id] = true; queue.push(id) }
            }
        }
        cursor += 1
    }
    let filtered: MinusBlock[] = []
    for block_ of blocks {
        let instructions: MinusInstruction[] = []
        for instruction of block_.instructions {
            if pureScalar(module_, instruction, table) && !live[minusValueId(table, instruction.result!.name)] { continue }
            instructions.push(instruction)
        }
        filtered.push(MinusBlock { name: block_.name, params: block_.params, instructions, line: block_.line, sourcePath: block_.sourcePath })
    }
    return MinusFunction { capturePanics: function_.capturePanics, name: function_.name, params: function_.params, result: function_.result, exported: function_.exported, body: rebuild(function_.body, filtered), line: function_.line, sourcePath: function_.sourcePath, exportName: function_.exportName }
}

/** Scalar copies, bounded integer constants, and dead nontrapping results. */
export function simplifyMinusInstructions(module_: MinusModule): MinusModule {
    let functions: MinusFunction[] = []
    for function_ of module_.functions { functions.push(simplifyFunction(module_, function_)) }
    return pruneDeadBlockArguments(MinusModule { recoverPanics: module_.recoverPanics, classes: module_.classes, interfaces: module_.interfaces, enums: module_.enums, imports: module_.imports, globals: module_.globals, functions })
}
