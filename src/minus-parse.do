import { MinusBlock, MinusClass, MinusField, MinusFunction, MinusInstruction, MinusInterface, MinusMethod, MinusModule, MinusValue } from "./minus-ir"

function tokens(line: string): string[] {
    let result: string[] = []
    let word = ""
    let index = 0
    while index < line.length {
        ch := line.substring(index, index + 1)
        if ch == "#" { break }
        if ch == "." && word != "" && index + 1 < line.length &&
            "0123456789".contains(word.substring(word.length - 1, word.length)) &&
            "0123456789".contains(line.substring(index + 1, index + 2)) {
            word += ch
        } else if ch == " " || ch == "\t" || ch == "\r" || ch == "(" || ch == ")" || ch == ":" || ch == "," || ch == "=" || ch == "." {
            if word != "" { result.push(word); word = "" }
            if ch != " " && ch != "\t" && ch != "\r" { result.push(ch) }
        } else if ch == "-" && index + 1 < line.length && line.substring(index + 1, index + 2) == ">" {
            if word != "" { result.push(word); word = "" }
            result.push("->")
            index += 1
        } else { word += ch }
        index += 1
    }
    if word != "" { result.push(word) }
    return result
}

function diagnostic(line: int, message: string): string => "line " + string(line) + ": " + message

function nameAt(parts: string[], index: int, line: int): Result<string, string> {
    if index >= parts.length || parts[index] == "" { return Failure(diagnostic(line, "missing name")) }
    return Success(parts[index])
}

function parseParams(parts: string[], start: int, named: bool, line: int): Result<MinusValue[], string> {
    if start >= parts.length || parts[start] != "(" { return Failure(diagnostic(line, "expected (")) }
    let values: MinusValue[] = []
    let index = start + 1
    while index < parts.length && parts[index] != ")" {
        if named {
            if index + 2 >= parts.length || parts[index + 1] != ":" { return Failure(diagnostic(line, "expected name:type parameter")) }
            values.push(MinusValue { name: parts[index], typeName: parts[index + 2] })
            index += 3
        } else {
            values.push(MinusValue { name: "", typeName: parts[index] })
            index += 1
        }
        if index < parts.length && parts[index] == "," { index += 1 }
        else if index < parts.length && parts[index] != ")" { return Failure(diagnostic(line, "expected , or )")) }
    }
    if index >= parts.length { return Failure(diagnostic(line, "missing )")) }
    return Success(values)
}

function closeIndex(parts: string[], start: int): int {
    for index of start..<parts.length { if parts[index] == ")" { return index } }
    return -1
}

function operands(parts: string[], start: int): string[] {
    let result: string[] = []
    for index of start..<parts.length {
        if parts[index] != "(" && parts[index] != ")" && parts[index] != "," && parts[index] != "=" {
            result.push(parts[index])
        }
    }
    return result
}

function parseInstruction(parts: string[], line: int): Result<MinusInstruction, string> {
    let index = 0
    let result: MinusValue | none = none
    if parts.length >= 4 && parts[1] == ":" && parts[3] == "=" {
        result = MinusValue { name: parts[0], typeName: parts[2] }
        index = 4
    }
    if index >= parts.length { return Failure(diagnostic(line, "missing instruction")) }
    op := parts[index]
    if op == "set" || op == "get" {
        if index + 3 >= parts.length || parts[index + 2] != "." { return Failure(diagnostic(line, "expected object.field")) }
        if op == "get" {
            if result == none || index + 4 != parts.length { return Failure(diagnostic(line, "invalid get")) }
            return Success(MinusInstruction { op, result, args: [parts[index + 1], parts[index + 3]], line })
        }
        if result != none || index + 6 != parts.length || parts[index + 4] != "=" { return Failure(diagnostic(line, "invalid set")) }
        return Success(MinusInstruction { op, args: [parts[index + 1], parts[index + 3], parts[index + 5]], line })
    }
    if op == "call" {
        if result == none || index + 2 >= parts.length { return Failure(diagnostic(line, "invalid call")) }
        if index + 3 < parts.length && parts[index + 2] == "." {
            if index + 4 >= parts.length || parts[index + 4] != "(" || parts[parts.length - 1] != ")" { return Failure(diagnostic(line, "expected method arguments")) }
            let args: string[] = [parts[index + 1], parts[index + 3]]
            for item of operands(parts, index + 5) { args.push(item) }
            return Success(MinusInstruction { op: "call-method", result, args, line })
        }
        if parts[index + 2] != "(" || parts[parts.length - 1] != ")" { return Failure(diagnostic(line, "expected call arguments")) }
        let args: string[] = [parts[index + 1]]
        for item of operands(parts, index + 3) { args.push(item) }
        return Success(MinusInstruction { op, result, args, line })
    }
    if op == "branch" {
        if result != none || index + 3 >= parts.length { return Failure(diagnostic(line, "invalid branch")) }
        firstClose := closeIndex(parts, index + 3)
        if firstClose < 0 || firstClose + 2 >= parts.length || parts[index + 3] != "(" || parts[firstClose + 2] != "(" || parts[parts.length - 1] != ")" {
            return Failure(diagnostic(line, "branch needs two block targets"))
        }
        let args: string[] = [parts[index + 1], parts[index + 2]]
        for cursor of (index + 4)..<firstClose { if parts[cursor] != "," { args.push(parts[cursor]) } }
        args.push("|")
        args.push(parts[firstClose + 1])
        for cursor of (firstClose + 3)..<parts.length { if parts[cursor] != "," && parts[cursor] != ")" { args.push(parts[cursor]) } }
        return Success(MinusInstruction { op, args, line })
    }
    if op == "jump" {
        if result != none || index + 2 >= parts.length || parts[index + 2] != "(" || parts[parts.length - 1] != ")" { return Failure(diagnostic(line, "invalid jump")) }
        let args: string[] = [parts[index + 1]]
        for item of operands(parts, index + 3) { args.push(item) }
        return Success(MinusInstruction { op, args, line })
    }
    if op == "new" && (index + 2 >= parts.length || parts[index + 2] != "(" || parts[parts.length - 1] != ")") { return Failure(diagnostic(line, "invalid construction")) }
    return Success(MinusInstruction { op, result, args: operands(parts, index + 1), line })
}

export function parseDoofMinus(source: string): Result<MinusModule, string> {
    let module_ = MinusModule {}
    let currentClass: MinusClass | none = none
    let currentInterface: MinusInterface | none = none
    let currentFunction: MinusFunction | none = none
    let currentBlock: MinusBlock | none = none
    lines := source.split("\n")
    for offset of 0..<lines.length {
        line := offset + 1
        parts := tokens(lines[offset])
        if parts.length == 0 { continue }
        if parts[0] == "end" {
            if parts.length != 1 || (currentClass == none && currentInterface == none && currentFunction == none) { return Failure(diagnostic(line, "unexpected end")) }
            if currentFunction != none && currentFunction!.blocks.length == 0 { return Failure(diagnostic(line, "function needs a block")) }
            currentClass = none; currentInterface = none; currentFunction = none; currentBlock = none
            continue
        }
        if currentClass == none && currentInterface == none && currentFunction == none {
            if parts[0] == "class" {
                if parts.length < 2 { return Failure(diagnostic(line, "class needs a name")) }
                let interfaces: string[] = []
                if parts.length > 2 {
                    if parts[2] != "implements" { return Failure(diagnostic(line, "expected implements")) }
                    for cursor of 3..<parts.length { if parts[cursor] != "," { interfaces.push(parts[cursor]) } }
                    if interfaces.length == 0 { return Failure(diagnostic(line, "implements needs an interface")) }
                }
                currentClass = MinusClass { name: parts[1], interfaces, line }
                module_.classes.push(currentClass!)
                continue
            }
            if parts[0] == "interface" {
                if parts.length != 2 { return Failure(diagnostic(line, "interface needs a name")) }
                currentInterface = MinusInterface { name: parts[1], line }
                module_.interfaces.push(currentInterface!)
                continue
            }
            let offset_ = 0
            let exported = false
            if parts[0] == "export" { exported = true; offset_ = 1 }
            if parts.length > offset_ + 3 && parts[offset_] == "func" {
                let name = parts[offset_ + 1]
                let paramsStart = offset_ + 2
                if paramsStart + 2 < parts.length && parts[paramsStart] == "." {
                    name += "." + parts[paramsStart + 1]
                    paramsStart += 2
                }
                try params := parseParams(parts, paramsStart, true, line)
                endIndex := closeIndex(parts, paramsStart)
                if endIndex + 2 >= parts.length || parts[endIndex + 1] != "->" || endIndex + 3 != parts.length { return Failure(diagnostic(line, "invalid function signature")) }
                currentFunction = MinusFunction { name, params, result: parts[endIndex + 2], exported, line }
                module_.functions.push(currentFunction!)
                continue
            }
            return Failure(diagnostic(line, "invalid declaration"))
        }
        if currentClass != none || currentInterface != none {
            if currentClass != none && parts[0] == "destructor" {
                if (parts.length != 2 && parts.length != 4) || (parts.length == 4 && parts[2] != ".") || currentClass!.finalizer != "" { return Failure(diagnostic(line, "destructor needs one function name")) }
                currentClass!.finalizer = if parts.length == 2 then parts[1] else parts[1] + "." + parts[3]
                continue
            }
            if parts[0] == "field" {
                let index = 1
                let mutable = false
                if parts.length > 1 && parts[1] == "let" { mutable = true; index = 2 }
                if index + 2 >= parts.length || parts[index + 1] != ":" || index + 3 != parts.length { return Failure(diagnostic(line, "expected field name:type")) }
                field := MinusField { name: parts[index], typeName: parts[index + 2], mutable, line }
                if currentClass != none { currentClass!.fields.push(field) } else { currentInterface!.fields.push(field) }
                continue
            }
            if currentInterface != none && parts[0] == "method" && parts.length > 4 {
                try params := parseParams(parts, 2, false, line)
                endIndex := closeIndex(parts, 2)
                if endIndex + 3 != parts.length || parts[endIndex + 1] != "->" { return Failure(diagnostic(line, "invalid method signature")) }
                let types: string[] = []
                for param of params { types.push(param.typeName) }
                currentInterface!.methods.push(MinusMethod { name: parts[1], params: types, result: parts[endIndex + 2], line })
                continue
            }
            return Failure(diagnostic(line, "invalid type member"))
        }
        if parts[0] == "block" {
            if parts.length < 2 { return Failure(diagnostic(line, "block needs a name")) }
            let params: MinusValue[] = []
            if parts.length > 2 {
                try parsedParams := parseParams(parts, 2, true, line)
                if closeIndex(parts, 2) != parts.length - 1 { return Failure(diagnostic(line, "invalid block parameters")) }
                params = parsedParams
            }
            currentBlock = MinusBlock { name: parts[1], params, line }
            currentFunction!.blocks.push(currentBlock!)
            continue
        }
        if currentBlock == none { return Failure(diagnostic(line, "instruction outside block")) }
        try instruction := parseInstruction(parts, line)
        currentBlock!.instructions.push(instruction)
    }
    if currentClass != none || currentInterface != none || currentFunction != none { return Failure("unterminated declaration") }
    return Success(module_)
}
