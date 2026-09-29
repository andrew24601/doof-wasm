// The decimal parsing surface used by the self-hosted encoder.
export enum ParsingError { InvalidFormat = 0, Overflow = 1, Underflow = 2, EmptyInput = 3, InvalidRadix = 4, NonFinite = 5 }

export function parseLong(value: string): Result<long, ParsingError> {
  if value.length == 0 { return Failure(ParsingError.EmptyInput) }
  let index = 0
  let negative = false
  if value[0] == '-' || value[0] == '+' { negative = value[0] == '-'; index = 1 }
  if index == value.length { return Failure(ParsingError.InvalidFormat) }
  for position of index..<value.length {
    if value[position] < '0' || value[position] > '9' { return Failure(ParsingError.InvalidFormat) }
  }
  // Accumulate negatively so the minimum signed value is representable.
  limit := if negative then -9223372036854775807L - 1L else -9223372036854775807L
  let result = 0L
  while index < value.length {
    digit := long(int(value[index]) - 48)
    if digit < 0L || digit > 9L { return Failure(ParsingError.InvalidFormat) }
    if result < limit \ 10L { return Failure(if negative then ParsingError.Underflow else ParsingError.Overflow) }
    result *= 10L
    if result < limit + digit { return Failure(if negative then ParsingError.Underflow else ParsingError.Overflow) }
    result -= digit
    index += 1
  }
  return Success(if negative then result else -result)
}

export function parseInt(value: string): Result<int, ParsingError> {
  try parsed := parseLong(value)
  if parsed < -2147483648L { return Failure(ParsingError.Underflow) }
  if parsed > 2147483647L { return Failure(ParsingError.Overflow) }
  return Success(int(parsed))
}

export function parseByte(value: string): Result<byte, ParsingError> {
  try parsed := parseLong(value)
  if parsed < 0L { return Failure(ParsingError.Underflow) }
  if parsed > 255L { return Failure(ParsingError.Overflow) }
  return Success(byte(parsed))
}

// Host conversion provides correctly rounded IEEE values. Status is a
// ParsingError ordinal, or -1 on success; no Result values cross the ABI.
import function doofStdFloatStatus(value: string, single: bool): int
import function doofStdParseDouble(value: string): double
import function doofStdParseFloat(value: string): float

function parsingError(status: int): ParsingError {
  if status == 1 { return ParsingError.Overflow }
  if status == 2 { return ParsingError.Underflow }
  if status == 3 { return ParsingError.EmptyInput }
  if status == 5 { return ParsingError.NonFinite }
  return ParsingError.InvalidFormat
}

export function parseDouble(value: string): Result<double, ParsingError> {
  status := doofStdFloatStatus(value, false)
  if status >= 0 { return Failure(parsingError(status)) }
  return Success(doofStdParseDouble(value))
}

export function parseFloat(value: string): Result<float, ParsingError> {
  status := doofStdFloatStatus(value, true)
  if status >= 0 { return Failure(parsingError(status)) }
  return Success(doofStdParseFloat(value))
}
