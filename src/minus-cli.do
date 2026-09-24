import { readText, writeBlob } from "std/fs"
import { compileDoofMinus } from "./minus-wasm"

function main(arguments: string[]): int {
    if arguments.length != 2 {
        println("usage: doof-minus input.dm output.wasm")
        return 2
    }
    source := readText(arguments[0]) else {
        println("could not read " + arguments[0])
        return 1
    }
    compiled := compileDoofMinus(source)
    let bytes: byte[] = []
    case compiled {
        success: Success<byte[]> -> { bytes = success.value }
        failure: Failure<string> -> { println("compile error: " + failure.error); return 1 }
    }
    _ := writeBlob(arguments[1], bytes.cloneReadonly()) else {
        println("could not write " + arguments[1])
        return 1
    }
    return 0
}
