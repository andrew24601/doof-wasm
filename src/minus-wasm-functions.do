// Emission buffers, not another source IR. Nonnegative entries are bytes;
// a negative entry -(index + 1) is a direct-call operand awaiting relocation.
export class WasmFunctionBody {
    typeIndex: int
    code: int[]
    live: bool = true
}

export class WasmFunctionPlan {
    bodies: WasmFunctionBody[] = []
    indexes: int[] = []
}

function callRepresentative(value: int, imports: int, representatives: int[]): int {
    if value >= 0 { return value }
    index := -value - 1
    if index < imports { return value }
    if representatives[index - imports] < 0 { panic("live call targets an unreachable function") }
    return -(imports + representatives[index - imports] + 1)
}

function bodyHash(body: WasmFunctionBody, imports: int, representatives: int[]): int {
    let hash = body.typeIndex % 65521
    for value of body.code {
        token := callRepresentative(value, imports, representatives)
        // Bounded arithmetic gives the same hash in native and Wasm builds.
        hash = (hash * 31 + token % 65521 + 65521) % 65521
    }
    return hash
}

function sameBody(left: WasmFunctionBody, right: WasmFunctionBody, imports: int, representatives: int[]): bool {
    if left.typeIndex != right.typeIndex || left.code.length != right.code.length { return false }
    for index of 0..<left.code.length {
        if callRepresentative(left.code[index], imports, representatives) != callRepresentative(right.code[index], imports, representatives) { return false }
    }
    return true
}

/** Fold exact implementations, then repeat so callers of newly shared bodies
 * can also share code. Hash collisions always require a full comparison.
 * Imports retain their distinct identities; first occurrence determines order. */
export function foldWasmFunctions(bodies: WasmFunctionBody[], imports: int): WasmFunctionPlan {
    let representatives: int[] = []
    for index of 0..<bodies.length { representatives.push(index) }
    let changed = true
    while changed {
        changed = false
        let heads: int[] = []
        for _ of 0..<(bodies.length * 2 + 1) { heads.push(-1) }
        let links: int[] = []
        let next: int[] = []
        for index of 0..<bodies.length {
            body := bodies[index]
            if !body.live { next.push(-1); links.push(-1); continue }
            bucket := bodyHash(body, imports, representatives) % heads.length
            let candidate = heads[bucket]
            while candidate >= 0 && !sameBody(body, bodies[candidate], imports, representatives) { candidate = links[candidate] }
            if candidate < 0 {
                next.push(index); links.push(heads[bucket]); heads[bucket] = index
            } else { next.push(candidate); links.push(-1) }
            if next[index] != representatives[index] { changed = true }
        }
        representatives = next
    }
    plan := WasmFunctionPlan {}
    for index of 0..<imports { plan.indexes.push(index) }
    for index of 0..<bodies.length {
        if !bodies[index].live { plan.indexes.push(-1); continue }
        if representatives[index] == index {
            plan.indexes.push(imports + plan.bodies.length)
            plan.bodies.push(bodies[index])
        } else { plan.indexes.push(plan.indexes[imports + representatives[index]]) }
    }
    return plan
}
