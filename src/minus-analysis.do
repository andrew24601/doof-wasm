import { MinusBlock, MinusFunction, MinusInstruction, MinusModule, MinusValue, minusModuleLookup, lookupMinusName } from "./minus-ir"
import { minusBlocks, minusBranchSplit, analyzeMinusControlFlow } from "./minus-control-flow"

export class MinusValues {
    values: MinusValue[] = []
    heads: int[] = []
    links: int[] = []
}

// Generated names share long prefixes (encoded module paths) and differ near
// the end, so hash the length and at most the last 24 characters.
function nameHash(name: string): int {
    let hash = name.length
    start := if name.length > 24 then name.length - 24 else 0
    for index of start..<name.length { hash = (hash * 31 + int(name[index])) % 65521 }
    return hash
}

export function indexMinusValues(values: MinusValue[]): MinusValues {
    table := MinusValues { values }
    for _ of 0..<(values.length * 2 + 1) { table.heads.push(-1) }
    for index of 0..<values.length {
        bucket := nameHash(values[index].name) % table.heads.length
        table.links.push(table.heads[bucket]); table.heads[bucket] = index
    }
    return table
}

export function minusValues(function_: MinusFunction): MinusValues {
    let values: MinusValue[] = []
    for value of function_.params { values.push(value) }
    for block_ of minusBlocks(function_) {
        for value of block_.params { values.push(value) }
        for instruction of block_.instructions { if instruction.result != none { values.push(instruction.result!) } }
    }
    return indexMinusValues(values)
}

export function minusValueId(table: MinusValues, name: string): int {
    let index = table.heads[nameHash(name) % table.heads.length]
    while index >= 0 {
        if table.values[index].name == name { return index }
        index = table.links[index]
    }
    return -1
}

export function minusReferenceType(module_: MinusModule, typeName: string): bool {
    if typeName == "any" { return true }
    lookup := minusModuleLookup(module_)
    return lookupMinusName(lookup.classes, typeName) >= 0 || lookupMinusName(lookup.interfaces, typeName) >= 0
}

/** Positions of value operands, excluding literal text, types, names and labels. */
export function minusOperandPositions(instruction: MinusInstruction): int[] {
    op := instruction.op
    args := instruction.args
    let positions: int[] = []
    if op == "const" || op == "string-const" || op == "global-get" { return positions }
    if op == "branch" {
        positions.push(0)
        split := minusBranchSplit(instruction)
        for index of 2..<split { positions.push(index) }
        for index of (split + 2)..<args.length { positions.push(index) }
        return positions
    }
    if op == "call-method" || op == "get" || op == "set" {
        positions.push(0)
        for index of 2..<args.length { positions.push(index) }
        return positions
    }
    if op == "is" || op == "cast" || op == "array-alloc" || op == "array-free" { positions.push(0); return positions }
    if op == "array-reserve" { positions.push(0); positions.push(1); return positions }
    if op == "array-copy" {
        for index of 0..<5 { positions.push(index) }
        return positions
    }
    start := if op == "new" || op == "call" || op == "jump" || (op == "box" && args.length == 2) then 1 else 0
    for index of start..<args.length { positions.push(index) }
    return positions
}

function markFunction(module_: MinusModule, name: string, live: bool[], queue: int[]): none {
    lookup := minusModuleLookup(module_)
    index := lookupMinusName(lookup.functions, name)
    if index >= 0 {
        if !live[index] { live[index] = true; queue.push(index) }
        return
    }
    // Native imports are already separate from defined functions.
    if lookupMinusName(lookup.imports, name) >= 0 { return }
    panic("validated function missing during reachability")
}

/** Trace declarations from exports, all initializers, and all finalizers.
 * Interface calls retain every implementation of that specific interface. */
export function reachableMinusFunctions(module_: MinusModule): bool[] {
    let live: bool[] = []
    let queue: int[] = []
    for _ of module_.functions { live.push(false) }
    for function_ of module_.functions { if function_.exported { markFunction(module_, function_.name, live, queue) } }
    for global_ of module_.globals { markFunction(module_, global_.initializer, live, queue) }
    for class_ of module_.classes { if class_.finalizer != "" { markFunction(module_, class_.finalizer, live, queue) } }
    let cursor = 0
    while cursor < queue.length {
        function_ := module_.functions[queue[cursor]]
        values := minusValues(function_)
        blocks := minusBlocks(function_)
        flow := analyzeMinusControlFlow(blocks)
        for blockIndex of 0..<blocks.length {
            if flow.positions[blockIndex] < 0 { continue }
            for instruction of blocks[blockIndex].instructions {
                if instruction.op == "call" { markFunction(module_, instruction.args[0], live, queue) }
                if instruction.op == "call-method" {
                    owner := values.values[minusValueId(values, instruction.args[0])].typeName
                    if lookupMinusName(minusModuleLookup(module_).interfaces, owner) >= 0 {
                        for class_ of module_.classes { if class_.interfaces.contains(owner) { markFunction(module_, class_.name + "." + instruction.args[1], live, queue) } }
                    } else { markFunction(module_, owner + "." + instruction.args[1], live, queue) }
                }
                if instruction.op == "eq" && values.values[minusValueId(values, instruction.args[0])].typeName == "any" {
                    for class_ of module_.classes { if class_.name == "__doof_string" { markFunction(module_, "__doof_string.compare", live, queue) } }
                }
            }
        }
        cursor += 1
    }
    return live
}

/** Module facts for short-lived borrows. Each function has an effect state:
 * 0 writes nothing that existed before the call, 1 writes only storage owned
 * by its first argument (such as an array method's receiver), 2 may write
 * anything or reach unknown code (interface dispatch). Releases are not
 * effects: they never free storage that another owner still roots. */
export class MinusEffects {
    enabled: bool = false
    functions: MinusValues = MinusValues {}
    interfaces: MinusValues = MinusValues {}
    classes: MinusValues = MinusValues {}
    states: int[] = []
    peekable: bool[] = []
    // Whether custom destructors make reference lifetimes observable; the
    // encoder computes it once per module.
    let preserve: bool = false
}

function namedTable(names: string[]): MinusValues {
    let values: MinusValue[] = []
    for name of names { values.push(MinusValue { name, typeName: "" }) }
    return indexMinusValues(values)
}

export function minusIsInterface(effects: MinusEffects, typeName: string): bool => minusValueId(effects.interfaces, typeName) >= 0

/** Target function index of a direct call, -1 for dynamic dispatch, -2 for
 * no call, and -3 for a host import (which only sees its arguments). */
export function minusCallTarget(effects: MinusEffects, table: MinusValues, instruction: MinusInstruction): int {
    if instruction.op == "call" {
        target := minusValueId(effects.functions, instruction.args[0])
        return if target >= 0 then target else -3
    }
    if instruction.op != "call-method" { return -2 }
    owner := table.values[minusValueId(table, instruction.args[0])].typeName
    if minusIsInterface(effects, owner) { return -1 }
    return minusValueId(effects.functions, owner + "." + instruction.args[1])
}

function mutation(op: string): bool {
    return op == "set" || op == "array-set" || op == "array-push" || op == "array-pop" || op == "array-copy" || op == "array-reserve" || op == "array-free"
}

// The argument a receiver-only callee may write: its first parameter.
function receiverArgument(instruction: MinusInstruction): int {
    if instruction.op == "call-method" { return 0 }
    return if instruction.args.length > 1 then 1 else -1
}

function freshResult(module_: MinusModule, effects: MinusEffects, table: MinusValues, fresh: bool[], instruction: MinusInstruction): bool {
    op := instruction.op
    if op == "array-alloc" { return true }
    // Boxing a class value yields the object itself, fresh only if it was.
    if op == "box" {
        if instruction.args.length == 2 { return true }
        source := minusValueId(table, instruction.args[0])
        typeName := table.values[source].typeName
        if typeName != "none" && minusReferenceType(module_, typeName) { return fresh[source] }
        return true
    }
    if op == "new" {
        // An array object is fresh only when its storage handle is.
        class_ := minusValueId(effects.classes, instruction.args[0])
        if class_ < 0 { return true }
        fields := module_.classes[class_].fields
        for index of 0..<fields.length {
            if fields[index].name == "data" && index + 1 < instruction.args.length { return fresh[minusValueId(table, instruction.args[index + 1])] }
        }
        return true
    }
    if op == "array-push" || op == "array-reserve" || op == "copy" || op == "as" { return fresh[minusValueId(table, instruction.args[0])] }
    if op == "get" && instruction.args[1] == "data" { return fresh[minusValueId(table, instruction.args[0])] }
    return false
}

/** Values whose storage was allocated by this invocation and is reachable
 * only through them, including loop-carried values whose every input is. */
export function minusFreshValues(module_: MinusModule, effects: MinusEffects, table: MinusValues, blocks: MinusBlock[]): bool[] {
    let fresh: bool[] = []
    for _ of table.values { fresh.push(false) }
    let blockNames: string[] = []
    for block_ of blocks {
        blockNames.push(block_.name)
        for param of block_.params { fresh[minusValueId(table, param.name)] = true }
    }
    blockTable := namedTable(blockNames)
    let changed = true
    while changed {
        changed = false
        // Parameters stay fixed while results settle; SSA results are acyclic.
        let settling = true
        while settling {
            settling = false
            for block_ of blocks {
                for instruction of block_.instructions {
                    if instruction.result == none { continue }
                    id := minusValueId(table, instruction.result!.name)
                    value := freshResult(module_, effects, table, fresh, instruction)
                    if value != fresh[id] { fresh[id] = value; settling = true }
                }
            }
        }
        for block_ of blocks {
            for instruction of block_.instructions {
                op := instruction.op
                if op != "jump" && op != "branch" { continue }
                let ranges: int[] = []
                if op == "jump" { ranges.push(0); ranges.push(1); ranges.push(instruction.args.length) }
                else {
                    split := minusBranchSplit(instruction)
                    ranges.push(1); ranges.push(2); ranges.push(split)
                    ranges.push(split + 1); ranges.push(split + 2); ranges.push(instruction.args.length)
                }
                let cursor = 0
                while cursor < ranges.length {
                    target := blocks[minusValueId(blockTable, instruction.args[ranges[cursor]])]
                    for index of ranges[cursor + 1]..<ranges[cursor + 2] {
                        param := minusValueId(table, target.params[index - ranges[cursor + 1]].name)
                        if fresh[param] && !fresh[minusValueId(table, instruction.args[index])] { fresh[param] = false; changed = true }
                    }
                    cursor += 3
                }
            }
        }
    }
    return fresh
}

/** A write to storage that may be shared, or a call that may perform one. */
export function minusHazard(effects: MinusEffects, table: MinusValues, fresh: bool[], instruction: MinusInstruction): bool {
    if mutation(instruction.op) { return !fresh[minusValueId(table, instruction.args[0])] }
    target := minusCallTarget(effects, table, instruction)
    if target == -2 || target == -3 { return false }
    if target == -1 || effects.states[target] == 2 { return true }
    if effects.states[target] == 0 { return false }
    receiver := receiverArgument(instruction)
    return receiver < 0 || !fresh[minusValueId(table, instruction.args[receiver])]
}

function peekableFunction(module_: MinusModule, function_: MinusFunction): bool {
    blocks := minusBlocks(function_)
    if blocks.length != 1 || function_.params.length != 2 || !minusReferenceType(module_, function_.result) { return false }
    code := blocks[0].instructions
    if code.length != 3 { return false }
    return code[0].op == "get" && code[0].args[0] == function_.params[0].name && code[0].args[1] == "data" && code[0].result != none
        && code[1].op == "array-get" && code[1].args[0] == code[0].result!.name && code[1].args[1] == function_.params[1].name && code[1].result != none
        && code[2].op == "return" && code[2].args.length == 1 && code[2].args[0] == code[1].result!.name
}

// Storage owned by the first parameter: itself, its array handle, and the
// handles that growing that array returns.
function receiverValues(function_: MinusFunction, table: MinusValues, blocks: MinusBlock[]): bool[] {
    let owned: bool[] = []
    for _ of table.values { owned.push(false) }
    if function_.params.length == 0 { return owned }
    owned[0] = true
    for block_ of blocks {
        for instruction of block_.instructions {
            if instruction.result == none || instruction.args.length == 0 { continue }
            op := instruction.op
            source := minusValueId(table, instruction.args[0])
            if source < 0 || !owned[source] { continue }
            if (op == "get" && instruction.args[1] == "data") || op == "array-push" || op == "array-reserve" || op == "copy" || op == "as" {
                owned[minusValueId(table, instruction.result!.name)] = true
            }
        }
    }
    return owned
}

// 0 fresh, 1 owned by the first parameter, 2 anything else.
function storageKind(table: MinusValues, fresh: bool[], owned: bool[], name: string): int {
    id := minusValueId(table, name)
    if fresh[id] { return 0 }
    return if owned[id] then 1 else 2
}

export function analyzeMinusEffects(module_: MinusModule, live: bool[]): MinusEffects {
    let names: string[] = []
    for function_ of module_.functions { names.push(function_.name) }
    let interfaceNames: string[] = []
    for interface_ of module_.interfaces { interfaceNames.push(interface_.name) }
    let classNames: string[] = []
    for class_ of module_.classes { classNames.push(class_.name) }
    effects := MinusEffects { enabled: true, functions: namedTable(names), interfaces: namedTable(interfaceNames), classes: namedTable(classNames) }
    // Summaries: the strongest direct write, plus each call's target and the
    // storage kind of the argument a receiver-only target may write.
    let direct: int[] = []
    let targets: int[][] = []
    let receivers: int[][] = []
    for index of 0..<module_.functions.length {
        effects.states.push(0); effects.peekable.push(false); direct.push(0); targets.push([]); receivers.push([])
        if !live[index] { continue }
        function_ := module_.functions[index]
        effects.peekable[index] = peekableFunction(module_, function_)
        table := minusValues(function_)
        blocks := minusBlocks(function_)
        fresh := minusFreshValues(module_, effects, table, blocks)
        owned := receiverValues(function_, table, blocks)
        for block_ of blocks {
            for instruction of block_.instructions {
                if mutation(instruction.op) {
                    kind := storageKind(table, fresh, owned, instruction.args[0])
                    if kind > direct[index] { direct[index] = kind }
                    continue
                }
                target := minusCallTarget(effects, table, instruction)
                if target == -1 { direct[index] = 2; continue }
                if target < 0 { continue }
                receiver := receiverArgument(instruction)
                targets[index].push(target)
                receivers[index].push(if receiver < 0 then 2 else storageKind(table, fresh, owned, instruction.args[receiver]))
            }
        }
    }
    // States only increase, so this reaches the least consistent solution.
    let changed = true
    while changed {
        changed = false
        for index of 0..<module_.functions.length {
            if !live[index] || effects.states[index] == 2 { continue }
            let state = direct[index]
            for call of 0..<targets[index].length {
                calleeState := effects.states[targets[index][call]]
                effect := if calleeState == 1 then receivers[index][call] else calleeState
                if effect > state { state = effect }
            }
            if state > effects.states[index] { effects.states[index] = state; changed = true }
        }
    }
    return effects
}
