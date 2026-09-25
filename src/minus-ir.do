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

export class MinusFunction {
    name: string
    params: MinusValue[] = []
    result: string = "none"
    let exported: bool = false
    blocks: MinusBlock[] = []
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

export class MinusModule {
    classes: MinusClass[] = []
    interfaces: MinusInterface[] = []
    enums: MinusEnum[] = []
    imports: MinusImport[] = []
    functions: MinusFunction[] = []
}
