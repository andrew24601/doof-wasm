function twice(value: int): int => value * 2

export function answer(): int {
    readonly base = 20
    return twice(base) + 2
}

export function widen(value: int): double => double(value)
