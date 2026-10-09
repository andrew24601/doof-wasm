import { MinusControlFlow, minusBlocks, analyzeMinusControlFlow, minusDominates, validateMinusRegions } from "./minus-control-flow"
import { parseByte, parseDouble, parseFloat, parseInt, parseLong } from "std/parse"
import { MinusBlock, MinusClass, MinusEnum, MinusField, MinusFunction, MinusImport, MinusInstruction, MinusInterface, MinusMethod, MinusModule, MinusValue, MinusNameIndex, createMinusNameIndex, lookupMinusName, insertMinusName, minusModuleLookup } from "./minus-ir"
import { classSize } from "./minus-layout"
import { minusReferenceType } from "./minus-analysis"

readonly MAX_BLOCK_SIZE = 1032

function problem(line: int, message: string): string => "line " + string(line) + ": " + message

// Declaration lookups use the module's hashed name indexes; linear scans made
// validation quadratic in the number of classes and functions.
function classByName(module_: MinusModule, name: string): MinusClass | none {
    index := lookupMinusName(minusModuleLookup(module_).classes, name)
    return if index < 0 then none else module_.classes[index]
}

function interfaceByName(module_: MinusModule, name: string): MinusInterface | none {
    index := lookupMinusName(minusModuleLookup(module_).interfaces, name)
    return if index < 0 then none else module_.interfaces[index]
}

function enumByName(module_: MinusModule, name: string): MinusEnum | none {
    index := lookupMinusName(minusModuleLookup(module_).enums, name)
    return if index < 0 then none else module_.enums[index]
}

function functionByName(module_: MinusModule, name: string): MinusFunction | none {
    lookup := minusModuleLookup(module_)
    index := lookupMinusName(lookup.functions, name)
    if index >= 0 { return module_.functions[index] }
    importIndex := lookupMinusName(lookup.imports, name)
    if importIndex < 0 { return none }
    item := module_.imports[importIndex]
    return MinusFunction { name: item.name, params: item.params, result: item.result, line: item.line, sourcePath: item.sourcePath }
}

function numeric(typeName: string): bool => typeName == "byte" || typeName == "int" || typeName == "long" || typeName == "float" || typeName == "double"
function primitive(typeName: string): bool => typeName == "none" || typeName == "bool" || typeName == "char" || numeric(typeName)
function arrayElementType(module_: MinusModule, typeName: string): bool => (typeName != "none" && primitive(typeName)) || minusReferenceType(module_, typeName) || enumByName(module_, typeName) != none
function hostExportType(module_: MinusModule, typeName: string): bool => !minusReferenceType(module_, typeName) || typeName == "__doof_string"

function letter(code: int): bool => (code >= 97 && code <= 122) || (code >= 65 && code <= 90) || code == 95

// ASCII letters or underscore, then letters, digits or underscores, in
// name[start..<end]. Character codes avoid a substring per character.
function identifierRange(name: string, start: int, end_: int): bool {
    if start >= end_ || !letter(int(name[start])) { return false }
    for index of (start + 1)..<end_ {
        code := int(name[index])
        if !letter(code) && !(code >= 48 && code <= 57) { return false }
    }
    return true
}

function identifier(name: string): bool => identifierRange(name, 0, name.length)

function valueName(name: string): bool => name.startsWith("%") && identifierRange(name, 1, name.length)

function functionName(name: string): bool {
    dot := name.indexOf(".")
    if dot < 0 { return identifier(name) }
    return identifierRange(name, 0, dot) && identifierRange(name, dot + 1, name.length)
}

function checkType(module_: MinusModule, typeName: string, line: int): Result<none, string> {
    if primitive(typeName) || typeName == "any" || classByName(module_, typeName) != none || interfaceByName(module_, typeName) != none || enumByName(module_, typeName) != none { return Success(none) }
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

// The values of one function, indexed once. A value is visible at a use when
// it is a function parameter, was defined earlier in the same block, or was
// defined in a block that dominates the using block.
class ValueScope {
    names: MinusNameIndex = MinusNameIndex {}
    types: string[] = []
    definingBlocks: int[] = []
    positions: int[] = []
    blocks: MinusBlock[] = []
    blockNames: MinusNameIndex = MinusNameIndex {}
    let flow: MinusControlFlow = MinusControlFlow {}
    let block: int = 0
    let position: int = 0
}

function valueType(values: ValueScope, name: string, line: int): Result<string, string> {
    id := lookupMinusName(values.names, name)
    if id >= 0 {
        source := values.definingBlocks[id]
        if source < 0 { return Success(values.types[id]) }
        if source == values.block {
            if values.positions[id] < values.position { return Success(values.types[id]) }
        } else if minusDominates(values.flow, source, values.block) { return Success(values.types[id]) }
    }
    return Failure(problem(line, "unknown or out-of-block value " + name))
}

function blockByName(values: ValueScope, name: string): MinusBlock | none {
    index := lookupMinusName(values.blockNames, name)
    return if index < 0 then none else values.blocks[index]
}

function checkArgs(values: ValueScope, args: string[], expected: string[], line: int): Result<none, string> {
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

function checkLiteral(module_: MinusModule, instruction: MinusInstruction, typeName: string): Result<none, string> {
    if instruction.args.length != 1 { return Failure(problem(instruction.line, "const needs one literal")) }
    literal := instruction.args[0]
    if typeName == "none" || typeName == "bool" {
        if (typeName == "none" && literal == "none") || (typeName == "bool" && (literal == "true" || literal == "false")) { return Success(none) }
        return Failure(problem(instruction.line, "invalid " + typeName + " constant"))
    }
    if typeName == "byte" { _ := parseByte(literal) else { return Failure(problem(instruction.line, "invalid byte constant")) }; return Success(none) }
    if typeName == "int" || typeName == "char" {
        parsed := parseInt(literal) else { return Failure(problem(instruction.line, "invalid integer constant")) }
        if typeName == "char" && (parsed < 0 || parsed > 255) { return Failure(problem(instruction.line, "char constant must fit in one UTF-8 byte")) }
        return Success(none)
    }
    if typeName == "long" { _ := parseLong(literal) else { return Failure(problem(instruction.line, "invalid long constant")) }; return Success(none) }
    if typeName == "float" { _ := parseFloat(literal) else { return Failure(problem(instruction.line, "invalid float constant")) }; return Success(none) }
    if typeName == "double" { _ := parseDouble(literal) else { return Failure(problem(instruction.line, "invalid double constant")) }; return Success(none) }
    if enumByName(module_, typeName) != none { _ := parseInt(literal) else { return Failure(problem(instruction.line, "invalid enum constant")) }; return Success(none) }
    return Failure(problem(instruction.line, "const needs a primitive or enum result"))
}

function checkEdge(blocks: MinusBlock[], values: ValueScope, args: string[], line: int): Result<none, string> {
    if args.length == 0 { return Failure(problem(line, "missing block target")) }
    block := blockByName(values, args[0])
    if block == none { return Failure(problem(line, "unknown block " + args[0])) }
    return checkArgs(values, tail(args, 1), paramTypes(block!.params), line)
}

function checkInstruction(module_: MinusModule, function_: MinusFunction, blocks: MinusBlock[], values: ValueScope, instruction: MinusInstruction): Result<string | none, string> {
    args := instruction.args
    line := instruction.line
    op := instruction.op
    resultType := if instruction.result == none then "none" else instruction.result!.typeName
    if op == "const" { try checkLiteral(module_, instruction, resultType); return Success(resultType) }
    if op == "global-get" {
        if args.length != 1 { return Failure(problem(line, "global-get needs one global name")) }
        for global_ of module_.globals { if global_.name == args[0] { return Success(global_.typeName) } }
        return Failure(problem(line, "unknown global " + args[0]))
    }
    if op == "string-const" {
        if args.length != 1 { return Failure(problem(line, "string-const needs one literal")) }
        if resultType != "__doof_string" || classByName(module_, resultType) == none {
            return Failure(problem(line, "string-const needs a __doof_string result"))
        }
        return Success(resultType)
    }
    if (op == "add" || op == "sub" || op == "mul" || op == "div" || op == "rem" || op == "eq" || op == "lt") {
        if args.length != 2 { return Failure(problem(line, op + " needs two operands")) }
        try left := valueType(values, args[0], line)
        try right := valueType(values, args[1], line)
        if op == "rem" && !(left == "byte" || left == "int" || left == "long") { return Failure(problem(line, "rem needs integer operands")) }
        if left != right || (!numeric(left) && !(op == "eq" && (left == "bool" || left == "char" || left == "none" || minusReferenceType(module_, left) || enumByName(module_, left) != none)) && !(op == "lt" && left == "char")) {
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
    if op == "array-alloc" {
        if args.length != 2 { return Failure(problem(line, "array-alloc needs a length and element type")) }
        try lengthType := valueType(values, args[0], line)
        if lengthType != "int" { return Failure(problem(line, "array length needs int")) }
        if !arrayElementType(module_, args[1]) { return Failure(problem(line, "unsupported array element type " + args[1])) }
        return Success("int")
    }
    if op == "array-free" {
        if args.length != 1 && args.length != 2 { return Failure(problem(line, "array-free needs a block handle and optional element type")) }
        try handleType := valueType(values, args[0], line)
        if handleType != "int" { return Failure(problem(line, "array-free needs an int block handle")) }
        if args.length == 2 && !arrayElementType(module_, args[1]) { return Failure(problem(line, "unsupported array element type " + args[1])) }
        return Success(none)
    }
    if op == "array-length" {
        if args.length != 1 { return Failure(problem(line, "array-length needs one block handle")) }
        try handleType := valueType(values, args[0], line)
        if handleType != "int" { return Failure(problem(line, "array-length needs an int block handle")) }
        return Success("int")
    }
    if op == "array-copy" {
        if args.length != 6 { return Failure(problem(line, "array-copy needs destination/index, source/index, count, and scalar element type")) }
        for index of 0..<5 {
            try typeName := valueType(values, args[index], line)
            if typeName != "int" { return Failure(problem(line, "array-copy handles, indexes, and count need int")) }
        }
        if !arrayElementType(module_, args[5]) || minusReferenceType(module_, args[5]) { return Failure(problem(line, "array-copy needs a scalar element type")) }
        return Success(none)
    }
    if op == "array-compare" || op == "array-equal" {
        if args.length != 2 { return Failure(problem(line, op + " needs two byte-array handles")) }
        for arg of args {
            try typeName := valueType(values, arg, line)
            if typeName != "int" { return Failure(problem(line, op + " handles need int")) }
        }
        return Success(if op == "array-equal" then "bool" else "int")
    }
    if op == "array-get" {
        if args.length != 2 { return Failure(problem(line, "array-get needs a block handle and index")) }
        try handleType := valueType(values, args[0], line)
        try indexType := valueType(values, args[1], line)
        if handleType != "int" || indexType != "int" { return Failure(problem(line, "array-get needs int handle and index")) }
        if !arrayElementType(module_, resultType) { return Failure(problem(line, "unsupported array element type " + resultType)) }
        return Success(resultType)
    }
    if op == "array-pop" {
        if args.length != 1 { return Failure(problem(line, "array-pop needs one block handle")) }
        try handleType := valueType(values, args[0], line)
        if handleType != "int" { return Failure(problem(line, "array-pop needs an int block handle")) }
        if !arrayElementType(module_, resultType) { return Failure(problem(line, "unsupported array element type " + resultType)) }
        return Success(resultType)
    }
    if op == "array-reserve" {
        if args.length != 3 { return Failure(problem(line, "array-reserve needs a block handle, capacity, and element type")) }
        try handleType := valueType(values, args[0], line)
        try capacityType := valueType(values, args[1], line)
        if handleType != "int" || capacityType != "int" { return Failure(problem(line, "array-reserve needs int handle and capacity")) }
        if !arrayElementType(module_, args[2]) { return Failure(problem(line, "unsupported array element type " + args[2])) }
        return Success("int")
    }
    if op == "array-push" {
        if args.length != 2 { return Failure(problem(line, "array-push needs a block handle and value")) }
        try handleType := valueType(values, args[0], line)
        try elementType := valueType(values, args[1], line)
        if handleType != "int" { return Failure(problem(line, "array-push needs an int block handle")) }
        if !arrayElementType(module_, elementType) { return Failure(problem(line, "unsupported array element type " + elementType)) }
        return Success("int")
    }
    if op == "array-set" {
        if args.length != 3 { return Failure(problem(line, "array-set needs a block handle, index, and value")) }
        try handleType := valueType(values, args[0], line)
        try indexType := valueType(values, args[1], line)
        try elementType := valueType(values, args[2], line)
        if handleType != "int" || indexType != "int" { return Failure(problem(line, "array-set needs int handle and index")) }
        if !arrayElementType(module_, elementType) { return Failure(problem(line, "unsupported array element type " + elementType)) }
        return Success(none)
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
        if op == "box" && args.length == 2 {
            class_ := classByName(module_, args[0])
            if class_ == none || class_!.fields.length != 1 || !class_!.fields[0].mutable {
                return Failure(problem(line, "box cell needs a class with one mutable field"))
            }
            try source := valueType(values, args[1], line)
            if source != class_!.fields[0].typeName || resultType != class_!.name {
                return Failure(problem(line, "box cell value and result need the cell field type and class"))
            }
            return Success(resultType)
        }
        if args.length != 1 { return Failure(problem(line, op + " needs one value")) }
        try source := valueType(values, args[0], line)
        if op == "copy" { return Success(source) }
        if op == "box" {
            if source == "any" { return Failure(problem(line, "box needs a primitive, enum, class, or interface")) }
            return Success("any")
        }
        if op == "as" {
            class_ := classByName(module_, source)
            if class_ == none || !class_!.interfaces.contains(resultType) { return Failure(problem(line, "class does not implement " + resultType)) }
            return Success(resultType)
        }
        if (!numeric(source) && source != "char" && enumByName(module_, source) == none) || !numeric(resultType) { return Failure(problem(line, "convert needs a numeric, char, or enum source and numeric result")) }
        return Success(resultType)
    }
    if op == "is" || op == "cast" {
        if args.length != 2 { return Failure(problem(line, op + " needs an any value and type")) }
        try source := valueType(values, args[0], line)
        if source != "any" { return Failure(problem(line, op + " needs any")) }
        try checkType(module_, args[1], line)
        if args[1] == "any" { return Failure(problem(line, op + " needs a primitive, class, or interface target")) }
        return Success(if op == "is" then "bool" else args[1])
    }
    if op == "drop" {
        if args.length != 1 { return Failure(problem(line, "drop needs one reference value")) }
        try source := valueType(values, args[0], line)
        if source != "any" && classByName(module_, source) == none && interfaceByName(module_, source) == none { return Failure(problem(line, "drop needs a reference value")) }
        return Success(none)
    }
    if op == "return" {
        if args.length > 1 { return Failure(problem(line, "return takes at most one value")) }
        let typeName = "none"
        if args.length == 1 { try known := valueType(values, args[0], line); typeName = known }
        if typeName != function_.result { return Failure(problem(line, "return needs " + function_.result)) }
        return Success(none)
    }
    if op == "panic" {
        if args.length > 1 || (args.length == 1 && !module_.recoverPanics) { return Failure(problem(line, "panic message requires self-hosting panic recovery")) }
        if args.length == 1 {
            try messageType := valueType(values, args[0], line)
            if messageType != "__doof_string" { return Failure(problem(line, "panic message must be a string")) }
        }
        return Success(none)
    }
    if op == "jump" { try checkEdge(blocks, values, args, line); return Success(none) }
    if op == "branch" {
        if args.length < 4 { return Failure(problem(line, "branch needs two targets")) }
        try condition := valueType(values, args[0], line)
        if condition != "bool" { return Failure(problem(line, "branch condition needs bool")) }
        let split = -1
        for index of 1..<args.length { if args[index] == "|" { split = index; break } }
        if split < 0 { return Failure(problem(line, "branch needs two targets")) }
        let first: string[] = []
        for index of 1..<split { first.push(args[index]) }
        try checkEdge(blocks, values, first, line)
        try checkEdge(blocks, values, tail(args, split + 1), line)
        return Success(none)
    }
    return Failure(problem(line, "unknown instruction " + op))
}

export function validateDoofMinus(module_: MinusModule): Result<none, string> {
    for index of 0..<module_.globals.length {
        global_ := module_.globals[index]
        if !identifier(global_.name) { return Failure(problem(global_.line, "invalid global name")) }
        try checkType(module_, global_.typeName, global_.line)
        if global_.typeName == "none" { return Failure(problem(global_.line, "global cannot have type none")) }
        for previous of 0..<index { if module_.globals[previous].name == global_.name { return Failure(problem(global_.line, "duplicate global")) } }
        let initializer: MinusFunction | none = none
        initializerIndex := lookupMinusName(minusModuleLookup(module_).functions, global_.initializer)
        if initializerIndex >= 0 { initializer = module_.functions[initializerIndex] }
        if initializer == none || initializer!.exported || initializer!.capturePanics || initializer!.params.length != 0 || initializer!.result != global_.typeName {
            return Failure(problem(global_.line, "global initializer must name a private function with no parameters returning its type"))
        }
    }
    for index of 0..<module_.classes.length {
        class_ := module_.classes[index]
        if !identifier(class_.name) { return Failure(problem(class_.line, "invalid class name")) }
        if primitive(class_.name) || class_.name == "any" { return Failure(problem(class_.line, "reserved class name")) }
        if lookupMinusName(minusModuleLookup(module_).classes, class_.name) != index { return Failure(problem(class_.line, "duplicate class")) }
        if interfaceByName(module_, class_.name) != none { return Failure(problem(class_.line, "class and interface names collide")) }
    }
    for index of 0..<module_.interfaces.length {
        interface_ := module_.interfaces[index]
        if !identifier(interface_.name) { return Failure(problem(interface_.line, "invalid interface name")) }
        if primitive(interface_.name) || interface_.name == "any" { return Failure(problem(interface_.line, "reserved interface name")) }
        if lookupMinusName(minusModuleLookup(module_).interfaces, interface_.name) != index { return Failure(problem(interface_.line, "duplicate interface")) }
    }
    for owner of module_.classes {
        for index of 0..<owner.fields.length {
            field := owner.fields[index]
            if !identifier(field.name) { return Failure(problem(field.line, "invalid field name")) }
            try checkType(module_, field.typeName, field.line)
            for previous of 0..<index { if owner.fields[previous].name == field.name { return Failure(problem(field.line, "duplicate field")) } }
        }
        if classSize(owner) > MAX_BLOCK_SIZE { return Failure(problem(owner.line, "class allocation exceeds 1032 bytes")) }
        if owner.finalizer != "" {
            finalizerFunction := functionByName(module_, owner.finalizer)
            if finalizerFunction == none || finalizerFunction!.exported || finalizerFunction!.result != "none" || finalizerFunction!.params.length != 1 || finalizerFunction!.params[0].typeName != owner.name {
                return Failure(problem(owner.line, "destructor must name a private function taking its class and returning none"))
            }
        }
    }
    for index of 0..<module_.enums.length {
        enum_ := module_.enums[index]
        if !identifier(enum_.name) || primitive(enum_.name) || enum_.name == "any" { return Failure(problem(enum_.line, "invalid enum name")) }
        if classByName(module_, enum_.name) != none || interfaceByName(module_, enum_.name) != none { return Failure(problem(enum_.line, "enum name collides with another type")) }
        if lookupMinusName(minusModuleLookup(module_).enums, enum_.name) != index { return Failure(problem(enum_.line, "duplicate enum")) }
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
        if function_.capturePanics && (!module_.recoverPanics || function_.result != "any") { return Failure(problem(function_.line, "panic capture requires recovery mode and a Result represented as any")) }
        if function_.capturePanics {
            failure := classByName(module_, "__doof_result_failure")
            if classByName(module_, "__doof_string") == none || failure == none { return Failure(problem(function_.line, "panic capture needs string and Failure runtime classes")) }
            if failure!.fields.length != 1 || failure!.fields[0].typeName != "any" { return Failure(problem(function_.line, "panic capture needs a single boxed Failure error field")) }
        }
        if !functionName(function_.name) { return Failure(problem(function_.line, "invalid function name")) }
        if lookupMinusName(minusModuleLookup(module_).functions, function_.name) != index { return Failure(problem(function_.line, "duplicate function")) }
        try checkType(module_, function_.result, function_.line)
        exportName := if function_.exportName == "" then function_.name else function_.exportName
        if function_.exported && (exportName == "__doof_panic_tag" || exportName == "__doof_ffi_alloc" || exportName == "__doof_ffi_release" || exportName == "__doof_ffi_memory" || exportName == "__doof_debug_heap_end") { return Failure(problem(function_.line, "export name is reserved by the Wasm host bindings")) }
        if function_.exported && !hostExportType(module_, function_.result) { return Failure(problem(function_.line, "export result must be primitive or string")) }
        blocks := minusBlocks(function_)
        let valueCount = function_.params.length
        for block of blocks {
            valueCount += block.params.length
            for instruction of block.instructions { if instruction.result != none { valueCount += 1 } }
        }
        values := ValueScope { names: createMinusNameIndex(valueCount), blockNames: createMinusNameIndex(blocks.length), blocks }
        for param of function_.params {
            if !valueName(param.name) { return Failure(problem(function_.line, "invalid parameter name")) }
            try checkType(module_, param.typeName, function_.line)
            if function_.exported && !hostExportType(module_, param.typeName) { return Failure(problem(function_.line, "export parameter must be primitive or string")) }
            if lookupMinusName(values.names, param.name) >= 0 { return Failure(problem(function_.line, "duplicate parameter")) }
            _ := insertMinusName(values.names, param.name)
            values.types.push(param.typeName); values.definingBlocks.push(-1); values.positions.push(-1)
        }
        dot := function_.name.indexOf(".")
        if dot >= 0 {
            className := function_.name.substring(0, dot)
            if classByName(module_, className) == none || function_.params.length == 0 || function_.params[0].typeName != className { return Failure(problem(function_.line, "class method needs a class receiver first")) }
        }
        if blocks.length == 0 { return Failure(problem(function_.line, "function needs a block")) }
        if blocks[0].params.length != 0 { return Failure(problem(blocks[0].line, "entry block cannot have parameters")) }
        flow := analyzeMinusControlFlow(blocks)
        values.flow = flow
        for blockIndex_ of 0..<blocks.length {
            block := blocks[blockIndex_]
            if !identifier(block.name) { return Failure(problem(block.line, "invalid block name")) }
            if lookupMinusName(values.blockNames, block.name) >= 0 { return Failure(problem(block.line, "duplicate block")) }
            _ := insertMinusName(values.blockNames, block.name)
            for param of block.params {
                if !valueName(param.name) { return Failure(problem(block.line, "invalid block parameter name")) }
                try checkType(module_, param.typeName, block.line)
                if lookupMinusName(values.names, param.name) >= 0 { return Failure(problem(block.line, "duplicate value " + param.name)) }
                _ := insertMinusName(values.names, param.name)
                values.types.push(param.typeName); values.definingBlocks.push(blockIndex_); values.positions.push(-1)
            }
        }
        // Index every result before checking uses: a dominating block may be
        // laid out after the block that uses its values.
        for blockIndex_ of 0..<blocks.length {
            block := blocks[blockIndex_]
            for position of 0..<block.instructions.length {
                instruction := block.instructions[position]
                if instruction.result == none { continue }
                if !valueName(instruction.result!.name) { return Failure(problem(instruction.line, "invalid value name")) }
                if lookupMinusName(values.names, instruction.result!.name) >= 0 { return Failure(problem(instruction.line, "duplicate value " + instruction.result!.name)) }
                _ := insertMinusName(values.names, instruction.result!.name)
                values.types.push(instruction.result!.typeName); values.definingBlocks.push(blockIndex_); values.positions.push(position)
            }
        }
        for blockIndex_ of 0..<blocks.length {
            block := blocks[blockIndex_]
            if block.instructions.length == 0 { return Failure(problem(block.line, "empty block")) }
            values.block = blockIndex_
            for position of 0..<block.instructions.length {
                instruction := block.instructions[position]
                values.position = position
                terminal := instruction.op == "return" || instruction.op == "jump" || instruction.op == "branch" || instruction.op == "panic"
                if terminal != (position == block.instructions.length - 1) { return Failure(problem(instruction.line, "block terminator must be last")) }
                if instruction.result != none { try checkType(module_, instruction.result!.typeName, instruction.line) }
                let inferred: string | none = none
                case checkInstruction(module_, function_, blocks, values, instruction) {
                  success: Success -> { inferred = success.value }
                  failure: Failure -> {
                    error := failure.error
                    path := if instruction.sourcePath == "" then function_.sourcePath else instruction.sourcePath
                    return Failure(if path == "" then error else path + ": " + error)
                  }
                }
                if instruction.result == none {
                    if inferred != none { return Failure(problem(instruction.line, "operation needs a result")) }
                } else {
                    if inferred == none { return Failure(problem(instruction.line, instruction.op + " does not produce a result")) }
                    if instruction.result!.typeName != inferred! { return Failure(problem(instruction.line, instruction.op + " result needs " + inferred!)) }
                }
            }
        }
        if !validateMinusRegions(function_, flow) { return Failure(problem(function_.line, "invalid structured control flow: branches must target an enclosing scope or loop")) }
    }
    for index of 0..<module_.imports.length {
        import_ := module_.imports[index]
        if !functionName(import_.name) || import_.importModule == "" || import_.importName == "" { return Failure(problem(import_.line, "invalid host import declaration")) }
        for previous of 0..<index {
            prior := module_.imports[previous]
            if prior.name == import_.name { return Failure(problem(import_.line, "duplicate host import")) }
            if prior.importModule == import_.importModule && prior.importName == import_.importName {
                if prior.result != import_.result || prior.params.length != import_.params.length { return Failure(problem(import_.line, "host imports sharing a JS binding must have the same signature")) }
                for paramIndex of 0..<prior.params.length {
                    if prior.params[paramIndex].typeName != import_.params[paramIndex].typeName { return Failure(problem(import_.line, "host imports sharing a JS binding must have the same signature")) }
                }
            }
        }
        if lookupMinusName(minusModuleLookup(module_).functions, import_.name) >= 0 { return Failure(problem(import_.line, "host import conflicts with function")) }
        try checkType(module_, import_.result, import_.line)
        if !hostExportType(module_, import_.result) { return Failure(problem(import_.line, "host import result must be primitive or string")) }
        for parameter of import_.params {
            try checkType(module_, parameter.typeName, import_.line)
            if !hostExportType(module_, parameter.typeName) { return Failure(problem(import_.line, "host import parameter must be primitive or string")) }
        }
    }
    return Success(none)
}
