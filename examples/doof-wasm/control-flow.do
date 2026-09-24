export function absolute(value: int): int {
    let result = value
    if value < 0 {
        result = 0 - value
    }
    return result
}

export function sumTo(limit: int): int {
    let total = 0
    let current = 0
    while current < limit {
        total = total + current
        current = current + 1
    }
    return total
}
