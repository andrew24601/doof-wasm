import { Assert } from "std/assert"
import { encodeModule } from "./encode"
import { Call, F32Add, F32Const, F64Const, FuncType, Function, FunctionExport, FunctionImport, I32Add, I32Const, LocalGet, Module, ValueType } from "./ir"
import { validateModule } from "./validate"

function assertBytes(actual: byte[], expectedBytes: byte[]): none {
    Assert.equal(actual.length, expectedBytes.length)
    for index of 0..<actual.length { Assert.equal(actual[index], expectedBytes[index]) }
}

export function testEmptyModule(): none {
    bytes := try! encodeModule(Module {})
    expectedBytes: byte[] := [0, 97, 115, 109, 1, 0, 0, 0]
    assertBytes(bytes, expectedBytes)
}

export function testHostImportAndGuestExport(): none {
    type_ := FuncType { params: [ValueType.I32], results: [ValueType.I32] }
    module_ := Module {
        imports: [FunctionImport { module: "host", name: "tick", type_ }],
        functions: [Function { type_, body: [LocalGet { index: 0 }, Call { functionIndex: 0 }] }],
        exports: [FunctionExport { name: "run", functionIndex: 1 }],
    }
    bytes := try! encodeModule(module_)
    expectedBytes: byte[] := [
        0, 97, 115, 109, 1, 0, 0, 0,
        1, 11, 2, 96, 1, 127, 1, 127, 96, 1, 127, 1, 127,
        2, 13, 1, 4, 104, 111, 115, 116, 4, 116, 105, 99, 107, 0, 0,
        3, 2, 1, 1,
        7, 7, 1, 3, 114, 117, 110, 0, 1,
        10, 8, 1, 6, 0, 32, 0, 16, 0, 11,
    ]
    assertBytes(bytes, expectedBytes)
}

export function testSignedConstants(): none {
    type_ := FuncType { results: [ValueType.I32] }
    bytes := try! encodeModule(Module {
        functions: [Function { type_, body: [I32Const { value: -65 }, I32Const { value: 1 }, I32Add {}] }],
    })
    // -65 uses two signed LEB bytes; 1 uses one.
    expectedBytes: byte[] := [65, 191, 127, 65, 1, 106, 11]
    assertBytes(bytes.slice(bytes.length - expectedBytes.length, bytes.length), expectedBytes)
}

export function testFloatingPointEncoding(): none {
    type_ := FuncType { results: [ValueType.F32] }
    bytes := try! encodeModule(Module {
        functions: [Function { type_, body: [F32Const { value: 1.5f }, F32Const { value: 2.0f }, F32Add {}] }],
    })
    let expectedBytes: byte[] = [67, 0, 0, 192, 63, 67, 0, 0, 0, 64, 146, 11]
    assertBytes(bytes.slice(bytes.length - expectedBytes.length, bytes.length), expectedBytes)
    doubleBytes := try! encodeModule(Module {
        functions: [Function { type_: FuncType { results: [ValueType.F64] }, body: [F64Const { value: 1.5 }] }],
    })
    let doubleTail: byte[] = [68, 0, 0, 0, 0, 0, 0, 248, 63, 11]
    assertBytes(doubleBytes.slice(doubleBytes.length - doubleTail.length, doubleBytes.length), doubleTail)
}

export function testRejectsInvalidCallAndStack(): none {
    type_ := FuncType { results: [ValueType.I32] }
    badCall := Module { functions: [Function { type_, body: [Call { functionIndex: 3 }] }] }
    callResult := validateModule(badCall)
    case callResult {
        failure: Failure<string> -> { Assert.stringContains(failure.error, "invalid function index") }
        _ -> { Assert.fail("Expected an invalid call") }
    }
    badStack := Module { functions: [Function { type_, body: [I32Add {}] }] }
    stackResult := validateModule(badStack)
    case stackResult {
        failure: Failure<string> -> { Assert.stringContains(failure.error, "requires a value") }
        _ -> { Assert.fail("Expected a stack error") }
    }
}

export function testRejectsDuplicateExports(): none {
    type_ := FuncType {}
    module_ := Module {
        functions: [Function { type_ }],
        exports: [
            FunctionExport { name: "run", functionIndex: 0 },
            FunctionExport { name: "run", functionIndex: 0 },
        ],
    }
    result := validateModule(module_)
    case result {
        failure: Failure<string> -> { Assert.stringContains(failure.error, "Duplicate export") }
        _ -> { Assert.fail("Expected duplicate export rejection") }
    }
}
