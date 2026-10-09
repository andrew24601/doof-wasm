import { minusBlocks } from "./minus-control-flow"
import { minusReferenceType } from "./minus-analysis"
// Block arguments are SSA copies, not additional source bindings. Trace their
// uses backwards through incoming edges; an unobserved forwarding cycle stays
// dead. Instructions and function parameters retain their existing ownership.
import { MinusBlock, MinusFunction, MinusInstruction, MinusModule, MinusRegion, MinusValue, MinusNameIndex, createMinusNameIndex, lookupMinusName, insertMinusName } from "./minus-ir"

class ParameterLiveness {
    // Block parameter names in offset order, and block names in block order.
    let parameters: MinusNameIndex = MinusNameIndex {}
    let blockNames: MinusNameIndex = MinusNameIndex {}
    offsets: int[] = []
    live: bool[] = []
    heads: int[] = []
    sources: int[] = []
    next: int[] = []
    queue: int[] = []
}

function blockIndex(blocks: MinusBlock[], name: string): int {
    for index of 0..<blocks.length { if blocks[index].name == name { return index } }
    panic("validated block missing during optimization")
}

function parameterIndex(block_: MinusBlock, name: string): int {
    for index of 0..<block_.params.length { if block_.params[index].name == name { return index } }
    return -1
}

function markLive(state: ParameterLiveness, index: int): none {
    if state.live[index] { return }
    state.live[index] = true
    state.queue.push(index)
}

function parameterId(state: ParameterLiveness, blocks: MinusBlock[], name: string): int => lookupMinusName(state.parameters, name)

function stateBlockIndex(state: ParameterLiveness, name: string): int {
    index := lookupMinusName(state.blockNames, name)
    if index < 0 { panic("validated block missing during optimization") }
    return index
}

function markValue(state: ParameterLiveness, blocks: MinusBlock[], name: string): none {
    index := parameterId(state, blocks, name)
    if index >= 0 { markLive(state, index) }
}

function branchSplit(instruction: MinusInstruction): int {
    for index of 0..<instruction.args.length { if instruction.args[index] == "|" { return index } }
    panic("validated branch separator missing during optimization")
}

function addEdge(state: ParameterLiveness, blocks: MinusBlock[], target: string, args: string[], start: int, stop: int): none {
    targetIndex := stateBlockIndex(state, target)
    for index of start..<stop {
        parameter := parameterId(state, blocks, args[index])
        if parameter < 0 { continue }
        targetParameter := state.offsets[targetIndex] + index - start
        state.sources.push(parameter)
        state.next.push(state.heads[targetParameter])
        state.heads[targetParameter] = state.sources.length - 1
    }
}

function storageFinalizer(function_: MinusFunction): bool {
    // Prove the simple storage-cleanup body used by generated array wrappers.
    // Anything else can observe when the last reference is released.
    blocks := minusBlocks(function_)
    if function_.capturePanics || blocks.length != 1 { return false }
    instructions := blocks[0].instructions
    if instructions.length != 3 { return false }
    read := instructions[0]
    free := instructions[1]
    exit := instructions[2]
    return read.op == "get" && read.result != none && read.result!.typeName == "int"
        && read.args[0] == function_.params[0].name
        && free.op == "array-free" && free.args[0] == read.result!.name
        && exit.op == "return"
}

export function preserveReferenceLifetimes(module_: MinusModule): bool {
    for class_ of module_.classes {
        if class_.finalizer == "" { continue }
        let found = false
        for function_ of module_.functions {
            if function_.name != class_.finalizer { continue }
            if !storageFinalizer(function_) { return true }
            found = true
            break
        }
        if !found { panic("validated finalizer missing during optimization") }
    }
    return false
}

function parameterLiveness(module_: MinusModule, function_: MinusFunction, preserveReferences: bool): ParameterLiveness {
    state := ParameterLiveness {}
    blocks := minusBlocks(function_)
    let parameterCount = 0
    for block_ of blocks { parameterCount += block_.params.length }
    state.parameters = createMinusNameIndex(parameterCount)
    state.blockNames = createMinusNameIndex(blocks.length)
    for block_ of blocks {
        _ := insertMinusName(state.blockNames, block_.name)
        state.offsets.push(state.live.length)
        for parameter of block_.params { _ := insertMinusName(state.parameters, parameter.name); state.live.push(false); state.heads.push(-1) }
    }
    for blockIndex_ of 0..<blocks.length {
        block_ := blocks[blockIndex_]
        offset := state.offsets[blockIndex_]
        if preserveReferences {
            for index of 0..<block_.params.length {
                if minusReferenceType(module_, block_.params[index].typeName) { markLive(state, offset + index) }
            }
        }
        for instruction of block_.instructions {
            args := instruction.args
            if instruction.op == "jump" {
                addEdge(state, blocks, args[0], args, 1, args.length)
            } else if instruction.op == "branch" {
                markValue(state, blocks, args[0])
                split := branchSplit(instruction)
                addEdge(state, blocks, args[1], args, 2, split)
                addEdge(state, blocks, args[split + 1], args, split + 2, args.length)
            } else if instruction.op != "const" && instruction.op != "string-const" && instruction.op != "global-get" {
                // Other non-value operands are validated identifiers and cannot
                // match a %parameter. Literal text must not count as a use.
                for arg of args { markValue(state, blocks, arg) }
            }
        }
    }
    let cursor = 0
    while cursor < state.queue.length {
        let edge = state.heads[state.queue[cursor]]
        while edge >= 0 {
            markLive(state, state.sources[edge])
            edge = state.next[edge]
        }
        cursor += 1
    }
    return state
}

function appendEdge(args: string[], state: ParameterLiveness, blocks: MinusBlock[], target: string, original: string[], start: int, stop: int): none {
    targetIndex := stateBlockIndex(state, target)
    args.push(target)
    for index of start..<stop {
        if state.live[state.offsets[targetIndex] + index - start] { args.push(original[index]) }
    }
}

function replaceRegion(region: MinusRegion, blocks: MinusBlock[], names: MinusNameIndex): MinusRegion {
    let children: MinusRegion[] = []
    for child of region.children { children.push(replaceRegion(child, blocks, names)) }
    let code: MinusBlock | none = none
    if region.code != none {
        index := lookupMinusName(names, region.label)
        if index >= 0 { code = blocks[index] }
    }
    return MinusRegion { kind: region.kind, label: region.label, code, children }
}

function pruneFunction(module_: MinusModule, function_: MinusFunction, preserveReferences: bool): MinusFunction {
    state := parameterLiveness(module_, function_, preserveReferences)
    let changed = false
    for live of state.live { if !live { changed = true; break } }
    if !changed { return function_ }
    let blocks: MinusBlock[] = []
    originals := minusBlocks(function_)
    for index of 0..<originals.length {
        original := originals[index]
        let params: MinusValue[] = []
        for parameter of 0..<original.params.length {
            if state.live[state.offsets[index] + parameter] { params.push(original.params[parameter]) }
        }
        let instructions: MinusInstruction[] = []
        for instruction of original.instructions {
            if instruction.op != "jump" && instruction.op != "branch" { instructions.push(instruction); continue }
            let args: string[] = []
            if instruction.op == "jump" {
                appendEdge(args, state, originals, instruction.args[0], instruction.args, 1, instruction.args.length)
            } else {
                split := branchSplit(instruction)
                args.push(instruction.args[0])
                appendEdge(args, state, originals, instruction.args[1], instruction.args, 2, split)
                args.push("|")
                appendEdge(args, state, originals, instruction.args[split + 1], instruction.args, split + 2, instruction.args.length)
            }
            instructions.push(MinusInstruction { op: instruction.op, result: instruction.result, args, line: instruction.line, sourcePath: instruction.sourcePath })
        }
        blocks.push(MinusBlock { name: original.name, params, instructions, line: original.line, sourcePath: original.sourcePath })
    }
    return MinusFunction {
        capturePanics: function_.capturePanics, name: function_.name, params: function_.params,
        result: function_.result, exported: function_.exported, body: replaceRegion(function_.body, blocks, state.blockNames), line: function_.line,
        sourcePath: function_.sourcePath, exportName: function_.exportName,
    }
}

/** Prune unused block arguments in validated IR, without mutating its model.
 * Calls, allocations, and instruction results remain, as do reference copies
 * when a custom destructor could observe their lifetime. */
export function pruneDeadBlockArguments(module_: MinusModule): MinusModule {
    preserveReferences := preserveReferenceLifetimes(module_)
    let functions: MinusFunction[] = []
    for function_ of module_.functions { functions.push(pruneFunction(module_, function_, preserveReferences)) }
    return MinusModule {
        recoverPanics: module_.recoverPanics, classes: module_.classes,
        interfaces: module_.interfaces, enums: module_.enums, imports: module_.imports,
        globals: module_.globals, functions,
    }
}
