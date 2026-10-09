import { MinusBlock, MinusFunction, MinusInstruction, MinusModule, MinusRegion, MinusValue } from "./minus-ir"
import { MinusValues, MinusEffects, minusValues, minusValueId, minusOperandPositions, minusReferenceType, indexMinusValues, minusCallTarget, minusFreshValues, minusHazard, minusIsInterface } from "./minus-analysis"
import { MinusControlFlow, minusBlocks, minusBlockIndex, minusBranchSplit, analyzeMinusControlFlow, minusDominates } from "./minus-control-flow"
import { preserveReferenceLifetimes } from "./minus-optimize"

export class WasmLocals {
    table: MinusValues
    slots: int[] = []
    locals: int[] = []
    borrowed: bool[] = []
    // Borrowed element reads bypass the owning array-get wrapper.
    peek: bool[] = []
    // Owned references whose ownership moves into a block parameter on their
    // only use, and those that are always moved before being redefined.
    transfers: bool[] = []
    cleared: bool[] = []
    repeated: bool[] = []
    stack: bool[] = []
    uses: int[] = []
    references: bool[] = []
    moved: bool[] = []
    checkedCasts: bool[] = []
    liveBlocks: bool[] = []
    let scratch: int = 0
}

function localCarrier(typeName: string): int {
    if typeName == "long" { return 126 }
    if typeName == "float" { return 125 }
    if typeName == "double" { return 124 }
    return 127
}

export function rawWasmLocals(values: MinusValue[]): WasmLocals {
    result := WasmLocals { table: indexMinusValues(values), scratch: values.length }
    for index of 0..<values.length {
        result.slots.push(index); result.stack.push(false); result.borrowed.push(false); result.peek.push(false)
        result.transfers.push(false); result.cleared.push(false)
        // A helper defines its single result once per call into a zeroed local.
        result.repeated.push(false); result.moved.push(false); result.checkedCasts.push(false); result.uses.push(1)
    }
    return result
}

function repeatValues(region: MinusRegion, table: MinusValues, repeated: bool[], inside: bool): none {
    nested := inside || region.kind == "loop"
    if region.code != none {
        for value of region.code!.params { repeated[minusValueId(table, value.name)] = nested }
        for instruction of region.code!.instructions { if instruction.result != none { repeated[minusValueId(table, instruction.result!.name)] = nested } }
    }
    for child of region.children { repeatValues(child, table, repeated, nested) }
}

function extendLoops(region: MinusRegion, names: string[], starts: int[], ends: int[], first: int[], last: int[]): none {
    if region.kind == "loop" {
        let start = -1
        let stop = -1
        let stack = [region]
        while stack.length > 0 {
            node := stack.pop()!
            if node.code != none {
                for index of 0..<names.length {
                    if names[index] != node.label { continue }
                    if start < 0 || starts[index] < start { start = starts[index] }
                    if ends[index] > stop { stop = ends[index] }
                }
            }
            for child of node.children { stack.push(child) }
        }
        for index of 0..<first.length { if first[index] < start && last[index] >= start && last[index] < stop { last[index] = stop } }
    }
    for child of region.children { extendLoops(child, names, starts, ends, first, last) }
}

function stackProducer(instruction: MinusInstruction, table: MinusValues): bool {
    if (instruction.op == "const" || instruction.op == "global-get" || instruction.op == "add" || instruction.op == "sub" || instruction.op == "mul" || instruction.op == "div" || instruction.op == "rem" || instruction.op == "eq" || instruction.op == "lt" || instruction.op == "convert" || instruction.op == "copy" || instruction.op == "is" || instruction.op == "cast" || instruction.op == "call" || instruction.op == "call-method") { return true }
    if instruction.op.startsWith("array-") { return true }
    return false
}

function firstStackOperand(instruction: MinusInstruction): int {
    if instruction.op == "call" || instruction.op == "jump" { return 1 }
    if (instruction.op == "add" || instruction.op == "sub" || instruction.op == "mul" || instruction.op == "div" || instruction.op == "rem" || instruction.op == "eq" || instruction.op == "lt" || instruction.op == "convert" || instruction.op == "copy" || instruction.op == "return" || instruction.op == "branch") || instruction.op.startsWith("array-") { return 0 }
    return -1
}

function immutableField(module_: MinusModule, ownerType: string, name: string): bool {
    for class_ of module_.classes {
        if class_.name != ownerType { continue }
        for field of class_.fields { if field.name == name { return !field.mutable } }
        return false
    }
    // An interface's read-only view can be implemented by a mutable field.
    // The concrete storage, rather than just the view, must be immutable.
    let found = false
    for class_ of module_.classes {
        if !class_.interfaces.contains(ownerType) { continue }
        found = true
        let immutable = false
        for field of class_.fields { if field.name == name { immutable = !field.mutable } }
        if !immutable { return false }
    }
    return found
}

function borrowDependency(values: WasmLocals, preserve: bool, source: int, target: int, heads: int[], targets: int[], links: int[]): none {
    // A single-definition owned value also roots its descendants until the
    // frame exits. Custom destructors make its cleanup position observable.
    if !preserve && !values.repeated[source] { return }
    targets.push(target); links.push(heads[source]); heads[source] = targets.length - 1
}

function borrowEdge(values: WasmLocals, preserve: bool, blocks: MinusBlock[], instruction: MinusInstruction, start: int, stop: int, heads: int[], targets: int[], links: int[]): none {
    target := blocks[minusBlockIndex(blocks, instruction.args[start - 1])]
    for index of start..<stop {
        id := minusValueId(values.table, target.params[index - start].name)
        if values.references[id] { borrowDependency(values, preserve, minusValueId(values.table, instruction.args[index]), id, heads, targets, links) }
    }
}

function borrowReferences(module_: MinusModule, values: WasmLocals, blocks: MinusBlock[], preserve: bool): none {
    let heads: int[] = []
    let targets: int[] = []
    let links: int[] = []
    for _ of values.table.values { heads.push(-1) }
    for blockIndex of 0..<blocks.length {
        if !values.liveBlocks[blockIndex] { continue }
        block_ := blocks[blockIndex]
        for param of block_.params {
            id := minusValueId(values.table, param.name)
            values.borrowed[id] = values.references[id]
        }
        for instruction of block_.instructions {
            if instruction.op == "jump" { borrowEdge(values, preserve, blocks, instruction, 1, instruction.args.length, heads, targets, links) }
            if instruction.op == "branch" {
                split := minusBranchSplit(instruction)
                borrowEdge(values, preserve, blocks, instruction, 2, split, heads, targets, links)
                borrowEdge(values, preserve, blocks, instruction, split + 2, instruction.args.length, heads, targets, links)
            }
            if instruction.result == none { continue }
            id := minusValueId(values.table, instruction.result!.name)
            if !values.references[id] { continue }
            op := instruction.op
            if op == "string-const" || op == "global-get" { values.borrowed[id] = true; continue }
            if op != "copy" && op != "as" && op != "get" && op != "cast" { continue }
            owner := minusValueId(values.table, instruction.args[0])
            if op == "get" && !immutableField(module_, values.table.values[owner].typeName, instruction.args[1]) { continue }
            values.borrowed[id] = true
            borrowDependency(values, preserve, owner, id, heads, targets, links)
        }
    }
    // A scoped root owns its snapshot until `drop`, even when its source is
    // borrowed. Propagate that finite lifetime through derived borrows.
    for block_ of blocks {
        for instruction of block_.instructions {
            if instruction.op == "drop" { values.borrowed[minusValueId(values.table, instruction.args[0])] = false }
        }
    }
    // Start with candidate borrows, then reject any dependency on a value that
    // can lose its root. A loop-forwarding cycle is safe only when all its
    // incoming values are rooted too; one owned repeating input rejects it.
    let queue: int[] = []
    for id of 0..<values.borrowed.length { if !values.borrowed[id] { queue.push(id) } }
    let cursor = 0
    while cursor < queue.length {
        let edge = heads[queue[cursor]]
        while edge >= 0 {
            target := targets[edge]
            if values.borrowed[target] { values.borrowed[target] = false; queue.push(target) }
            edge = links[edge]
        }
        cursor += 1
    }
}

export function allocateWasmLocals(module_: MinusModule, function_: MinusFunction, effects: MinusEffects = MinusEffects {}): WasmLocals {
    table := minusValues(function_)
    result := WasmLocals { table }
    let first: int[] = []
    let last: int[] = []
    let aliases: int[] = []
    let stable: bool[] = []
    for index of 0..<table.values.length {
        first.push(-1); last.push(0); aliases.push(index)
        stable.push(false)
        result.slots.push(-1); result.borrowed.push(false); result.peek.push(false); result.repeated.push(false)
        result.transfers.push(false); result.cleared.push(false)
        result.stack.push(false); result.uses.push(0); result.moved.push(false); result.checkedCasts.push(false)
        result.references.push(minusReferenceType(module_, table.values[index].typeName))
    }
    repeatValues(function_.body, table, result.repeated, false)
    for index of 0..<table.values.length { stable[index] = !result.repeated[index] }
    blocks := minusBlocks(function_)
    flow := analyzeMinusControlFlow(blocks)
    let starts: int[] = []
    let ends: int[] = []
    let names: string[] = []
    for index of 0..<function_.params.length { first[index] = 0; result.borrowed[index] = result.references[index] }
    let position = 1
    for blockIndex of 0..<blocks.length {
        block_ := blocks[blockIndex]
        names.push(block_.name); starts.push(position)
        result.liveBlocks.push(flow.positions[blockIndex] >= 0)
        for param of block_.params {
            id := minusValueId(table, param.name)
            if first[id] < 0 || position < first[id] { first[id] = position }
        }
        for instruction of block_.instructions {
            if flow.positions[blockIndex] >= 0 {
                for operand of minusOperandPositions(instruction) {
                    id := minusValueId(table, instruction.args[operand]); last[id] = position; result.uses[id] += 1
                }
                if instruction.op == "jump" || instruction.op == "branch" {
                    let targets: string[] = []
                    if instruction.op == "jump" { targets.push(instruction.args[0]) }
                    else { targets.push(instruction.args[1]); targets.push(instruction.args[minusBranchSplit(instruction) + 1]) }
                    for target of targets {
                        for param of blocks[minusBlockIndex(blocks, target)].params {
                            id := minusValueId(table, param.name)
                            if first[id] < 0 || position < first[id] { first[id] = position }
                            if position > last[id] { last[id] = position }
                        }
                    }
                }
                if instruction.result != none {
                    id := minusValueId(table, instruction.result!.name)
                    first[id] = position
                    if position > last[id] { last[id] = position }
                }
            }
            position += 1
        }
        ends.push(position)
    }
    extendLoops(function_.body, names, starts, ends, first, last)
    preserve := if effects.enabled then effects.preserve else preserveReferenceLifetimes(module_)
    let scoped = false
    for block_ of blocks { for instruction of block_.instructions { if instruction.op == "drop" { scoped = true } } }
    // Scoped roots can end before the function epilogue. Derived reads and
    // copies must own snapshots instead of borrowing a root that is cleared.
    borrowReferences(module_, result, blocks, preserve || scoped)
    if effects.enabled && !preserve && !scoped { borrowTransients(module_, result, blocks, flow, effects) }
    for blockIndex of 0..<blocks.length {
        if !result.liveBlocks[blockIndex] { continue }
        instructions := blocks[blockIndex].instructions
        for index of 0..<instructions.length {
            instruction := instructions[index]
            if instruction.result == none { continue }
            id := minusValueId(table, instruction.result!.name)
            // These pointers have instance-lifetime roots, even when their
            // defining read repeats in a loop. Escaping uses retain ownership.
            if result.references[id] && (instruction.op == "string-const" || instruction.op == "global-get") {
                result.borrowed[id] = true; stable[id] = true
            }
            if result.references[id] && result.borrowed[id] && (instruction.op == "copy" || instruction.op == "as") {
                root := aliases[minusValueId(table, instruction.args[0])]
                if stable[root] {
                    aliases[id] = root; stable[id] = true
                }
            }
            if result.references[id] && result.borrowed[id] && (instruction.op == "get" || instruction.op == "cast") {
                owner := minusValueId(table, instruction.args[0])
                stable[id] = stable[owner]
            }
            if index + 1 >= instructions.length { continue }
            next := instructions[index + 1]
            if result.references[id] && !result.borrowed[id] && result.uses[id] == 1 && next.op == "return" && next.args.length == 1 && next.args[0] == instruction.result!.name {
                result.moved[id] = true
            }
            operand := firstStackOperand(next)
            if !result.references[id] && instruction.result!.typeName != "none" && result.uses[id] == 1 && stackProducer(instruction, table) && operand >= 0 && operand < next.args.length && next.args[operand] == instruction.result!.name {
                result.stack[id] = true
            }
        }
        exit := instructions[instructions.length - 1]
        if exit.op != "branch" { continue }
        yes := minusBlockIndex(blocks, exit.args[1])
        no := minusBlockIndex(blocks, exit.args[minusBranchSplit(exit) + 1])
        if yes == no || flow.predecessors[yes].length != 1 { continue }
        for test of instructions {
            if test.op != "is" || test.result == none || test.result!.name != exit.args[0] { continue }
            let boxes = [test.args[0]]
            split := minusBranchSplit(exit)
            for arg of 2..<split { if exit.args[arg] == test.args[0] { boxes.push(blocks[yes].params[arg - 2].name) } }
            for target of 0..<blocks.length {
                if !minusDominates(flow, yes, target) { continue }
                for cast of blocks[target].instructions {
                    if cast.op == "cast" && cast.args[1] == test.args[1] && boxes.contains(cast.args[0]) { result.checkedCasts[minusValueId(table, cast.result!.name)] = true }
                }
            }
        }
    }
    transferOwnership(result, blocks)
    // Allocate in interval-start order, using buckets rather than a sorting API.
    let heads: int[] = []
    let links: int[] = []
    for _ of 0..<(position + 1) { heads.push(-1) }
    for _ of table.values { links.push(-1) }
    let index = table.values.length - 1
    while index >= function_.params.length {
        if first[index] >= 0 {
            links[index] = heads[first[index]]; heads[first[index]] = index
        }
        index -= 1
    }
    let slotEnds: int[] = []
    let slotStarts: int[] = []
    let slotTypes: int[] = []
    let owned: bool[] = []
    for param of 0..<function_.params.length {
        result.slots[param] = param; slotEnds.push(last[param]); slotStarts.push(0); slotTypes.push(localCarrier(table.values[param].typeName)); owned.push(result.references[param])
    }
    for start of 0..<heads.length {
        let id = heads[start]
        while id >= 0 {
            if aliases[id] != id { result.slots[id] = result.slots[aliases[id]] }
            else if !result.stack[id] && !result.moved[id] && (result.references[id] || result.uses[id] > 0) {
                carrier := localCarrier(table.values[id].typeName)
                let slot = -1
                if !result.references[id] {
                    for candidate of 0..<slotEnds.length {
                        if !owned[candidate] && slotTypes[candidate] == carrier && slotStarts[candidate] < start && slotEnds[candidate] <= start { slot = candidate; break }
                    }
                }
                if slot < 0 { slot = slotEnds.length; slotEnds.push(last[id]); slotStarts.push(start); slotTypes.push(carrier); owned.push(result.references[id]); result.locals.push(carrier) }
                else { slotEnds[slot] = last[id]; slotStarts[slot] = start }
                result.slots[id] = slot
            }
            id = links[id]
        }
    }
    result.scratch = slotEnds.length
    for id of 0..<table.values.length { if result.moved[id] { result.slots[id] = result.scratch + 4 } }
    return result
}

// Short-lived borrows. A mutable field read or an array element read normally
// retains its result, because later code might overwrite the slot that roots
// it. When every use of the value (and of borrows derived from it) is reached
// before any instruction that can write shared storage, the slot still owns
// the value throughout, so the read can borrow it instead. Uses must not flow
// into block parameters, and a repeating owned container must not be replaced
// within the window.
function transientSource(module_: MinusModule, values: WasmLocals, effects: MinusEffects, instruction: MinusInstruction): int {
    if instruction.result == none { return -1 }
    id := minusValueId(values.table, instruction.result!.name)
    if !values.references[id] || values.borrowed[id] { return -1 }
    if instruction.op == "get" { return minusValueId(values.table, instruction.args[0]) }
    if instruction.op != "call-method" { return -1 }
    target := minusCallTarget(effects, values.table, instruction)
    if target < 0 || !effects.peekable[target] { return -1 }
    return minusValueId(values.table, instruction.args[0])
}

class TransientWindow {
    uses: int[] = []
    let escapes: bool = false
}

function transientClosure(values: WasmLocals, candidate: bool[], children: int[][], useBlocks: int[][], escapes: bool[], id: int, window: TransientWindow): none {
    let stack = [id]
    while stack.length > 0 {
        current := stack.pop()!
        if escapes[current] { window.escapes = true; return }
        for block_ of useBlocks[current] { window.uses.push(block_) }
        for child of children[current] { if values.borrowed[child] || candidate[child] { stack.push(child) } }
    }
}

function transientSafe(values: WasmLocals, blocks: MinusBlock[], flow: MinusControlFlow, effects: MinusEffects, fresh: bool[], candidate: bool[], sources: int[], children: int[][], useBlocks: int[][], escapes: bool[], defBlocks: int[], defIndexes: int[], id: int): bool {
    window := TransientWindow {}
    transientClosure(values, candidate, children, useBlocks, escapes, id, window)
    if window.escapes { return false }
    source := sources[id]
    // An owned repeating container is released when it is redefined.
    guarded := !values.borrowed[source] && !candidate[source] && values.repeated[source]
    sourceName := values.table.values[source].name
    let sourceBlock = -1
    if guarded && defBlocks[source] >= 0 && defIndexes[source] < 0 { sourceBlock = defBlocks[source] }
    defBlock := defBlocks[id]
    let visited: bool[] = []
    for _ of blocks { visited.push(false) }
    let pending: int[] = []
    for block_ of window.uses { if block_ != defBlock { pending.push(block_) } }
    let scan: int[] = []
    while pending.length > 0 {
        block_ := pending.pop()!
        if block_ == defBlock || visited[block_] { continue }
        visited[block_] = true; scan.push(block_)
        if block_ == 0 || flow.predecessors[block_].length == 0 { return false }
        for predecessor of flow.predecessors[block_] { if flow.positions[predecessor] >= 0 { pending.push(predecessor) } }
    }
    for index of (defIndexes[id] + 1)..<blocks[defBlock].instructions.length {
        if transientHazard(values, blocks, effects, fresh, guarded, sourceName, sourceBlock, blocks[defBlock].instructions[index]) { return false }
    }
    for block_ of scan {
        for instruction of blocks[block_].instructions {
            if transientHazard(values, blocks, effects, fresh, guarded, sourceName, sourceBlock, instruction) { return false }
        }
    }
    return true
}

function transientHazard(values: WasmLocals, blocks: MinusBlock[], effects: MinusEffects, fresh: bool[], guarded: bool, sourceName: string, sourceBlock: int, instruction: MinusInstruction): bool {
    if minusHazard(effects, values.table, fresh, instruction) { return true }
    if !guarded { return false }
    if instruction.result != none && instruction.result!.name == sourceName { return true }
    if sourceBlock >= 0 && (instruction.op == "jump" || instruction.op == "branch") {
        target := blocks[sourceBlock].name
        if instruction.op == "jump" { return instruction.args[0] == target }
        return instruction.args[1] == target || instruction.args[minusBranchSplit(instruction) + 1] == target
    }
    return false
}

function borrowTransients(module_: MinusModule, values: WasmLocals, blocks: MinusBlock[], flow: MinusControlFlow, effects: MinusEffects): none {
    table := values.table
    count := table.values.length
    let candidate: bool[] = []
    let sources: int[] = []
    let children: int[][] = []
    let useBlocks: int[][] = []
    let escapes: bool[] = []
    let defBlocks: int[] = []
    let defIndexes: int[] = []
    for _ of 0..<count { candidate.push(false); sources.push(-1); children.push([]); useBlocks.push([]); escapes.push(false); defBlocks.push(-1); defIndexes.push(-1) }
    let any = false
    for blockIndex of 0..<blocks.length {
        if !values.liveBlocks[blockIndex] { continue }
        block_ := blocks[blockIndex]
        // Parameters use index -1: they are defined on entry to their block.
        for param of block_.params { defBlocks[minusValueId(table, param.name)] = blockIndex }
        for index of 0..<block_.instructions.length {
            instruction := block_.instructions[index]
            for operand of minusOperandPositions(instruction) {
                id := minusValueId(table, instruction.args[operand])
                if !values.references[id] { continue }
                if instruction.op == "jump" || instruction.op == "branch" { if operand > 0 { escapes[id] = true } }
                useBlocks[id].push(blockIndex)
            }
            if instruction.result == none { continue }
            id := minusValueId(table, instruction.result!.name)
            defBlocks[id] = blockIndex; defIndexes[id] = index
            if !values.references[id] { continue }
            op := instruction.op
            if (op == "get" || op == "cast" || op == "copy" || op == "as" || op == "call-method") && instruction.args.length > 0 {
                owner := minusValueId(table, instruction.args[0])
                if owner >= 0 && values.references[owner] { children[owner].push(id) }
            }
            source := transientSource(module_, values, effects, instruction)
            if source >= 0 { candidate[id] = true; sources[id] = source; any = true }
        }
    }
    if !any { return }
    fresh := minusFreshValues(module_, effects, table, blocks)
    let changed = true
    while changed {
        changed = false
        let id = count - 1
        while id >= 0 {
            if candidate[id] && !transientSafe(values, blocks, flow, effects, fresh, candidate, sources, children, useBlocks, escapes, defBlocks, defIndexes, id) {
                candidate[id] = false; changed = true
            }
            id -= 1
        }
    }
    for id of 0..<count {
        if !candidate[id] { continue }
        values.borrowed[id] = true
        definition := blocks[defBlocks[id]].instructions[defIndexes[id]]
        if definition.op == "call-method" { values.peek[id] = true }
    }
}

// An owned reference used only as an edge argument can hand its reference to
// the block parameter instead of retaining it there and releasing its own slot
// at exit. The source slot is cleared after the move. Values that root other
// borrows keep their ownership, and a borrowed parameter never takes a move.
function transferOwnership(values: WasmLocals, blocks: MinusBlock[]): none {
    table := values.table
    count := table.values.length
    let rooting: bool[] = []
    let edgeUses: int[] = []
    let otherUses: bool[] = []
    let site: int[] = []
    let defBlock: int[] = []
    for _ of 0..<count { rooting.push(false); edgeUses.push(0); otherUses.push(false); site.push(-1); defBlock.push(-1) }
    for blockIndex of 0..<blocks.length {
        if !values.liveBlocks[blockIndex] { continue }
        block_ := blocks[blockIndex]
        for param of block_.params { defBlock[minusValueId(table, param.name)] = blockIndex }
        for index of 0..<block_.instructions.length {
            instruction := block_.instructions[index]
            op := instruction.op
            if instruction.result != none {
                id := minusValueId(table, instruction.result!.name)
                defBlock[id] = blockIndex
                if values.borrowed[id] && (op == "get" || op == "cast" || op == "copy" || op == "as" || op == "call-method") && instruction.args.length > 0 {
                    owner := minusValueId(table, instruction.args[0])
                    if owner >= 0 { rooting[owner] = true }
                }
            }
            if op == "jump" || op == "branch" {
                let groups: int[] = []
                if op == "jump" { groups.push(0); groups.push(1); groups.push(instruction.args.length) }
                else {
                    split := minusBranchSplit(instruction)
                    groups.push(1); groups.push(2); groups.push(split)
                    groups.push(split + 1); groups.push(split + 2); groups.push(instruction.args.length)
                }
                let cursor = 0
                while cursor < groups.length {
                    target := blocks[minusBlockIndex(blocks, instruction.args[groups[cursor]])]
                    let seen: int[] = []
                    for index_ of groups[cursor + 1]..<groups[cursor + 2] {
                        id := minusValueId(table, instruction.args[index_])
                        param := minusValueId(table, target.params[index_ - groups[cursor + 1]].name)
                        if values.borrowed[param] || seen.contains(id) { rooting[id] = true }
                        seen.push(id)
                        if site[id] >= 0 && site[id] != blockIndex { otherUses[id] = true }
                        site[id] = blockIndex; edgeUses[id] += 1
                    }
                    cursor += 3
                }
            } else {
                for operand of minusOperandPositions(instruction) { otherUses[minusValueId(table, instruction.args[operand])] = true }
            }
        }
    }
    for id of 0..<count {
        if !values.references[id] || values.borrowed[id] || values.moved[id] || rooting[id] || otherUses[id] { continue }
        if edgeUses[id] == 0 || site[id] != defBlock[id] { continue }
        values.transfers[id] = true
        exit := blocks[site[id]].instructions[blocks[site[id]].instructions.length - 1]
        // Every successor receives the value, so its slot is empty again
        // before the definition can repeat.
        values.cleared[id] = exit.op == "jump" || edgeUses[id] == 2
    }
}
