// The source-level doof-- model. Value names are local to a function.
export class MinusField {
    name: string
    typeName: string
    mutable: bool = false
    line: int = 0
    sourcePath: string = ""
}

export class MinusMethod {
    name: string
    params: string[] = []
    result: string = "none"
    line: int = 0
    sourcePath: string = ""
}

export class MinusClass {
    name: string
    interfaces: string[] = []
    fields: MinusField[] = []
    let finalizer: string = ""
    line: int = 0
    sourcePath: string = ""
}

export class MinusInterface {
    name: string
    fields: MinusField[] = []
    methods: MinusMethod[] = []
    line: int = 0
    sourcePath: string = ""
}

export class MinusEnum {
    name: string
    line: int = 0
    sourcePath: string = ""
}

export class MinusValue {
    name: string
    typeName: string
}

export class MinusInstruction {
    op: string
    result: MinusValue | none = none
    args: string[] = []
    line: int = 0
    sourcePath: string = ""
}

export class MinusBlock {
    name: string
    params: MinusValue[] = []
    instructions: MinusInstruction[] = []
    line: int = 0
    sourcePath: string = ""
}

// The sole function-body representation: typed code in nested exit scopes and
// loops. A control-flow graph can be derived from this tree for analysis.
export class MinusRegion {
    kind: string = "sequence"
    label: string = ""
    code: MinusBlock | none = none
    children: MinusRegion[] = []
}

export class MinusFunction {
    capturePanics: bool = false
    name: string
    params: MinusValue[] = []
    result: string = "none"
    let exported: bool = false
    body: MinusRegion = MinusRegion {}
    line: int = 0
    sourcePath: string = ""
    let exportName: string = ""
}

export class MinusImport {
    name: string
    importModule: string = "doof"
    importName: string
    params: MinusValue[] = []
    result: string = "none"
    line: int = 0
    sourcePath: string = ""
}

// The initializer returns one owned value, retained for the instance lifetime.
export class MinusGlobal {
    name: string
    typeName: string
    initializer: string
    line: int = 0
    sourcePath: string = ""
}

export class MinusModule {
    let recoverPanics: bool = false
    classes: MinusClass[] = []
    interfaces: MinusInterface[] = []
    enums: MinusEnum[] = []
    imports: MinusImport[] = []
    globals: MinusGlobal[] = []
    functions: MinusFunction[] = []
    // Derived name indexes; see minusModuleLookup. Not part of the IR text.
    let lookup: MinusModuleLookup | none = none
}

/** A hash index from names to positions. Insert names in order; lookup
 * returns the position of the first insertion of a name, or -1. */
export class MinusNameIndex {
    heads: int[] = []
    links: int[] = []
    names: string[] = []
}

// Generated names share long prefixes (encoded module paths) and differ near
// the end, so hash the length and at most the last 24 characters.
function nameHash(name: string): int {
    let hash = name.length
    start := if name.length > 24 then name.length - 24 else 0
    for index of start..<name.length { hash = (hash * 31 + int(name[index])) % 1000003 }
    return hash
}

export function createMinusNameIndex(capacity: int): MinusNameIndex {
    index := MinusNameIndex {}
    for _ of 0..<(capacity * 2 + 1) { index.heads.push(-1) }
    return index
}

export function lookupMinusName(index: MinusNameIndex, name: string): int {
    if index.heads.length == 0 { return -1 }
    let cursor = index.heads[nameHash(name) % index.heads.length]
    let found = -1
    while cursor >= 0 {
        if index.names[cursor] == name { found = cursor }
        cursor = index.links[cursor]
    }
    return found
}

/** Adds a name at the next position and returns that position. */
export function insertMinusName(index: MinusNameIndex, name: string): int {
    bucket := nameHash(name) % index.heads.length
    index.names.push(name)
    index.links.push(index.heads[bucket])
    index.heads[bucket] = index.names.length - 1
    return index.names.length - 1
}

/** Name indexes for a module's declarations, rebuilt whenever a declaration
 * list has changed length. */
export class MinusModuleLookup {
    let classes: MinusNameIndex = MinusNameIndex {}
    let interfaces: MinusNameIndex = MinusNameIndex {}
    let enums: MinusNameIndex = MinusNameIndex {}
    let functions: MinusNameIndex = MinusNameIndex {}
    let imports: MinusNameIndex = MinusNameIndex {}
    classCount: int
    interfaceCount: int
    enumCount: int
    functionCount: int
    importCount: int
}

export function minusModuleLookup(module_: MinusModule): MinusModuleLookup {
    if module_.lookup != none {
        cached := module_.lookup!
        if cached.classCount == module_.classes.length && cached.interfaceCount == module_.interfaces.length &&
            cached.enumCount == module_.enums.length && cached.functionCount == module_.functions.length &&
            cached.importCount == module_.imports.length { return cached }
    }
    lookup := MinusModuleLookup {
        classCount: module_.classes.length, interfaceCount: module_.interfaces.length,
        enumCount: module_.enums.length, functionCount: module_.functions.length, importCount: module_.imports.length,
    }
    lookup.classes = createMinusNameIndex(module_.classes.length)
    for item of module_.classes { _ := insertMinusName(lookup.classes, item.name) }
    lookup.interfaces = createMinusNameIndex(module_.interfaces.length)
    for item of module_.interfaces { _ := insertMinusName(lookup.interfaces, item.name) }
    lookup.enums = createMinusNameIndex(module_.enums.length)
    for item of module_.enums { _ := insertMinusName(lookup.enums, item.name) }
    lookup.functions = createMinusNameIndex(module_.functions.length)
    for item of module_.functions { _ := insertMinusName(lookup.functions, item.name) }
    lookup.imports = createMinusNameIndex(module_.imports.length)
    for item of module_.imports { _ := insertMinusName(lookup.imports, item.name) }
    module_.lookup = lookup
    return lookup
}
