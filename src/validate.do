import { Call, Drop, Function, FuncType, F32Add, F32Const, F64Add, F64Const, I32Add, I32Const, I64Add, I64Const, LocalGet, Module, ValueType } from "./ir"

export function validateModule(module_: Module): Result<none, string> {
    for import_ of module_.imports {
        if import_.module == "" || import_.name == "" {
            return Failure("Host import module and name must be nonempty")
        }
        try validateName(import_.module)
        try validateName(import_.name)
        try validateType(import_.type_)
    }
    for function_ of module_.functions {
        try validateType(function_.type_)
        try validateFunction(module_, function_)
    }
    let names: string[] = []
    for export_ of module_.exports {
        if export_.name == "" { return Failure("Export name must be nonempty") }
        try validateName(export_.name)
        if names.contains(export_.name) { return Failure("Duplicate export: " + export_.name) }
        names.push(export_.name)
        if export_.functionIndex < 0 || export_.functionIndex >= functionCount(module_) {
            return Failure("Export " + export_.name + " has an invalid function index")
        }
    }
    return Success(none)
}

function validateName(name: string): Result<none, string> {
    for index of 0..<name.length {
        if int(name[index]) > 127 {
            return Failure("This IR subset currently requires ASCII import and export names")
        }
    }
    return Success(none)
}

function validateType(type_: FuncType): Result<none, string> {
    if type_.results.length > 1 {
        return Failure("This IR subset supports at most one function result")
    }
    return Success(none)
}

function functionCount(module_: Module): int => module_.imports.length + module_.functions.length

function functionType(module_: Module, index: int): FuncType {
    if index < module_.imports.length { return module_.imports[index].type_ }
    return module_.functions[index - module_.imports.length].type_
}

function popExpected(stack: ValueType[], expected: ValueType, context: string): Result<none, string> {
    if stack.length == 0 { return Failure(context + " requires a value") }
    actual := try! stack.pop()
    if actual != expected { return Failure(context + " has the wrong value type") }
    return Success(none)
}

function validateFunction(module_: Module, function_: Function): Result<none, string> {
    let stack: ValueType[] = []
    for instruction of function_.body {
        case instruction {
            value: I32Const -> { stack.push(ValueType.I32) }
            value: I64Const -> { stack.push(ValueType.I64) }
            value: F32Const -> { stack.push(ValueType.F32) }
            value: F64Const -> { stack.push(ValueType.F64) }
            local: LocalGet -> {
                if local.index < 0 || local.index >= function_.type_.params.length + function_.locals.length {
                    return Failure("local.get has an invalid local index")
                }
                if local.index < function_.type_.params.length {
                    stack.push(function_.type_.params[local.index])
                } else {
                    stack.push(function_.locals[local.index - function_.type_.params.length])
                }
            }
            call: Call -> {
                if call.functionIndex < 0 || call.functionIndex >= functionCount(module_) {
                    return Failure("call has an invalid function index")
                }
                type_ := functionType(module_, call.functionIndex)
                let index = type_.params.length - 1
                while index >= 0 {
                    try popExpected(stack, type_.params[index], "call")
                    index -= 1
                }
                for result of type_.results { stack.push(result) }
            }
            add: I32Add -> {
                try popExpected(stack, ValueType.I32, "i32.add")
                try popExpected(stack, ValueType.I32, "i32.add")
                stack.push(ValueType.I32)
            }
            add: I64Add -> {
                try popExpected(stack, ValueType.I64, "i64.add")
                try popExpected(stack, ValueType.I64, "i64.add")
                stack.push(ValueType.I64)
            }
            add: F32Add -> {
                try popExpected(stack, ValueType.F32, "f32.add")
                try popExpected(stack, ValueType.F32, "f32.add")
                stack.push(ValueType.F32)
            }
            add: F64Add -> {
                try popExpected(stack, ValueType.F64, "f64.add")
                try popExpected(stack, ValueType.F64, "f64.add")
                stack.push(ValueType.F64)
            }
            drop: Drop -> {
                if stack.length == 0 { return Failure("drop requires a value") }
                try! stack.pop()
            }
        }
    }
    if stack.length != function_.type_.results.length {
        return Failure("Function body leaves the wrong number of results")
    }
    for index of 0..<stack.length {
        if stack[index] != function_.type_.results[index] {
            return Failure("Function body result has the wrong value type")
        }
    }
    return Success(none)
}
