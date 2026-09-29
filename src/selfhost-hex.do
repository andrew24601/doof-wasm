// Bound leaf concatenation and combine equally sized ranges. Artifact publication
// copies O(n log n) characters instead of repeatedly copying an ever-growing hex
// string. This stays within the portable byte-character ABI.
function encodeRange(bytes: byte[], start: int, end: int): string {
  if end - start > 256 {
    middle := start + (end - start) \ 2
    return encodeRange(bytes, start, middle) + encodeRange(bytes, middle, end)
  }
  digits := "0123456789abcdef"
  let hex = ""
  for index of start..<end {
    value := int(bytes[index])
    hex += digits.substring(value \ 16, value \ 16 + 1)
    hex += digits.substring(value % 16, value % 16 + 1)
  }
  return hex
}

export function encodeWasmHex(bytes: byte[]): string => encodeRange(bytes, 0, bytes.length)
