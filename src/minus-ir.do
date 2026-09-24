// The source-level doof-- model. Value names are local to a function.
export class MinusField {
    name: string
    typeName: string
    mutable: bool = false
    line: int = 0
}

export class MinusMethod {
    name: string
    params: string[] = []
    result: string = "none"
    line: int = 0
}

export class MinusClass {
    name: string
    interfaces: string[] = []
    fields: MinusField[] = []
    line: int = 0
}

export class MinusInterface {
    name: string
    fields: MinusField[] = []
    methods: MinusMethod[] = []
    line: int = 0
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
}

export class MinusBlock {
    name: string
    params: MinusValue[] = []
    instructions: MinusInstruction[] = []
    line: int = 0
}

export class MinusFunction {
    name: string
    params: MinusValue[] = []
    result: string = "none"
    exported: bool = false
    blocks: MinusBlock[] = []
    line: int = 0
}

export class MinusModule {
    classes: MinusClass[] = []
    interfaces: MinusInterface[] = []
    functions: MinusFunction[] = []
}
