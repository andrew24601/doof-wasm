// A typed, host-independent subset of the WebAssembly core module model.
// Function indices count imports first, then module-defined functions.

export enum ValueType { I32, I64, F32, F64 }

export class FuncType {
    params: ValueType[] = []
    results: ValueType[] = []
}

export class FunctionImport {
    module: string
    name: string
    type_: FuncType
}

export class I32Const { value: int }
export class I64Const { value: long }
export class F32Const { value: float }
export class F64Const { value: double }
export class LocalGet { index: int }
export class Call { functionIndex: int }
export class I32Add {}
export class I64Add {}
export class F32Add {}
export class F64Add {}
export class Drop {}

export type Instruction = I32Const | I64Const | F32Const | F64Const | LocalGet | Call | I32Add | I64Add | F32Add | F64Add | Drop

export class Function {
    type_: FuncType
    locals: ValueType[] = []
    body: Instruction[] = []
}

export class FunctionExport {
    name: string
    functionIndex: int
}

export class Module {
    imports: FunctionImport[] = []
    functions: Function[] = []
    exports: FunctionExport[] = []
}
