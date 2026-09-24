function maybePositive(value: int): int | none {
    if value > 0 {
        return value
    }
    return none
}

export function classify(value: int): int {
    optional := maybePositive(value)
    case optional {
        present: int -> {
            if present > 10 {
                return present
            } else if present > 0 {
                return present + 1
            } else {
                return 0
            }
        }
        none -> {
            return -1
        }
    }
}

export function unwrapOrMinusOne(value: int | none): int {
    present := value else {
        return -1
    }
    return present
}
