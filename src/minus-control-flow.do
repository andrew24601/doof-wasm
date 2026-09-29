import { MinusBlock, MinusFunction, MinusInstruction, MinusRegion } from "./minus-ir"

export class MinusControlFlow {
    successors: int[][] = []
    predecessors: int[][] = []
    order: int[] = []
    positions: int[] = []
    dominators: int[] = []
}

export function minusBlockIndex(blocks: MinusBlock[], name: string): int {
    for index of 0..<blocks.length { if blocks[index].name == name { return index } }
    return -1
}

export function minusBranchSplit(instruction: MinusInstruction): int {
    for index of 0..<instruction.args.length { if instruction.args[index] == "|" { return index } }
    return -1
}

function intersect(flow: MinusControlFlow, left: int, right: int): int {
    let a = left
    let b = right
    while a != b {
        while flow.positions[a] > flow.positions[b] { a = flow.dominators[a] }
        while flow.positions[b] > flow.positions[a] { b = flow.dominators[b] }
    }
    return a
}

/** Reachability, reverse postorder, and immediate dominators. Unknown targets
 * are left to instruction validation rather than indexing outside the graph. */
export function analyzeMinusControlFlow(blocks: MinusBlock[]): MinusControlFlow {
    flow := MinusControlFlow {}
    for _ of blocks {
        flow.successors.push([]); flow.predecessors.push([])
        flow.positions.push(-1); flow.dominators.push(-1)
    }
    for index of 0..<blocks.length {
        block_ := blocks[index]
        if block_.instructions.length == 0 { continue }
        last := block_.instructions[block_.instructions.length - 1]
        let targets: string[] = []
        if last.op == "jump" && last.args.length > 0 { targets.push(last.args[0]) }
        if last.op == "branch" && last.args.length > 1 {
            targets.push(last.args[1])
            split := minusBranchSplit(last)
            if split >= 0 && split + 1 < last.args.length { targets.push(last.args[split + 1]) }
        }
        for target of targets {
            successor := minusBlockIndex(blocks, target)
            if successor >= 0 && !flow.successors[index].contains(successor) {
                flow.successors[index].push(successor); flow.predecessors[successor].push(index)
            }
        }
    }
    if blocks.length == 0 { return flow }
    let visited: bool[] = []
    for _ of blocks { visited.push(false) }
    let stack = [0]
    let cursors = [0]
    let postorder: int[] = []
    visited[0] = true
    while stack.length > 0 {
        top := stack.length - 1
        block_ := stack[top]
        if cursors[top] < flow.successors[block_].length {
            successor := flow.successors[block_][cursors[top]]
            cursors[top] += 1
            if !visited[successor] { visited[successor] = true; stack.push(successor); cursors.push(0) }
        } else {
            postorder.push(block_); _ := try! stack.pop(); _ := try! cursors.pop()
        }
    }
    let index = postorder.length - 1
    while index >= 0 {
        block_ := postorder[index]
        flow.positions[block_] = flow.order.length; flow.order.push(block_)
        index -= 1
    }
    flow.dominators[0] = 0
    let changed = true
    while changed {
        changed = false
        for position of 1..<flow.order.length {
            block_ := flow.order[position]
            let parent = -1
            for predecessor of flow.predecessors[block_] {
                if flow.dominators[predecessor] < 0 { continue }
                parent = if parent < 0 then predecessor else intersect(flow, parent, predecessor)
            }
            if parent != flow.dominators[block_] { flow.dominators[block_] = parent; changed = true }
        }
    }
    return flow
}

export function minusDominates(flow: MinusControlFlow, definition: int, use: int): bool {
    if definition < 0 || use < 0 || flow.dominators[use] < 0 { return false }
    let current = use
    while current != definition && current != flow.dominators[current] { current = flow.dominators[current] }
    return current == definition
}

class NaturalLoop {
    header: int
    members: int[] = []
    let parent: int = -1
}

function loops(blocks: MinusBlock[], flow: MinusControlFlow): NaturalLoop[] {
    let result: NaturalLoop[] = []
    for source of flow.order {
        for target of flow.successors[source] {
            if !minusDominates(flow, target, source) { continue }
            let loopIndex = -1
            for index of 0..<result.length { if result[index].header == target { loopIndex = index } }
            if loopIndex < 0 { loopIndex = result.length; result.push(NaturalLoop { header: target, members: [target] }) }
            loop_ := result[loopIndex]
            let pending = [source]
            while pending.length > 0 {
                block_ := try! pending.pop()
                if loop_.members.contains(block_) { continue }
                loop_.members.push(block_)
                for predecessor of flow.predecessors[block_] {
                    if flow.positions[predecessor] >= 0 { pending.push(predecessor) }
                }
            }
        }
    }
    for index of 0..<result.length {
        loop_ := result[index]
        for candidate of 0..<result.length {
            other := result[candidate]
            if candidate == index || other.members.length <= loop_.members.length || !other.members.contains(loop_.header) { continue }
            let contains = true
            for member of loop_.members { if !other.members.contains(member) { contains = false; break } }
            if contains && (loop_.parent < 0 || other.members.length < result[loop_.parent].members.length) { loop_.parent = candidate }
        }
    }
    return result
}

function regionEntry(region: MinusRegion): string {
    if region.kind == "code" || region.kind == "loop" { return region.label }
    if region.children.length == 0 { return "" }
    return regionEntry(region.children[0])
}

function schedule(blocks: MinusBlock[], flow: MinusControlFlow, natural: NaturalLoop[], owners: int[], parent: int): MinusRegion {
    let items: MinusRegion[] = []
    for block_ of flow.order {
        let child = -1
        for index of 0..<natural.length {
            if natural[index].parent == parent && natural[index].header == block_ { child = index; break }
        }
        if child >= 0 {
            body := schedule(blocks, flow, natural, owners, child)
            items.push(MinusRegion { kind: "loop", label: blocks[block_].name, children: body.children })
        } else if owners[block_] == parent {
            items.push(MinusRegion { kind: "code", label: blocks[block_].name, code: blocks[block_] })
        }
    }
    if items.length == 0 { return MinusRegion {} }
    // Each forward destination has a lexical exit label. Branching to it exits
    // its scope and reaches that item's code; loop labels target their header.
    let prefix = MinusRegion { children: [items[0]] }
    for index of 1..<items.length {
        scope := MinusRegion { kind: "scope", label: regionEntry(items[index]), children: prefix.children }
        prefix = MinusRegion { children: [scope, items[index]] }
    }
    return prefix
}

function collectRegionOrder(region: MinusRegion, blocks: MinusBlock[], labels: string[], seen: bool[], order: int[]): bool {
    if region.kind == "code" {
        if region.code == none || region.code!.name != region.label { return false }
        index := minusBlockIndex(blocks, region.label)
        if index < 0 || seen[index] { return false }
        seen[index] = true; order.push(index)
        block_ := blocks[index]
        if block_.instructions.length == 0 { return false }
        last := block_.instructions[block_.instructions.length - 1]
        let targets: string[] = []
        if last.op == "jump" && last.args.length > 0 { targets.push(last.args[0]) }
        if last.op == "branch" && last.args.length > 1 {
            split := minusBranchSplit(last)
            if split < 0 || split + 1 >= last.args.length { return false }
            targets.push(last.args[1]); targets.push(last.args[split + 1])
        }
        for target of targets { if !labels.contains(target) { return false } }
        return region.children.length == 0
    }
    if region.kind != "sequence" && region.kind != "scope" && region.kind != "loop" { return false }
    if region.children.length == 0 || region.code != none { return false }
    if region.kind != "sequence" {
        if minusBlockIndex(blocks, region.label) < 0 { return false }
        labels.push(region.label)
    }
    start := order.length
    for index of 0..<region.children.length {
        child := region.children[index]
        if child.kind == "scope" {
            if index + 1 >= region.children.length || regionEntry(region.children[index + 1]) != child.label { return false }
        }
        if !collectRegionOrder(child, blocks, labels, seen, order) { return false }
    }
    if region.kind == "loop" && (order.length == start || blocks[order[start]].name != region.label) { return false }
    if region.kind != "sequence" { _ := try! labels.pop() }
    return true
}

function appendBlocks(region: MinusRegion, blocks: MinusBlock[]): none {
    if region.code != none { blocks.push(region.code!) }
    for child of region.children { appendBlocks(child, blocks) }
}

/** Derive the basic-block view; no second body is stored. */
export function minusBlocks(function_: MinusFunction): MinusBlock[] {
    let blocks: MinusBlock[] = []
    appendBlocks(function_.body, blocks)
    return blocks
}

export function validateMinusRegions(function_: MinusFunction, flow: MinusControlFlow): bool {
    blocks := minusBlocks(function_)
    let seen: bool[] = []
    for _ of blocks { seen.push(false) }
    let order: int[] = []
    if !collectRegionOrder(function_.body, blocks, [], seen, order) || order.length == 0 || order[0] != 0 { return false }
    for index of 0..<blocks.length { if !seen[index] { return false } }
    return true
}

/** Build a structured body from transient lowering blocks. Irreducible input
 * is rejected; there is no dispatcher or alternate stored representation. */
export function structureMinusBlocks(blocks: MinusBlock[]): MinusRegion | none {
    flow := analyzeMinusControlFlow(blocks)
    natural := loops(blocks, flow)
    let owners: int[] = []
    for block_ of 0..<blocks.length {
        let owner = -1
        for index of 0..<natural.length {
            if natural[index].members.contains(block_) && (owner < 0 || natural[index].members.length < natural[owner].members.length) { owner = index }
        }
        owners.push(owner)
    }
    region := schedule(blocks, flow, natural, owners, -1)
    let seen: bool[] = []
    for _ of blocks { seen.push(false) }
    let order: int[] = []
    if !collectRegionOrder(region, blocks, [], seen, order) || order.length == 0 || order[0] != 0 { return none }
    for index of flow.order { if !seen[index] { return none } }
    return region
}
