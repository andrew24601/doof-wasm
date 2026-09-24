interface Reader {
    read(): int
}

class Counter implements Reader {
    let value: int

    increment(): none {
        this.value = this.value + 1
    }

    read(): int => this.value
}

export function readAfterIncrement(initial: int): int {
    let counter = Counter { value: initial }
    counter.increment()
    let reader: Reader = counter
    return reader.read()
}
