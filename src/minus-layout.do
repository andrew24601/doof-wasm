import { MinusClass } from "./minus-ir"

// Live fields use their natural Wasm storage width. The four-byte common
// header is followed by a four-byte reference count, so class content starts
// eight-byte aligned. Allocations use the runtime's reusable size classes.
readonly MIN_BLOCK_SIZE = 24
readonly BLOCK_SIZE_STEP = 16

export function fieldWidth(typeName: string): int {
    if typeName == "none" { return 0 }
    if typeName == "bool" || typeName == "byte" { return 1 }
    if typeName == "short" { return 2 }
    if typeName == "long" || typeName == "double" { return 8 }
    if typeName == "char" { return 1 }
    return 4 // int, float, class, interface, any
}

function align(value: int, width: int): int {
    if width == 0 { return value }
    return value + (width - value % width) % width
}

export function classFieldOffset(class_: MinusClass, fieldIndex: int): int {
    let cursor = 8
    for index of 0..fieldIndex {
        width := fieldWidth(class_.fields[index].typeName)
        cursor = align(cursor, width)
        if index == fieldIndex { return cursor }
        cursor += width
    }
    panic("invalid class field index")
}

export function classSize(class_: MinusClass): int {
    let cursor = 8
    for field of class_.fields {
        width := fieldWidth(field.typeName)
        cursor = align(cursor, width) + width
    }
    if cursor <= MIN_BLOCK_SIZE { return MIN_BLOCK_SIZE }
    return MIN_BLOCK_SIZE + align(cursor - MIN_BLOCK_SIZE, BLOCK_SIZE_STEP)
}
