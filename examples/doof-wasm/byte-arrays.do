export function main(): int {
  values: byte[] := [1, 2, 255]
  values[1] = 9
  return int(values[0]) + int(values[1]) + int(values[2]) + values.length
}
