import { parseByte, parseDouble, parseFloat, parseInt, parseLong } from "std/parse"
import { MinusBlock, MinusClass, MinusField, MinusFunction, MinusInstruction, MinusInterface, MinusMethod, MinusModule, MinusValue } from "./minus-ir"
import { classSize } from "./minus-layout"

readonly MAX_BLOCK_SIZE = 1032

function problem(line: int, message: string): string => "line " + string(line) + ": " + message

function classByName(module_: MinusModule, name: string): MinusClass | none {
    for item of module_.classes { if item.name == name { return item } }
    return none
}

function interfaceByName(module_: MinusModule, name: string): MinusInterface | none {
    for item of module_.interfaces { if item.name == name { return item } }
    return none
}

function functionByName(module_: MinusModule, name: string): MinusFunction | none {
    for item of module_.functions { if item.name == name { return item } }
    return none
}

function blockByName(function_: MinusFunction, name: string): MinusBlock | none {
    for item of function_.blocks { if item.name == name { return item } }
    return none
}

function primitive(typeName: string): bool => ["none", "bool", "char", "byte", "short", "int", "long", "float", "double"].contains(typeName)
function numeric(typeName: string): bool => ["byte", "short", "int", "long", "float", "double"].contains(typeName)
function reference(module_: MinusModule, typeName: string): bool => typeName == "any" || classByName(module_, typeName) != none || interfaceByName(module_, typeName) != none

function identifier(name: string): bool {
    if name == "" { return false }
    letters := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
    digits := "0123456789"
    if !letters.contains(name.substring(0, 1)) { return false }
    for index of 1..<name.length {
        ch := name.substring(index, index + 1)
        if !letters.contains(ch) && !digits.contains(ch) { return false }
    }
    return true
}

function valueName(name: string): bool => name.startsWith("%") && identifier(name.substring(1, name.length))

function functionName(name: string): bool {
    parts := name.split(".")
    if parts.length == 1 { return identifier(parts[0]) }
    return parts.length == 2 && identifier(parts[0]) && identifier(parts[1])
}

function checkType(module_: MinusModule, typeName: string, line: int): Result<none, string> {
    if primitive(typeName) || typeName == "any" || classByName(module_, typeName) != none || interfaceByName(module_, typeName) != none { return Success(none) }
    return Failure(problem(line, "unknown type " + typeName))
}

function fieldIn(module_: MinusModule, typeName: string, fieldName: string): MinusField | none {
    class_ := classByName(module_, typeName)
    if class_ != none { for field of class_!.fields { if field.name == fieldName { return field } } }
    interface_ := interfaceByName(module_, typeName)
    if interface_ != none { for field of interface_!.fields { if field.name == fieldName { return field } } }
    return none
}

function methodIn(interface_: MinusInterface, methodName: string): MinusMethod | none {
    for method of interface_.methods { if method.name == methodName { return method } }
    return none
}

function valueType(values: MinusValue[], name: string, line: int): Result<string, string> {
    for value of values { if value.name == name { return Success(value.typeName) } }
    return Failure(problem(line, "unknown or out-of-block value " + name))
}

function checkArgs(values: MinusValue[], args: string[], expected: string[], line: int): Result<none, string> {
    if args.length != expected.length { return Failure(problem(line, "expected " + string(expected.length) + " positional arguments, got " + string(args.length))) }
    for index of 0..<args.length {
        try actual := valueType(values, args[index], line)
        if actual != expected[index] { return Failure(problem(line, "argument " + string(index + 1) + " needs " + expected[index])) }
    }
    return Success(none)
}

function tail(args: string[], start: int): string[] {
    let result: string[] = []
    for index of start..<args.length { result.push(args[index]) }
    return result
}

function paramTypes(values: MinusValue[]): string[] {
    let types: string[] = []
    for value of values { types.push(value.typeName) }
    return types
}

function checkLiteral(instruction: MinusInstruction, typeName: string): Result<none, string> {
    if instruction.args.length != 1 { return Failure(problem(instruction.line, "const needs one literal")) }
    literal := instruction.args[0]
    if typeName == "none" || typeName == "bool" {
        if (typeName == "none" && literal == "none") || (typeName == "bool" && (literal == "true" || literal == "false")) { return Success(none) }
        return Failure(problem(instruction.line, "invalid " + typeName + " constant"))
    }
    if typeName == "byte" { _ := parseByte(literal) else { return Failure(problem(instruction.line, "invalid byte constant")) }; return Success(none) }
    if typeName == "short" || typeName == "int" || typeName == "char" {
        parsed := parseInt(literal) else { return Failure(problem(instruction.line, "invalid integer constant")) }
        if typeName == "short" && (parsed < -32768 || parsed > 32767) { return Failure(problem(instruction.line, "short constant out of range")) }
        if typeName == "char" && (parsed < 0 || parsed > 1114111 || (parsed >= 55296 && parsed <= 57343)) { return Failure(problem(instruction.line, "char constant must be a Unicode scalar")) }
        return Success(none)
    }
    if typeName == "long" { _ := parseLong(literal) else { return Failure(problem(instruction.line, "invalid long constant")) }; return Success(none) }
    if typeName == "float" { _ := parseFloat(literal) else { return Failure(problem(instruction.line, "invalid float constant")) }; return Success(none) }
    if typeName == "double" { _ := parseDouble(literal) else { return Failure(problem(instruction.line, "invalid double constant")) }; return Success(none) }
    return Failure(problem(instruction.line, "const needs a primitive result"))
}

function checkEdge(function_: MinusFunction, values: MinusValue[], args: string[], line: int): Result<none, string> {
    if args.length == 0 { return Failure(problem(line, "missing block target")) }
    block := blockByName(function_, args[0])
    if block == none { return Failure(problem(line, "unknown block " + args[0])) }
    return checkArgs(values, tail(args, 1), paramTypes(block!.params), line)
}

function checkInstruction(module_: MinusModule, function_: MinusFunction, values: MinusValue[], instruction: MinusInstruction): Result<string | none, string> {
    args := instruction.args
    line := instruction.line
    op := instruction.op
    resultType := if instruction.result == none then "none" else instruction.result!.typeName
    if op == "const" { try checkLiteral(instruction, resultType); return Success(resultType) }
    if ["add", "sub", "mul", "div", "eq", "lt"].contains(op) {
        if args.length != 2 { return Failure(problem(line, op + " needs two operands")) }
        try left := valueType(values, args[0], line)
        try right := valueType(values, args[1], line)
        if left != right || (!numeric(left) && !(op == "eq" && (left == "bool" || left == "char" || left == "none")) && !(op == "lt" && left == "char")) {
            return Failure(problem(line, op + " needs matching supported operands"))
        }
        return Success(if op == "eq" || op == "lt" then "bool" else left)
    }
    if op == "new" {
        if args.length == 0 { return Failure(problem(line, "new needs a class")) }
        class_ := classByName(module_, args[0])
        if class_ == none { return Failure(problem(line, "unknown class " + args[0])) }
        let expected: string[] = []
        for field of class_!.fields { expected.push(field.typeName) }
        try checkArgs(values, tail(args, 1), expected, line)
        return Success(class_!.name)
    }
    if op == "get" || op == "set" {
        if args.length != (if op == "get" then 2 else 3) { return Failure(problem(line, "invalid field operation")) }
        try owner := valueType(values, args[0], line)
        field := fieldIn(module_, owner, args[1])
        if field == none { return Failure(problem(line, owner + " has no field " + args[1])) }
        if op == "get" { return Success(field!.typeName) }
        if !field!.mutable { return Failure(problem(line, "field " + args[1] + " is immutable")) }
        try assigned := valueType(values, args[2], line)
        if assigned != field!.typeName { return Failure(problem(line, "field " + args[1] + " needs " + field!.typeName)) }
        return Success(none)
    }
    if op == "call" || op == "call-method" {
        if args.length == 0 { return Failure(problem(line, "missing call target")) }
        if op == "call" {
            target := functionByName(module_, args[0])
            if target == none { return Failure(problem(line, "unknown function " + args[0])) }
            try checkArgs(values, tail(args, 1), paramTypes(target!.params), line)
            return Success(target!.result)
        }
        if args.length < 2 { return Failure(problem(line, "missing method")) }
        try owner := valueType(values, args[0], line)
        interface_ := interfaceByName(module_, owner)
        if interface_ != none {
            method := methodIn(interface_!, args[1])
            if method == none { return Failure(problem(line, "unknown interface method " + args[1])) }
            try checkArgs(values, tail(args, 2), method!.params, line)
            return Success(method!.result)
        }
        target := functionByName(module_, owner + "." + args[1])
        if target == none { return Failure(problem(line, "unknown class method " + args[1])) }
        try checkArgs(values, tail(args, 2), tail(paramTypes(target!.params), 1), line)
        return Success(target!.result)
    }
    if op == "as" || op == "box" || op == "copy" || op == "convert" {
        if args.length != 1 { return Failure(problem(line, op + " needs one value")) }
        try source := valueType(values, args[0], line)
        if op == "copy" { return Success(source) }
        if op == "box" {
            if source == "any" || interfaceByName(module_, source) != none { return Failure(problem(line, "box needs a primitive or concrete class")) }
            return Success("any")
        }
        if op == "as" {
            class_ := classByName(module_, source)
            if class_ == none || !class_!.interfaces.contains(resultType) { return Failure(problem(line, "class does not implement " + resultType)) }
            return Success(resultType)
        }
        if !numeric(source) || !numeric(resultType) { return Failure(problem(line, "convert needs numeric types")) }
        return Success(resultType)
    }
    if op == "is" || op == "cast" {
        if args.length != 2 { return Failure(problem(line, op + " needs an any value and type")) }
        try source := valueType(values, args[0], line)
        if source != "any" { return Failure(problem(line, op + " needs any")) }
        try checkType(module_, args[1], line)
        if args[1] == "any" || interfaceByName(module_, args[1]) != none { return Failure(problem(line, op + " needs a primitive or concrete class target")) }
        return Success(if op == "is" then "bool" else args[1])
    }
    if op == "return" {
        if args.length > 1 { return Failure(problem(line, "return takes at most one value")) }
        let typeName = "none"
        if args.length == 1 { try known := valueType(values, args[0], line); typeName = known }
        if typeName != function_.result { return Failure(problem(line, "return needs " + function_.result)) }
        return Success(none)
    }
    if op == "jump" { try checkEdge(function_, values, args, line); return Success(none) }
    if op == "branch" {
        if args.length < 4 { return Failure(problem(line, "branch needs two targets")) }
        try condition := valueType(values, args[0], line)
        if condition != "bool" { return Failure(problem(line, "branch condition needs bool")) }
        let split = -1
        for index of 1..<args.length { if args[index] == "|" { split = index; break } }
        if split < 0 { return Failure(problem(line, "branch needs two targets")) }
        let first: string[] = []
        for index of 1..<split { first.push(args[index]) }
        try checkEdge(function_, values, first, line)
        try checkEdge(function_, values, tail(args, split + 1), line)
        return Success(none)
    }
    return Failure(problem(line, "unknown instruction " + op))
}

export function validateDoofMinus(module_: MinusModule): Result<none, string> {
    for index of 0..<module_.classes.length {
        class_ := module_.classes[index]
        if !identifier(class_.name) { return Failure(problem(class_.line, "invalid class name")) }
        if primitive(class_.name) || class_.name == "any" { return Failure(problem(class_.line, "reserved class name")) }
        for previous of 0..<index { if module_.classes[previous].name == class_.name { return Failure(problem(class_.line, "duplicate class")) } }
        if interfaceByName(module_, class_.name) != none { return Failure(problem(class_.line, "class and interface names collide")) }
    }
    for index of 0..<module_.interfaces.length {
        interface_ := module_.interfaces[index]
        if !identifier(interface_.name) { return Failure(problem(interface_.line, "invalid interface name")) }
        if primitive(interface_.name) || interface_.name == "any" { return Failure(problem(interface_.line, "reserved interface name")) }
        for previous of 0..<index { if module_.interfaces[previous].name == interface_.name { return Failure(problem(interface_.line, "duplicate interface")) } }
    }
    for owner of module_.classes {
        for index of 0..<owner.fields.length {
            field := owner.fields[index]
            if !identifier(field.name) { return Failure(problem(field.line, "invalid field name")) }
            try checkType(module_, field.typeName, field.line)
            for previous of 0..<index { if owner.fields[previous].name == field.name { return Failure(problem(field.line, "duplicate field")) } }
        }
        if classSize(owner) > MAX_BLOCK_SIZE { return Failure(problem(owner.line, "class allocation exceeds 1032 bytes")) }
    }
    for owner of module_.interfaces {
        for index of 0..<owner.fields.length {
            field := owner.fields[index]
            if !identifier(field.name) { return Failure(problem(field.line, "invalid field name")) }
            try checkType(module_, field.typeName, field.line)
            for previous of 0..<index { if owner.fields[previous].name == field.name { return Failure(problem(field.line, "duplicate field")) } }
        }
        for index of 0..<owner.methods.length {
            method := owner.methods[index]
            if !identifier(method.name) { return Failure(problem(method.line, "invalid method name")) }
            for previous of 0..<index { if owner.methods[previous].name == method.name { return Failure(problem(method.line, "duplicate interface method")) } }
            for typeName of method.params { try checkType(module_, typeName, method.line) }
            try checkType(module_, method.result, method.line)
        }
    }
    for class_ of module_.classes {
        for index of 0..<class_.interfaces.length {
            interfaceName := class_.interfaces[index]
            for previous of 0..<index { if class_.interfaces[previous] == interfaceName { return Failure(problem(class_.line, "duplicate implemented interface")) } }
            interface_ := interfaceByName(module_, interfaceName)
            if interface_ == none { return Failure(problem(class_.line, "unknown interface " + interfaceName)) }
            for required of interface_!.fields {
                actual := fieldIn(module_, class_.name, required.name)
                if actual == none || actual!.typeName != required.typeName || (required.mutable && !actual!.mutable) { return Failure(problem(class_.line, class_.name + " does not implement field " + interfaceName + "." + required.name)) }
            }
            for method of interface_!.methods {
                implementation := functionByName(module_, class_.name + "." + method.name)
                if implementation == none || implementation!.params.length != method.params.length + 1 || implementation!.params[0].typeName != class_.name || implementation!.result != method.result {
                    return Failure(problem(class_.line, class_.name + " does not implement method " + interfaceName + "." + method.name))
                }
                for index of 0..<method.params.length {
                    if implementation!.params[index + 1].typeName != method.params[index] { return Failure(problem(class_.line, "interface method parameter differs")) }
                }
            }
        }
    }
    for index of 0..<module_.functions.length {
        function_ := module_.functions[index]
        if !functionName(function_.name) { return Failure(problem(function_.line, "invalid function name")) }
        for previous of 0..<index { if module_.functions[previous].name == function_.name { return Failure(problem(function_.line, "duplicate function")) } }
        try checkType(module_, function_.result, function_.line)
        if function_.exported && reference(module_, function_.result) { return Failure(problem(function_.line, "export result must be primitive")) }
        let defined: MinusValue[] = []
        for param of function_.params {
            if !valueName(param.name) { return Failure(problem(function_.line, "invalid parameter name")) }
            try checkType(module_, param.typeName, function_.line)
            if function_.exported && reference(module_, param.typeName) { return Failure(problem(function_.line, "export parameter must be primitive")) }
            for known of defined { if known.name == param.name { return Failure(problem(function_.line, "duplicate parameter")) } }
            defined.push(param)
        }
        dot := function_.name.indexOf(".")
        if dot >= 0 {
            className := function_.name.substring(0, dot)
            if classByName(module_, className) == none || function_.params.length == 0 || function_.params[0].typeName != className { return Failure(problem(function_.line, "class method needs a class receiver first")) }
        }
        if function_.blocks.length == 0 { return Failure(problem(function_.line, "function needs a block")) }
        if function_.blocks[0].params.length != 0 { return Failure(problem(function_.blocks[0].line, "entry block cannot have parameters")) }
        for block of function_.blocks {
            if !identifier(block.name) { return Failure(problem(block.line, "invalid block name")) }
            for other of function_.blocks { if other != block && other.name == block.name { return Failure(problem(block.line, "duplicate block")) } }
            for param of block.params {
                if !valueName(param.name) { return Failure(problem(block.line, "invalid block parameter name")) }
                try checkType(module_, param.typeName, block.line)
                for known of defined { if known.name == param.name { return Failure(problem(block.line, "duplicate value " + param.name)) } }
                defined.push(param)
            }
        }
        for block of function_.blocks {
            if block.instructions.length == 0 { return Failure(problem(block.line, "empty block")) }
            let available: MinusValue[] = []
            for param of function_.params { available.push(param) }
            for param of block.params { available.push(param) }
            for position of 0..<block.instructions.length {
                instruction := block.instructions[position]
                terminal := ["return", "jump", "branch"].contains(instruction.op)
                if terminal != (position == block.instructions.length - 1) { return Failure(problem(instruction.line, "block terminator must be last")) }
                if instruction.result != none {
                    if !valueName(instruction.result!.name) { return Failure(problem(instruction.line, "invalid value name")) }
                    try checkType(module_, instruction.result!.typeName, instruction.line)
                    for known of defined { if known.name == instruction.result!.name { return Failure(problem(instruction.line, "duplicate value " + instruction.result!.name)) } }
                }
                try inferred := checkInstruction(module_, function_, available, instruction)
                if instruction.result == none {
                    if inferred != none { return Failure(problem(instruction.line, "operation needs a result")) }
                } else {
                    if inferred == none { return Failure(problem(instruction.line, instruction.op + " does not produce a result")) }
                    if instruction.result!.typeName != inferred! { return Failure(problem(instruction.line, instruction.op + " result needs " + inferred!)) }
                    defined.push(instruction.result!)
                    available.push(instruction.result!)
                }
            }
        }
    }
    return Success(none)
}
